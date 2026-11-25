# -*- coding: utf-8 -*-
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "SesliKontrol_Windows"))


class FakeGemini:
    """Sahte Gemini sunucusu: cevap isteği, dosya yükleme ve kaynak deposu uçlarını taklit eder; gelen istekleri kaydeder."""

    def __init__(self):
        self.requests = []          # (yöntem, yol, başlıklar, gövde)
        self.replies = []           # generateContent için sıradaki cevaplar: (durum, sözlük)
        self.stores = {}            # depo adı -> {"title": ..., "docs": {id: {...}}}
        self.fail_uploads = set()   # bu adlı dosyaların yüklemesi 400 döner
        self.next = 1
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _reply(self, status, obj, headers=None):
                data = json.dumps(obj).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)

            def _handle(self, method):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                outer.requests.append((method, self.path, {k.lower(): v for k, v in self.headers.items()}, body))
                status, obj, headers = outer.route(method, self.path, body, self.headers)
                self._reply(status, obj, headers)

            def do_GET(self):
                self._handle("GET")

            def do_POST(self):
                self._handle("POST")

            def do_DELETE(self):
                self._handle("DELETE")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        self.base = "http://127.0.0.1:%d/v1beta" % self.port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def answer(self, text, status=200, chunks=None):
        if status != 200:
            self.replies.append((status, {"error": {"code": status, "message": text}}))
            return
        cand = {"finishReason": "STOP", "content": {"parts": [{"text": text}]}}
        if chunks:
            cand["groundingMetadata"] = {"groundingChunks": [{"retrievedContext": {"title": t}} for t in chunks]}
        self.replies.append((200, {"candidates": [cand]}))

    def bodies(self):
        return [json.loads(b.decode("utf-8")) for m, p, h, b in self.requests if ":generateContent" in p]

    def paths(self):
        return ["%s %s" % (m, p) for m, p, h, b in self.requests]

    def route(self, method, path, body, headers):
        bare = path.split("?")[0]
        if ":generateContent" in path:
            if not self.replies:
                return 500, {"error": {"message": "sirada cevap yok"}}, None
            status, obj = self.replies.pop(0)
            return status, obj, None
        if bare == "/upload/v1beta/files":
            self.next += 1
            return 200, {}, {"X-Goog-Upload-URL": "http://127.0.0.1:%d/yukle/dosya/%d" % (self.port, self.next)}
        if bare.startswith("/yukle/dosya/"):
            return 200, {"file": {"name": "files/f%s" % bare.rsplit("/", 1)[1], "uri": "https://ornek/files/f%s" % bare.rsplit("/", 1)[1], "state": "ACTIVE"}}, None
        if bare == "/v1beta/fileSearchStores" and method == "GET":
            return 200, {"fileSearchStores": [{"name": n, "displayName": s["title"]} for n, s in self.stores.items()]}, None
        if bare == "/v1beta/fileSearchStores" and method == "POST":
            name = "fileSearchStores/depo%d" % self.next
            self.next += 1
            self.stores[name] = {"title": json.loads(body.decode())["displayName"], "docs": {}}
            return 200, {"name": name}, None
        if bare.startswith("/upload/v1beta/fileSearchStores/") and bare.endswith(":uploadToFileSearchStore"):
            store = bare[len("/upload/v1beta/"):-len(":uploadToFileSearchStore")]
            meta = json.loads(body.decode())
            if meta["displayName"] in self.fail_uploads:
                return 400, {"error": {"message": "Unsupported file"}}, None
            self.next += 1
            self.pending = (store, meta["displayName"])
            return 200, {}, {"X-Goog-Upload-URL": "http://127.0.0.1:%d/yukle/kaynak/%d" % (self.port, self.next)}
        if bare.startswith("/yukle/kaynak/"):
            store, title = self.pending
            ident = "%s/documents/d%s" % (store, bare.rsplit("/", 1)[1])
            self.stores[store]["docs"][ident] = {"name": ident, "displayName": title, "state": "STATE_ACTIVE", "sizeBytes": str(len(body))}
            return 200, {"name": store + "/upload/operations/is" + bare.rsplit("/", 1)[1], "done": True}, None
        if bare.startswith("/v1beta/fileSearchStores/"):
            rest = bare[len("/v1beta/"):]
            if rest.endswith("/documents") and method == "GET":
                store = rest[:-len("/documents")]
                if store not in self.stores:
                    return 404, {"error": {"message": "store not found"}}, None
                return 200, {"documents": list(self.stores[store]["docs"].values())}, None
            if "/documents/" in rest and method == "DELETE":
                store = rest.split("/documents/")[0]
                self.stores.get(store, {"docs": {}})["docs"].pop(rest, None)
                return 200, {}, None
            if method == "GET":
                return (200, {"name": rest}, None) if rest in self.stores else (404, {"error": {"message": "not found"}}, None)
        return 404, {"error": {"message": "bilinmeyen yol " + path}}, None


@pytest.fixture
def fake(monkeypatch):
    server = FakeGemini()
    monkeypatch.setenv("SK_GEMINI_BASE", server.base)
    yield server
    server.server.shutdown()


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("SK_HOME", str(tmp_path / "ayar"))
    return tmp_path


@pytest.fixture
def settings(home):
    from sk.settings import Settings
    s = Settings()
    s.update({"local_dir": str(home / "kayit"), "p1_key": "ANAHTAR-1", "answer_gap": 0, "pdf_pages": 20})
    return s


class FakeSpeaker:
    def __init__(self):
        self.said = []

    def say(self, text, wait=False, **kw):
        self.said.append(text)

    def stop(self):
        pass
