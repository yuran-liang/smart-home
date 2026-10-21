# docker — Raspberry Pi service stack

Docker Compose stack for the home automation Raspberry Pi (arm64).

| Service | Image | Purpose |
|---|---|---|
| `homeassistant` | `ghcr.io/home-assistant/home-assistant:stable` | Home Assistant, config in `/home/pi/homeassistant` |
| `zigbee2mqtt` | `koenkk/zigbee2mqtt:latest` | Zigbee bridge using the SONOFF Dongle Plus MG24, data in `/home/pi/zigbee2mqtt/data` |
| `watchtower` | `containrrr/watchtower` | Updates the containers once per day and removes old images |
| `portainer` | `portainer/portainer-ce:latest` | Docker web UI on port 9000 |

Home Assistant and Zigbee2MQTT use host networking. The Zigbee dongle is passed through by its
`/dev/serial/by-id/...` path; update it in `docker-compose.yml` if the dongle changes.

## Usage

```bash
docker compose up -d
```
