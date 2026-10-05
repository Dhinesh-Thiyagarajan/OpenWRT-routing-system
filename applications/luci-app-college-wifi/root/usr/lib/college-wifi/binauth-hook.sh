#!/bin/sh
# =============================================================================
# College WiFi — BinAuth Post-Authentication Hook
# =============================================================================
#
# openNDS calls this script after every client auth/deauth event.
# Install path: copy to /usr/lib/opennds/custombinauth.sh
#
# Command line arguments (from openNDS):
#   $1  method    : "auth_client" | "deauth_client"
#   $2  mac       : client MAC address
#   $3  token     : openNDS token (NOT the phone — never passed here)
#   $4  minutes   : session length in minutes
#   $5  upload    : upload data bytes
#   $6  download  : download data bytes
#   $7  custom    : custom string (we use: "college_id=ENG23CS001")
#
# See: https://opennds.readthedocs.io/en/stable/binauth.html
# =============================================================================

METHOD="$1"
MAC="$2"
TOKEN="$3"
MINUTES="$4"
UPLOAD="$5"
DOWNLOAD="$6"
CUSTOM="$7"

# Extract college_id from the custom string
COLLEGE_ID="$(echo "$CUSTOM" | sed -n 's/.*college_id=\([^&]*\).*/\1/p')"

ubus_call() {
    ubus call "$1" "$2" "$3" 2>/dev/null
}

case "$METHOD" in
    auth_client)
        logger -t college-wifi-binauth \
            "AUTH: mac=${MAC} cid=${COLLEGE_ID} token=${TOKEN} mins=${MINUTES}"

        # Create or confirm session
        if [ -n "$COLLEGE_ID" ]; then
            ubus_call 'college.wifi' 'create_session' \
                "$(printf '{"college_id":"%s","client_mac":"%s","nds_token":"%s"}' \
                   "$COLLEGE_ID" "$MAC" "$TOKEN")"
        fi
        ;;

    deauth_client)
        logger -t college-wifi-binauth \
            "DEAUTH: mac=${MAC} cid=${COLLEGE_ID} up=${UPLOAD} down=${DOWNLOAD}"

        # Terminate session
        if [ -n "$COLLEGE_ID" ]; then
            ubus_call 'college.wifi' 'logout_student' \
                "$(printf '{"college_id":"%s","reason":"nds_deauth"}' "$COLLEGE_ID")"
        fi
        ;;

    *)
        logger -t college-wifi-binauth "Unknown method: ${METHOD}"
        ;;
esac

exit 0
