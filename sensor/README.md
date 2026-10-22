# sensor — ESP8266 + DHT22 room sensor

PlatformIO firmware for a NodeMCU (ESP8266) room sensor.

- Reads temperature and humidity from a DHT22 on GPIO 13 every 60 s
- Publishes them via MQTT to `esp/dht/temperature` and `esp/dht/humidity` (QoS 1, retained)
- Serves a small WebSocket page on port 80 to toggle the on-board LED (GPIO 2)
- Supports OTA firmware updates via ElegantOTA 3 in async mode (`http://<device-ip>/update`)

Not deployed at the moment. It used to feed the room temperature to the radiator controller,
which has since been removed. CI builds it on every pull request; since the move from the
retired AsyncElegantOTA to ElegantOTA 3 it has not been flashed to hardware, so check the
`/update` page the next time it is.

## Setup

1. Copy `include/secrets.h.example` to `include/secrets.h` and fill in the WiFi credentials,
   ThingSpeak key and MQTT broker address. `secrets.h` is git-ignored.
2. Build and upload with PlatformIO: `pio run -t upload`, monitor with `pio device monitor` (115200 baud).
