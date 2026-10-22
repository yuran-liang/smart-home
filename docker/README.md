# docker — Raspberry Pi service stack

Docker Compose stack for the home automation Raspberry Pi (arm64).

| Service | Image | Purpose |
|---|---|---|
| `mosquitto` | `eclipse-mosquitto:2` | MQTT broker on port 1883, config in `$DATA_DIR/mosquitto/config` |
| `homebridge` | `homebridge/homebridge:latest` | Apple HomeKit bridge, UI on port 8581, data in `$DATA_DIR/homebridge` |
| `zigbee2mqtt` | `koenkk/zigbee2mqtt:latest` | Zigbee bridge using the SONOFF Dongle Plus MG24, data in `$DATA_DIR/zigbee2mqtt/data` |
| `nodered` | `nodered/node-red:latest` | Node-RED on port 1880, flows in `$DATA_DIR/nodered/data` |
| `watchtower` | `containrrr/watchtower` | Updates the containers once per day and removes old images |
| `portainer` | `portainer/portainer-ce:latest` | Docker web UI on port 9000 |

All services except Watchtower and Portainer use host networking.

## Configuration

Host-specific values live in `.env` (not committed):

| Variable | Meaning |
|---|---|
| `DATA_DIR` | Base directory for all service data; `/home/pi` on the current Pi |
| `TZ` | Time zone for all containers |
| `ZIGBEE_DONGLE` | `/dev/serial/by-id/...` path of the Zigbee coordinator |

Service configs and data (Zigbee2MQTT config, Mosquitto `mosquitto.conf`
and `passwd`, Homebridge `config.json`, Node-RED flows) are not in this repository; restore
them into `$DATA_DIR` before starting the stack on a new host.

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
