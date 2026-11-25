# -*- coding: utf-8 -*-
"""PDF dosyasını az sayfalı parçalara böler: bir istekte az soru gidince model her soruya daha çok düşünme payı ayırır."""
import io

from .applog import log


def split(pdf, pages_per_part):
    """Dönüş: [(parça baytları, ilk sayfa, son sayfa)], toplam sayfa. Bölünemezse (pypdf yok, şifreli ya da bozuk dosya) tek parça döner
    ve toplam sayfa 0 olur."""
    try:
        from pypdf import PdfReader, PdfWriter
        reader = PdfReader(io.BytesIO(pdf))
        total = len(reader.pages)
        size = max(1, int(pages_per_part))
        if total <= size:
            return [(pdf, 1, total)], total
        parts = []
        for first in range(0, total, size):
            writer = PdfWriter()
            last = min(first + size, total)
            for i in range(first, last):
                writer.add_page(reader.pages[i])
            buf = io.BytesIO()
            writer.write(buf)
            parts.append((buf.getvalue(), first + 1, last))
        return parts, total
    except Exception as e:
        log("[pdf] dosya parcalara bolunemedi (%r); tek istekte gonderiliyor" % (e,))
        return [(pdf, 1, 0)], 0
