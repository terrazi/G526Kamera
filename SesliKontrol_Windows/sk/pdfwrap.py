# -*- coding: utf-8 -*-
"""JPEG'i yeniden isleme sokmadan tek sayfalik PDF'e sarar.

JPEG baytlari PDF icine oldugu gibi (DCTDecode) konur: cozme, yeniden sikistirma ve resim kutuphanesi yok,
bu yuzden kalite kaybi olmaz, islem milisaniyeler surer ve bellekte yalnizca dosyanin kendisi kadar yer tutar.
"""

DPI = 150.0  # sayfa boyutu = piksel / DPI inc (yalnizca sayfanin kagit boyutunu belirler)

# ------------------------------------------------------------------ OCR metin sayfalari
# Yazi tipi gomulmez: standart Helvetica kullanilir. WinAnsi'de olmayan 6 Turkce harf, kullanilmayan kodlara
# (Differences) ve ToUnicode ile eslenir; boylece harfler dogru gorunur, kopyalanir ve aranir.
_TR_CODES = {"\u011e": 0x81, "\u011f": 0x8D, "\u0130": 0x8F, "\u0131": 0x90, "\u015e": 0x9D, "\u015f": 0xA0}
_TR_USED = set(_TR_CODES.values())
# Helvetica uyumlu karakter genislikleri (1000 birim), kod 32..255
_WIDTHS = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 750, 556, 778, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 556, 611, 278, 278, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 667, 500, 667, 500, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 556, 737, 552, 400, 549, 333, 333, 333, 576, 537, 333, 333, 333, 365, 556, 834, 834, 834, 611, 667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, 556, 556, 556, 556, 556, 556, 556, 549, 611, 556, 556, 556, 556, 500, 556, 500]
PAGE_W, PAGE_H, MARGIN = 595.0, 842.0, 54.0
BODY_SIZE, LEADING, HEAD_SIZE = 10.5, 14.5, 13.0
MAX_TEXT_CHARS = 20000


def _encode(text):
    """Metni PDF'in kullandigi tek baytlik kodlamaya cevirir (Turkce harfler ozel kodlarda)."""
    out = bytearray()
    for ch in text:
        if ch in _TR_CODES:
            out.append(_TR_CODES[ch])
            continue
        if ch == "\u00a0" or ch == "\t":
            ch = " "
        if ord(ch) < 32:
            continue
        try:
            b = ch.encode("cp1252")
        except UnicodeEncodeError:
            b = b"?"
        out.append(63 if b[0] in _TR_USED or b[0] == 0xAD else b[0])
    return bytes(out)


def _width(code_bytes, size):
    return sum(_WIDTHS[b - 32] if b >= 32 else 0 for b in code_bytes) * size / 1000.0


def _wrap(line, max_w, size):
    """Tek satiri sayfa genisligine gore boler (kelime sinirinda; cok uzun kelime karakterden)."""
    enc = _encode(line)
    if _width(enc, size) <= max_w:
        return [enc]
    lines, cur = [], b""
    for word in enc.split(b" "):
        trial = cur + b" " + word if cur else word
        if _width(trial, size) <= max_w:
            cur = trial
            continue
        if cur:
            lines.append(cur)
            cur = b""
        while _width(word, size) > max_w and len(word) > 1:
            k = len(word)
            while k > 1 and _width(word[:k], size) > max_w:
                k -= 1
            lines.append(word[:k])
            word = word[k:]
        cur = word
    if cur:
        lines.append(cur)
    return lines


def _esc(b):
    return b.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


def text_pages(texts):
    """[(sayfa_no, metin)] -> sayfa icerik akislari listesi (bytes). Bos metinler atlanir."""
    per_page = int((PAGE_H - 2 * MARGIN - HEAD_SIZE - 14) // LEADING)
    max_w = PAGE_W - 2 * MARGIN
    pages = []
    for number, text in texts:
        text = (text or "").replace("\r", "").replace("\x0c", "\n").strip()[:MAX_TEXT_CHARS]
        if not text:
            continue
        lines = []
        for raw in text.split("\n"):
            lines.extend(_wrap(raw.rstrip(), max_w, BODY_SIZE) if raw.strip() else [b""])
        while lines and not lines[-1]:
            lines.pop()
        for start in range(0, len(lines), per_page):
            chunk = lines[start:start + per_page]
            head = _encode("Sayfa %d - okunan metin (OCR)%s" % (number, "" if start == 0 else " (devam)"))
            body = b" T* ".join(b"(" + _esc(l) + b") Tj" for l in chunk)
            content = (b"BT /F2 %d Tf %d %d Td (" % (HEAD_SIZE, MARGIN, PAGE_H - MARGIN) + _esc(head) + b") Tj ET\n"
                       b"BT /F1 %s Tf %s TL %d %d Td " % (str(BODY_SIZE).encode(), str(LEADING).encode(),
                                                          MARGIN, PAGE_H - MARGIN - HEAD_SIZE - 20)
                       + body + b" ET")
            pages.append(content)
    return pages


def _to_unicode_cmap():
    rows = []
    for code in range(32, 256):
        if code in _TR_USED:
            uni = [k for k, v in _TR_CODES.items() if v == code][0]
        else:
            try:
                uni = bytes([code]).decode("cp1252")
            except UnicodeDecodeError:
                continue
        rows.append("<%02X> <%04X>" % (code, ord(uni)))
    out = ["/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
           "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
           "/CMapName /Adobe-Identity-UCS def", "/CMapType 2 def",
           "1 begincodespacerange", "<00> <FF>", "endcodespacerange"]
    for i in range(0, len(rows), 100):
        part = rows[i:i + 100]
        out += ["%d beginbfchar" % len(part)] + part + ["endbfchar"]
    out += ["endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end"]
    return "\n".join(out).encode("ascii")



def jpeg_info(data):
    """(genislik, yukseklik, bilesen sayisi) dondurur; JPEG degilse ValueError."""
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        raise ValueError("JPEG degil")
    i, n = 2, len(data)
    while i + 4 <= n:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xFF:
            i += 1
            continue
        if marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker == 0xD9:
            break
        length = (data[i + 2] << 8) | data[i + 3]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if i + 10 > n:
                break
            precision = data[i + 4]
            height = (data[i + 5] << 8) | data[i + 6]
            width = (data[i + 7] << 8) | data[i + 8]
            comps = data[i + 9]
            if precision != 8 or not width or not height or comps not in (1, 3):
                raise ValueError("Desteklenmeyen JPEG (kesinlik %d, bilesen %d)" % (precision, comps))
            return width, height, comps
        i += 2 + length
    raise ValueError("JPEG basligi okunamadi")


def jpegs_to_pdf(jpegs, title="", texts=None):
    """Her JPEG'i kendi sayfasina koyarak cok sayfali PDF baytlari dondurur. Gecersiz JPEG ValueError verir.
    `texts` (JPEG ile ayni sirada, bos olabilir) verilirse okunan metin, resimlerden SONRA ayri sayfalar olarak eklenir."""
    if not jpegs:
        raise ValueError("Sayfa yok")
    safe_title = "".join(c for c in title if 32 <= ord(c) < 127 and c not in "()\\")[:80]
    n = len(jpegs)
    page_nums = [3 + 3 * i for i in range(n)]        # her sayfa: sayfa, resim, icerik nesneleri
    info_num = 3 + 3 * n
    contents = text_pages([(i + 1, t) for i, t in enumerate(texts or [])]) if texts else []
    next_num = info_num + 1
    font1, font2, enc_num, cmap_num = next_num, next_num + 1, next_num + 2, next_num + 3
    text_page_nums = []
    if contents:
        text_page_nums = [next_num + 4 + 2 * i for i in range(len(contents))]    # her sayfa: sayfa + icerik
    all_pages = page_nums + text_page_nums
    parts = [(1, b"<< /Type /Catalog /Pages 2 0 R >>"),
             (2, ("<< /Type /Pages /Kids [%s] /Count %d >>"
                  % (" ".join("%d 0 R" % k for k in all_pages), len(all_pages))).encode("ascii"))]
    for k, jpeg in zip(page_nums, jpegs):
        width, height, comps = jpeg_info(jpeg)
        pw, ph = round(width * 72.0 / DPI, 2), round(height * 72.0 / DPI, 2)
        cs = "/DeviceRGB" if comps == 3 else "/DeviceGray"
        content = ("q %s 0 0 %s 0 0 cm /Im0 Do Q" % (pw, ph)).encode("ascii")
        parts.append((k, ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] "
                          "/Resources << /XObject << /Im0 %d 0 R >> >> /Contents %d 0 R >>"
                          % (pw, ph, k + 1, k + 2)).encode("ascii")))
        head = ("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s "
                "/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n"
                % (width, height, cs, len(jpeg))).encode("ascii")
        parts.append((k + 1, head + jpeg + b"\nendstream"))
        parts.append((k + 2, ("<< /Length %d >>\nstream\n" % len(content)).encode("ascii") + content + b"\nendstream"))
    parts.append((info_num, ("<< /Producer (Sesli Kontrol)" + (" /Title (%s)" % safe_title if safe_title else "")
                             + " >>").encode("ascii")))
    if contents:
        enc = ("<< /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences "
               "[129 /Gbreve 141 /gbreve 143 /Idotaccent /dotlessi 157 /Scedilla 160 /scedilla] >>")
        for num, base in ((font1, "Helvetica"), (font2, "Helvetica-Bold")):
            parts.append((num, ("<< /Type /Font /Subtype /Type1 /BaseFont /%s /Encoding %d 0 R /ToUnicode %d 0 R >>"
                                % (base, enc_num, cmap_num)).encode("ascii")))
        parts.append((enc_num, enc.encode("ascii")))
        cmap = _to_unicode_cmap()
        parts.append((cmap_num, ("<< /Length %d >>\nstream\n" % len(cmap)).encode("ascii") + cmap + b"\nendstream"))
        for pn, content in zip(text_page_nums, contents):
            parts.append((pn, ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Resources << /Font << /F1 %d 0 R "
                               "/F2 %d 0 R >> >> /Contents %d 0 R >>" % (PAGE_W, PAGE_H, font1, font2, pn + 1)).encode("ascii")))
            parts.append((pn + 1, ("<< /Length %d >>\nstream\n" % len(content)).encode("ascii") + content + b"\nendstream"))

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num, body in parts:
        offsets[num] = len(out)
        out += ("%d 0 obj\n" % num).encode("ascii") + body + b"\nendobj\n"
    xref = len(out)
    out += ("xref\n0 %d\n" % (len(parts) + 1)).encode("ascii") + b"0000000000 65535 f \n"
    for num, _ in parts:
        out += ("%010d 00000 n \n" % offsets[num]).encode("ascii")
    out += ("trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(parts) + 1, info_num, xref)).encode("ascii")
    return bytes(out)


def jpeg_to_pdf(jpeg, title=""):
    """Tek sayfalik PDF baytlari."""
    return jpegs_to_pdf([jpeg], title)
