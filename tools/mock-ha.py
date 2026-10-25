#!/usr/bin/env python3
"""A pretend Home Assistant, for developing HA Overview without a real house.

    python3 tools/mock-ha.py            # listens on 127.0.0.1:8124

Point the widget at it — address 127.0.0.1:8124, any token shaped like one
(aaa.bbb.ccc) — and the panel shows a demo house: lights, a thermostat, a
camera, an alarm, history, energy, a logbook, a to-do list, Assist. Service
calls change its state and come back as state_changed events, so every control
can be tried without touching anything real. It is also how the README's
preview.png is taken.

Two plain HTTP endpoints poke it from outside, to see notifications arrive:

    curl '127.0.0.1:8124/mock/state?entity_id=binary_sensor.front_door&state=on'
    curl '127.0.0.1:8124/mock/notify?title=Hello&message=From+the+mock'

Standard library only. Everything it serves is made up.
"""

import base64
import hashlib
import json
import math
import random
import socket
import struct
import sys
import threading
import time
import urllib.parse
import zlib
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8124
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
HOME = (52.3731, 4.8922)


def now_iso(offset=0):
    return (datetime.now(timezone.utc) - timedelta(seconds=offset)).isoformat()


def ent(entity_id, state, ago=600, **attrs):
    stamp = now_iso(ago)
    return {"entity_id": entity_id, "state": str(state), "attributes": attrs,
            "last_changed": stamp, "last_updated": stamp}


STATES = {s["entity_id"]: s for s in [
    ent("light.living_room", "on", 3600, friendly_name="Living room", brightness=180, color_mode="color_temp",
        supported_color_modes=["color_temp"], color_temp_kelvin=3200, min_color_temp_kelvin=2200,
        max_color_temp_kelvin=6500),
    ent("light.reading_lamp", "off", 7200, friendly_name="Reading lamp", supported_color_modes=["brightness"]),
    ent("light.kitchen", "on", 900, friendly_name="Kitchen", brightness=255, supported_color_modes=["brightness"],
        color_mode="brightness"),
    ent("light.hallway", "off", 5400, friendly_name="Hallway", supported_color_modes=["onoff"]),
    ent("light.garden", "off", 20000, friendly_name="Garden", supported_color_modes=["onoff"]),
    ent("switch.coffee_maker", "off", 4000, friendly_name="Coffee maker", icon="mdi:coffee-maker"),
    ent("fan.ceiling", "on", 1200, friendly_name="Ceiling fan", percentage=66, percentage_step=33,
        supported_features=1),
    ent("cover.living_room_blinds", "open", 10000, friendly_name="Blinds", current_position=70,
        device_class="blind", supported_features=15),
    ent("lock.front_door", "locked", 8000, friendly_name="Front door lock"),
    ent("binary_sensor.front_door", "off", 1500, friendly_name="Front door", device_class="door"),
    ent("binary_sensor.hallway_motion", "off", 300, friendly_name="Hallway motion", device_class="motion"),
    ent("sensor.living_room_temperature", "21.4", 120, friendly_name="Living room temperature",
        unit_of_measurement="°C", device_class="temperature", state_class="measurement"),
    ent("sensor.outdoor_temperature", "12.8", 120, friendly_name="Outdoor temperature",
        unit_of_measurement="°C", device_class="temperature", state_class="measurement"),
    ent("sensor.living_room_humidity", "48", 300, friendly_name="Humidity", unit_of_measurement="%",
        device_class="humidity", state_class="measurement"),
    ent("sensor.power", "412", 30, friendly_name="Power", unit_of_measurement="W", device_class="power",
        state_class="measurement"),
    ent("sensor.grid_import", "5321.4", 60, friendly_name="Grid import", unit_of_measurement="kWh",
        device_class="energy", state_class="total_increasing"),
    ent("sensor.solar_production", "2874.9", 60, friendly_name="Solar production", unit_of_measurement="kWh",
        device_class="energy", state_class="total_increasing"),
    ent("sensor.grid_export", "1022.7", 60, friendly_name="Grid export", unit_of_measurement="kWh",
        device_class="energy", state_class="total_increasing"),
    ent("climate.living_room", "heat", 9000, friendly_name="Thermostat", current_temperature=21.4, temperature=22,
        hvac_modes=["off", "heat", "cool", "auto"], min_temp=7, max_temp=30, target_temp_step=0.5,
        hvac_action="heating", supported_features=1 | 128 | 256),
    ent("media_player.living_room", "playing", 700, friendly_name="Living room speaker", volume_level=0.35,
        media_title="Blue in Green", media_artist="Miles Davis", media_content_type="music",
        supported_features=1 | 4 | 8 | 16 | 32 | 4096 | 16384 | 128 | 256),
    ent("alarm_control_panel.home", "armed_home", 30000, friendly_name="Home alarm", code_arm_required=False,
        code_format="number", supported_features=1 | 2 | 4 | 8),
    ent("camera.driveway", "streaming", 30000, friendly_name="Driveway", entity_picture="/api/camera_proxy/camera.driveway?token=demo",
        supported_features=0),
    ent("weather.home", "partlycloudy", 900, friendly_name="Home", temperature=12.8, temperature_unit="°C",
        humidity=71, wind_speed=14, wind_speed_unit="km/h", pressure=1016, pressure_unit="hPa", supported_features=1),
    ent("todo.shopping", "3", 400, friendly_name="Shopping list", supported_features=15),
    ent("person.alex", "home", 4000, friendly_name="Alex", latitude=HOME[0], longitude=HOME[1], gps_accuracy=20),
    ent("person.sam", "not_home", 7000, friendly_name="Sam", latitude=52.3600, longitude=4.8852, gps_accuracy=30),
    ent("zone.home", "1", 99999, friendly_name="Home", latitude=HOME[0], longitude=HOME[1], radius=100,
        icon="mdi:home"),
    ent("sun.sun", "above_horizon", 20000, friendly_name="Sun"),
    ent("scene.movie_night", "2026-01-01T20:00:00+00:00", 99999, friendly_name="Movie night"),
]}

AREAS = [{"area_id": "living_room", "name": "Living room"}, {"area_id": "kitchen", "name": "Kitchen"}]
DEVICES = []
ENTITY_AREAS = {"light.living_room": "living_room", "light.reading_lamp": "living_room",
                "light.kitchen": "kitchen", "climate.living_room": "living_room"}

TODO = [{"uid": "1", "summary": "Coffee beans", "status": "needs_action"},
        {"uid": "2", "summary": "Oat milk", "status": "needs_action"},
        {"uid": "3", "summary": "Lemons", "status": "needs_action"},
        {"uid": "4", "summary": "Batteries", "status": "completed"}]

NOTIFICATIONS = {
    "new_device": {"notification_id": "new_device", "title": "New device discovered",
                   "message": "A **Smart plug** was found on your network. Open Settings → Devices to set it up.",
                   "created_at": now_iso(1800)},
}

DASHBOARD = {
    "title": "Home",
    "views": [
        {"title": "Home", "path": "home", "icon": "mdi:home",
         "badges": ["person.alex", "person.sam", "sensor.outdoor_temperature"],
         "cards": [
             {"type": "entities", "title": "Living room", "entities": [
                 "light.living_room", "light.reading_lamp", "fan.ceiling", "cover.living_room_blinds",
                 "switch.coffee_maker"]},
             {"type": "thermostat", "entity": "climate.living_room"},
             {"type": "picture-entity", "entity": "camera.driveway"},
             {"type": "sensor", "entity": "sensor.living_room_temperature", "graph": "line", "name": "Temperature"},
             {"type": "grid", "columns": 2, "cards": [
                 {"type": "tile", "entity": "light.kitchen"}, {"type": "tile", "entity": "light.hallway"},
                 {"type": "tile", "entity": "lock.front_door"}, {"type": "tile", "entity": "binary_sensor.front_door"}]},
             {"type": "energy-distribution", "title": "Energy today"},
             {"type": "weather-forecast", "entity": "weather.home", "show_forecast": True},
             {"type": "media-control", "entity": "media_player.living_room"},
             {"type": "todo-list", "entity": "todo.shopping"},
             {"type": "logbook", "hours_to_show": 6, "entities": [
                 "binary_sensor.front_door", "light.kitchen", "light.living_room", "lock.front_door"]},
         ]},
        {"title": "History", "path": "history", "icon": "mdi:chart-line",
         "cards": [
             {"type": "history-graph", "title": "Temperatures", "hours_to_show": 24,
              "entities": ["sensor.living_room_temperature", "sensor.outdoor_temperature"]},
             {"type": "history-graph", "title": "Doors and lights", "hours_to_show": 24,
              "entities": ["binary_sensor.front_door", "light.living_room", "light.kitchen"]},
             {"type": "statistics-graph", "title": "Power, last week", "days_to_show": 7, "period": "hour",
              "entities": ["sensor.power"]},
             {"type": "statistic", "entity": "sensor.solar_production", "name": "Solar today",
              "stat_type": "change", "period": {"calendar": {"period": "day"}}},
         ]},
        {"title": "Security", "path": "security", "icon": "mdi:shield-home",
         "cards": [
             {"type": "alarm-panel", "entity": "alarm_control_panel.home", "states": ["arm_home", "arm_away"]},
             {"type": "map", "entities": ["person.alex", "person.sam", "zone.home"]},
         ]},
    ],
}


# ----------------------------------------------------------------- pictures

def png(width, height, pixel):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def driveway(width=640, height=360, seed=0):
    """A dusk scene: sky, a house with lit windows, a driveway."""
    rnd = random.Random(seed)
    stars = {(rnd.randrange(width), rnd.randrange(height // 3)) for _ in range(40)}
    def pixel(x, y):
        h = y / height
        if (x, y) in stars:
            return (230, 230, 255)
        # house body and roof
        if 200 <= x <= 440 and 150 <= y <= 290:
            if (230 <= x <= 280 or 360 <= x <= 410) and 180 <= y <= 220:
                return (250, 205, 120)  # windows
            if 300 <= x <= 340 and 230 <= y <= 290:
                return (70, 50, 40)  # door
            return (120, 112, 104)
        if 180 <= x <= 460 and 90 <= y < 150 and abs(x - 320) <= (y - 90) * 140 / 60:
            return (80, 60, 58)
        if y > 290:
            # driveway trapezoid
            half = 40 + (y - 290) * 2.2
            if abs(x - 320) < half:
                return (88, 88, 92)
            return (46, 72, 44)
        return (int(30 + 70 * h), int(40 + 60 * h), int(90 + 60 * h))
    return png(width, height, pixel)


CAMERA_FRAMES = [driveway(seed=i) for i in range(2)]


# ---------------------------------------------------------------- websocket

class Socket:
    def __init__(self, conn):
        self.conn = conn
        self.lock = threading.Lock()

    def send(self, message):
        data = json.dumps(message).encode()
        header = bytes([0x81])
        if len(data) < 126:
            header += bytes([len(data)])
        elif len(data) < 65536:
            header += bytes([126]) + struct.pack("!H", len(data))
        else:
            header += bytes([127]) + struct.pack("!Q", len(data))
        with self.lock:
            self.conn.sendall(header + data)

    def read(self, count):
        data = b""
        while len(data) < count:
            chunk = self.conn.recv(count - len(data))
            if not chunk:
                raise ConnectionError
            data += chunk
        return data

    def recv(self):
        b0, b1 = self.read(2)
        size = b1 & 0x7F
        if size == 126:
            size = struct.unpack("!H", self.read(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.read(8))[0]
        mask = self.read(4) if b1 & 0x80 else b"\0\0\0\0"
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.read(size)))
        opcode = b0 & 0x0F
        if opcode == 0x8:
            raise ConnectionError
        if opcode == 0x9:
            return None
        return json.loads(payload.decode()) if opcode == 0x1 else None


CLIENTS = []
CLIENTS_LOCK = threading.Lock()


class Client:
    def __init__(self, sock):
        self.sock = sock
        self.subs = {}  # id -> ("event", event_type) | ("notifications",)

    def result(self, mid, result=None, success=True, error=None):
        message = {"id": mid, "type": "result", "success": success, "result": result}
        if error:
            message["error"] = {"code": "mock", "message": error}
        self.sock.send(message)

    def event(self, mid, event):
        self.sock.send({"id": mid, "type": "event", "event": event})

    def fire(self, event_type, data):
        for mid, sub in list(self.subs.items()):
            if sub == ("event", event_type):
                self.event(mid, {"event_type": event_type, "data": data, "origin": "LOCAL",
                                 "time_fired": now_iso()})

    def notify(self, kind, items):
        for mid, sub in list(self.subs.items()):
            if sub == ("notifications",):
                self.event(mid, {"type": kind, "notifications": items})


def broadcast(fn):
    with CLIENTS_LOCK:
        clients = list(CLIENTS)
    for client in clients:
        try:
            fn(client)
        except OSError:
            pass


def set_state(entity_id, state, **attrs):
    old = STATES.get(entity_id)
    new = json.loads(json.dumps(old)) if old else ent(entity_id, state)
    if new["state"] != str(state):
        new["last_changed"] = now_iso()
    new["state"] = str(state)
    new["attributes"].update(attrs)
    new["last_updated"] = now_iso()
    STATES[entity_id] = new
    LOG.append({"entity_id": entity_id, "state": str(state), "when": time.time()})
    broadcast(lambda c: c.fire("state_changed", {"entity_id": entity_id, "old_state": old, "new_state": new}))


def add_notification(title, message):
    nid = "mock_%d" % int(time.time() * 1000)
    item = {"notification_id": nid, "title": title, "message": message, "created_at": now_iso()}
    NOTIFICATIONS[nid] = item
    broadcast(lambda c: c.notify("added", {nid: item}))


ON_OFF = {"turn_on": "on", "turn_off": "off"}


def call_service(domain, service, data, target):
    ids = (target or {}).get("entity_id") or data.get("entity_id") or []
    if isinstance(ids, str):
        ids = [ids]
    if domain == "persistent_notification":
        if service == "create":
            add_notification(data.get("title", "Notification"), data.get("message", ""))
        elif service in ("dismiss", "dismiss_all"):
            gone = list(NOTIFICATIONS) if service == "dismiss_all" else [data.get("notification_id")]
            items = {nid: NOTIFICATIONS.pop(nid) for nid in gone if nid in NOTIFICATIONS}
            broadcast(lambda c: c.notify("removed", items))
        return
    for entity_id in ids:
        st = STATES.get(entity_id)
        if not st:
            continue
        d = entity_id.split(".")[0]
        if service in ON_OFF:
            attrs = {k: v for k, v in data.items() if k != "entity_id"}
            if "brightness_pct" in attrs:
                attrs["brightness"] = round(attrs.pop("brightness_pct") * 2.55)
            set_state(entity_id, ON_OFF[service], **attrs)
        elif service == "toggle":
            if d == "cover":
                set_state(entity_id, "closed" if st["state"] == "open" else "open")
            else:
                set_state(entity_id, "off" if st["state"] == "on" else "on")
        elif d == "lock" and service in ("lock", "unlock"):
            set_state(entity_id, service + "ed")
        elif d == "cover":
            if service == "set_cover_position":
                pos = data.get("position", 0)
                set_state(entity_id, "open" if pos else "closed", current_position=pos)
            else:
                set_state(entity_id, {"open_cover": "open", "close_cover": "closed"}.get(service, st["state"]))
        elif d == "climate":
            if service == "set_temperature":
                set_state(entity_id, st["state"], temperature=data.get("temperature"))
            elif service == "set_hvac_mode":
                set_state(entity_id, data.get("hvac_mode", st["state"]))
        elif d == "alarm_control_panel":
            set_state(entity_id, {"alarm_arm_home": "armed_home", "alarm_arm_away": "armed_away",
                                  "alarm_arm_night": "armed_night", "alarm_disarm": "disarmed",
                                  "alarm_trigger": "triggered"}.get(service, st["state"]))
        elif d == "media_player":
            if service == "media_play_pause":
                set_state(entity_id, "paused" if st["state"] == "playing" else "playing")
            elif service == "volume_set":
                set_state(entity_id, st["state"], volume_level=data.get("volume_level"))
        elif d == "fan" and service == "set_percentage":
            set_state(entity_id, "on" if data.get("percentage") else "off", percentage=data.get("percentage"))
        elif d == "todo":
            if service == "add_item":
                TODO.append({"uid": str(len(TODO) + 10), "summary": data.get("item", ""), "status": "needs_action"})
            elif service == "update_item":
                for item in TODO:
                    if item["uid"] == data.get("item"):
                        item["status"] = data.get("status", item["status"])
            elif service == "remove_item":
                TODO[:] = [i for i in TODO if i["uid"] not in (data.get("item") or [])]
            set_state(entity_id, str(sum(1 for i in TODO if i["status"] == "needs_action")))


LOG = []


def seed_log():
    t = time.time()
    for ago, entity_id, state in [(5400, "light.living_room", "on"), (4000, "lock.front_door", "unlocked"),
                                  (3950, "binary_sensor.front_door", "on"), (3900, "binary_sensor.front_door", "off"),
                                  (3800, "lock.front_door", "locked"), (2200, "light.kitchen", "off"),
                                  (900, "light.kitchen", "on")]:
        LOG.append({"entity_id": entity_id, "state": state, "when": t - ago})


seed_log()


# ------------------------------------------------------------------ history

def history(entity_ids, start, end):
    out = {}
    for entity_id in entity_ids:
        st = STATES.get(entity_id)
        if not st:
            continue
        rows = []
        if st["attributes"].get("state_class") == "measurement":
            base = float(st["state"])
            amplitude = 4 if "temperature" in entity_id else base * 0.4
            t = start
            while t < end:
                hour = datetime.fromtimestamp(t).hour + datetime.fromtimestamp(t).minute / 60
                value = base + amplitude * math.sin((hour - 9) / 24 * 2 * math.pi) + random.uniform(-0.3, 0.3) * amplitude / 4
                if "outdoor" in entity_id:
                    value -= 2
                rows.append({"s": "%.1f" % value, "lu": t})
                t += 900
        else:
            rnd = random.Random(entity_id)
            t = start
            value = st["state"]
            other = {"on": "off", "off": "on", "locked": "unlocked", "unlocked": "locked"}.get(value, value)
            states = [other, value]
            i = 0
            while t < end:
                rows.append({"s": states[i % 2], "lu": t})
                t += rnd.randint(1200, 9000) if i % 2 else rnd.randint(300, 2400)
                i += 1
            rows.append({"s": st["state"], "lu": end - 600})
        out[entity_id] = rows
    return out


def statistics(ids, start, end, period, types):
    step = {"5minute": 300, "hour": 3600, "day": 86400, "week": 604800, "month": 2592000}.get(period, 3600)
    out = {}
    for sid in ids:
        rows = []
        t = int(start // step * step)
        while t < end:
            hour = datetime.fromtimestamp(t).hour
            if sid == "sensor.power":
                mean = 250 + 400 * max(0, math.sin((hour - 6) / 24 * 2 * math.pi)) + random.uniform(-40, 40)
                row = {"start": t * 1000, "end": (t + step) * 1000, "mean": mean, "min": mean * 0.6, "max": mean * 1.5}
            else:
                # Daylight on a clock shifted by ten hours, so a demo at night
                # still has some sun to show.
                day = (hour + 10) % 24
                solar = max(0.0, math.sin((day - 6) / 12 * math.pi)) if 6 <= day <= 18 else 0.0
                change = {"sensor.solar_production": 1.4 * solar, "sensor.grid_export": 0.6 * solar,
                          "sensor.grid_import": 0.5 + 0.3 * (1 - solar)}.get(sid, 0.2)
                row = {"start": t * 1000, "end": (t + step) * 1000, "change": change, "sum": change}
            rows.append({k: v for k, v in row.items() if k in ("start", "end") or k in types})
            t += step
        out[sid] = rows
    return out


# ------------------------------------------------------------------ handler

def answer(client, msg):
    mid, kind = msg.get("id"), msg.get("type")
    if kind == "ping":
        client.sock.send({"id": mid, "type": "pong"})
    elif kind == "get_config":
        client.result(mid, {"location_name": "Demo House", "version": "2026.10.0", "unit_system": {"temperature": "°C"},
                            "language": "en", "currency": "EUR", "latitude": HOME[0], "longitude": HOME[1]})
    elif kind == "get_panels":
        client.result(mid, {"lovelace": {"component_name": "lovelace", "url_path": "lovelace", "title": None,
                                         "icon": None, "config": {"mode": "storage"}}})
    elif kind == "config/area_registry/list":
        client.result(mid, AREAS)
    elif kind == "config/device_registry/list":
        client.result(mid, DEVICES)
    elif kind == "config/entity_registry/list_for_display":
        client.result(mid, {"entities": [{"ei": e, "ai": ENTITY_AREAS.get(e)} for e in STATES]})
    elif kind == "auth/current_user":
        client.result(mid, {"id": "demo", "name": "Demo", "is_admin": True})
    elif kind == "get_states":
        client.result(mid, list(STATES.values()))
    elif kind == "lovelace/config":
        client.result(mid, DASHBOARD)
    elif kind == "subscribe_events":
        client.subs[mid] = ("event", msg.get("event_type"))
        client.result(mid)
    elif kind == "unsubscribe_events":
        client.subs.pop(msg.get("subscription"), None)
        client.result(mid)
    elif kind == "persistent_notification/subscribe":
        client.subs[mid] = ("notifications",)
        client.result(mid)
        client.event(mid, {"type": "current", "notifications": dict(NOTIFICATIONS)})
    elif kind == "call_service":
        client.result(mid, {"context": {}})
        call_service(msg.get("domain"), msg.get("service"), msg.get("service_data") or {}, msg.get("target"))
    elif kind == "history/history_during_period":
        start = datetime.fromisoformat(msg["start_time"]).timestamp()
        end = datetime.fromisoformat(msg["end_time"]).timestamp() if msg.get("end_time") else time.time()
        client.result(mid, history(msg.get("entity_ids") or [], start, end))
    elif kind == "recorder/statistics_during_period":
        start = datetime.fromisoformat(msg["start_time"]).timestamp()
        end = datetime.fromisoformat(msg["end_time"]).timestamp() if msg.get("end_time") else time.time()
        client.result(mid, statistics(msg.get("statistic_ids") or [], start, end, msg.get("period", "hour"),
                                      msg.get("types") or ["mean"]))
    elif kind == "recorder/statistic_during_period":
        midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        rows = statistics([msg.get("statistic_id")], midnight, time.time(), "hour", ["change"])[msg.get("statistic_id")]
        client.result(mid, {"change": sum(r.get("change", 0) for r in rows)})
    elif kind == "logbook/get_events":
        wanted = msg.get("entity_ids")
        client.result(mid, [e for e in LOG if not wanted or e["entity_id"] in wanted])
    elif kind == "energy/get_prefs":
        client.result(mid, {"energy_sources": [
            {"type": "grid", "flow_from": [{"stat_energy_from": "sensor.grid_import"}],
             "flow_to": [{"stat_energy_to": "sensor.grid_export"}]},
            {"type": "solar", "stat_energy_from": "sensor.solar_production"}], "device_consumption": []})
    elif kind == "assist_pipeline/pipeline/list":
        client.result(mid, {"preferred_pipeline": "demo", "pipelines": [
            {"id": "demo", "name": "Home Assistant", "conversation_engine": "conversation.home_assistant",
             "conversation_language": "en", "language": "en"}]})
    elif kind == "conversation/process":
        text = str(msg.get("text", "")).lower()
        if "light" in text and ("off" in text or "on" in text):
            state = "off" if "off" in text else "on"
            for e in ("light.living_room", "light.kitchen"):
                set_state(e, state)
            speech = "Turned %s the lights" % state
        elif "temperature" in text:
            speech = "It is %s °C in the living room" % STATES["sensor.living_room_temperature"]["state"]
        else:
            speech = "Sorry, I couldn't understand that"
        client.result(mid, {"conversation_id": "demo-conversation", "response": {
            "response_type": "error" if speech.startswith("Sorry") else "action_done",
            "speech": {"plain": {"speech": speech}}}})
    elif kind == "todo/item/list":
        client.result(mid, {"items": TODO})
    elif kind == "weather/subscribe_forecast":
        client.result(mid)
        days = [{"datetime": (datetime.now(timezone.utc) + timedelta(days=i)).isoformat(),
                 "condition": c, "temperature": hi, "templow": lo, "precipitation_probability": p}
                for i, (c, hi, lo, p) in enumerate([("partlycloudy", 14, 8, 10), ("rainy", 11, 7, 80),
                                                    ("cloudy", 12, 6, 30), ("sunny", 16, 7, 0), ("sunny", 17, 9, 0)])]
        client.event(mid, {"type": "daily", "forecast": days})
    elif kind == "render_template":
        client.result(mid)
        client.event(mid, {"result": str(msg.get("template", "")), "listeners": {}})
    elif kind in ("camera/stream", "map_tiles/access_token"):
        client.result(mid, success=False, error="not available in the mock")
    else:
        client.result(mid, success=False, error="the mock does not know " + str(kind))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, body, kind="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/api/websocket":
            return self.websocket()
        if url.path.startswith("/api/camera_proxy/"):
            return self.reply(CAMERA_FRAMES[int(time.time() / 10) % len(CAMERA_FRAMES)], "image/png")
        if url.path == "/mock/state":
            set_state(query["entity_id"], query.get("state", "on"))
            return self.reply(b"ok\n", "text/plain")
        if url.path == "/mock/notify":
            add_notification(query.get("title", "Hello"), query.get("message", ""))
            return self.reply(b"ok\n", "text/plain")
        self.reply(b"not found\n", "text/plain", 404)

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        sock = Socket(self.connection)
        client = Client(sock)
        try:
            sock.send({"type": "auth_required", "ha_version": "2026.10.0"})
            auth = sock.recv()
            if not auth or auth.get("type") != "auth":
                return
            sock.send({"type": "auth_ok", "ha_version": "2026.10.0"})
            with CLIENTS_LOCK:
                CLIENTS.append(client)
            while True:
                msg = sock.recv()
                if msg:
                    answer(client, msg)
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            with CLIENTS_LOCK:
                if client in CLIENTS:
                    CLIENTS.remove(client)
            self.close_connection = True


def tick():
    """Keep the numbers moving, as a real house does."""
    while True:
        time.sleep(15)
        st = STATES["sensor.power"]
        set_state("sensor.power", str(max(80, int(float(st["state"]) + random.randint(-60, 60)))))


if __name__ == "__main__":
    threading.Thread(target=tick, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("mock Home Assistant on http://127.0.0.1:%d" % PORT, flush=True)
    server.serve_forever()
