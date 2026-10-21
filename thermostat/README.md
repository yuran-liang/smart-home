# thermostat — radiator controller

Room temperature control on a Raspberry Pi: an eQ-3 Bluetooth radiator thermostat is
driven from the room temperature measured by the [`sensor`](../sensor) firmware.

## How it works

- `main_temp_ctrl.py` subscribes to the MQTT topic `esp/dht/temperature` (broker on `localhost:1883`).
  On every reading it queries the thermostat via
  [eQ-3-radiator-thermostat](https://github.com/Heckie75/eQ-3-radiator-thermostat) (`eq3.exp`),
  and if the measured temperature is more than 1 °C off the target it adjusts the thermostat
  set point with a proportional controller (`K_p = 1.0`, clamped to 5–30 °C, 0.5 °C steps).
- `config.json` holds the target temperature (default 27 °C if the file cannot be read).
- `increase_temp.py` / `decrease_temp.py` raise or lower the target by 2 °C (e.g. bound to buttons).
- `pub_config.py` publishes the current target to `desire/temperature` every 10 s.

## Requirements

- Python 3.7+, `paho-mqtt`
- An MQTT broker (e.g. Mosquitto) on the same host
- `eq3.exp` installed at `/home/pi/eQ-3-radiator-thermostat/`; the thermostat MAC address is set in `main_temp_ctrl.py`
