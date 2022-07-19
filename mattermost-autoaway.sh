#!/bin/bash
#
# mattermost-autoaway.sh
#
# Script to update your online/away status in Mattermost
# automatically. This is a workaround for
# https://github.com/mattermost/desktop/issues/1187
#
# Currently tested / works on KDE (Linux) against MM 6.6.x
#

# USAGE:
#
# 1) Server-side requirements:
#
#    - You need to enable Personal Access Tokens on the Mattermost
#      server as described in
#      https://docs.mattermost.com/developer/personal-access-tokens.html
#
#    - Personal Access Tokens are required when using SSO. With 
#      username/password based logins they might not be necessary,
#      but the script doesn't support that ATM - for details, see:
#      https://api.mattermost.com/#tag/authentication
#
# 2) Personal setup:
#
#    - Create ${HOME}/.config/mattermost-autoaway-rc.sh with:
#         MATTERMOST_ACCESS_TOKEN="..."
#         MATTERMOST_URL="https://yourchatserver.com"
#
#    - Get a Personal Access Token in the desktop client as
#      described in
#      https://docs.mattermost.com/developer/personal-access-tokens.html
#      and insert it into the file created above
#
# 3) To set yourself online/away based on the screen lock status
#    on KDE, run this in the background:
#
#      mattermost-autoaway.sh dbus-monitor-kde
#
#    - or, add this to the config file:
#         DEFAULT_COMMAND="dbus-monitor-kde"
#    and configure the script as a "login script" without arguments.
#
#    The monitoring feature logs to syslog by default.
#

# APIs used:
# - https://api.mattermost.com/#operation/GetUserStatus
# - https://api.mattermost.com/#operation/UpdateUserStatus
#
# DBUS:
# - https://unix.stackexchange.com/questions/28181/how-to-run-a-script-on-screen-lock-unlock


CONF_FILE="${HOME}/.config/mattermost-autoaway-rc.sh"

# Call Mattermost API to get our userId
function get_user_id(){
    curl -s -H "Authorization: Bearer ${MATTERMOST_ACCESS_TOKEN}" "${MATTERMOST_URL}/api/v4/users/me"  | jq -r .id
}

# Call Mattermost API to get our status
function get_user_status(){
    curl -s -H "Authorization: Bearer ${MATTERMOST_ACCESS_TOKEN}" "${MATTERMOST_URL}/api/v4/users/me/status" | jq -r .status
}

# Call Mattermost API to set our status
function set_user_status(){
    status="$1"
    # This endpoint doesn't support "me" as userid
    user_id="$(get_user_id)"
    curl \
        -s \
        -H "Authorization: Bearer ${MATTERMOST_ACCESS_TOKEN}" \
        -X PUT \
        -d "{\"user_id\": \"${user_id}\", \"status\": \"${status}\"}" \
        "${MATTERMOST_URL}/api/v4/users/${user_id}/status" \
        | jq .
}

# Listen on the the local DBUS for screen lock events
function dbus_monitor_kde(){
    dbus-monitor \
        --session \
        "type='signal',interface='org.freedesktop.ScreenSaver', path='/org/freedesktop/ScreenSaver'" 
}

# Sanitize output from dbus_monitor_filter_kde()
function dbus_monitor_filter(){
    grep --line-buffered -A 1 member=ActiveChanged | grep --line-buffered -E '^[[:space:]]*boolean[[:space:]]+' | awk '{print $2; fflush()}'
}

#
# Main
#

if [ -e "${CONF_FILE}" ]; then
    source "${CONF_FILE}"
fi

if [ -z "${MATTERMOST_URL}" -o -z "${MATTERMOST_ACCESS_TOKEN}" ]; then
    echo "ERROR: MATTERMOST_URL and MATTERMOST_ACCESS_TOKEN must be set" >&2
    exit 1
fi

command="$1"
shift
if [ -z "$command" ]; then
    command="${DEFAULT_COMMAND}"
fi

case "$command" in
    get)
        get_user_status
        ;;
    
    set)
        status="$1"
        if [ -z "$status" ]; then
            echo "USAGE: $0 set online|away|offline|dnd" >&2
            exit 1
        fi
        set_user_status "$status"
        ;;

    dbus-monitor-kde)
        (while true ; do
            echo "$(date) starting dbus-monitor..."
            dbus_monitor_kde | dbus_monitor_filter | while read value ; do
                case "${value}" in
                    true)
                        echo "$(date) screen locked, setting away"
                        set_user_status away
                        ;;
                    false)
                        echo "$(date) screen unlocked, setting online"
                        set_user_status online
                        ;;
                esac
            done
            echo "$(date) dbus-monitor exited, waiting 5s..."
            sleep 5
         done) |
            logger --id=$$ --priority user.notice --tag mattermost-autoaway/${USER} "$@"
        ;;
    
    _debug)
        set -x
        curl \
            -s \
            -vv \
            -H "Authorization: Bearer ${MATTERMOST_ACCESS_TOKEN}" \
            "${MATTERMOST_URL}/api/v4/users/me/status"
        ;;
    _dm)
        dbus_monitor
        ;;
    
    _dmf)
        dbus_monitor | dbus_monitor_filter
        ;;

    *)
        echo "USAGE:" >&2
        echo "  $0 get" >&2
        echo "  $0 set online|away|offline|dnd" >&2
        echo "  $0 dbus-monitor-kde [--stderr]" >&2
        exit 1
        ;;
esac
