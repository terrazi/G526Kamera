# -*- coding: utf-8 -*-
"""Ag yardimcilari (yalnizca standart kutuphane).

* urlopen(): urllib.request.urlopen gibi calisir, ama baglanti kurulurken kisa zaman asimi kullanir ve once IPv4 adreslerini dener.
  Windows'ta IPv6 yolu ya da vekil (proxy) yanit vermeyince standart urllib her adres icin tam zaman asimi kadar bekler;
  program bu yuzden dakikalarca "dusunuyor" gorunebiliyordu.
* probe(): bir sunucuya DNS, TCP ve TLS adimlarini ayri ayri deneyip hangisinde takildigini yazar.
"""
import http.client
import socket
import ssl
import time
import urllib.request

CONNECT_BUDGET = 20.0       # bir baglanti denemesinin tum adresler icin toplam suresi (sn)
PER_ADDRESS = 8.0           # tek bir adrese baglanma suresi (sn)


def create_connection(address, timeout=None, source_address=None):
    """socket.create_connection gibi; IPv4 adreslerini once dener, her adrese kisa sure ayirir, toplami sinirlar."""
    host, port = address
    infos = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
    infos.sort(key=lambda i: 0 if i[0] == socket.AF_INET else 1)       # kararli siralama: aile ici sira korunur
    if timeout is socket._GLOBAL_DEFAULT_TIMEOUT:
        timeout = socket.getdefaulttimeout()
    deadline = time.monotonic() + CONNECT_BUDGET
    last = None
    for family, kind, proto, _name, sockaddr in infos:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        per = min(PER_ADDRESS, left)
        if timeout:
            per = min(per, timeout)
        s = socket.socket(family, kind, proto)
        try:
            s.settimeout(per)
            if source_address:
                s.bind(source_address)
            s.connect(sockaddr)
            s.settimeout(timeout)
            return s
        except OSError as e:
            last = e
            s.close()
    raise last if last is not None else socket.timeout("baglanti suresi doldu")


class _Http(http.client.HTTPConnection):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self._create_connection = create_connection


class _Https(http.client.HTTPSConnection):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self._create_connection = create_connection


class _HttpHandler(urllib.request.HTTPHandler):
    def do_open(self, http_class, req, **kw):
        return super().do_open(_Http if http_class is http.client.HTTPConnection else http_class, req, **kw)


class _HttpsHandler(urllib.request.HTTPSHandler):
    def do_open(self, http_class, req, **kw):
        return super().do_open(_Https if http_class is http.client.HTTPSConnection else http_class, req, **kw)


_opener = None


def urlopen(req, timeout=None):
    """urllib.request.urlopen yerine: ayni donus nesnesi ve ayni hatalar (HTTPError, URLError)."""
    global _opener
    if _opener is None:
        _opener = urllib.request.build_opener(_HttpHandler, _HttpsHandler)
    if timeout is None:
        return _opener.open(req)
    return _opener.open(req, timeout=timeout)


def _addresses(host, port):
    infos = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
    seen, out = set(), []
    for family, _k, _p, _n, sa in infos:
        key = (family, sa[0])
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out


def probe(host, port=443, short=False, tries=6.0):
    """Sunucuya adim adim baglanmayi dener. Dondurur: metin satirlari listesi."""
    lines = ["[%s]" % host]
    t0 = time.monotonic()
    try:
        addrs = _addresses(host, port)
    except OSError as e:
        lines.append("  DNS: HATA - ad cozulemedi (%s). Internet/DNS ayarini ya da vekil/guvenlik duvarini denetleyin." % e)
        return lines
    v4 = [a for a in addrs if a[0] == socket.AF_INET]
    v6 = [a for a in addrs if a[0] != socket.AF_INET]
    lines.append("  DNS: tamam (%d IPv4, %d IPv6 adres, %.1f sn)" % (len(v4), len(v6), time.monotonic() - t0))
    working = None
    for fam, ip in v4[:3] + v6[:2]:
        t = time.monotonic()
        s = socket.socket(fam, socket.SOCK_STREAM)
        try:
            s.settimeout(tries)
            s.connect((ip, port))
            lines.append("  %s %s:%d baglandi (%.2f sn)" % ("IPv4" if fam == socket.AF_INET else "IPv6", ip, port, time.monotonic() - t))
            if working is None:
                working = (fam, ip)
        except OSError as e:
            what = "ZAMAN ASIMI (yanit yok)" if isinstance(e, socket.timeout) else "hata: %s" % e
            lines.append("  %s %s:%d %s" % ("IPv4" if fam == socket.AF_INET else "IPv6", ip, port, what))
        finally:
            s.close()
        if short and working:
            break
    if working is None:
        lines.append("  SONUC: hicbir adrese baglanilamadi. Guvenlik duvari, vekil ya da internet baglantisi engelliyor olabilir.")
        return lines
    t = time.monotonic()
    raw = socket.socket(working[0], socket.SOCK_STREAM)
    try:
        raw.settimeout(tries)
        raw.connect((working[1], port))
        with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as tls:
            lines.append("  TLS (sifreli baglanti): tamam (%s, %.2f sn)" % (tls.version(), time.monotonic() - t))
    except ssl.SSLCertVerificationError as e:
        lines.append("  TLS: SERTIFIKA HATASI - %s. Antivirus/guvenlik yazilimi ya da kurum agi sifreli trafigi araya girip degistiriyor olabilir." % (e.verify_message or e))
    except (OSError, ssl.SSLError) as e:
        lines.append("  TLS: HATA - %s" % e)
    finally:
        try:
            raw.close()
        except OSError:
            pass
    return lines
