# -*- coding: utf-8 -*-
"""
Created on Wed Dec 22 17:35:08 2021

@author: yuran
"""

# Python program to read
# json file
 
 
import json

config_files = "/home/pi/python_script/temp_ctrl/config.json"

with open(config_files, 'r') as f:
    data = json.load(f)
    data['temperature'] -= 2.0

with open(config_files, 'w') as f:
    json.dump(data, f)
    