# -*- coding: utf-8 -*-
"""Serbest tarama: kamera sayfaların üzerinde gezdirilirken gelen karelerden PDF'e girecekleri seçer.
iPhone programındaki düzenin karşılığıdır (SeriesSelection / FrameAnalysis): her yarım saniyelik dilimin EN TEMİZ karesi alınır
(bozuk karesiz olan önce, sonra netlik / bloklaşma puanı); sonra çok bulanık ve birbirinin aynısı kareler azaltılır."""
import io

import numpy as np
from PIL import Image

from . import pdfwrap

CLEAN_BLOCKINESS = 1.05     # buraya kadar bloklaşma cezası yok
BLOCK_PENALTY = 10.0        # üstündeki her birim netlik puanını bu katsayıyla böler
DAMAGED_BLOCKINESS = 1.22   # bundan bozuk kare "geçersiz" sayılır (yerine iyisi varsa seçilmez)
BLUR_SHARE = 0.25           # ortanca netliğin bu oranının altındaki kare "çok bulanık"tır
NEIGHBOR_SECONDS = 2.0      # çok bulanık kare, bu kadar yakınında daha net kare varsa atılır
REPEAT_DIFFERENCE = 1.2     # ardışık iki karenin imza farkı bundan küçükse "aynı görüntü" sayılır
REPEAT_KEEP = 2             # aynı görüntünün en iyi bu kadar karesi kalır
SIGNATURE = (24, 16)        # hareket / tekrar ölçümü için küçültülmüş parlaklık ızgarası


def blockiness(gray, skip_top=0):
    """16 piksellik blok sınırlarındaki kenar şiddetinin blok içindekine oranı (yatay ve dikeyin geometrik ortalaması).
    Sağlam görüntüde yaklaşık 1; bozulup bloklaşmış görüntüde belirgin biçimde büyük. iPhone'daki ölçümün aynısı."""
    h, w = gray.shape
    if w < 64 or h < 64:
        return 1.0
    top = max(0, min(skip_top, h // 2))
    g = gray.astype(np.int16)
    xs = np.arange(16, w - 8, 16)
    rows = g[(top + 1) & ~1::2]
    if xs.size == 0 or rows.size == 0:
        return 1.0
    edge_v = np.abs(rows[:, xs] - rows[:, xs - 1]).mean()
    ref_v = np.abs(rows[:, xs + 8] - rows[:, xs + 7]).mean()
    ys = np.arange(((top + 15) // 16 + 1) * 16, h - 8, 16)
    if ys.size == 0:
        return 1.0
    cols = g[:, ::2]
    edge_h = np.abs(cols[ys] - cols[ys - 1]).mean()
    ref_h = np.abs(cols[ys + 8] - cols[ys + 7]).mean()
    v = (edge_v + 1.0) / (ref_v + 1.0)
    hh = (edge_h + 1.0) / (ref_h + 1.0)
    return float(np.sqrt(v * hh))


def sharpness(gray, skip_top=0):
    """Netlik: 2x küçültülmüş parlaklıkta Laplace'ın varyansı (yazı netleştikçe büyür)."""
    g = gray[skip_top::2, ::2].astype(np.float32)
    if g.shape[0] < 8 or g.shape[1] < 8:
        return 0.0
    lap = 4.0 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return float(lap.var())


def signature(gray, skip_top=0):
    """Görüntünün küçük parlaklık özeti: iki kare aynı yeri mi gösteriyor diye karşılaştırılır."""
    g = gray[skip_top:]
    h, w = g.shape
    gw, gh = SIGNATURE
    if h < gh or w < gw:
        return np.zeros((gh, gw), np.float32)
    g = g[:h - h % gh, :w - w % gw]
    return g.reshape(gh, g.shape[0] // gh, gw, g.shape[1] // gw).mean(axis=(1, 3)).astype(np.float32)


def difference(a, b):
    return float(np.abs(a - b).mean())


def clean_score(sharp, block):
    return sharp / (1.0 + BLOCK_PENALTY * max(0.0, block - CLEAN_BLOCKINESS))


def encode_jpeg(rgb, quality=0.85):
    buf = io.BytesIO()
    Image.fromarray(rgb).save(buf, "JPEG", quality=int(round(quality * 100)))
    return buf.getvalue()


class Shot:
    """Seçilmiş bir kare."""
    __slots__ = ("jpeg", "time", "sharp", "block", "clean", "sig", "valid")

    def __init__(self, jpeg, t, sharp, block, clean, sig):
        self.jpeg, self.time, self.sharp, self.block, self.clean, self.sig = jpeg, t, sharp, block, clean, sig
        self.valid = bool(clean) and block < DAMAGED_BLOCKINESS

    @property
    def score(self):
        return (1e12 if self.valid else 0.0) + clean_score(self.sharp, self.block)


class ScanCollector:
    """Bir taramanın karelerini toplar. Her 1/rate saniyelik dilimde en yüksek puanlı kare tutulur; dilim kapanınca JPEG'e çevrilir
    (bellekte yalnız seçilen kareler kalır)."""

    def __init__(self, seconds, rate=2, quality=0.85, skip_share=0.05):
        self.seconds, self.rate, self.quality, self.skip_share = float(seconds), max(1, int(rate)), quality, skip_share
        self.start = None
        self.shots = []
        self.seen = 0               # ölçülen kare sayısı
        self.damaged = 0            # geçersiz (bozuk) kare sayısı
        self._slot = -1
        self._best = None           # (puan, rgb, zaman, netlik, blok, temiz, imza)

    def add(self, rgb, gray, t, clean=True):
        """Bir kare ekler. Tarama süresi dolduysa False döner."""
        if self.start is None:
            self.start = t
        rel = t - self.start
        if rel >= self.seconds:
            return False
        skip = int(round(gray.shape[0] * self.skip_share))      # kameranın tarih / saat yazısı ölçüme girmez
        sharp, block = sharpness(gray, skip), blockiness(gray, skip)
        valid = bool(clean) and block < DAMAGED_BLOCKINESS
        self.seen += 1
        self.damaged += 0 if valid else 1
        slot = int(rel * self.rate)
        if slot != self._slot:
            self._close()
            self._slot = slot
        score = (1e12 if valid else 0.0) + clean_score(sharp, block)
        if self._best is None or score > self._best[0]:
            self._best = (score, rgb, rel, sharp, block, clean, signature(gray, skip))
        return True

    def _close(self):
        if self._best is not None:
            _, rgb, rel, sharp, block, clean, sig = self._best
            self.shots.append(Shot(encode_jpeg(rgb, self.quality), rel, sharp, block, clean, sig))
            self._best = None

    def elapsed(self, now):
        return 0.0 if self.start is None else now - self.start

    def finish(self):
        self._close()
        return self.shots


def thin(shots):
    """Sınırlı azaltma (iPhone'daki gibi, yazı okumadan): çok bulanık kare yakınında daha neti varsa atılır; aynı görüntünün art arda
    kareleri en iyi REPEAT_KEEP tanesine iner. Dönüş: (kalanlar, {"blurry": n, "repeats": n, "damaged": n})."""
    report = {"blurry": 0, "repeats": 0, "damaged": 0}
    if len(shots) <= 2:
        return list(shots), report
    # 0) Bozuk kare: yakınında sağlamı varsa atılır
    kept = []
    for s in shots:
        near = [o for o in shots if o is not s and abs(o.time - s.time) <= NEIGHBOR_SECONDS and o.valid]
        if not s.valid and near:
            report["damaged"] += 1
        else:
            kept.append(s)
    # 1) Çok bulanık kare: iki yanında (yakında) daha net kare varsa atılır
    floor = float(np.median([s.sharp for s in kept])) * BLUR_SHARE if kept else 0.0
    out = []
    for s in kept:
        before = any(o.time < s.time and s.time - o.time <= NEIGHBOR_SECONDS and o.sharp >= floor for o in kept)
        after = any(o.time > s.time and o.time - s.time <= NEIGHBOR_SECONDS and o.sharp >= floor for o in kept)
        if s.sharp < floor and before and after:
            report["blurry"] += 1
        else:
            out.append(s)
    # 2) Art arda aynı görüntü: en iyi REPEAT_KEEP kare kalır (zaman sırası korunur)
    result, run = [], []

    def flush():
        if len(run) > REPEAT_KEEP:
            best = sorted(sorted(run, key=lambda x: -x.score)[:REPEAT_KEEP], key=lambda x: x.time)
            report["repeats"] += len(run) - len(best)
            result.extend(best)
        else:
            result.extend(run)

    for s in out:
        if run and difference(run[-1].sig, s.sig) >= REPEAT_DIFFERENCE:
            flush()
            run = []
        run.append(s)
    flush()
    return result, report


def label(shot, rate, floor):
    """PDF sayfasının etiketi: karenin çekildiği zaman aralığı ve zayıfsa nedeni (Gemini'ye ipucu)."""
    step = 1.0 / rate
    a = int(shot.time * rate) * step
    text = ("%.1f–%.1f sn" % (a, a + step)).replace(".", ",")
    if not shot.valid:
        text += " (bozuk kare)"
    elif shot.sharp < floor:
        text += " (bulanık kare)"
    return text


def build(shots, rate, thin_frames=True, title="Tarama"):
    """Seçilen karelerden PDF. Dönüş: (pdf baytları, etiketler, rapor)."""
    kept, report = thin(shots) if thin_frames else (list(shots), {"blurry": 0, "repeats": 0, "damaged": 0})
    floor = float(np.median([s.sharp for s in kept])) * BLUR_SHARE if kept else 0.0
    labels = [label(s, rate, floor) for s in kept]
    pdf = pdfwrap.jpegs_to_pdf([s.jpeg for s in kept], title=title) if kept else b""
    report["pages"] = len(kept)
    return pdf, labels, report
