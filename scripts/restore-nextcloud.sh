#!/bin/bash
# Restore Nextcloud from a backup (files, database dump, config.php) into the Docker stack and
# upgrade it, one major version at a time, to the newest image that exists.
#
# Usage, as the normal user, on the Pi after install.sh:
#
#   BACKUP_DIR=/path/to/backup NEXTCLOUD_HOST=<host>.<tailnet>.ts.net scripts/restore-nextcloud.sh
#
# BACKUP_DIR contains:
#   nextcloud-data.tar       the data directory, archived as "data/..." (tar -C <parent> data)
#   nextclouddb.sql.gz       a dump of the database (mysqldump / mariadb-dump)
#   config/config.php        the old config.php
#
# Idempotent: the database is only imported into an empty database, the files are only extracted
# into an empty data directory, and the upgrade loop skips versions that are already installed.
#
# Environment:
#   BACKUP_DIR       directory described above (required)
#   NEXTCLOUD_HOST   address the clients use, without https:// (required); added to trusted_domains
#   SNAPSHOT_DIR     where the database is dumped before each upgrade step
#                    (default: $BACKUP_DIR/upgrade-snapshots)
#   MAX_MAJOR        stop after this major version (default: 60)
#
# The script does not publish Nextcloud: afterwards run `tailscale serve` or `tailscale funnel`
# (docker/README.md).
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the normal user, not as root; it uses sudo where needed." >&2
    exit 1
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=$REPO/docker/.env
BACKUP_DIR=${BACKUP_DIR:?set BACKUP_DIR}
NEXTCLOUD_HOST=${NEXTCLOUD_HOST:?set NEXTCLOUD_HOST}
SNAPSHOT_DIR=${SNAPSHOT_DIR:-$BACKUP_DIR/upgrade-snapshots}
MAX_MAJOR=${MAX_MAJOR:-60}

for f in nextcloud-data.tar nextclouddb.sql.gz config/config.php; do
    [ -f "$BACKUP_DIR/$f" ] || {
        echo "Missing $BACKUP_DIR/$f" >&2
        exit 1
    }
done

get_env() { grep "^$1=" "$ENV_FILE" | head -n 1 | cut -d= -f2-; }
set_env() {
    if grep -q "^$1=" "$ENV_FILE"; then
        sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
    else
        echo "$1=$2" >> "$ENV_FILE"
    fi
}
compose() { (cd "$REPO/docker" && sudo docker compose "$@"); }
occ() { sudo docker exec -u www-data nextcloud php occ "$@"; }
# Ready = Apache answers. The image's entrypoint finishes unpacking and any automatic upgrade
# before it starts Apache, so this also covers a freshly started or recreated container.
wait_ready() {
    for _ in $(seq 1 360); do
        sudo docker exec nextcloud curl -fs -m 5 http://localhost/status.php 2> /dev/null | grep -q '"installed"' && return 0
        sleep 10
    done
    return 1
}
db_root() { sudo docker exec -i nextcloud-db sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$@"' sh "$@"; }

for key in NEXTCLOUD_DB_PASSWORD NEXTCLOUD_DB_ROOT_PASSWORD; do
    value=$(get_env "$key")
    if [ -z "$value" ] || [ "$value" = change-me ]; then
        echo "$key in $ENV_FILE is not set (install.sh generates it)." >&2
        exit 1
    fi
done
DATA_DIR_NC=$(get_env NEXTCLOUD_DATA_DIR)
DATA_DIR_NC=${DATA_DIR_NC:-/var/nextcloud/data}
if [ "$(basename "$DATA_DIR_NC")" != data ]; then
    echo "NEXTCLOUD_DATA_DIR must end in /data (the archive holds \"data/...\")." >&2
    exit 1
fi

old_version=$(grep -o "'version' => '[0-9.]*'" "$BACKUP_DIR/config/config.php" | grep -o '[0-9][0-9.]*')
first_major=${old_version%%.*}
echo "Backup is Nextcloud $old_version."

echo "==> Database"
compose up -d nextcloud-db nextcloud-redis
until db_root -e 'SELECT 1' > /dev/null 2>&1; do sleep 3; done
tables=$(db_root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='nextclouddb'")
if [ "$tables" -eq 0 ]; then
    gunzip -c "$BACKUP_DIR/nextclouddb.sql.gz" | db_root nextclouddb
    echo "Imported."
else
    echo "Database already has $tables tables: skipped."
fi

echo "==> Files"
sudo mkdir -p "$DATA_DIR_NC"
if [ -z "$(sudo ls -A "$DATA_DIR_NC")" ]; then
    # Owner and mode come from the archive (www-data inside the container, uid 33)
    sudo tar --numeric-owner --warning=no-timestamp -xpf "$BACKUP_DIR/nextcloud-data.tar" -C "$(dirname "$DATA_DIR_NC")"
else
    echo "$DATA_DIR_NC is not empty: skipped."
fi

echo "==> Start the image of the backup's major version"
set_env NEXTCLOUD_VERSION "$first_major"
# No admin credentials in the environment, so the image's entrypoint does not install a new
# instance; it only unpacks the code into the volume
compose up -d nextcloud
wait_ready || {
    echo "Nextcloud did not start; see: docker logs nextcloud" >&2
    exit 1
}

echo "==> config.php"
if ! sudo docker exec nextcloud test -f /var/www/html/config/config.php; then
    # shellcheck disable=SC2024  # the backup file is readable by the user; only docker needs sudo
    sudo docker exec -i -u www-data nextcloud sh -c 'cat > /tmp/old-config.php' < "$BACKUP_DIR/config/config.php"
    sudo docker exec -u www-data \
        -e DBPASS="$(get_env NEXTCLOUD_DB_PASSWORD)" -e NCHOST="$NEXTCLOUD_HOST" -e NCDATA="$DATA_DIR_NC" \
        nextcloud php -r '
        include "/tmp/old-config.php";
        $CONFIG["dbhost"] = "nextcloud-db";
        $CONFIG["dbport"] = "";
        $CONFIG["dbname"] = "nextclouddb";
        $CONFIG["dbuser"] = "nextcloud";
        $CONFIG["dbpassword"] = getenv("DBPASS");
        $CONFIG["datadirectory"] = getenv("NCDATA");
        $CONFIG["overwritehost"] = getenv("NCHOST");
        $CONFIG["overwriteprotocol"] = "https";
        $CONFIG["overwrite.cli.url"] = "https://" . getenv("NCHOST");
        $CONFIG["trusted_domains"] = array_values(array_unique(array_merge($CONFIG["trusted_domains"] ?? [], [getenv("NCHOST")])));
        $CONFIG["trusted_proxies"] = ["127.0.0.1", "172.16.0.0/12"];
        $CONFIG["memcache.local"] = "\\OC\\Memcache\\APCu";
        $CONFIG["memcache.distributed"] = "\\OC\\Memcache\\Redis";
        $CONFIG["memcache.locking"] = "\\OC\\Memcache\\Redis";
        $CONFIG["redis"] = ["host" => "nextcloud-redis", "port" => 6379];
        $CONFIG["check_data_directory_permissions"] = false;
        $CONFIG["maintenance"] = false;
        file_put_contents("/var/www/html/config/config.php", "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");
    '
    sudo docker exec nextcloud rm -f /tmp/old-config.php
    sudo docker exec nextcloud chmod 640 /var/www/html/config/config.php
    sudo docker restart nextcloud > /dev/null
else
    echo "config.php exists: skipped."
fi

echo "==> Upgrade, one major version at a time"
mkdir -p "$SNAPSHOT_DIR"
for v in $(seq "$first_major" "$MAX_MAJOR"); do
    if [ "$v" -gt "$first_major" ] && ! sudo docker pull "nextcloud:$v-apache" > /dev/null 2>&1; then
        echo "No image for $v: staying on $((v - 1))."
        break
    fi
    echo "--- $v"
    sudo docker exec nextcloud-db sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction nextclouddb' |
        gzip > "$SNAPSHOT_DIR/db-before-$v.sql.gz"
    set_env NEXTCLOUD_VERSION "$v"
    compose up -d nextcloud
    wait_ready || {
        echo "Nextcloud $v did not become ready; see: docker logs nextcloud" >&2
        exit 1
    }
    status=$(occ status 2>&1)
    if echo "$status" | grep -q -E 'require upgrade|needsDbUpgrade: true'; then
        occ upgrade || {
            echo "occ upgrade failed at $v; the database before this step is in $SNAPSHOT_DIR." >&2
            exit 1
        }
        status=$(occ status 2>&1)
    fi
    echo "$status" | grep -q "versionstring: $v\." || {
        echo "Expected version $v, got: $(echo "$status" | grep versionstring)" >&2
        exit 1
    }
done

echo "==> Database row format"
# Tables created by old versions or dumps may not use ROW_FORMAT=DYNAMIC, which Nextcloud wants
# shellcheck disable=SC2016  # the backticks are SQL quoting, not a command substitution
db_root -N -e 'SELECT CONCAT("ALTER TABLE `", table_name, "` ROW_FORMAT=DYNAMIC;") FROM information_schema.tables WHERE table_schema="nextclouddb" AND engine="InnoDB" AND row_format<>"Dynamic"' |
    db_root nextclouddb

echo "==> Maintenance"
occ maintenance:mode --off || true
occ db:add-missing-indices
occ db:add-missing-columns
occ maintenance:repair --include-expensive
compose up -d nextcloud-cron
occ status

nc_port=$(get_env NEXTCLOUD_PORT)
echo
echo "Done. Publish it: sudo tailscale serve --bg --https=443 http://127.0.0.1:${nc_port:-8090}"
echo "(or funnel, to reach it without a VPN), then run scripts/verify.sh."
