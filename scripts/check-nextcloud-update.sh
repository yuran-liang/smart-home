#!/bin/bash
# Look for a newer Nextcloud image and tell the admin through a Nextcloud notification, which the
# web interface and the mobile and desktop apps show. Nothing is updated.
#
# Reports two things: a newer image of the running major version (minor and patch updates) and
# the next major version.
#
# Usage: NEXTCLOUD_NOTIFY_USER=<admin user> scripts/check-nextcloud-update.sh
#
# install.sh adds it to root's crontab (weekly) when NEXTCLOUD_NOTIFY_USER is set.
set -euo pipefail

user=${NEXTCLOUD_NOTIFY_USER:?set NEXTCLOUD_NOTIFY_USER to the Nextcloud user that gets the notification}
occ() { docker exec -u www-data nextcloud php occ "$@"; }

version=$(occ status | sed -n 's/^ *- versionstring: //p')
major=${version%%.*}
if [ -z "$major" ]; then
    echo "Could not read the Nextcloud version." >&2
    exit 1
fi

hub=https://hub.docker.com/v2/repositories/library/nextcloud/tags
messages=()

# Same major version: compare the digest of the tag on Docker Hub with the running image
latest=$(curl -fsS -m 30 "$hub/$major-apache" | jq -r '.digest')
running=$(docker inspect --format '{{index .RepoDigests 0}}' "$(docker inspect --format '{{.Image}}' nextcloud)" 2> /dev/null | sed 's/.*@//')
if [ -n "$latest" ] && [ "$latest" != null ] && [ "$latest" != "$running" ]; then
    messages+=("A newer $major image is available: docker compose pull nextcloud nextcloud-cron && docker compose up -d")
fi

# Next major version
next=$((major + 1))
if curl -fs -m 30 -o /dev/null "$hub/$next-apache"; then
    messages+=("Nextcloud $next is available (running $version); upgrade one major version at a time")
fi

if [ "${#messages[@]}" -eq 0 ]; then
    echo "Nextcloud $version is up to date."
    exit 0
fi
for m in "${messages[@]}"; do
    echo "$m"
    occ notification:generate "$user" "Nextcloud update" -l "$m"
done
