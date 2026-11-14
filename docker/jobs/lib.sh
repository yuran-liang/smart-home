#!/bin/bash
# Shared helpers of the scheduled jobs (sourced, not run).

# Send an email through ALERT_SMTP_URL (e.g. smtps://smtp.example.com:465). Does nothing unless the
# SMTP settings and ALERT_EMAIL_TO are set; a failure is logged and never fails the calling job.
send_email() {
    local subject=$1 body=$2 from
    [ -n "${ALERT_SMTP_URL:-}" ] && [ -n "${ALERT_EMAIL_TO:-}" ] || return 0
    from=${ALERT_EMAIL_FROM:-${ALERT_SMTP_USER:-}}
    {
        printf 'From: Home server <%s>\r\n' "$from"
        printf 'To: %s\r\n' "$ALERT_EMAIL_TO"
        printf 'Subject: =?UTF-8?B?%s?=\r\n' "$(printf '%s' "[home] $subject" | base64 -w0)"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n' "$body"
    } | curl -sS -m 60 --ssl-reqd --url "$ALERT_SMTP_URL" \
        --mail-from "$from" --mail-rcpt "$ALERT_EMAIL_TO" \
        --user "${ALERT_SMTP_USER:-}:${ALERT_SMTP_PASSWORD:-}" -T - > /dev/null ||
        echo "Could not send the email \"$subject\"." >&2
}

# Tell the Nextcloud admin through a Nextcloud notification. Does nothing without
# NEXTCLOUD_NOTIFY_USER and never fails the calling job (Nextcloud may be the thing that is down).
notify() {
    [ -n "${NEXTCLOUD_NOTIFY_USER:-}" ] || return 0
    docker exec -u www-data nextcloud php occ notification:generate "$NEXTCLOUD_NOTIFY_USER" "$1" -l "$2" > /dev/null 2>&1 || true
}

# Raise an alert: the container log, an email and a Nextcloud notification.
alert() {
    echo "ALERT: $1 - $2" >&2
    send_email "$1" "$2"
    notify "$1" "$2"
}

# /hdd is bind-mounted from the host. If the HDD was not mounted there, it is a plain directory
# on the system disk and has the same device number as /data: stop instead of filling the disk.
require_hdd() {
    if [ "$(stat -c %d /hdd)" = "$(stat -c %d /data)" ]; then
        echo "The HDD is not mounted." >&2
        return 1
    fi
}
