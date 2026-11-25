# -*- coding: utf-8 -*-
"""Uygulama ici gunluk (arayuzdeki 'Gunluk' bolumu ve dosya)."""
import collections
import os
import threading
import time

_lines = collections.deque(maxlen=400)
_lock = threading.Lock()
_file = None


def init_file(path):
    global _file
    try:
        _file = open(path, "a", encoding="utf-8", buffering=1)
    except OSError:
        _file = None


def log(msg):
    line = time.strftime("%H:%M:%S ") + str(msg)
    with _lock:
        _lines.append(line)
        if _file:
            try:
                _file.write(line + "\n")
            except OSError:
                pass
    if not os.environ.get("SK_QUIET"):
        try:
            print(line, flush=True)
        except (UnicodeEncodeError, OSError, ValueError):
            pass


def lines(n=120):
    with _lock:
        return list(_lines)[-n:]


def clear():
    with _lock:
        _lines.clear()
