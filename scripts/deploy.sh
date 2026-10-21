#!/bin/bash
# Deploy the pushed state of smart-home and home-config to the Pi, from any machine with SSH access.
#
# Usage: scripts/deploy.sh [--dry-run]
#
#   --dry-run  only check for unexported live changes and list the incoming commits
#
# Steps on the Pi:
#   1. Run home-config's export.py and stop if a live config differs from git, e.g. after a change
#      in a web UI that was never exported. Deploying would overwrite it; commit it first.
#   2. Show the incoming commits of both repositories and ask for confirmation.
#   3. Pull both, write the configs with restore.py, apply docker-compose.yml, and restart the
#      services whose config files were written.
#
# DEPLOY_HOST (default: pi) is an SSH host; DATA_DIR (default: /home/pi) is the services' data root.
set -euo pipefail

HOST=${DEPLOY_HOST:-pi}
DATA_DIR=${DATA_DIR:-/home/pi}
# Clones in the home directory of the SSH user, where remote commands start
SMART_HOME=smart-home
HOME_CONFIG=home-config
DRY_RUN=false
if [ "${1:-}" = --dry-run ]; then
    DRY_RUN=true
fi

# LogLevel=ERROR hides the Pi's warning about its older OpenSSH key exchange
remote() {
    ssh -o LogLevel=ERROR "$HOST" "$@"
}

echo "==> Checking $HOST for live changes that are not in home-config"
remote "cd $HOME_CONFIG && test -z \"\$(git status --porcelain)\"" || {
    echo "home-config on $HOST has uncommitted changes; commit or discard them first:" >&2
    remote "cd $HOME_CONFIG && git status --short" >&2
    exit 1
}
remote "cd $HOME_CONFIG && DATA_DIR=$DATA_DIR python3 scripts/export.py > /dev/null"
drift=$(remote "cd $HOME_CONFIG && git status --porcelain")
if [ -n "$drift" ]; then
    echo "Live configs differ from git (exported into $HOME_CONFIG on $HOST):" >&2
    echo "$drift" >&2
    echo "Review them there, then commit and push, or 'git checkout -- data' to drop them." >&2
    exit 1
fi

echo "==> Incoming commits"
incoming=false
for repo in "$SMART_HOME" "$HOME_CONFIG"; do
    log=$(remote "cd $repo && git fetch -q && git log --oneline HEAD..@{u}")
    if [ -n "$log" ]; then
        incoming=true
        echo "$repo:"
        echo "  ${log//$'\n'/$'\n  '}"
    fi
done
if ! $incoming; then
    echo "Nothing to deploy."
    exit 0
fi
if $DRY_RUN; then
    exit 0
fi

read -rp "Deploy to $HOST? [y/N] " answer
if [ "$answer" != y ]; then
    exit 1
fi

echo "==> Pulling"
remote "git -C $SMART_HOME pull -q --ff-only && git -C $HOME_CONFIG pull -q --ff-only"

echo "==> Writing configs"
written=$(remote "cd $HOME_CONFIG && DATA_DIR=$DATA_DIR python3 scripts/restore.py")
echo "${written:-  (no config changes)}"

echo "==> Applying docker-compose.yml"
remote "cd $SMART_HOME/docker && docker compose up -d"

# Each service keeps its config under DATA_DIR/<service name>/
services=$(echo "$written" | sed -n "s|^write $DATA_DIR/\([^/]*\)/.*|\1|p" | sort -u | tr '\n' ' ')
if [ -n "$services" ]; then
    echo "==> Restarting $services"
    remote "cd $SMART_HOME/docker && docker compose restart $services"
fi

remote "docker ps --format 'table {{.Names}}\t{{.Status}}'"
