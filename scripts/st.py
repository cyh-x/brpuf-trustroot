#!/usr/bin/env python
"""st.py - simple serial test, writes result to file"""
import serial, time, sys, os

result = "NO_TEST"
for port in ['COM3', 'COM4']:
    try:
        s = serial.Serial(port, 115200, timeout=0.5)
        s.write(b'CMD:PING\r\n')
        time.sleep(1)
        d = s.read(256)
        s.close()
        if d:
            result = f"{port}: {d[:80]}"
            break
        else:
            result = f"{port}: no_data"
    except Exception as e:
        result = f"{port}: ERR_{str(e)[:40]}"

with open(os.path.join(os.path.dirname(__file__), 'st_result.txt'), 'w') as f:
    f.write(result)
os._exit(0)
