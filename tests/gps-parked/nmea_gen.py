#!/usr/bin/env python3
"""Fake car GPS for a parked test: RMC + GGA at 1 Hz with the current UTC time, driving
north-east from a start point at a constant speed. GGA has no satellite count, like the car."""
import math, sys, time
from datetime import datetime, timezone

lat = float(sys.argv[2]) if len(sys.argv) > 2 else 56.0  # start point: pass one near the car (Maps route)
lon = float(sys.argv[3]) if len(sys.argv) > 3 else 9.0
speed_ms, bearing = 12.0, 45.0
seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 90

def cs(body):
    c = 0
    for ch in body:
        c ^= ord(ch)
    return f"{c:02X}"

def dm(v, lat_axis):
    a = abs(v); d = int(a); m = (a - d) * 60
    return (f"{d:02d}{m:09.6f}" if lat_axis else f"{d:03d}{m:09.6f}"), ("N" if v >= 0 else "S") if lat_axis else ("E" if v >= 0 else "W")

for _ in range(seconds):
    now = datetime.now(timezone.utc)
    t = now.strftime("%H%M%S.00"); d = now.strftime("%d%m%y")
    la, ns = dm(lat, True); lo, ew = dm(lon, False)
    gga = f"GPGGA,{t},{la},{ns},{lo},{ew},1,,,61.0,M,,M,,"
    rmc = f"GPRMC,{t},A,{la},{ns},{lo},{ew},{speed_ms / 0.514444:.4f},{bearing:.4f},{d},,,"
    sys.stdout.write(f"${gga}*{cs(gga)}\r\n${rmc}*{cs(rmc)}\r\n"); sys.stdout.flush()
    dist = speed_ms
    lat += math.degrees(dist * math.cos(math.radians(bearing)) / 6371000)
    lon += math.degrees(dist * math.sin(math.radians(bearing)) / (6371000 * math.cos(math.radians(lat))))
    time.sleep(1 - (time.time() % 1))
