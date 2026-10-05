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
# 3. openNDS redirects to: http://192.168.1.1:2080/cw-auth/portal.sh?fas=<b64>
#    The b64 string decodes to:
#      clientip=<ip>, clientmac=<mac>, gatewayname=<name>,
#      client_hid=<hashed-token>, gatewayaddress=<ip:port>,
#      authdir=<auth-path>, originurl=<original-url>
# 4. This script decodes the params, serves portal/index.html
# 5. Student submits College ID + phone → POST /cw-auth/authenticate
# 6. This script:
#    a. Calls ubus college.wifi.authenticate_student
#    b. On success: calls openNDS auth URL → grants internet access
#    c. Redirects back to portal with ?status=authenticated
#    d. On failure: redirects back with ?status=error&msg=<reason>
# 7. BinAuth hook (/usr/lib/opennds/custombinauth.sh) is also called
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

# Determine which endpoint was requested via PATH_INFO
# uhttpd sets PATH_INFO from the URL after the script name
ENDPOINT="${PATH_INFO:-/}"

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

# ── Handle authentication POST (/cw-auth/authenticate) ────────────────────
if [ "$REQUEST_METHOD" = "POST" ]; then

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

    # ── Call college.wifi.authenticate_student via ubus ────────────────────
    # IMPORTANT: phone is passed to the RPC call but never logged or stored
    AUTH_ARGS="$(printf '{"college_id":"%s","phone":"%s","client_ip":"%s","client_mac":"%s","nds_token":"%s"}' \
        "$COLLEGE_ID" "$PHONE" "$CLIENT_IP" "$CLIENT_MAC" "$CLIENT_HID")"

    AUTH_RESULT="$(ubus_call 'college.wifi' 'authenticate_student' "$AUTH_ARGS")"

    SUCCESS="$(json_get 'success' "$AUTH_RESULT")"
    ERROR_MSG="$(json_get 'error' "$AUTH_RESULT")"
    SESSION_ID="$(json_get 'session_id' "$AUTH_RESULT")"
    QUOTA_EXHAUSTED="$(json_get 'quota_exhausted' "$AUTH_RESULT")"

    # ── Authentication failed ──────────────────────────────────────────────
    if [ "$SUCCESS" != "true" ]; then
        logger -t college-wifi-fas \
            "Auth FAILED: cid=${COLLEGE_ID} ip=${CLIENT_IP} reason=${ERROR_MSG}"

        ENCODED_MSG="$(printf '%s' "$ERROR_MSG" | sed 's/ /%20/g; s/\./%2E/g')"
        printf "Status: 302 Found\r\n"
        printf "Location: /portal/index.html?status=error&msg=%s\r\n" "$ENCODED_MSG"
        printf "Cache-Control: no-store\r\n"
        printf "\r\n"
        exit 0
    fi

    # ── Authentication succeeded ───────────────────────────────────────────
    logger -t college-wifi-fas \
        "Auth SUCCESS: cid=${COLLEGE_ID} ip=${CLIENT_IP} mac=${CLIENT_MAC} session=${SESSION_ID}"

    # If quota is exhausted, allow portal access but don't call ndsctl auth
    # (Phase 5 will handle quota-based firewall enforcement)
    if [ "$QUOTA_EXHAUSTED" = "true" ]; then
        logger -t college-wifi-fas \
            "Quota exhausted for ${COLLEGE_ID} — portal access only"

        printf "Status: 302 Found\r\n"
        printf "Location: /portal/index.html?status=authenticated&quota_exhausted=1\r\n"
        printf "Cache-Control: no-store\r\n"
        printf "\r\n"
        exit 0
    fi

    # ── Authorize client in openNDS ────────────────────────────────────────
    # Method 1: ndsctl auth (preferred — direct socket call)
    if command -v ndsctl > /dev/null 2>&1; then
        NDS_RESULT="$(ndsctl auth "$CLIENT_MAC" 2>&1)"
        logger -t college-wifi-fas "ndsctl auth ${CLIENT_MAC}: ${NDS_RESULT}"
    fi

    # Method 2: openNDS virtual URL (fallback for fas_secure_enabled 0/1/2)
    # Construct the authorization URL:
    #   http://<gateway>/<authdir>/?tok=<hid>&redir=<landing>
    if [ -n "$GW_ADDR" ] && [ -n "$AUTH_DIR" ] && [ -n "$CLIENT_HID" ]; then
        AUTH_URL="http://${GW_ADDR}/${AUTH_DIR}/?tok=${CLIENT_HID}&redir=/portal/index.html%3Fstatus%3Dauthenticated"
        logger -t college-wifi-fas "Calling NDS auth URL: $AUTH_URL"
        wget -q -O /dev/null --timeout=5 "$AUTH_URL" 2>/dev/null || true
    fi

    # Redirect to portal success page
    printf "Status: 302 Found\r\n"
    printf "Location: /portal/index.html?status=authenticated\r\n"
    printf "Cache-Control: no-store\r\n"
    printf "\r\n"
    exit 0
fi

# ── Handle logout POST (/cw-auth/logout) ──────────────────────────────────
if [ "$REQUEST_METHOD" = "POST" ] && [ "$ENDPOINT" = "/cw-auth/logout" ]; then
    SESSION_ID="$(echo "$POST_BODY" | tr '&' '\n' | grep '^session_id=' | cut -d= -f2 | head -1)"

    if [ -n "$SESSION_ID" ]; then
        ubus_call 'college.wifi' 'logout_student' \
            "$(printf '{"session_id":"%s","reason":"student_logout"}' "$SESSION_ID")"
        logger -t college-wifi-fas "Logout: session=${SESSION_ID}"
    fi

    printf "Content-Type: application/json\r\n"
    printf "\r\n"
    printf '{"success":true}\n'
    exit 0
fi

# ── 404 fallback ───────────────────────────────────────────────────────────
printf "Status: 404 Not Found\r\n"
printf "Content-Type: text/plain\r\n"
printf "\r\n"
printf "Not found\n"
exit 0
