#!/usr/bin/env python3
"""docs/ISLEM_ZINCIRLERI.md içindeki kod ve test adlarını depoda arar.

Kullanım (depo kökünden): python3 -I docs/check_chains.py
Çıkış kodu 0: bütün adlar bulundu. 1: eksik ad var (listelenir).
Aranan adlar: `test...` ile başlayanlar Tests/ altında "func <ad>" olarak,
`Say.x` Sources/ altında "static (let|var|func) x" olarak, diğer
küçük harfle başlayan tek sözcüklü adlar (camelCase) Sources/ altında
"func <ad>", "case <ad>", "var <ad>", "let <ad>" ya da "enum/struct/class/protocol <ad>" olarak aranır.
"""
import pathlib
import re
import sys

root = pathlib.Path(".")
doc = (root / "docs" / "ISLEM_ZINCIRLERI.md").read_text(encoding="utf-8")


def read_all(folder):
    parts = []
    for p in sorted((root / folder).rglob("*.swift")):
        parts.append(p.read_text(encoding="utf-8"))
    return "\n".join(parts)


sources = read_all("Sources")
tests = read_all("Tests")

names = set(re.findall(r"`([^`\n]+)`", doc))
missing = []
checked = 0
skip_words = {"kod", "test", "docs"}

for raw in sorted(names):
    token = raw.strip()
    # cümle, yol ve komut satırlarını atla
    if " " in token or "/" in token or "." in token and not token.startswith("Say."):
        if not token.startswith("Say."):
            continue
    if token in skip_words:
        continue
    if token.startswith("Say."):
        sym = token[4:]
        pat = r"\b(static\s+(let|var|func)|case)\s+%s\b" % re.escape(sym)
        # Say uzantıları: "static func x(" / "static let x" / "static var x"
        checked += 1
        if not re.search(pat, sources):
            missing.append(token)
        continue
    if token.startswith("test"):
        checked += 1
        if not re.search(r"func\s+%s\s*\(" % re.escape(token), tests):
            missing.append(token)
        continue
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token):
        if token[0].islower() or token[0].isupper():
            checked += 1
            pat = (
                r"(func|case|var|let|enum|struct|class|protocol|extension)\s+%s\b"
                % re.escape(token)
            )
            if not re.search(pat, sources):
                # parametre adı / protokol üyesi olabilir: son çare düz arama
                if not re.search(r"\b%s\b" % re.escape(token), sources):
                    missing.append(token)

print("denetlenen ad: %d, eksik: %d" % (checked, len(missing)))
for m in missing:
    print("  EKSİK:", m)
sys.exit(1 if missing else 0)
