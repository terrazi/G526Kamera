# -*- coding: utf-8 -*-
"""Yerel arayüz sunucusu: yalnız bu bilgisayardan (127.0.0.1) ve gizli anahtarla erişilir."""
import json
import os
import secrets
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .applog import lines, log
from .page import PAGE

MAX_PDF = 100_000_000


def load_key(directory):
    path = os.path.join(directory, "anahtar.txt")
    try:
        with open(path, "r", encoding="ascii") as f:
            key = f.read().strip()
        if len(key) >= 16:
            return key
    except OSError:
        pass
    key = secrets.token_urlsafe(18)
    try:
        with open(path, "w", encoding="ascii") as f:
            f.write(key)
    except OSError:
        pass
    return key


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, app, key, port):
        super().__init__(("127.0.0.1", port), Handler)
        self.app = app
        self.key = key
        self.port = self.server_address[1]
        self.allowed_hosts = {"127.0.0.1:%d" % self.port, "localhost:%d" % self.port}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _host_ok(self):
        return self.headers.get("Host", "") in self.server.allowed_hosts

    def _query(self):
        return urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

    def _key_ok(self):
        supplied = self.headers.get("X-SK-Key")
        if supplied is None:
            supplied = (self._query().get("k") or [""])[0]
        return secrets.compare_digest(supplied or "", self.server.key)

    def _send(self, status, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _raw_body(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > limit:
            return b""
        return self.rfile.read(n)

    def _json_body(self):
        raw = self._raw_body(2_000_000)
        try:
            obj = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            return {}
        return obj if isinstance(obj, dict) else {}

    def _guarded(self, fn, what):
        try:
            fn()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
        except Exception as e:
            log("[web] %s hatasi: %r" % (what, e))
            try:
                self._send(500, {"ok": False, "message": str(e)})
            except OSError:
                pass

    def do_GET(self):
        self._guarded(self._get, "GET")

    def do_POST(self):
        self._guarded(self._post, "POST")

    def _get(self):
        if not self._host_ok():
            return self._send(403, {"error": "host"})
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/ping":
            return self._send(200, {"app": "seslikontrol"})
        if not self._key_ok():
            return self._send(403, "Erişim anahtarı yok. Programı SESLI_KONTROL_BASLAT.bat ile açın.", "text/plain; charset=utf-8")
        app = self.server.app
        if path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if path == "/api/state":
            return self._send(200, app.state())
        if path == "/api/log":
            return self._send(200, {"lines": lines(300)})
        if path == "/api/webcams":
            return self._send(200, app.webcam_cameras(refresh=bool(self._query().get("refresh"))))
        if path == "/api/mics":
            return self._send(200, app.mic_list())
        if path == "/video.mjpg":
            return self._mjpeg()
        return self._send(404, {"error": "yok"})

    def _mjpeg(self):
        app = self.server.app
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=skframe")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        last_id, last_sent = -1, 0.0
        try:
            while True:
                pid, data = app.preview_jpeg()
                now = time.time()
                if data and (pid != last_id or now - last_sent > 3):
                    self.wfile.write(b"--skframe\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                     + str(len(data)).encode() + b"\r\n\r\n" + data + b"\r\n")
                    self.wfile.flush()
                    last_id, last_sent = pid, now
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            return

    def _post(self):
        if not self._host_ok() or not self._key_ok():
            return self._send(403, {"error": "yetki"})
        path = urllib.parse.urlparse(self.path).path
        app = self.server.app
        if path == "/api/pdf":
            data = self._raw_body(MAX_PDF)
            if not data:
                return self._send(200, {"ok": False, "message": "Dosya boş ya da 100 MB'tan büyük."})
            name = (self._query().get("name") or ["sorular.pdf"])[0]
            return self._send(200, app.receive_pdf(data, name))
        body = self._json_body()
        if path == "/api/command":
            return self._send(200, app.command(str(body.get("name") or "")))
        if path == "/api/settings":
            return self._send(200, {"ok": True, "changed": app.update_settings(body)})
        if path == "/api/silence":
            app.speaker.stop()
            return self._send(200, {"ok": True})
        if path == "/api/sources/sync":
            return self._send(200, {"ok": app.sources.sync_now()})
        if path == "/api/open":
            return self._send(200, app.open_folder(str(body.get("which") or "")))
        if path == "/api/key/test":
            return self._send(200, app.test_key(body.get("slot") or 1))
        if path == "/api/camera/restart":
            app._restart_camera()
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "yok"})


def start_server(app, key, preferred_port=8536):
    """Tercih edilen kapı doluysa başka bir kapı dener."""
    last = None
    for port in [preferred_port] + list(range(preferred_port + 1, preferred_port + 15)) + [0]:
        try:
            srv = Server(app, key, port)
            threading.Thread(target=srv.serve_forever, daemon=True, name="sk-web").start()
            return srv
        except OSError as e:
            last = e
    raise last
