#!/bin/bash
# Deploy the pushed state of smart-home and home-config to the Pi, from any machine with SSH access.
#
# Usage: scripts/deploy.sh [--dry-run]
#
#   --dry-run  only run the checks and list the incoming commits with their CI status
#
# Steps on the Pi:
#   1. Run home-config's export.py and stop if a live config differs from git, e.g. after a change
#      in a web UI that was never exported. Deploying would overwrite it; commit it first.
#   2. Show the incoming commits of both repositories, stop unless CI passed on them, and ask for
#      confirmation.
#   3. Pull both, write the configs with restore.py, apply docker-compose.yml, and restart the
#      services whose config files were written.
#
# DEPLOY_HOST (default: pi) is an SSH host; DATA_DIR (default: /home/pi) is the services' data root.
# Needs the GitHub CLI (gh), logged in with access to both repositories of GITHUB_OWNER
# (default: yuran-liang), to check that CI passed on the commits to deploy.
set -euo pipefail

HOST=${DEPLOY_HOST:-pi}
DATA_DIR=${DATA_DIR:-/home/pi}
GITHUB_OWNER=${GITHUB_OWNER:-yuran-liang}
# Clones in the home directory of the SSH user, where remote commands start
SMART_HOME=smart-home
HOME_CONFIG=home-config
DRY_RUN=false
if [ "${1:-}" = --dry-run ]; then
    DRY_RUN=true
fi

# LogLevel=ERROR hides the Pi's warning about its older OpenSSH key exchange; -n keeps ssh from
# reading stdin, which would swallow the answer to the confirmation prompt
remote() {
    ssh -n -o LogLevel=ERROR "$HOST" "$@"
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
ci_failed=false
# Indexed arrays only: macOS ships bash 3.2, which has no associative arrays
repos=("$SMART_HOME" "$HOME_CONFIG")
targets=()
for i in "${!repos[@]}"; do
    repo=${repos[$i]}
    targets[i]=$(remote "cd $repo && git fetch -q && git rev-parse @{u}")
    log=$(remote "cd $repo && git log --oneline HEAD..${targets[i]}")
    if [ -z "$log" ]; then
        continue
    fi
    incoming=true
    # The last push run of CI on the commit to deploy must have passed
    ci=$(gh run list -R "$GITHUB_OWNER/$repo" --commit "${targets[i]}" --event push -L 1 \
        --json status,conclusion --jq '.[] | "\(.status) \(.conclusion)"')
    echo "$repo (CI: ${ci:-no run}):"
    echo "  ${log//$'\n'/$'\n  '}"
    if [ "$ci" != "completed success" ]; then
        ci_failed=true
    fi
done
if ! $incoming; then
    echo "Nothing to deploy."
    exit 0
fi
if $ci_failed; then
    echo "CI has not passed on every commit to deploy; wait for it or fix it first." >&2
    exit 1
fi
if $DRY_RUN; then
    exit 0
fi

read -rp "Deploy to $HOST? [y/N] " answer
if [ "$answer" != y ]; then
    exit 1
fi

echo "==> Pulling"
# Merge exactly the commits CI was checked on, even if something was pushed since
for i in "${!repos[@]}"; do
    remote "git -C ${repos[i]} merge -q --ff-only ${targets[i]}"
done

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
