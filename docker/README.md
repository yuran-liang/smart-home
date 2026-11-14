# docker — Raspberry Pi service stack

Docker Compose stack for the home automation Raspberry Pi (arm64).

| Service | Image | Purpose |
|---|---|---|
| `mosquitto` | `eclipse-mosquitto:2` | MQTT broker on port 1883, config in `$DATA_DIR/mosquitto/config` |
| `homebridge` | `homebridge/homebridge:latest` | Apple HomeKit bridge, UI on port 8581, data in `$DATA_DIR/homebridge` |
| `zigbee2mqtt` | `koenkk/zigbee2mqtt:latest` | Zigbee bridge using the SONOFF Dongle Plus MG24, data in `$DATA_DIR/zigbee2mqtt/data` |
| `nodered` | `nodered/node-red:latest` | Node-RED on port 1880, flows in `$DATA_DIR/nodered/data` |
| `samba` | `dockurr/samba` | Shares the external HDD (`$HDD_DIR`) as an SMB network drive on port 445 |
| `nextcloud`, `nextcloud-db`, `nextcloud-cron` | `nextcloud:<NEXTCLOUD_VERSION>-apache`, `mariadb` | Nextcloud on localhost port `NEXTCLOUD_PORT` (8090), its database and a background job runner; see below |
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

Nextcloud listens only on `127.0.0.1:$NEXTCLOUD_PORT`; HTTPS comes from Tailscale. `sudo tailscale
serve --bg --https=443 http://127.0.0.1:8090` publishes it inside the tailnet at
`https://<host>.<tailnet>.ts.net`, and `sudo tailscale funnel --bg --https=443 http://127.0.0.1:8090`
makes the same address reachable from the internet, so the clients work without a VPN. Funnel needs
to be enabled once for the tailnet in the Tailscale admin console; `tailscale funnel --https=443 off`
goes back to tailnet-only. Pass the full target URL: `tailscale funnel 443` would proxy to port 443.
With Funnel on, keep Nextcloud up to date and turn on two-factor authentication. The code and
`config.php` live in the `nextcloud_html` volume,
the database in `nextcloud_db`, the files in `NEXTCLOUD_DATA_DIR` on the host. `config.php` must
contain `trusted_domains` with that address, `overwritehost`, `overwriteprotocol` = `https` and
`trusted_proxies` with the Docker range (`172.16.0.0/12`).

Watchtower leaves these containers alone: Nextcloud can only be upgraded one major version at a
time. Set `NEXTCLOUD_VERSION` to the next major version, run `docker compose up -d nextcloud
nextcloud-cron`, wait for the container to finish upgrading (`docker logs nextcloud`), check
`occ status`, and repeat. Minor and patch updates come with `docker compose pull nextcloud`.
