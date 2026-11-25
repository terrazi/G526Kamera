# -*- coding: utf-8 -*-
"""Kameraya baglanti: ag kesfi, PPPP el sikisma, giris, canli video, otomatik yeniden baglanma."""
import json
import os
import random
import re
import socket
import struct
import subprocess
import threading
import time

from . import protocol as P

_IPV4 = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")


def _log(msg):
    from .applog import log
    log("[kamera] " + msg)


def _usable(ip):
    return bool(ip) and bool(_IPV4.match(ip)) and not ip.startswith(("127.", "169.254.", "0.", "255."))


def route_info():
    """(varsayilan_gecitler, bu_bilgisayarin_yerel_ipleri)"""
    gws, locs = [], []
    try:
        if os.name == "nt":
            out = subprocess.run(["route", "print", "-4"], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=10,
                                 creationflags=0x08000000).stdout
            for line in out.decode("utf-8", "replace").splitlines():
                p = line.split()
                if len(p) >= 4 and _IPV4.match(p[0]) and _IPV4.match(p[1]):
                    if p[0] == "0.0.0.0" and p[1] == "0.0.0.0" and _IPV4.match(p[2]):
                        gws.append(p[2])
                    if _IPV4.match(p[3]):
                        locs.append(p[3])
        elif os.path.exists("/proc/net/route"):
            with open("/proc/net/route") as f:
                for line in f.read().splitlines()[1:]:
                    p = line.split()
                    if len(p) > 2 and p[1] == "00000000":
                        gws.append(socket.inet_ntoa(struct.pack("<L", int(p[2], 16))))
    except Exception:
        pass
    return gws, locs


def discover_network(user_ip=None):
    gws, locs = route_info()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            locs.append(info[4][0])
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 9))
        locs.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    locs = [ip for ip in dict.fromkeys(locs) if _usable(ip)]
    gws = [ip for ip in dict.fromkeys(gws) if _usable(ip)]
    nets = []
    for ip in locs + gws:
        base = ip.rsplit(".", 1)[0]
        if base not in nets:
            nets.append(base)
    targets = []
    for ip in ([user_ip] if user_ip else []) + gws + [b + ".1" for b in nets] + ["192.168.100.1"]:
        if ip and ip not in targets and ip not in locs:
            targets.append(ip)
    if not nets:
        nets = ["192.168.100"]
    return targets, nets, locs, gws


def _disable_udp_connreset(sock):
    """Windows: bir UDP gonderimine ICMP 'port yok' donunce recvfrom'un hata vermesini kapatir."""
    code = getattr(socket, "SIO_UDP_CONNRESET", 0x9800000C)
    try:
        sock.ioctl(code, False)
        return
    except Exception:
        pass
    try:
        import ctypes
        from ctypes import wintypes
        flag, ret = wintypes.DWORD(0), wintypes.DWORD(0)
        ctypes.WinDLL("ws2_32").WSAIoctl(ctypes.c_size_t(sock.fileno()), code, ctypes.byref(flag), 4,
                                         None, 0, ctypes.byref(ret), None, None)
    except Exception:
        pass


# ----------------------------------------------------------------- Paket birlestirme
class DrwAssembler:
    """DRW paketlerini numarasina gore siralar, tekrarlari eler, kayip bosluklari atlar."""

    def __init__(self):
        self.expected = None
        self.pending = {}
        self.pending_since = None
        self.duplicates = 0
        self.lost = 0
        self.max_pending = 48
        self.max_ahead = 400
        self.max_wait = 0.3

    def push(self, index, body, now):
        """Donus: (bytes, bosluk_atlandi)"""
        if self.expected is None:
            self.expected = (index + 1) & 0xFFFF
            return body, False
        diff = (index - self.expected) & 0xFFFF
        if diff >= 0x8000:
            diff -= 0x10000
        if diff < 0:
            self.duplicates += 1
            return b"", False
        if diff == 0:
            out = bytearray(body)
            self.expected = (self.expected + 1) & 0xFFFF
            self._drain(out)
            if not self.pending:
                self.pending_since = None
            return bytes(out), False
        if index in self.pending:
            self.duplicates += 1
        else:
            self.pending[index] = body
            if self.pending_since is None:
                self.pending_since = now
        waited = now - (self.pending_since if self.pending_since is not None else now)
        if len(self.pending) > self.max_pending or diff > self.max_ahead or waited > self.max_wait:
            return self._skip_gap()
        return b"", False

    def _drain(self, out):
        while self.expected in self.pending:
            out += self.pending.pop(self.expected)
            self.expected = (self.expected + 1) & 0xFFFF

    def _skip_gap(self):
        if not self.pending:
            return b"", False
        best_key, best_diff = None, 1 << 30
        for key in self.pending:
            d = (key - self.expected) & 0xFFFF
            if d >= 0x8000:
                d -= 0x10000
            if 0 < d < best_diff:
                best_diff, best_key = d, key
        if best_key is None:
            self.pending.clear()
            self.pending_since = None
            return b"", False
        self.lost += best_diff
        self.expected = best_key
        out = bytearray()
        self._drain(out)
        if not self.pending:
            self.pending_since = None
        return bytes(out), True


class VideoFrame:
    __slots__ = ("header", "payload", "loss_before")

    def __init__(self, header, payload, loss_before):
        self.header, self.payload, self.loss_before = header, payload, loss_before


class VideoFrameParser:
    """01AFAFAF + 83 bayt baslik (uzunluk ofset 79, u32 LE) + yuk + F4F3F2F1"""
    HEADER = 83
    LEN_OFF = 79
    MAX_PAYLOAD = 12 * 1024 * 1024
    MARK = b"\x01\xaf\xaf\xaf"

    def __init__(self):
        self.buf = bytearray()
        self.loss_pending = False
        self.frames_parsed = 0
        self.resyncs = 0

    def reset(self):
        self.buf.clear()
        self.loss_pending = False

    def append(self, data, gap_before=False):
        if gap_before:
            if self.buf:
                self.resyncs += 1
            self.buf.clear()
            self.loss_pending = True
        self.buf += data
        frames = []
        pos = 0
        total = len(self.buf)
        while True:
            m = self.buf.find(self.MARK, pos, total)
            if m < 0:
                pos = max(pos, total - 3)
                break
            if m > pos:
                self.resyncs += 1
            pos = m
            if total - pos < self.HEADER:
                break
            plen = struct.unpack_from("<I", self.buf, pos + self.LEN_OFF)[0]
            if plen <= 0 or plen > self.MAX_PAYLOAD:
                pos += 4
                continue
            end = pos + self.HEADER + plen
            if total < end + 4:
                break
            if self.buf[end:end + 4] == P.ENV_TRAILER:
                frames.append(VideoFrame(bytes(self.buf[pos:pos + self.HEADER]),
                                         bytes(self.buf[pos + self.HEADER:end]), self.loss_pending))
                self.loss_pending = False
                self.frames_parsed += 1
                pos = end + 4
            else:
                self.resyncs += 1
                self.loss_pending = True
                pos += 4
        if pos > 0:
            del self.buf[:pos]
        return frames


# ----------------------------------------------------------------- Oturum
class CameraSession:
    def __init__(self, uid, password, manual_ip, video_state, video_stream, tz_hours):
        self.uid = uid
        self.password = password
        self.manual_ip = (manual_ip or "").strip()
        self.video_state = video_state
        self.video_stream = video_stream
        self.tz = tz_hours
        self.did = uid.device_payload()

        self.on_frame = None
        self.on_status = None
        self.on_connected = None
        self.on_device_info = None

        self._stop = threading.Event()
        self.sock = None
        self.cam = None
        self.connected = False
        self.closed_by_camera = False
        self.replies = {}
        self.acked = set()
        self.cmd_index = 0
        self.cmd_bytes = b""
        self.video_asm = DrwAssembler()
        self.cmd_asm = DrwAssembler()
        self.parser = VideoFrameParser()
        self.last_rx = time.time()
        self.last_video_rx = 0.0
        self.video_packets = 0
        self.frames_delivered = 0

    def request_stop(self):
        self._stop.set()

    @property
    def statistics(self):
        return "paket %d, kare %d, kayip %d, tekrar %d" % (
            self.video_packets, self.frames_delivered, self.video_asm.lost, self.video_asm.duplicates)

    def _status(self, text):
        if self.on_status:
            self.on_status(text)

    def _tx(self, data, addr):
        try:
            self.sock.sendto(data, addr)
            return True
        except OSError:
            return False

    # ---- ana akis
    def run(self):
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            try:
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 21)
            except OSError:
                pass
            if os.name == "nt":
                _disable_udp_connreset(self.sock)
            self.sock.bind(("", 0))
            self.sock.settimeout(0.1)
        except OSError as e:
            return "Ag soketi acilamadi: %s" % e
        try:
            return self._run()
        finally:
            try:
                self.sock.close()
            except OSError:
                pass

    def _run(self):
        self._status("Kameraya baglaniliyor...")
        if not self._connect(40):
            return "Durduruldu" if self._stop.is_set() else \
                "Kamera bulunamadi. Bilgisayar kameranin Wi-Fi agina bagli mi?"
        cam = self.cam
        if self.on_connected:
            self.on_connected("%s:%d" % cam)
        self._tx(P.drw_setup(), cam)
        self._pump(0.3)

        self._status("Giris yapiliyor...")
        login = self._command(Commands_login(self.password), "LoginDev")
        if login is not None:
            result = login.get("result")
            if isinstance(result, int) and result != 0:
                return "Kamera girisi reddetti (sifre yanlis olabilir)"
        else:
            _log("LoginDev cevabi gelmedi, devam ediliyor")
        self._command(P.Commands.appoint(self.password, self.tz), "AppointDev", tries=3)
        info = self._command(P.Commands.device_info(), "GetDevInfo", tries=3)
        if info and self.on_device_info:
            self.on_device_info(info)

        self._status("Goruntu isteniyor...")
        user_id = random.randint(1, 100)
        self._open_video(user_id)
        last_keep = time.time()
        stream_start = time.time()
        open_retries = 0
        packets_at_start = self.video_packets

        while not self._stop.is_set():
            self._pump(0.1)
            if self.closed_by_camera:
                return "Kamera baglantiyi kapatti"
            now = time.time()
            if now - last_keep > 2:
                self._tx(P.packet(P.T_ALIVE), cam)
                last_keep = now
            if now - self.last_rx > 6:
                return "Kameradan 6 sn cevap gelmedi"
            if self.video_packets != packets_at_start:
                packets_at_start = self.video_packets
                stream_start = now
                open_retries = 0
            elif now - max(self.last_video_rx, stream_start) > 4:
                if open_retries < 2:
                    open_retries += 1
                    _log("Goruntu gelmiyor, OpenVideo yeniden gonderiliyor (%d)" % open_retries)
                    self._open_video(user_id)
                    stream_start = now
                else:
                    return "Goruntu akisi durdu"

        close_json = P.Commands.open_video(0, self.password, self.video_stream, user_id)
        pkt = P.drw_command(P.CH_CMD, self.cmd_index & 0xFFFF, close_json, self.tz)
        self._tx(pkt, cam)
        self._tx(pkt, cam)
        self._tx(P.packet(P.T_CLOSE), cam)
        return "Durduruldu"

    def _open_video(self, user_id):
        self._command(P.Commands.open_video(self.video_state, self.password, self.video_stream, user_id),
                      None, tries=3, gap=0.3)

    # ---- baglanti kurma
    def _connect(self, timeout):
        targets, nets, locs, gws = discover_network(self.manual_ip)
        _log("Bu bilgisayarin agi: %s | gecit: %s | denenecek: %s" % (
            ", ".join(locs) or "bulunamadi", ", ".join(gws) or "yok", ", ".join(targets)))
        punch = P.packet(P.T_PUNCH, self.did)
        lan = P.packet(P.T_LAN_SEARCH)
        local_port = self.sock.getsockname()[1]
        req = P.packet(P.T_P2P_REQ, self.uid.p2p_request_payload(local_port, locs[0] if locs else None))
        bcasts = ["255.255.255.255"] + [b + ".255" for b in nets]

        t0 = time.time()
        scans = 0
        while not self.connected and not self._stop.is_set() and time.time() - t0 < timeout:
            for b in bcasts:
                self._tx(lan, (b, P.LAN_PORT))
            for ip in targets:
                self._tx(punch, (ip, P.DEV_PORT))
                self._tx(req, (ip, P.DEV_PORT))
                self._tx(lan, (ip, P.LAN_PORT))
            elapsed = time.time() - t0
            if (scans == 0 and elapsed > 4) or (scans == 1 and elapsed > 12):
                scans += 1
                _log("Cevap yok, aglar taraniyor: %s.1-254" % ", ".join(nets))
                for base in nets:
                    for host in range(1, 255):
                        ip = "%s.%d" % (base, host)
                        if ip not in locs:
                            self._tx(punch, (ip, P.DEV_PORT))
            self._pump(0.4, lambda: self.connected)
        return self.connected

    # ---- komutlar
    def _command(self, json_text, wait_name, tries=6, gap=0.4):
        if self.cam is None:
            return None
        index = self.cmd_index & 0xFFFF
        self.cmd_index += 1
        packet = P.drw_command(P.CH_CMD, index, json_text, self.tz)
        if wait_name:
            self.replies.pop(wait_name, None)
        for _ in range(tries):
            if self._stop.is_set():
                break
            self._tx(packet, self.cam)
            if wait_name:
                self._pump(gap, lambda: wait_name in self.replies)
                if wait_name in self.replies:
                    return self.replies[wait_name]
            else:
                self._pump(gap, lambda: index in self.acked)
                if index in self.acked:
                    break
        return self.replies.get(wait_name) if wait_name else None

    # ---- alma
    def _pump(self, duration, until=None):
        deadline = time.time() + duration
        while time.time() < deadline and not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(65535)
            except socket.timeout:
                data = None
            except ConnectionResetError:
                data = None
            except OSError:
                time.sleep(0.02)
                data = None
            if data:
                self._handle(data, addr)
            if until and until():
                return

    def _handle(self, data, addr):
        if len(data) < 4 or data[0] != P.MAGIC:
            return
        if self.cam is not None and self.cam[0] != addr[0]:
            return
        ptype = data[1]
        plen = (data[2] << 8) | data[3]
        payload = data[4:4 + plen]
        self.last_rx = time.time()
        if ptype in (P.T_PUNCH, P.T_P2P_RDY):
            self.cam = addr
            self._tx(P.packet(P.T_P2P_RDY, self.did), addr)
            self._tx(P.packet(P.T_P2P_RDY_ACK, self.did), addr)
            if not self.connected:
                self.connected = True
                _log("El sikisma tamam, kamera %s:%d" % addr)
        elif ptype == P.T_P2P_RDY_ACK:
            self.cam = addr
            if not self.connected:
                self.connected = True
                _log("Baglanti onaylandi, kamera %s:%d" % addr)
        elif ptype == P.T_ALIVE:
            self._tx(P.packet(P.T_ALIVE_ACK), addr)
        elif ptype == P.T_CLOSE:
            self.closed_by_camera = True
            _log("Kamera CLOSE gonderdi")
        elif ptype == P.T_DRW_ACK:
            self._handle_drw_ack(payload)
        elif ptype == P.T_DRW:
            self._handle_drw(payload, addr)

    def _handle_drw_ack(self, p):
        if len(p) < 4 or p[0] != 0xD1 or p[1] != P.CH_CMD:
            return
        count = (p[2] << 8) | p[3]
        i = 4
        for _ in range(count):
            if i + 1 >= len(p):
                break
            self.acked.add((p[i] << 8) | p[i + 1])
            i += 2

    def _handle_drw(self, p, addr):
        if len(p) < 4 or p[0] != 0xD1:
            return
        channel = p[1]
        index = (p[2] << 8) | p[3]
        self._tx(P.drw_acknowledge(channel, index), addr)
        body = p[4:]
        now = time.time()
        if channel == P.CH_CMD:
            data, _gap = self.cmd_asm.push(index, body, now)
            if data:
                self._process_command_bytes(data)
        elif channel == P.CH_VIDEO:
            self.video_packets += 1
            self.last_video_rx = now
            data, gap = self.video_asm.push(index, body, now)
            if data or gap:
                for frame in self.parser.append(data, gap):
                    self.frames_delivered += 1
                    if self.on_frame:
                        self.on_frame(frame)

    def _process_command_bytes(self, data):
        self.cmd_bytes += data
        jsons, self.cmd_bytes = P.mykj_extract(self.cmd_bytes)
        for text in jsons:
            try:
                obj = json.loads(text)
                name = obj.get("cmd")
            except ValueError:
                _log("Cozulemeyen cevap: " + text[:120])
                continue
            if not name:
                continue
            self.replies[name] = obj
            _log("Cevap %s: %s" % (name, text.replace("\t", "").replace("\n", "")[:200]))


def Commands_login(password):
    return P.Commands.login(password)


# ----------------------------------------------------------------- Yeniden baglanan istemci
class CameraClient:
    """Oturumu yonetir; baglanti koparsa kendiliginden yeniden dener."""

    def __init__(self):
        self.on_state = None          # (durum_anahtari, metin)
        self.on_frame = None
        self.on_device_info = None
        self._lock = threading.Lock()
        self._gen = 0
        self._running = False
        self._session = None
        self._thread = None

    @property
    def statistics(self):
        with self._lock:
            s = self._session
        return s.statistics if s else ""

    def start(self, uid, password, manual_ip, video_state, video_stream, tz_hours):
        self.stop()
        with self._lock:
            self._running = True
            self._gen += 1
            gen = self._gen
        self._thread = threading.Thread(
            target=self._loop, args=(gen, uid, password, manual_ip, video_state, video_stream, tz_hours),
            daemon=True, name="sk-kamera")
        self._thread.start()

    def stop(self):
        with self._lock:
            self._running = False
            s = self._session
        if s:
            s.request_stop()

    def _current(self, gen):
        with self._lock:
            return self._running and self._gen == gen

    def _emit(self, key, text):
        if self.on_state:
            self.on_state(key, text)

    def _loop(self, gen, uid, password, manual_ip, video_state, video_stream, tz_hours):
        attempt = 0
        while self._current(gen):
            session = CameraSession(uid, password, manual_ip, video_state, video_stream, tz_hours)
            got_frame = [False]

            def on_status(text, session=session):
                if self._current(gen):
                    self._emit("connecting", text)

            def on_connected(addr, session=session):
                if self._current(gen):
                    self._emit("connected", "Baglandi (%s), goruntu bekleniyor..." % addr)

            def on_frame(frame, session=session):
                if not self._current(gen):
                    return
                if not got_frame[0]:
                    got_frame[0] = True
                    self._emit("streaming", "Canli")
                if self.on_frame:
                    self.on_frame(frame)

            session.on_status = on_status
            session.on_connected = on_connected
            session.on_frame = on_frame
            session.on_device_info = lambda info: self.on_device_info and self.on_device_info(info)
            with self._lock:
                self._session = session
                cancelled = not (self._running and self._gen == gen)
            if cancelled:
                session.request_stop()       # durdur/yeniden baslat tam bu aralikta geldiyse oturum hic baslamasin
            reason = session.run()
            _log("oturum bitti: %s (%s)" % (reason, session.statistics))
            with self._lock:
                if self._session is session:  # eski is parcacigi, yeni baslatilan oturumun kaydini silmesin
                    self._session = None
            if not self._current(gen):
                break
            attempt = 1 if got_frame[0] else attempt + 1
            wait = min(2.0 * attempt, 8.0)
            self._emit("reconnecting", "%s - %d sn sonra yeniden denenecek" % (reason, int(wait)))
            waited = 0.0
            while waited < wait and self._current(gen):
                time.sleep(0.2)
                waited += 0.2
        with self._lock:
            latest = self._gen == gen
        if latest:
            self._emit("stopped", "Kamera kapali")
