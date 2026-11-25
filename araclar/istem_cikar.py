# -*- coding: utf-8 -*-
"""iPhone programının (Swift) Gemini talimatlarını Windows programına aynen aktarır: sk/prompts.py dosyasını üretir."""
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()

def literal(name):
    m = re.search(r"static let %s = \"\"\"\n(.*?)\n\s*\"\"\"" % name, src, re.S)
    assert m, name
    lines = m.group(1).split("\n")
    indent = min(len(l) - len(l.lstrip(" ")) for l in lines if l.strip())
    out, cur = [], ""
    for l in lines:
        l = l[indent:] if l.strip() else ""
        if l.endswith("\\"):
            cur += l[:-1]
        else:
            out.append(cur + l)
            cur = ""
    if cur:
        out.append(cur)
    text = "\n".join(out)
    assert "\\" not in text, (name, [x for x in text.split("\n") if "\\" in x][:2])
    return text

page = literal("pageSystemPrompt")
source = literal("sourceInstruction")
# pageText içindeki uzun cümleler (serbest tarama notu)
m = re.search(r'static func pageText\(.*?\n    \}\n', src, re.S)
body = m.group(0)
strings = re.findall(r'"((?:[^"\\]|\\.)*)"', body)
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write('# -*- coding: utf-8 -*-\n"""Gemini talimatlari. BU DOSYA URETILMISTIR: iPhone programinin (surum-4, 885ddbc) AnswerService.swift dosyasindan\n'
            'araclar/istem_cikar.py ile aynen alinir; elle degistirmeyin."""\n\n')
    f.write("PAGE_SYSTEM = %r\n\n" % page)
    f.write("SOURCE_INSTRUCTION = %r\n\n" % source)
    f.write("PAGE_TEXT_STRINGS = %r\n" % strings)
print(len(page), len(source), len(strings))
for i, s in enumerate(strings):
    print(i, s[:110].replace("\n", " "))
