#!/usr/bin/env python3
"""The one connection between the widget and Home Assistant.

Everything a dashboard needs lives behind Home Assistant's websocket API: the
dashboards themselves (`lovelace/config` has no REST endpoint), the area and
entity registries an auto-generated Overview is built from, and the stream of
state changes that keeps every control honest. qt6-websockets is not part of
the shell, so this process speaks the protocol with the standard library and
the widget talks to it in JSON lines.

A long-lived token is the keys to the house, so it is kept out of everything
another local account can read. It never goes in argv (/proc/<pid>/cmdline is
world-readable), and it is not kept in shell.json, whose permissions the shell
does not control. This process owns it instead: a token the widget passes on
stdin is written to ~/.config/ha-overview/token (mode 0600, in a 0700
directory), and a connect line without one reads it back from there.

    stdin   {"type": "connect", "url": "http://ha.local:8123", "token": "..."}
            ("token" only when there is a new one to keep; omit it to use the saved one)
            {"type": "lovelace", "dashboard": "lovelace"}
            {"type": "call", "id": 7, "domain": "light", "service": "toggle",
             "data": {...}, "target": {"entity_id": "light.desk"}}
            {"type": "refresh"}
            {"type": "subscribe", "key": "md-3", "message": {"type": "render_template", ...}}
            {"type": "unsubscribe", "key": "md-3"}
            {"type": "request", "id": 9, "message": {"type": "camera/stream", ...}}

    stdout  {"type": "status", "state": "connecting|connected|auth_invalid|no_token|error", ...}
            {"type": "token", "stored": true|false, "saved": true|false}
            {"type": "config" | "panels" | "registry" | "lovelace" | "states" | "delta"
                     | "result" | "response" | "subscription" | "user", ...}
"""

import base64
import json
import os
import queue
import socket
import ssl
import stat
import struct
import sys
import threading
import time
import urllib.parse

STATE_BATCH_SEC = 0.25
PING_EVERY_SEC = 30
BACKOFF = [1, 2, 5, 10, 30]
# The largest message accepted from Home Assistant. A big install's full state
# dump is a few MB; anything past this is a broken or hostile server, and the
# connection is dropped before the frame is buffered.
MAX_MESSAGE = 64 * 1024 * 1024
MAX_HANDSHAKE = 64 * 1024

out_lock = threading.Lock()


TOKEN_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "ha-overview")
TOKEN_FILE = os.path.join(TOKEN_DIR, "token")
TOKEN_MAX_BYTES = 8192


def private_token_dir():
    """The token's directory, created 0700, refused if it is not ours."""
    os.makedirs(TOKEN_DIR, mode=0o700, exist_ok=True)
    info = os.lstat(TOKEN_DIR)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise PermissionError("%s is not a directory owned by you" % TOKEN_DIR)
    if stat.S_IMODE(info.st_mode) != 0o700:
        os.chmod(TOKEN_DIR, 0o700)


def load_token():
    try:
        fd = os.open(TOKEN_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return ""
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        # Only a regular file of ours; anything else may have been planted.
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return ""
        if stat.S_IMODE(info.st_mode) & 0o077:
            os.fchmod(handle.fileno(), 0o600)
        return handle.read(TOKEN_MAX_BYTES).decode("utf-8", "replace").strip()


def save_token(token):
    """Write the token atomically, readable by nobody else at any point."""
    private_token_dir()
    temp = os.path.join(TOKEN_DIR, ".token.%d" % os.getpid())
    try:
        os.unlink(temp)
    except FileNotFoundError:
        pass
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(token.encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, TOKEN_FILE)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def emit(message):
    line = json.dumps(message, separators=(",", ":"), ensure_ascii=False)
    with out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def status(state, message=""):
    emit({"type": "status", "state": state, "message": message})


class Closed(Exception):
    pass


class NoToken(Exception):
    pass


class AuthInvalid(Exception):
    pass


def open_socket(host, port, timeout):
    # IPv4 first. A homeassistant.local name resolves over mDNS, and the AAAA
    # query for a host that only announces IPv4 waits out its full five-second
    # timeout before getaddrinfo returns — curl hides that by racing both
    # families, plain create_connection does not.
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror:
        infos = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)

    last = None
    for family, kind, proto, _, address in infos:
        sock = socket.socket(family, kind, proto)
        sock.settimeout(timeout)
        try:
            sock.connect(address)
            return sock
        except OSError as error:
            last = error
            sock.close()
    raise last or OSError("no address")


class WebSocket:
    """RFC 6455 client: just what Home Assistant's API uses."""

    def __init__(self, url, timeout=10):
        parts = urllib.parse.urlsplit(url)
        secure = parts.scheme in ("https", "wss")
        host = parts.hostname or ""
        port = parts.port or (443 if secure else 80)
        path = (parts.path.rstrip("/") or "") + "/api/websocket"

        raw = open_socket(host, port, timeout)
        if secure:
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        self.sock = raw
        self.buffer = b""
        self.send_lock = threading.Lock()

        key = base64.b64encode(os.urandom(16)).decode()
        host_header = host if port in (80, 443) else "%s:%d" % (host, port)
        request = (
            "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, host_header, key)
        )
        self.sock.sendall(request.encode())

        head = b""
        while b"\r\n\r\n" not in head:
            if len(head) > MAX_HANDSHAKE:
                raise Closed("handshake too large")
            chunk = self.sock.recv(4096)
            if not chunk:
                raise Closed("handshake closed")
            head += chunk
        head, self.buffer = head.split(b"\r\n\r\n", 1)
        first = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in first + " ":
            raise Closed("handshake refused: " + first)

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed("connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        size = len(payload)
        if size < 126:
            header += bytes([0x80 | size])
        elif size < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", size)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", size)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self.send_lock:
            self.sock.sendall(header + mask + masked)

    def send(self, message):
        self.send_frame(0x1, json.dumps(message, separators=(",", ":")).encode())

    def recv(self):
        """One complete text message, as parsed JSON. Answers pings itself."""
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode = b0 & 0x0F
            size = b1 & 0x7F
            if size == 126:
                size = struct.unpack("!H", self._read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self._read(8))[0]
            if len(message) + size > MAX_MESSAGE:
                raise Closed("message over %d bytes" % MAX_MESSAGE)
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(size)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if opcode == 0x8:
                raise Closed("server closed the connection")
            if opcode == 0x9:
                self.send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue

            message += payload
            if b0 & 0x80:
                return json.loads(message.decode("utf-8"))

    def close(self):
        try:
            self.send_frame(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class Bridge:
    def __init__(self):
        self.url = ""
        self.token = ""
        self.ws = None
        self.next_id = 1
        # id -> (kind, extra). What a result frame answers.
        self.pending = {}
        self.pending_lock = threading.Lock()
        self.commands = queue.Queue()
        self.changed = {}
        self.removed = set()
        self.changed_lock = threading.Lock()
        self.wanted_dashboards = set()
        # key -> the subscribe message, so a reconnect can subscribe again.
        self.subscriptions = {}
        # key -> the HA id of that subscription on the current connection.
        self.subscription_ids = {}
        self.stopping = False

    # ------------------------------------------------------------- requests

    def request(self, message, kind, extra=None):
        if not self.ws:
            return None
        with self.pending_lock:
            mid = self.next_id
            self.next_id += 1
            self.pending[mid] = (kind, extra)
        message = dict(message)
        message["id"] = mid
        self.ws.send(message)
        return mid

    def ask_lovelace(self, dashboard):
        dashboard = str(dashboard or "lovelace")
        self.wanted_dashboards.add(dashboard)
        message = {"type": "lovelace/config"}
        # The default dashboard is the one without a url_path.
        if dashboard != "lovelace":
            message["url_path"] = dashboard
        self.request(message, "lovelace", dashboard)

    def ask_everything(self):
        self.request({"type": "get_config"}, "config")
        self.request({"type": "get_panels"}, "panels")
        self.request({"type": "config/area_registry/list"}, "areas")
        self.request({"type": "config/device_registry/list"}, "devices")
        self.request({"type": "config/entity_registry/list_for_display"}, "entities")
        self.request({"type": "auth/current_user"}, "user")
        self.request({"type": "get_states"}, "states")
        for dashboard in sorted(self.wanted_dashboards):
            self.ask_lovelace(dashboard)

    # -------------------------------------------------------------- inbound

    def handle(self, message):
        kind = message.get("type")

        if kind == "event":
            key = self.subscription_key(message.get("id"))
            if key is not None:
                emit({"type": "subscription", "key": key, "event": message.get("event")})
                return
            event = message.get("event") or {}
            if event.get("event_type") == "state_changed":
                data = event.get("data") or {}
                entity_id = data.get("entity_id")
                new_state = data.get("new_state")
                with self.changed_lock:
                    if new_state is None:
                        self.removed.add(entity_id)
                        self.changed.pop(entity_id, None)
                    else:
                        self.changed[entity_id] = slim_state(new_state)
                        self.removed.discard(entity_id)
            elif event.get("event_type") in ("lovelace_updated",):
                dashboard = (event.get("data") or {}).get("url_path") or "lovelace"
                if dashboard in self.wanted_dashboards:
                    self.ask_lovelace(dashboard)
            elif event.get("event_type") in ("area_registry_updated", "entity_registry_updated",
                                             "device_registry_updated"):
                self.request({"type": "config/area_registry/list"}, "areas")
                self.request({"type": "config/entity_registry/list_for_display"}, "entities")
                self.request({"type": "config/device_registry/list"}, "devices")
            return

        if kind != "result":
            return

        with self.pending_lock:
            kind_extra = self.pending.pop(message.get("id"), None)
        if not kind_extra:
            return
        what, extra = kind_extra
        ok = message.get("success") is True
        result = message.get("result")
        error = message.get("error") or {}

        if what == "config" and ok:
            emit({"type": "config", "config": slim_config(result)})
        elif what == "panels" and ok:
            emit({"type": "panels", "panels": lovelace_panels(result)})
        elif what == "areas" and ok:
            emit({"type": "registry", "kind": "areas", "items": slim_areas(result)})
        elif what == "devices" and ok:
            emit({"type": "registry", "kind": "devices", "items": slim_devices(result)})
        elif what == "entities" and ok:
            emit({"type": "registry", "kind": "entities", "items": slim_entities(result)})
        elif what == "states" and ok:
            states = {s["entity_id"]: slim_state(s) for s in (result or []) if "entity_id" in s}
            with self.changed_lock:
                self.changed.clear()
                self.removed.clear()
            emit({"type": "states", "states": states})
        elif what == "lovelace":
            if ok:
                emit({"type": "lovelace", "dashboard": extra, "config": result})
            else:
                # config_not_found is the auto-generated Overview: nobody ever
                # took control of it, so the widget builds it from the registry.
                emit({"type": "lovelace", "dashboard": extra, "config": None,
                      "error": error.get("code", "error"), "message": error.get("message", "")})
        elif what == "user" and ok:
            emit({"type": "user", "user": {"id": (result or {}).get("id"), "name": (result or {}).get("name"),
                                           "is_admin": bool((result or {}).get("is_admin"))}})
        elif what == "subscribe":
            if ok:
                self.subscription_ids[extra] = message.get("id")
            else:
                emit({"type": "subscription", "key": extra, "error": error.get("message", "failed")})
        elif what == "response":
            emit({"type": "response", "id": extra, "success": ok, "result": result,
                  "error": error.get("message", "") if not ok else ""})
        elif what == "call":
            emit({"type": "result", "id": extra, "success": ok,
                  "error": error.get("message", "") if not ok else ""})

    # ------------------------------------------------------------- outbound

    def subscription_key(self, mid):
        for key, sid in self.subscription_ids.items():
            if sid == mid:
                return key
        return None

    def subscribe(self, key):
        message = self.subscriptions.get(key)
        if message is None or not self.ws:
            return
        mid = self.request(message, "subscribe", key)
        # Events can arrive before the result frame does.
        self.subscription_ids[key] = mid

    def run_command(self, command):
        kind = command.get("type")
        if kind == "subscribe":
            key = str(command.get("key", ""))
            message = command.get("message")
            if not key or not isinstance(message, dict):
                return
            if key in self.subscriptions and self.subscriptions[key] == message:
                return
            self.unsubscribe(key)
            self.subscriptions[key] = message
            self.subscribe(key)
            return
        if kind == "unsubscribe":
            self.unsubscribe(str(command.get("key", "")))
            self.subscriptions.pop(str(command.get("key", "")), None)
            return
        if kind == "request":
            message = command.get("message")
            if isinstance(message, dict):
                self.request(message, "response", command.get("id"))
            return
        if kind == "lovelace":
            self.ask_lovelace(command.get("dashboard"))
        elif kind == "refresh":
            self.ask_everything()
        elif kind == "call":
            message = {
                "type": "call_service",
                "domain": str(command.get("domain", "")),
                "service": str(command.get("service", "")),
                "service_data": command.get("data") or {},
            }
            if command.get("target"):
                message["target"] = command["target"]
            self.request(message, "call", command.get("id"))

    def unsubscribe(self, key):
        sid = self.subscription_ids.pop(key, None)
        if sid is not None and self.ws:
            self.request({"type": "unsubscribe_events", "subscription": sid}, "unsub")

    # The address images should load from. Qt's own resolver has the same
    # five-second mDNS wait this process avoids, once per camera frame, so a
    # plain-http .local name is handed over as the IP it resolved to. https
    # keeps its name: the certificate is issued for the name, not the IP.
    def peer_url(self):
        parts = urllib.parse.urlsplit(self.url)
        if parts.scheme != "http" or not self.ws:
            return self.url
        try:
            ip = self.ws.sock.getpeername()[0]
        except OSError:
            return self.url
        host = "[%s]" % ip if ":" in ip else ip
        port = ":%d" % parts.port if parts.port else ""
        return "%s://%s%s%s" % (parts.scheme, host, port, parts.path.rstrip("/"))

    def flush_states(self):
        with self.changed_lock:
            if not self.changed and not self.removed:
                return
            changed, removed = self.changed, sorted(self.removed)
            self.changed, self.removed = {}, set()
        emit({"type": "delta", "changed": changed, "removed": removed})

    # ----------------------------------------------------------- lifecycle

    def connect(self):
        if not self.token:
            raise NoToken()
        status("connecting")
        ws = WebSocket(self.url)
        hello = ws.recv()
        if hello.get("type") == "auth_required":
            ws.send({"type": "auth", "access_token": self.token})
            answer = ws.recv()
            if answer.get("type") == "auth_invalid":
                ws.close()
                raise AuthInvalid(answer.get("message", "invalid token"))
            if answer.get("type") != "auth_ok":
                ws.close()
                raise Closed("unexpected auth answer")
        # Short timeouts from here on, so the loop can batch and ping.
        ws.sock.settimeout(STATE_BATCH_SEC)
        self.ws = ws
        with self.pending_lock:
            self.pending.clear()
        self.request({"type": "subscribe_events", "event_type": "state_changed"}, "sub")
        self.request({"type": "subscribe_events", "event_type": "lovelace_updated"}, "sub")
        for registry in ("area_registry_updated", "entity_registry_updated", "device_registry_updated"):
            self.request({"type": "subscribe_events", "event_type": registry}, "sub")
        self.subscription_ids = {}
        for key in list(self.subscriptions):
            self.subscribe(key)
        self.ask_everything()
        emit({"type": "status", "state": "connected", "message": hello.get("ha_version", ""),
              "address": self.peer_url()})

    def serve(self):
        last_ping = time.monotonic()
        while not self.stopping:
            try:
                while True:
                    self.run_command(self.commands.get_nowait())
            except queue.Empty:
                pass

            try:
                message = self.ws.recv()
                self.handle(message)
            except socket.timeout:
                pass

            self.flush_states()
            if time.monotonic() - last_ping > PING_EVERY_SEC:
                self.request({"type": "ping"}, "ping")
                last_ping = time.monotonic()

    def run(self):
        attempt = 0
        while not self.stopping:
            try:
                self.connect()
                attempt = 0
                self.serve()
            except AuthInvalid as error:
                status("auth_invalid", str(error))
                # A wrong token does not get better by retrying every second.
                self.wait_for_new_connect()
                continue
            except NoToken:
                status("no_token")
                self.wait_for_new_connect()
                continue
            except (OSError, Closed, ValueError) as error:
                status("error", describe(error))
            finally:
                if self.ws:
                    self.ws.close()
                    self.ws = None
            delay = BACKOFF[min(attempt, len(BACKOFF) - 1)]
            attempt += 1
            self.sleep(delay)

    def sleep(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and not self.stopping:
            time.sleep(0.1)

    def take_token(self, command):
        """A token on the connect line is new: keep it. Otherwise use the saved one."""
        token = str(command.get("token", "") or "").strip()
        saved = False
        if token:
            try:
                save_token(token)
                saved = True
            except OSError as error:
                status("error", "could not save the token: %s" % error.strerror)
            self.token = token
        else:
            self.token = load_token()
        emit({"type": "token", "stored": bool(self.token), "saved": saved})

    def wait_for_new_connect(self):
        self.reconnect_requested = False
        while not self.stopping and not self.reconnect_requested:
            time.sleep(0.2)

    def read_stdin(self):
        for line in sys.stdin:
            try:
                command = json.loads(line)
            except ValueError:
                continue
            if command.get("type") == "connect":
                self.url = str(command.get("url", "")).rstrip("/")
                self.take_token(command)
                self.reconnect_requested = True
                if self.ws:
                    # Dropping the socket makes serve() fail and reconnect with
                    # the new address and token.
                    try:
                        self.ws.sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                continue
            self.commands.put(command)
        # The shell closed our stdin: the widget is gone.
        self.stopping = True
        os._exit(0)


def describe(error):
    if isinstance(error, socket.gaierror):
        return "no machine by that name"
    if isinstance(error, ConnectionRefusedError):
        return "nothing answers on that address and port"
    if isinstance(error, (socket.timeout, TimeoutError)):
        return "no answer — wrong IP, or the machine is off"
    if isinstance(error, ssl.SSLError):
        return "TLS failed: " + str(error)
    text = str(error)
    return text if text else error.__class__.__name__


# ---- trimming: the widget only needs a fraction of what the registries carry

def slim_state(state):
    # context and last_reported change on every report and nothing reads them.
    return {
        "entity_id": state.get("entity_id"),
        "state": state.get("state"),
        "attributes": state.get("attributes") or {},
        "last_changed": state.get("last_changed"),
        "last_updated": state.get("last_updated"),
    }


def slim_config(config):
    config = config or {}
    return {
        "location_name": config.get("location_name", ""),
        "version": config.get("version", ""),
        "unit_system": config.get("unit_system", {}),
        "language": config.get("language", ""),
        "currency": config.get("currency", ""),
    }


def lovelace_panels(panels):
    out = []
    for key, panel in (panels or {}).items():
        if (panel or {}).get("component_name") != "lovelace":
            continue
        out.append({
            "url_path": panel.get("url_path") or key,
            "title": panel.get("title") or "",
            "icon": panel.get("icon") or "",
            "mode": ((panel.get("config") or {}).get("mode")) or "",
            "require_admin": bool(panel.get("require_admin")),
        })
    return out


def slim_areas(items):
    return [{"area_id": a.get("area_id"), "name": a.get("name"), "icon": a.get("icon"),
             "floor_id": a.get("floor_id")} for a in (items or [])]


def slim_devices(items):
    return [{"id": d.get("id"), "area_id": d.get("area_id"),
             "name": d.get("name_by_user") or d.get("name") or ""} for d in (items or [])]


def slim_entities(result):
    # list_for_display uses one-letter keys: ei entity_id, ai area_id,
    # di device_id, ec entity_category, hb hidden, en name, ic icon,
    # dp display_precision.
    items = (result or {}).get("entities", []) if isinstance(result, dict) else []
    out = []
    for e in items:
        out.append({
            "entity_id": e.get("ei"),
            "area_id": e.get("ai"),
            "device_id": e.get("di"),
            "entity_category": e.get("ec"),
            "hidden": bool(e.get("hb")),
            "name": e.get("en"),
            "icon": e.get("ic"),
            "display_precision": e.get("dp"),
        })
    return out


def main():
    bridge = Bridge()
    first = sys.stdin.readline()
    try:
        command = json.loads(first)
    except ValueError:
        status("error", "no connect line")
        return 2
    bridge.url = str(command.get("url", "")).rstrip("/")
    bridge.take_token(command)
    bridge.reconnect_requested = False
    for dashboard in command.get("dashboards") or []:
        bridge.wanted_dashboards.add(str(dashboard))

    threading.Thread(target=bridge.read_stdin, daemon=True).start()
    bridge.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
