#!/bin/sh
# =============================================================================
# College WiFi — FAS (Forward Authentication Service) Handler
# =============================================================================
#
# This script runs on the OpenWrt router and acts as the bridge between
# openNDS and the college-wifi RPC backend.
#
# It is served by uhttpd on port 2080, configured in /etc/config/uhttpd:
#
#   list listen_http  0.0.0.0:2080
#   list interpreter  ".sh=/bin/sh"
#
# openNDS configuration (/etc/config/opennds):
#
#   option fasport         '2080'
#   option faspath         '/cw-auth/portal.sh'
#   option fas_secure_enabled '1'
#   option faskey          'CHANGE_THIS_IN_PRODUCTION'
#
# openNDS FAS flow (fas_secure_enabled = 1):
# ------------------------------------------
# 1. Client connects → openNDS blocks internet
# 2. Client browser makes HTTP request → port 80 captured by openNDS
# 3. openNDS redirects to: http://192.168.100.254:2080/cw-auth/portal.sh?fas=<b64>
#    The b64 string decodes to:
#      clientip=<ip>, clientmac=<mac>, gatewayname=<name>,
#      client_hid=<hashed-token>, gatewayaddress=<ip:port>,
#      authdir=<auth-path>, originurl=<original-url>
# 4. This script decodes the params, serves portal/index.html
# 5. Student submits College ID + phone →
#      POST /cw-auth/portal.sh/authenticate   (PATH_INFO = /authenticate)
# 6. This script:
#    a. Calls ubus college.wifi.authenticate_student
#    b. On success: calls openNDS ndsctl auth + FAS authorization URL
#    c. Returns HTTP 200 JSON to the portal's fetch() call.
#       Success: { success:true, name, college_id, quota_bytes, used_bytes,
#                  remaining_bytes, quota_exhausted, expires_at, session_id }
#       Failure: { success:false, error:"<message>" }
#       The portal reads this JSON and renders the status panel directly.
#       No redirects are used for POST responses — they break fetch().json().
# 7. Logout:
#      POST /cw-auth/portal.sh/logout         (PATH_INFO = /logout)
#    Returns HTTP 200 JSON { success:true } after calling logout_student + ndsctl deauth.
# 8. BinAuth hook (/usr/lib/opennds/custombinauth.sh) is also called
#    by openNDS on each auth/deauth event for logging.
#
# IMPORTANT NOTES:
# - fas_secure_enabled 1 uses base64 encoding (no AES decryption required)
# - The client_hid is a hashed token, never the raw token itself
# - We do NOT use the raw openNDS token for anything security-sensitive;
#   our session management is handled entirely within college-wifi.uc
# - Phone numbers NEVER appear in URLs, logs, or HTTP responses
#
# =============================================================================

# ── Environment setup ──────────────────────────────────────────────────────
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Helper: URL decode a percent-encoded string
urldecode() {
    local s="$1"
    s="$(echo "$s" | sed 's/+/ /g; s/%/\\x/g')"
    printf '%b' "$s"
}

# Helper: base64 decode (busybox base64 -d)
b64decode() {
    echo "$1" | base64 -d 2>/dev/null
}

# Helper: extract a value from "key=val, key2=val2" string
get_param() {
    local key="$1" str="$2"
    echo "$str" | sed -n "s/.*${key}=\([^,]*\).*/\1/p" | tr -d ' '
}

# Helper: call a ubus method and return JSON response
ubus_call() {
    local object="$1" method="$2" args="$3"
    ubus call "$object" "$method" "$args" 2>/dev/null
}

# Helper: extract JSON field (simple grep, no jq needed)
json_get() {
    local field="$1" json="$2"
    echo "$json" | grep -o "\"${field}\":[^,}]*" | sed 's/.*:\s*//' | tr -d '"'
}

# ── Parse CGI environment ──────────────────────────────────────────────────
REQUEST_METHOD="${REQUEST_METHOD:-GET}"
QUERY_STRING="${QUERY_STRING:-}"
CONTENT_LENGTH="${CONTENT_LENGTH:-0}"

# Read POST body if applicable
POST_BODY=""
if [ "$REQUEST_METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
    POST_BODY="$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)"
fi

# ── Determine the logical endpoint ────────────────────────────────────────
#
# uHTTPd sets PATH_INFO to the path fragment after the script name.
# When the request is:
#
#   GET  /cw-auth/portal.sh            → PATH_INFO is "" or "/"
#   POST /cw-auth/portal.sh/authenticate → PATH_INFO is "/authenticate"
#   POST /cw-auth/portal.sh/logout     → PATH_INFO is "/logout"
#
# Fallback: if PATH_INFO is empty, derive from REQUEST_URI by stripping
# the script prefix.  This handles edge cases where some uHTTPd versions
# do not set PATH_INFO.
#
SCRIPT_NAME="${SCRIPT_NAME:-/cw-auth/portal.sh}"
RAW_PATH_INFO="${PATH_INFO:-}"

if [ -z "$RAW_PATH_INFO" ] || [ "$RAW_PATH_INFO" = "/" ]; then
    # Try to derive from REQUEST_URI
    REQUEST_URI="${REQUEST_URI:-}"
    # Strip query string from REQUEST_URI
    URI_PATH="$(echo "$REQUEST_URI" | cut -d'?' -f1)"
    # Strip the script name prefix to get the sub-path
    SUB_PATH="$(echo "$URI_PATH" | sed "s|^${SCRIPT_NAME}||")"
    if [ -n "$SUB_PATH" ] && [ "$SUB_PATH" != "$URI_PATH" ]; then
        RAW_PATH_INFO="$SUB_PATH"
    fi
fi

# Normalize: ensure leading slash, lowercase, no trailing slash
ENDPOINT="$(echo "$RAW_PATH_INFO" | sed 's|/*$||')"
[ -z "$ENDPOINT" ] && ENDPOINT="/"

# ── Serve portal HTML (GET /cw-auth/portal.sh) ────────────────────────────
if [ "$REQUEST_METHOD" = "GET" ]; then

    # Decode the FAS query parameter from openNDS
    FAS_B64="$(echo "$QUERY_STRING" | sed -n 's/.*fas=\([^&]*\).*/\1/p')"
    FAS_DECODED=""
    if [ -n "$FAS_B64" ]; then
        FAS_DECODED="$(b64decode "$FAS_B64")"
    fi

    CLIENT_IP="$(get_param 'clientip'  "$FAS_DECODED")"
    CLIENT_MAC="$(get_param 'clientmac' "$FAS_DECODED")"
    CLIENT_HID="$(get_param 'client_hid' "$FAS_DECODED")"
    GW_ADDR="$(get_param 'gatewayaddress' "$FAS_DECODED")"
    AUTH_DIR="$(get_param 'authdir' "$FAS_DECODED")"

    # Log the portal request
    logger -t college-wifi-fas \
        "Portal request: ip=${CLIENT_IP} mac=${CLIENT_MAC}"

    # Serve the portal HTML page
    printf "Content-Type: text/html; charset=UTF-8\r\n"
    printf "Cache-Control: no-store, no-cache, must-revalidate\r\n"
    printf "\r\n"
    cat /www/portal/index.html

    exit 0
fi

# ── POST request routing ──────────────────────────────────────────────────
#
# Endpoint values after normalization (PATH_INFO with script prefix stripped):
#
#   POST /cw-auth/portal.sh/authenticate → ENDPOINT = "/authenticate"
#   POST /cw-auth/portal.sh/logout       → ENDPOINT = "/logout"
#   POST /cw-auth/portal.sh              → ENDPOINT = "/"   (root POST)
#
# Logout is always checked FIRST so it cannot be swallowed by the auth branch.
#
if [ "$REQUEST_METHOD" = "POST" ]; then

    # ── Handle logout POST (/cw-auth/portal.sh/logout) ────────────────────
    if [ "$ENDPOINT" = "/logout" ]; then
        SESSION_ID="$(echo "$POST_BODY" | tr '&' '\n' | grep '^session_id=' | cut -d= -f2 | head -1)"
        SESSION_ID="$(urldecode "$SESSION_ID")"
        CLIENT_MAC_LOGOUT="$(echo "$POST_BODY" | tr '&' '\n' | grep '^client_mac=' | cut -d= -f2 | head -1)"
        CLIENT_MAC_LOGOUT="$(urldecode "$CLIENT_MAC_LOGOUT")"

        if [ -n "$SESSION_ID" ]; then
            ubus_call 'college.wifi' 'logout_student' \
                "$(printf '{"session_id":"%s","reason":"student_logout"}' "$SESSION_ID")"
            logger -t college-wifi-fas "Logout: session=${SESSION_ID}"
        fi

        # Deauth the client in openNDS if we have a MAC address
        # (passed by the portal via the logout POST body as client_mac)
        if [ -n "$CLIENT_MAC_LOGOUT" ]; then
            if command -v ndsctl > /dev/null 2>&1; then
                NDS_DEAUTH="$(ndsctl deauth "$CLIENT_MAC_LOGOUT" 2>&1)"
                logger -t college-wifi-fas "ndsctl deauth ${CLIENT_MAC_LOGOUT}: ${NDS_DEAUTH}"
            fi
        fi

        printf "Content-Type: application/json\r\n"
        printf "Cache-Control: no-store\r\n"
        printf "\r\n"
        printf '{"success":true}\n'
        exit 0
    fi

    # ── Handle authentication POST (/cw-auth/portal.sh/authenticate) ────────
    if [ "$ENDPOINT" = "/authenticate" ] || [ "$ENDPOINT" = "/" ]; then

        # Parse POST body: college_id=...&phone=...&fas=...
        COLLEGE_ID="$(echo "$POST_BODY" | tr '&' '\n' | grep '^college_id=' | cut -d= -f2 | head -1)"
        PHONE="$(echo "$POST_BODY" | tr '&' '\n' | grep '^phone=' | cut -d= -f2 | head -1)"
        FAS_B64="$(echo "$POST_BODY" | tr '&' '\n' | grep '^fas=' | cut -d= -f2 | head -1)"

        # URL decode
        COLLEGE_ID="$(urldecode "$COLLEGE_ID")"
        PHONE="$(urldecode "$PHONE")"

        # Decode FAS params to get client IP/MAC/token
        FAS_DECODED=""
        if [ -n "$FAS_B64" ]; then
            FAS_DECODED="$(b64decode "$FAS_B64")"
        fi
        CLIENT_IP="$(get_param 'clientip'   "$FAS_DECODED")"
        CLIENT_MAC="$(get_param 'clientmac'  "$FAS_DECODED")"
        CLIENT_HID="$(get_param 'client_hid' "$FAS_DECODED")"
        GW_ADDR="$(get_param 'gatewayaddress' "$FAS_DECODED")"
        AUTH_DIR="$(get_param 'authdir' "$FAS_DECODED")"
        ORIGIN_URL="$(get_param 'originurl' "$FAS_DECODED")"

        # Fall back to REMOTE_ADDR if FAS params are missing
        [ -z "$CLIENT_IP" ]  && CLIENT_IP="${REMOTE_ADDR:-}"
        [ -z "$CLIENT_MAC" ] && CLIENT_MAC=""

        logger -t college-wifi-fas \
            "Auth attempt: cid=${COLLEGE_ID} ip=${CLIENT_IP} mac=${CLIENT_MAC}"

        # ── Call college.wifi.authenticate_student via ubus ────────────────
        # IMPORTANT: phone is passed to the RPC call but never logged or stored
        AUTH_ARGS="$(printf '{"college_id":"%s","phone":"%s","client_ip":"%s","client_mac":"%s","nds_token":"%s"}' \
            "$COLLEGE_ID" "$PHONE" "$CLIENT_IP" "$CLIENT_MAC" "$CLIENT_HID")"

        AUTH_RESULT="$(ubus_call 'college.wifi' 'authenticate_student' "$AUTH_ARGS")"

        SUCCESS="$(json_get 'success' "$AUTH_RESULT")"
        ERROR_MSG="$(json_get 'error' "$AUTH_RESULT")"
        SESSION_ID="$(json_get 'session_id' "$AUTH_RESULT")"
        QUOTA_EXHAUSTED="$(json_get 'quota_exhausted' "$AUTH_RESULT")"

        # ── Authentication failed — return JSON so fetch().json() works ────
        if [ "$SUCCESS" != "true" ]; then
            logger -t college-wifi-fas \
                "Auth FAILED: cid=${COLLEGE_ID} ip=${CLIENT_IP} reason=${ERROR_MSG}"

            # Escape double-quotes in the error message for safe JSON embedding
            SAFE_ERROR="$(printf '%s' "$ERROR_MSG" | sed 's/"/\\"/g')"
            printf "Content-Type: application/json\r\n"
            printf "Cache-Control: no-store\r\n"
            printf "\r\n"
            printf '{"success":false,"error":"%s"}\n' "$SAFE_ERROR"
            exit 0
        fi

        # ── Authentication succeeded ───────────────────────────────────────
        logger -t college-wifi-fas \
            "Auth SUCCESS: cid=${COLLEGE_ID} ip=${CLIENT_IP} mac=${CLIENT_MAC} session=${SESSION_ID}"

        # Extract additional fields from ubus result for the JSON response
        # (phone_hash and phone are never included — privacy requirement)
        AUTH_NAME="$(json_get 'name' "$AUTH_RESULT")"
        AUTH_QUOTA="$(json_get 'quota_bytes' "$AUTH_RESULT")"
        AUTH_USED="$(json_get 'used_bytes' "$AUTH_RESULT")"
        AUTH_REMAINING="$(json_get 'remaining_bytes' "$AUTH_RESULT")"
        AUTH_EXPIRES="$(json_get 'expires_at' "$AUTH_RESULT")"

        # If quota is exhausted, allow portal access but skip ndsctl auth.
        # (Phase 5 will add firewall-level enforcement.)
        if [ "$QUOTA_EXHAUSTED" = "true" ]; then
            logger -t college-wifi-fas \
                "Quota exhausted for ${COLLEGE_ID} — portal access only"

            printf "Content-Type: application/json\r\n"
            printf "Cache-Control: no-store\r\n"
            printf "\r\n"
            printf '{"success":true,"college_id":"%s","name":"%s","session_id":"%s","quota_bytes":%s,"used_bytes":%s,"remaining_bytes":%s,"quota_exhausted":true,"expires_at":%s}\n' \
                "$COLLEGE_ID" "$AUTH_NAME" "$SESSION_ID" \
                "${AUTH_QUOTA:-0}" "${AUTH_USED:-0}" "${AUTH_REMAINING:-0}" "${AUTH_EXPIRES:-0}"
            exit 0
        fi

        # ── Authorize client in openNDS ────────────────────────────────────
        # These calls happen BEFORE returning JSON so the client is granted
        # internet access before the portal shows the success panel.

        # Method 1: ndsctl auth (preferred — direct socket call)
        if command -v ndsctl > /dev/null 2>&1; then
            NDS_RESULT="$(ndsctl auth "$CLIENT_MAC" 2>&1)"
            logger -t college-wifi-fas "ndsctl auth ${CLIENT_MAC}: ${NDS_RESULT}"
        fi

        # Method 2: openNDS virtual URL (fallback for fas_secure_enabled 0/1/2)
        if [ -n "$GW_ADDR" ] && [ -n "$AUTH_DIR" ] && [ -n "$CLIENT_HID" ]; then
            AUTH_URL="http://${GW_ADDR}/${AUTH_DIR}/?tok=${CLIENT_HID}&redir=/portal/index.html%3Fstatus%3Dauthenticated"
            logger -t college-wifi-fas "Calling NDS auth URL: $AUTH_URL"
            wget -q -O /dev/null --timeout=5 "$AUTH_URL" 2>/dev/null || true
        fi

        # Return JSON — fetch().json() in the portal reads this directly
        printf "Content-Type: application/json\r\n"
        printf "Cache-Control: no-store\r\n"
        printf "\r\n"
        printf '{"success":true,"college_id":"%s","name":"%s","session_id":"%s","quota_bytes":%s,"used_bytes":%s,"remaining_bytes":%s,"quota_exhausted":false,"expires_at":%s}\n' \
            "$COLLEGE_ID" "$AUTH_NAME" "$SESSION_ID" \
            "${AUTH_QUOTA:-0}" "${AUTH_USED:-0}" "${AUTH_REMAINING:-0}" "${AUTH_EXPIRES:-0}"
        exit 0
    fi

    # ── Unsupported POST path ──────────────────────────────────────────────
    logger -t college-wifi-fas "Unsupported POST path: ${ENDPOINT}"
    printf "Status: 404 Not Found\r\n"
    printf "Content-Type: application/json\r\n"
    printf "Cache-Control: no-store\r\n"
    printf "\r\n"
    printf '{"error":"Not found"}\n'
    exit 0

fi

# ── 404 fallback ───────────────────────────────────────────────────────────
printf "Status: 404 Not Found\r\n"
printf "Content-Type: text/plain\r\n"
printf "\r\n"
printf "Not found\n"
exit 0
