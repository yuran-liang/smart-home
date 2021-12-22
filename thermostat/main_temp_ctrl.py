#! /usr/bin/env python 3.7


import random

from paho.mqtt import client as mqtt_client
import re
import subprocess
import json
import copy

broker = 'localhost'
port = 1883
topic = "esp/dht/temperature"
# generate client ID with pub prefix randomly
client_id = f'python-mqtt-{random.randint(0, 100)}'
# username = 'emqx'
# password = 'public'

temp_default = 27.0
K_p = 1.0

list_files = subprocess.run(["/home/pi/eQ-3-radiator-thermostat/eq3.exp", "00:1A:22:16:D0:FA", "manual"])

config_files = "/home/pi/python_script/temp_ctrl/config.json"

def connect_mqtt() -> mqtt_client:
    def on_connect(client, userdata, flags, rc):
        if rc == 0:
            print("Connected to MQTT Broker!")
        else:
            print("Failed to connect, return code %d\n", rc)

    client = mqtt_client.Client(client_id)
    # client.username_pw_set(username, password)
    client.on_connect = on_connect
    client.connect(broker, port)
    return client


def subscribe(client: mqtt_client):
    def on_message(client, userdata, msg):    
        payload = subprocess.check_output(["/home/pi/eQ-3-radiator-thermostat/eq3.exp", "00:1A:22:16:D0:FA", "sync"])
        payload_bt = []
        for word in payload.decode('utf-8').split('\n'):
            payload_bt.append(word)

                            
        temp = float(re.findall("\d+\.\d+", payload_bt[1])[0])
        valve = float(re.findall("\d+", payload_bt[2])[0])
        temp_meas = float(msg.payload.decode())
        
        try:
            with open(config_files, 'r') as f:
                data = json.load(f)
                temp_desire = data['temperature']            
        except:
          temp_desire = copy.deepcopy(temp_default)
                  
        delta_temp = temp_desire - temp_meas
        
        if abs(delta_temp) > 1:
            temp_ctrl = temp + K_p*delta_temp

            temp_ctrl = min([temp_ctrl, 30])
            temp_ctrl = max([temp_ctrl, 5])

            if temp_ctrl > round(temp_ctrl):
                temp_ctrl = round(temp_ctrl)+0.5
            else:
                temp_ctrl = round(temp_ctrl)


            if (valve < 100 and delta_temp > 0) or delta_temp < 0:
                
                list_files = subprocess.run(["/home/pi/eQ-3-radiator-thermostat/eq3.exp", "00:1A:22:16:D0:FA", "temp", str(temp_ctrl)])       

    client.subscribe(topic)
    client.on_message = on_message


def run():
    client = connect_mqtt()
    subscribe(client)
    client.loop_forever()
    

    
if __name__ == '__main__':
    run()
    



    
    
