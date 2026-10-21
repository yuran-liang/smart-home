#! /usr/bin/env python 3.7

import random
import time
import json
import os

from paho.mqtt import client as mqtt_client


broker = 'localhost'
port = 1883
topic = "desire/temperature"
# generate client ID with pub prefix randomly
client_id = f"python-mqtt-{random.randint(0, 1000)}"

config_files = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")

def connect_mqtt():
    def on_connect(client, userdata, flags, rc):
        if rc == 0:
            print("Connected to MQTT Broker!")
        else:
            print("Failed to connect, return code %d\n", rc)

    client = mqtt_client.Client(client_id)
    client.on_connect = on_connect
    client.connect(broker, port)
    return client


def publish(client):
    while True:
        time.sleep(10)
        try:
            with open(config_files, 'r') as f:
                data = json.load(f)
                msg = data['temperature']
                result = client.publish(topic, msg)
        except:
            print("Failed to load configuration.")


def run():
    client = connect_mqtt()
    client.loop_start()
    publish(client)


if __name__ == '__main__':
    run()
