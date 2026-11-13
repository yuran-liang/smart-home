#!/bin/bash
# Set up a fresh Raspberry Pi OS (64-bit, Debian 12 or newer) as the home automation host.
#
# Usage, as the normal user (not root, with sudo rights), from a clone of this repository:
#
#   HDD_UUID=<uuid> scripts/install.sh
#
# Every step is idempotent, so the script can be run again after fixing a failure.
#
# Before the first run:
#   - clone home-config next to this repository (it is private, so this script does not clone it)
#     and put its secrets.env in place
#   - optional: STATE_ARCHIVE=/path/to/state-*.tgz restores the runtime state (HomeKit pairing,
#     Zigbee network, Mosquitto passwords) written by home-config's backup-state.sh
#
# Environment (all optional):
#   DATA_DIR         base directory of the service data (default: the user's home directory)
#   HOME_CONFIG      path of the home-config clone (default: ../home-config next to this repository)
#   HDD_UUID         UUID of the external HDD (blkid); without it the HDD is not set up
#   HDD_FSTYPE       file system of the HDD (default: ntfs-3g)
#   HDD_DIR          mount point of the HDD (default: /mnt/hdd)
#   STATE_ARCHIVE    runtime state archive to restore, see above
#   WITH_TAILSCALE   1 installs Tailscale and enables IP forwarding for a subnet router
#
# Steps: packages, Docker, docker/.env, HDD mount, service configs, udev rule, containers,
# daily state backup, optional Tailscale.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the normal user, not as root; it uses sudo where needed." >&2
    exit 1
fi
if [ "$(uname -m)" != aarch64 ]; then
    echo "Expected a 64-bit ARM system (aarch64), found $(uname -m)." >&2
    exit 1
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA_DIR=${DATA_DIR:-$HOME}
HOME_CONFIG=${HOME_CONFIG:-$(dirname "$REPO")/home-config}
HDD_UUID=${HDD_UUID:-}
HDD_FSTYPE=${HDD_FSTYPE:-ntfs-3g}
HDD_DIR=${HDD_DIR:-/mnt/hdd}
STATE_ARCHIVE=${STATE_ARCHIVE:-}
WITH_TAILSCALE=${WITH_TAILSCALE:-0}
ENV_FILE=$REPO/docker/.env

if [ ! -f "$HOME_CONFIG/scripts/restore.py" ]; then
    echo "home-config not found at $HOME_CONFIG; clone it there or set HOME_CONFIG." >&2
    exit 1
fi
if [ ! -f "$HOME_CONFIG/secrets.env" ] && [ -z "$STATE_ARCHIVE" ]; then
    echo "No $HOME_CONFIG/secrets.env, and no STATE_ARCHIVE that contains one." >&2
    exit 1
fi

# Set KEY=value in docker/.env: replace the line if the key exists, append otherwise
set_env() {
    local key=$1 value=$2
    if grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
    else
        echo "$key=$value" >> "$ENV_FILE"
    fi
}
get_env() {
    grep "^$1=" "$ENV_FILE" | head -n 1 | cut -d= -f2-
}

echo "==> Packages"
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq python3 pigz rsync ntfs-3g

echo "==> Docker"
if ! command -v docker > /dev/null; then
    # shellcheck source=/dev/null
    . /etc/os-release
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" |
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

echo "==> docker/.env"
if [ ! -f "$ENV_FILE" ]; then
    cp "$REPO/docker/.env.example" "$ENV_FILE"
fi
set_env DATA_DIR "$DATA_DIR"
set_env HDD_DIR "$HDD_DIR"
dongles=$(find /dev/serial/by-id -name '*SONOFF*' 2> /dev/null || true)
if [ -n "$dongles" ] && [ "$(echo "$dongles" | wc -l)" -eq 1 ]; then
    set_env ZIGBEE_DONGLE "$dongles"
elif grep -q '<serial>' "$ENV_FILE"; then
    echo "Zigbee dongle not detected: plug it in and run again, or set ZIGBEE_DONGLE in $ENV_FILE." >&2
    exit 1
fi
if [ "$(get_env SAMBA_PASSWORD)" = change-me ]; then
    set_env SAMBA_PASSWORD "$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    echo "Generated SAMBA_PASSWORD in $ENV_FILE."
fi

echo "==> HDD"
if [ -n "$HDD_UUID" ]; then
    sudo mkdir -p "$HDD_DIR"
    if ! grep -q "UUID=$HDD_UUID" /etc/fstab; then
        echo "UUID=$HDD_UUID $HDD_DIR $HDD_FSTYPE defaults,auto,users,rw,nofail,noatime 0 0" |
            sudo tee -a /etc/fstab > /dev/null
        sudo systemctl daemon-reload
    fi
    if ! mountpoint -q "$HDD_DIR"; then
        # While the HDD is unmounted, writes to the empty mount point would fill the system disk
        sudo chattr +i "$HDD_DIR"
        sudo mount "$HDD_DIR"
    fi
    mountpoint -q "$HDD_DIR" || {
        echo "$HDD_DIR is not mounted." >&2
        exit 1
    }
else
    echo "HDD_UUID not set: skipped. The samba service needs $HDD_DIR to exist."
    sudo mkdir -p "$HDD_DIR"
fi

echo "==> Runtime state"
if [ -n "$STATE_ARCHIVE" ]; then
    # --no-overwrite-dir: the archive has an entry for its top directory ("./"), which would
    # otherwise replace the owner and mode of DATA_DIR itself. When DATA_DIR is the home
    # directory, that locks the user out of SSH.
    sudo tar xzf "$STATE_ARCHIVE" --no-overwrite-dir -C "$DATA_DIR"
    # sudo: the archive's files may belong to root, so the user may not be able to see them
    if [ ! -f "$HOME_CONFIG/secrets.env" ] && sudo test -f "$DATA_DIR/secrets.env"; then
        sudo mv "$DATA_DIR/secrets.env" "$HOME_CONFIG/secrets.env"
        sudo chown "$USER:$USER" "$HOME_CONFIG/secrets.env"
        sudo chmod 600 "$HOME_CONFIG/secrets.env"
    fi
fi
# Safety net: a home directory that is not the user's, or is writable by others, makes sshd refuse
# the user's keys
case "$(stat -c '%U %a' "$HOME")" in
    "$USER 700" | "$USER 750" | "$USER 755") ;;
    *)
        echo "The home directory has an unexpected owner or mode: $(stat -c '%U %a' "$HOME")" >&2
        exit 1
        ;;
esac

echo "==> Service configs"
sudo env DATA_DIR="$DATA_DIR" python3 "$HOME_CONFIG/scripts/restore.py"

echo "==> udev rule for the Zigbee dongle"
if [ -f "$REPO/docker/udev/99-zigbee-dongle.rules" ]; then
    sudo cp "$REPO/docker/udev/99-zigbee-dongle.rules" /etc/udev/rules.d/
    sudo udevadm control --reload
fi

echo "==> Containers"
(cd "$REPO/docker" && sudo docker compose pull && sudo docker compose up -d)

echo "==> Node-RED modules"
# The flows need the nodes listed in nodered/data/package.json (dashboard, HomeKit, ...). They are
# not part of home-config, and without them Node-RED does not start the flows at all.
if [ ! -d "$DATA_DIR/nodered/data/node_modules" ]; then
    sudo docker exec nodered sh -c 'cd /data && npm install --omit=dev --no-audit --no-fund'
    sudo docker exec nodered sh -c 'cd /data/node_modules/node-red-dashboard && node fixgrid.js' || true
    sudo docker restart nodered > /dev/null
fi

echo "==> Daily state backup"
if [ -f "$HOME_CONFIG/scripts/backup-state.sh" ] && mountpoint -q "$HDD_DIR"; then
    job="30 3 * * * DATA_DIR=$DATA_DIR BACKUP_DIR=$HDD_DIR/backup/smart-home-state $HOME_CONFIG/scripts/backup-state.sh >> /var/log/backup-state.log 2>&1"
    if ! sudo crontab -l 2> /dev/null | grep -qF "backup-state.sh"; then
        (sudo crontab -l 2> /dev/null || true; echo "$job") | sudo crontab -
    fi
else
    echo "Skipped (needs home-config's backup-state.sh and the mounted HDD)."
fi

if [ "$WITH_TAILSCALE" = 1 ]; then
    echo "==> Tailscale"
    if ! command -v tailscale > /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' |
        sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null
    echo "Log in with: sudo tailscale up (open the printed link in a browser)."
fi

echo "==> Done. Log out and in again for the docker group to take effect."
