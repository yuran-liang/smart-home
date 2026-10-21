# smart-home

Home automation built around a Raspberry Pi and MQTT: a Wi-Fi room sensor reports
temperature and humidity, a controller on the Pi drives a Bluetooth radiator thermostat
to hold a target temperature, and a Docker stack runs the MQTT broker, Home Assistant,
Zigbee2MQTT, Homebridge and Node-RED.

## Architecture

```mermaid
flowchart LR
    subgraph ESP["ESP8266 (NodeMCU)"]
        S["sensor/<br/>DHT22 firmware"]
    end

    subgraph PI["Raspberry Pi"]
        T["thermostat/<br/>P-controller"]
        C["config.json<br/>target temperature"]
        subgraph D["docker/"]
            B[("Mosquitto<br/>:1883")]
            HA["Home Assistant"]
            Z["Zigbee2MQTT"]
            HB["Homebridge"]
            NR["Node-RED"]
        end
    end

    V["eQ-3 radiator<br/>thermostat"]
    ZD["Zigbee devices"]

    S -- "esp/dht/temperature<br/>esp/dht/humidity" --> B
    B -- "esp/dht/temperature" --> T
    C --> T
    T -- "Bluetooth LE<br/>(eq3.exp)" --> V
    ZD -- "SONOFF MG24 dongle" --> Z
    Z --> B
    B <--> HB
    B <--> NR
```

## Components

| Directory | What it is | Stack |
|---|---|---|
| [`sensor/`](sensor) | ESP8266 firmware: reads a DHT22 every 60 s and publishes temperature and humidity via MQTT; WebSocket status page and OTA updates | C++, PlatformIO, Arduino |
| [`thermostat/`](thermostat) | Subscribes to the room temperature and adjusts an eQ-3 Bluetooth radiator thermostat with a proportional controller | Python, paho-mqtt |
| [`docker/`](docker) | Docker Compose stack for the Pi: Mosquitto, Home Assistant, Zigbee2MQTT, Homebridge, Node-RED, Watchtower, Portainer | Docker Compose |

Each directory has its own README with setup details.

## Getting started

1. Start the services: `cd docker && cp .env.example .env`, adjust `.env`, restore the service
   configs into `DATA_DIR` (see [`docker/README.md`](docker/README.md)), then `docker compose up -d`.
2. Flash the sensor: copy `sensor/include/secrets.h.example` to `sensor/include/secrets.h`,
   fill in Wi-Fi credentials and the broker address, then `pio run -t upload`.
3. Start the controller on the Pi: `python thermostat/main_temp_ctrl.py`.

## History

This repository combines three earlier repositories, with their commit history preserved:
`raspberrypi-docker` → `docker/`, `Temperature-controll` → `thermostat/`, `ESP8266-DHT22` → `sensor/`.
