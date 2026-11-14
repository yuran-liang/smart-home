# docker — Raspberry Pi service stack

Docker Compose stack for the home automation Raspberry Pi (arm64).

| Service | Image | Purpose |
|---|---|---|
| `mosquitto` | `eclipse-mosquitto:2` | MQTT broker on port 1883, config in `$DATA_DIR/mosquitto/config` |
| `homebridge` | `homebridge/homebridge:latest` | Apple HomeKit bridge, UI on port 8581, data in `$DATA_DIR/homebridge` |
| `zigbee2mqtt` | `koenkk/zigbee2mqtt:latest` | Zigbee bridge using the SONOFF Dongle Plus MG24, data in `$DATA_DIR/zigbee2mqtt/data` |
| `nodered` | `nodered/node-red:latest` | Node-RED on port 1880, flows in `$DATA_DIR/nodered/data` |
| `samba` | `dockurr/samba` | Shares the external HDD (`$HDD_DIR`) as an SMB network drive on port 445 |
| `nextcloud`, `nextcloud-db`, `nextcloud-redis`, `nextcloud-cron` | `nextcloud:<NEXTCLOUD_VERSION>-apache`, `mariadb`, `redis` | Nextcloud on localhost port `NEXTCLOUD_PORT` (8090), its database, a cache and file-locking service and a background job runner; see below |
| `tailscale` | `tailscale/tailscale:stable` | Tailscale in the host network: VPN access, subnet routes, and the HTTPS address of Nextcloud (`tailscale/serve.json`) |
| `guest-exit` | `tailscale/tailscale:stable` | Optional (profile `guest-exit`): a Tailscale exit node for one guest that cannot reach any private network; see below |
| `jobs` | built from `jobs/Dockerfile` | Cron in a container: the daily state and Nextcloud backups onto the HDD, disk health, monitoring with email alerts, guest exit traffic and the weekly Nextcloud update check; see below |
| `watchtower` | `containrrr/watchtower` | Updates the containers once per day and removes old images |
| `portainer` | `portainer/portainer-ce:latest` | Docker web UI on port 9000 |

All services except Samba, Watchtower and Portainer use host networking.

## Configuration

Host-specific values live in `.env` (not committed):

| Variable | Meaning |
|---|---|
| `DATA_DIR` | Base directory for all service data; `/home/pi` on the current Pi |
| `TZ` | Time zone for all containers |
| `ZIGBEE_DONGLE` | `/dev/serial/by-id/...` path of the Zigbee coordinator |
| `HDD_DIR` | Mount point of the external HDD that the `samba` service shares |
| `SAMBA_SHARE` | Name of the Samba share |
| `SAMBA_USER` | Account to connect to the share with |
| `SAMBA_PASSWORD` | Password of that account; required, `docker compose` refuses to start without it |
| `COMPOSE_PROJECT_NAME` | Compose project name, `pi` on the current Pi. It prefixes the named volumes, so changing it on an existing host gives Portainer an empty `<name>_portainer_data` volume |

Service configs and data (Zigbee2MQTT config, Mosquitto `mosquitto.conf` and `passwd`,
Homebridge `config.json`, Node-RED flows) are not in this repository; restore them into
`$DATA_DIR` before starting the stack on a new host.

Mosquitto refuses anonymous clients. Its `mosquitto.conf` is:

```
persistence true
persistence_location /mosquitto/data/
log_dest stdout
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
```

## Usage

```bash
cp .env.example .env   # then edit
docker compose up -d
```

## Notes

Do not mount a volume inside `/data/nrchkb` of the Node-RED container. The HomeKit plugin
(`node-red-contrib-homekit-bridged`) stores its data there with `node-persist`, which reads every
entry in that directory every 2 minutes; a subdirectory makes it throw `EISDIR` and Node-RED exits.

If the HDD is not mounted, `$HDD_DIR` is an empty directory on the system disk and files copied
to the share would fill it. Make the empty mount point immutable while the HDD is unmounted, so
such writes fail instead: `sudo umount $HDD_DIR && sudo chattr +i $HDD_DIR && sudo mount $HDD_DIR`.
The share also picks up the HDD when it is mounted after the container started, e.g. at boot.

The HDD behind the Samba share spins down on its own when idle (drive firmware; no `hd-idle`
needed). The first access after that takes about 20 seconds while it spins up. A Finder or
Explorer window left open on the share keeps polling it and stops it from spinning down.

If the Zigbee dongle is not plugged in or not detected when the stack starts, `zigbee2mqtt` cannot
start (its device path is missing) and Docker does not retry. `udev/99-zigbee-dongle.rules` restarts
the container whenever the dongle appears, so plugging it in is enough. Install it once per host:
`sudo cp udev/99-zigbee-dongle.rules /etc/udev/rules.d/ && sudo udevadm control --reload`. It matches the
dongle model, not its serial number; a replacement dongle only needs the new path in `ZIGBEE_DONGLE`.

## Nextcloud

Nextcloud listens only on `127.0.0.1:$NEXTCLOUD_PORT`; HTTPS comes from the `tailscale` service,
which `tailscale/serve.json` tells to publish it at `https://<host>.<tailnet>.ts.net`. The same
file turns Funnel on (`AllowFunnel`), so the address is reachable from the internet and the
clients work without a VPN; set it to `false` for tailnet-only access. Funnel has to be enabled
once for the tailnet in the Tailscale admin console. With Funnel on, keep Nextcloud up to date and turn on two-factor authentication. The code and
`config.php` live in the `nextcloud_html` volume,
the database in `nextcloud_db`, the files in `NEXTCLOUD_DATA_DIR` on the host. `config.php` must
contain `trusted_domains` with that address, `overwritehost`, `overwriteprotocol` = `https` and
`trusted_proxies` with the Docker range (`172.16.0.0/12`).

`config.php` also needs `memcache.local` (`\OC\Memcache\APCu`), `memcache.distributed` and `memcache.locking` (`\OC\Memcache\Redis`) and `redis` with host `nextcloud-redis`, port 6379; `restore-nextcloud.sh` writes them. `nextcloud/hsts.conf` adds the HSTS header. `occ setupchecks` lists what is left to tune.

Watchtower leaves these containers alone: Nextcloud can only be upgraded one major version at a
time. Set `NEXTCLOUD_VERSION` to the next major version, run `docker compose up -d nextcloud
nextcloud-cron`, wait for the container to finish upgrading (`docker logs nextcloud`), check
`occ status`, and repeat. Minor and patch updates come with `docker compose pull nextcloud`. The MariaDB major version (`NEXTCLOUD_DB_VERSION`) changes the same way: dump the database first, set the new version and recreate `nextcloud-db`; the image upgrades the data files on start.

## Scheduled jobs

The `jobs` service replaces the root crontab on the host. Its `jobs/crontab` has these entries:

| When | Job |
| --- | --- |
| 03:30 daily | `jobs/backup-state.sh`: home-config's `backup-state.sh` onto the HDD, keeping the newest 7 archives; refuses to run when the HDD is not mounted |
| 04:00 daily | `jobs/backup-nextcloud.sh`: Nextcloud backup into a restic repository on the HDD (below) |
| 07:30 daily | `jobs/check-disk-health.sh`: SMART status of the HDD and the SSD |
| Sunday 02:00, 1st of the month 05:00 | `jobs/check-disk-health.sh short` and `long`: SMART self-tests; the next daily check reads their result |
| every 5 minutes | `jobs/monitor.sh`: containers, service ports, Nextcloud, Tailscale, free space, Pi supply voltage and temperature, age of the backups (below) |
| 23:55 daily | `jobs/guest-exit-usage.sh`: traffic of the guest exit node (below) |
| Monday 08:00 | `jobs/weekly-report.sh`: email with open problems, free space, newest backups and guest traffic |
| Monday 09:00 | `scripts/check-nextcloud-update.sh`: a Nextcloud notification for `NEXTCLOUD_NOTIFY_USER`; no check when it is empty |

The container gets the service data (`DATA_DIR`), the Nextcloud data directory (read-only), the HDD,
the home-config clone (`HOME_CONFIG_DIR`, read-only), this repository's `scripts`, the HDD's
device node (`HDD_DEVICE`) and the Docker socket. Output goes to the container log:
`docker logs jobs`. To run a job by hand: `docker exec jobs /jobs/backup-state.sh`. The job scripts
are baked into the image, so `deploy.sh` rebuilds it (`docker compose up -d --build`).

### Alerts and monitoring

An alert is an email (`ALERT_*` in `docker/.env`: an SMTP server and an app password of the sending
account, and the recipient) plus a Nextcloud notification for `NEXTCLOUD_NOTIFY_USER`, and always a
line in `docker logs jobs`. Email is the main channel because it does not depend on Nextcloud or
the Pi's services being up; each channel is skipped when its settings are empty. The jobs raise
one when a backup fails, a disk looks unhealthy (SMART verdict, reallocated or pending sectors,
temperature, self-test errors) or the monitor finds a problem.

`jobs/monitor.sh` keeps the state of every check in the `jobs_state` volume. A problem is reported
after `MONITOR_FAIL_AFTER` (2) failing runs in a row, repeated daily while it lasts, and a recovery
is reported once. It checks that every container of the Compose project runs and is not unhealthy,
that the service ports in `MONITOR_PORTS` answer (the `jobs` container is in the host network for
this; adjust the Homebridge UI port if it is not 8581), Nextcloud's status, Tailscale, free space
(90%) of the system disk, the Nextcloud data and the HDD, the Pi's under-voltage and throttling
flags and CPU temperature, and twice a day the age of the state backup and of the newest Nextcloud
snapshot (not more often: reading the HDD wakes it). A Pi that is off cannot send an alert; that
needs a check from outside (for example a heartbeat service).

`jobs/guest-exit-usage.sh` reads the byte counters of the guest exit node's `tailscale0` interface
once a day and appends the difference to `usage.csv` in the `jobs_state` volume (`docker exec jobs cat
/state/guest-exit/usage.csv`: date, bytes received, bytes sent). The Monday report sums the last 7
days and the month. `GUEST_EXIT_MONTHLY_LIMIT_GB` raises an alert once a month when the traffic
passes it; nothing is limited.

### Nextcloud backup

`jobs/backup-nextcloud.sh` writes a [restic](https://restic.net) repository to
`$HDD_DIR/backup/nextcloud-restic` with three kinds of snapshot: `files` (the data directory,
without the generated previews), `db` (a `mariadb-dump`) and `config` (`config.php`). The first run
copies everything and takes hours (start it by hand: `docker exec -d jobs /jobs/backup-nextcloud.sh`);
later runs only read the data directory and store what changed. It runs at low CPU and disk priority.
The database is dumped before the files are read, so a restore never lacks a file that the database
knows. Retention: 7 daily, 4 weekly and 6 monthly snapshots per kind (`KEEP_DAILY`, `KEEP_WEEKLY`,
`KEEP_MONTHLY` in the container environment). On Sundays the job also prunes the repository and
checks a 2% sample of its data.

The repository is encrypted with `NEXTCLOUD_BACKUP_PASSWORD` from `docker/.env` (`install.sh`
generates it). **Keep a copy of the password outside the Pi**: without it the backup cannot be
read. An existing host needs the variables once, by hand: add `NEXTCLOUD_BACKUP_PASSWORD=<random>`
and, for the health check, `HDD_DEVICE=/dev/disk/by-id/<the HDD>` to `docker/.env` (see
`.env.example`), then deploy.

Restore (the repository and its password are in the `jobs` container's environment; this is not
yet wired into `scripts/restore-nextcloud.sh`, which still expects the tar and dump layout):

```sh
docker exec jobs restic snapshots
# Everything of the newest snapshots into /hdd/restore, e.g. for a new Pi (data directory under
# /hdd/restore/var/nextcloud/data, dump as /hdd/restore/nextclouddb.sql.gz, config.php under config/)
docker exec jobs restic restore latest --tag files --target /hdd/restore
docker exec jobs restic restore latest --tag db --target /hdd/restore
docker exec jobs restic restore latest --tag config --target /hdd/restore
# One file or directory from a day in the past
docker exec jobs restic restore <snapshot id> --tag files --target /hdd/restore --include '/var/nextcloud/data/<user>/files/<path>'
```

After restoring files into a data directory, run `occ files:scan --all`. Without a mounted HDD the
backup does not run. Not covered: the HDD is in the same house as the Pi, so this is no protection
against fire or theft (an off-site copy of the repository, `restic copy`, is still open).

## Tailscale

The `tailscale` service runs in the host network, so it behaves like Tailscale installed on the
host: the Pi has its own Tailscale address and can offer networks to the tailnet. Its identity
is the state in the `tailscale_state` volume (name, address, key expiry). Settings come from
`.env`: `TS_HOSTNAME` (keep the existing name; it is part of the HTTPS address), `TS_ROUTES` (a
network to offer, e.g. the LAN; allow it in the admin console) and `TS_AUTHKEY` (only for a node
without state). Run Tailscale commands with `docker exec tailscale tailscale <command>`.

To move a host install into the container, stop it (`sudo systemctl disable --now tailscaled`),
copy its `/var/lib/tailscale/tailscaled.state` into the volume and start the service; the node
keeps its identity. A rebuilt Pi does the same with `TAILSCALE_STATE` for `install.sh`. Never run
the host service and the container with the same state at the same time.

## Tailscale access policy

`tailscale/policy.hujson` is the copy of the tailnet's access policy that is kept in git: allow
all connections, SSH to a user's own devices, Funnel for members, and a tag for the guest exit
node (`tag:guest-exit`, owned by the admins, its exit node route approved automatically). The
admin console (Access controls, JSON editor) is the source of truth, and nothing applies this file
by itself: after a change here, paste it into the console and save. Before replacing the policy
in the console, compare it with the file to make sure nothing was changed there first.

## Rebuilding a Pi

Only the physical steps are manual: flash an SD card, swap cards, power cycle. The rest is scripted
(all in `scripts/`, run on the Pi as the normal user):

1. Boot a spare SD card with Raspberry Pi OS (64-bit), SSH key and sudo set up, the SSD attached.
2. `TARGET=/dev/sda CONFIRM=/dev/sda scripts/clone-to-ssd.sh` copies that system onto the SSD, fixes
   its identifiers and grows the root partition. `HOSTKEYS_DIR=<dir with the old ssh_host_* files>`
   keeps the host identity, so SSH clients do not warn. Shut down, remove the SD card, power on.
3. `HDD_UUID=<uuid> STATE_ARCHIVE=<state-*.tgz> NEXTCLOUD_NOTIFY_USER=<admin> scripts/install.sh`
   with home-config cloned next to this repository (see `install.sh` for all options). `TAILSCALE_STATE=<tailscaled.state of the old install>` keeps the Tailscale identity.
4. `BACKUP_DIR=<dir> NEXTCLOUD_HOST=<host>.<tailnet>.ts.net scripts/restore-nextcloud.sh` restores
   Nextcloud and upgrades it one major version at a time, with a database dump before each step.
5. `scripts/verify.sh` checks the services, the dongle, the HDD, Nextcloud, Tailscale and the age of
   the newest state backup. It changes nothing and exits non-zero on a failed check.

`scripts/check-nextcloud-update.sh` (weekly, run by the `jobs` service when `NEXTCLOUD_NOTIFY_USER`
is set) compares the running image with Docker Hub and sends a Nextcloud notification to
that user when a newer image of the running major version, or the next major version, exists.

## Exit node for a guest

The optional `guest-exit` service is a separate Tailscale node that is shared with one person
outside the tailnet. That person can send his internet traffic through this house, and nothing
else: `guest-exit/firewall.sh` drops everything that arrives through Tailscale and is addressed
to a private range (10/8, 172.16/12, 192.168/16, link-local, loopback, the Tailscale range and
the IPv6 equivalents), before connection tracking and before Tailscale's own forwarding rules.
The rules are applied before Tailscale starts and again every 30 seconds. The only exception is
the node's own Tailscale address, where it answers DNS queries.

Setup, once:

1. In the Tailscale admin console, create an auth key (one-time use, not reusable, not
   ephemeral). On the host, put it into `docker/.env` as `GUEST_EXIT_AUTHKEY`, add
   `COMPOSE_PROFILES=guest-exit` and run `docker compose up -d`. Remove the key from `.env`
   afterwards; the node's identity is kept in the `guest_exit_state` volume.
2. In the admin console, open the machine `guest-exit` (name: `GUEST_EXIT_HOSTNAME`), edit its
   route settings and allow it as an exit node. Also disable its key expiry: a node key expires
   after 180 days by default, and the node then drops off until someone logs it in again. The
   auth key from step 1 is a different thing; it is only used once, at the first start.
3. Open Share on that machine, create an invite link and send it to the guest. He accepts it with
   his own Tailscale account and selects the node as his exit node.

What it cannot do: limit the guest to certain sites (an exit node forwards everything), or hide
that his traffic comes from this house. His traffic uses this house's upload bandwidth. To stop
it, remove the share in the admin console or run `docker compose stop guest-exit`.
