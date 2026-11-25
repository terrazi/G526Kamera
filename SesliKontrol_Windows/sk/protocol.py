# -*- coding: utf-8 -*-
"""CS2 PPPP (LookCam / tcam ailesi) paketleri. Gercek kamerada dogrulanmistir."""
import json
import socket
import struct
import time

MAGIC = 0xF1
T_P2P_REQ, T_LAN_SEARCH = 0x20, 0x30
T_PUNCH, T_P2P_RDY, T_P2P_RDY_ACK = 0x41, 0x42, 0x43
T_DRW, T_DRW_ACK = 0xD0, 0xD1
T_ALIVE, T_ALIVE_ACK = 0xE0, 0xE1
T_CLOSE = 0xF0

DEV_PORT = 32100
LAN_PORT = 32108
CH_VIDEO = 0
CH_CMD = 1

ENV_MAGIC = b"\xa0\xaf\xaf\xaf"
ENV_TRAILER = b"\xf4\xf3\xf2\xf1"

_PREFIX_MAP = {"9": "AHCC", "B": "BHCC", "C": "CHCC", "F": "FHBB", "G": "GHBB",
               "H": "HHBB", "I": "IHBB", "J": "JHBB", "K": "KHBB", "T": "THBB", "X": "XHBB"}


def packet(ptype, payload=b""):
    return bytes([MAGIC, ptype, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF]) + payload


def mykj_encode(json_text, tz_hours, now=None):
    body = json_text.encode("utf-8")
    buf = bytearray(26 + len(body) + 4)
    buf[0:4] = ENV_MAGIC
    buf[4] = 0
    buf[5] = tz_hours & 0xFF
    t = int(now if now is not None else time.time()) + tz_hours * 3600
    struct.pack_into("<Q", buf, 6, t)
    struct.pack_into("<I", buf, 22, len(body))
    buf[26:26 + len(body)] = body
    buf[26 + len(body):] = ENV_TRAILER
    return bytes(buf)


def mykj_extract(data):
    """Zarflardaki JSON metinlerini cikarir. Donus: (json_listesi, kalan_baytlar)."""
    out = []
    i = 0
    n = len(data)
    while i + 26 <= n:
        if data[i:i + 4] == ENV_MAGIC:
            length = struct.unpack_from("<I", data, i + 22)[0]
            if length > 1_000_000:
                i += 4
                continue
            start = i + 26
            if start + length > n:
                break
            out.append(data[start:start + length].decode("utf-8", "replace"))
            i = start + length
            if data[i:i + 4] == ENV_TRAILER:
                i += 4
        else:
            i += 1
    return out, bytes(data[i:])


def drw_command(channel, index, json_text, tz_hours):
    inner = bytes([0xD1, channel, (index >> 8) & 0xFF, index & 0xFF]) + mykj_encode(json_text, tz_hours)
    return packet(T_DRW, inner)


def drw_acknowledge(channel, index):
    return packet(T_DRW_ACK, bytes([0xD1, channel, 0x00, 0x01, (index >> 8) & 0xFF, index & 0xFF]))


def drw_setup():
    return packet(T_DRW_ACK, bytes([0xD1, 0x07, 0x00, 0x01, 0xAA, 0xAA]))


class CameraUID:
    """'G123456ABCDE' veya 'GHBB-123456-ABCDE' bicimini kabul eder."""

    def __init__(self, prefix, serial, suffix):
        self.prefix, self.serial, self.suffix = prefix, serial, suffix

    @classmethod
    def parse(cls, text):
        t = (text or "").strip().upper()
        try:
            if "-" in t:
                parts = t.split("-")
                if len(parts) != 3:
                    return None
                return cls(parts[0], int(parts[1]), parts[2])
            if len(t) < 8 or t[0] not in _PREFIX_MAP:
                return None
            return cls(_PREFIX_MAP[t[0]], int(t[1:7]), t[7:])
        except ValueError:
            return None

    def display(self):
        return "%s-%06d-%s" % (self.prefix, self.serial, self.suffix)

    def device_payload(self):
        buf = bytearray(20)
        pb = self.prefix.encode()[:4]
        buf[0:len(pb)] = pb
        struct.pack_into(">Q", buf, 4, self.serial)
        sb = self.suffix.encode()[:8]
        buf[12:12 + len(sb)] = sb
        return bytes(buf)

    def p2p_request_payload(self, local_port, local_ip=None):
        buf = bytearray(36)
        pb = self.prefix.encode()[:7]
        buf[0:len(pb)] = pb
        struct.pack_into(">I", buf, 8, self.serial & 0xFFFFFFFF)
        sb = self.suffix.encode()[:7]
        buf[12:12 + len(sb)] = sb
        buf[19] = 0x02
        buf[20] = local_port & 0xFF
        buf[21] = (local_port >> 8) & 0xFF
        if local_ip:
            try:
                buf[22:26] = socket.inet_aton(local_ip)
            except OSError:
                pass
        return bytes(buf)


def _obj(pairs):
    return json.dumps(dict(pairs), separators=(",", ":"), ensure_ascii=False)


class Commands:
    @staticmethod
    def login(password):
        return _obj([("pwd", password), ("cmd", "LoginDev")])

    @staticmethod
    def appoint(password, tz_hours, now=None):
        local = int(now if now is not None else time.time()) + tz_hours * 3600
        return _obj([("state", 3), ("pwd", password), ("zone", tz_hours),
                     ("zone_s", tz_hours * 3600), ("time", local), ("cmd", "AppointDev")])

    @staticmethod
    def device_info():
        return _obj([("cmd", "GetDevInfo")])

    @staticmethod
    def open_video(state, password, stream, user_id):
        return _obj([("state", state), ("pwd", password), ("stream", stream),
                     ("userid", user_id), ("cmd", "OpenVideo")])
