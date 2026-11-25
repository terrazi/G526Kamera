# -*- coding: utf-8 -*-
"""Soruları verilen kaynaklara göre cevaplama (iPhone programındaki SourceRules / SourceSync'in karşılığı).
Kayıt klasörünün içindeki "Kaynaklar" klasörüne konan belgeler, kullanıcı "Dosyaları senkronize et"e basınca Gemini'nin dosya arama
deposuna işlenir: yeni ya da değişen dosya yüklenir, klasörden silinen depodan silinir, depoda eksilen yeniden yüklenir, değişmeyen
yeniden gönderilmez. Kendiliğinden yükleme yoktur. Bitince rapor yazılır. Seçenek kapalıyken hiçbir şey yapılmaz."""
import hashlib
import json
import os
import re
import threading
import time

from . import gemini as G
from .applog import log

FOLDER = "Kaynaklar"
STORE_TITLE = "Sesli Kontrol Kaynaklar"
MAX_BYTES = 100_000_000
MIME = {"pdf": "application/pdf", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "txt": "text/plain", "md": "text/markdown"}
SETTLE_POLLS, SETTLE_PAUSE = 24, 5.0
_PAGE = re.compile(rb"/Type\s*/Page(?![A-Za-z])")


def mime_type(name):
    return MIME.get(os.path.splitext(name)[1].lower().lstrip("."))


def page_count(path):
    """PDF'in sayfa sayısı (yaklaşık: sayfa nesneleri sayılır; sıkıştırılmış yapılı PDF'te 0 dönebilir)."""
    if not path.lower().endswith(".pdf"):
        return 0
    try:
        with open(path, "rb") as f:
            return len(_PAGE.findall(f.read()))
    except OSError:
        return 0


def size_text(size):
    mb = size / 1_000_000.0
    if mb >= 10:
        return "%d MB" % round(mb)
    if mb >= 1:
        return ("%.1f MB" % mb).replace(".", ",")
    return "%d KB" % max(1, size // 1000)


def grouped(number):
    return "{:,}".format(number).replace(",", ".")


def scan(folder):
    """Klasördeki kaynak dosyaları (ada göre) ve yüklenmeyecek olanlar. Dosya: {"name","bytes","pages"}"""
    files, skipped = [], []
    try:
        names = sorted(os.listdir(folder), key=lambda n: n.lower())
    except OSError:
        return files, skipped
    for name in names:
        path = os.path.join(folder, name)
        if name.startswith(".") or name.startswith("~$") or not os.path.isfile(path):
            continue
        if not mime_type(name):
            skipped.append("%s: desteklenmeyen tür (PDF, Word .docx ya da metin olmalı)" % name)
            continue
        size = os.path.getsize(path)
        if size <= 0:
            skipped.append("%s: boş dosya" % name)
        elif size > MAX_BYTES:
            skipped.append("%s: 100 MB'tan büyük (%s)" % (name, size_text(size)))
        else:
            files.append({"name": name, "bytes": size, "pages": page_count(path)})
    return files, skipped


def summary(files):
    parts = ["%d kaynak" % len(files)]
    pages = sum(f["pages"] for f in files)
    if pages:
        parts.append("%s sayfa" % grouped(pages))
    parts.append(size_text(sum(f["bytes"] for f in files)))
    return ", ".join(parts)


def same_content(file, doc, uploaded):
    if doc["title"] in uploaded:
        return uploaded[doc["title"]] == file["bytes"]
    if doc.get("bytes"):
        return doc["bytes"] == file["bytes"]
    return True


def plan(local, remote, uploaded):
    """Depo klasörün aynası olur. Dönüş: {"upload": [...], "remove": [...], "keep": [...]}"""
    by_name = {f["name"]: f for f in local}
    covered, out = set(), {"upload": [], "remove": [], "keep": []}
    for doc in remote:
        file = by_name.get(doc["title"])
        if (file is None or doc["title"] in covered or doc["state"] == "STATE_FAILED"
                or not same_content(file, doc, uploaded)):
            out["remove"].append(doc)
            continue
        covered.add(doc["title"])
        out["keep"].append(doc)
    out["upload"] = [f for f in local if f["name"] not in covered]
    return out


def new_state():
    return {"store": "", "uploaded": {}, "active": [], "pending": [], "failed": {}, "synced": [], "date": 0, "problem": "", "rejected": ""}


def out_of_date(state, files):
    if not state:
        return bool(files)
    return state["synced"] != files or bool(state["pending"] or state["failed"] or state["problem"])


def state_text(state, files):
    if not state or not (state["date"] or state["problem"]):
        return "depoda kaynak yok" if not files else "henüz yüklenmedi, senkronize edin"
    text = "depoda hazır kaynak yok" if not state["active"] else "%d kaynak hazır" % len(state["active"])
    if state["pending"]:
        text += ", %d kaynağı Google işliyor" % len(state["pending"])
    if state["failed"]:
        name = sorted(state["failed"])[0]
        text += ", %d dosya yüklenemedi (%s: %s)" % (len(state["failed"]), name, state["failed"][name])
    if state["problem"]:
        text += "; senkronize edilemedi: " + state["problem"]
    if state["rejected"]:
        text += "; Gemini depoyu kabul etmedi: " + state["rejected"]
    if state["synced"] != files:
        text += "; klasör değişmiş, senkronize edin"
    if state["date"]:
        text += " (son senkron %s)" % time.strftime("%d.%m %H:%M", time.localtime(state["date"]))
    return text


def report_text(r):
    """Senkron bitince kullanıcıya verilen rapor: kaç dosya, ne kadar boyut; yüklenen, silinen, değişmeyen; eksik kalanlar."""
    if r.get("problem"):
        return "Senkron yapılamadı: " + r["problem"]
    complete = not r["failed"] and not r["pending"] and not r["stopped"]
    text = "Senkron tamamlandı: " if complete else "Senkron eksik kaldı: "
    if not r["ready"] and not r["uploaded"] and complete:
        return text + ("klasör boş; depodaki %d kaynak silindi." % r["removed"] if r["removed"] else "klasör boş, depoda kaynak yok.")
    loaded = "yüklenen %d" % len(r["uploaded"])
    if r["uploaded"]:
        loaded += " (%s)" % size_text(sum(f["bytes"] for f in r["uploaded"]))
    text += "%s boyutunda %d dosya senkronize edildi (%s, depodan silinen %d, değişmeyen %d)." % (
        size_text(sum(f["bytes"] for f in r["ready"])), len(r["ready"]), loaded, r["removed"], r["unchanged"])
    if r["pending"]:
        text += " %d dosyayı Google hâlâ işliyor; biraz sonra yeniden senkronize edin." % r["pending"]
    if r["failed"]:
        text += " Yüklenemeyen %d dosya: %s." % (len(r["failed"]), "; ".join("%s (%s)" % kv for kv in sorted(r["failed"].items())))
    if r["stopped"]:
        text += " İşlem sürerken yarıda kaldı; yeniden senkronize edin."
    return text


def key_id(key):
    return hashlib.sha256(key.strip().encode("utf-8")).hexdigest()[:16]


def key_groups(profiles):
    """Ayrı anahtarlar (yuva sırasıyla): [(anahtar, [profil, ...])]. Depo anahtarın projesine aittir."""
    groups = []
    for p in profiles:
        for g in groups:
            if g[0] == p["key"]:
                g[1].append(p)
                break
        else:
            groups.append((p["key"], [p]))
    return groups


def group_label(profiles):
    slots = ["%d." % p["slot"] for p in profiles]
    if len(slots) <= 1:
        return (slots[0] if slots else "") + " profilin anahtarı"
    return ", ".join(slots[:-1]) + " ve " + slots[-1] + " profilin anahtarı"


def _pending(files, remote):
    out = []
    for f in files:
        own = [d for d in remote if d["title"] == f["name"]]
        if not any(d["state"] == "STATE_ACTIVE" for d in own) and any(d["state"] not in ("STATE_ACTIVE", "STATE_FAILED") for d in own):
            out.append(f["name"])
    return out


class SourceSync:
    def __init__(self, settings, directory, profiles, busy_elsewhere=lambda: False, sleep=time.sleep):
        self.s = settings
        self.profiles = profiles                    # () -> kullanılabilir profiller
        self.busy_elsewhere = busy_elsewhere        # tarama / gönderme sürüyor mu: sürerken senkron başlamaz
        self.sleep = sleep
        self.on_change = None
        self._path = os.path.join(directory, "kaynak_durumu.json")
        self._lock = threading.RLock()
        self._thread = None
        self.busy = False
        self.progress = ""
        self.report = []
        try:
            with open(self._path, "r", encoding="utf-8") as f:
                self._states = json.load(f)
        except (OSError, ValueError):
            self._states = {}

    # ---- klasör ve durum
    @property
    def folder(self):
        return os.path.join(self.s.local_dir(), FOLDER)

    def prepare_folder(self):
        try:
            os.makedirs(self.folder, exist_ok=True)
            return True
        except OSError as e:
            log("[kaynak] Kaynaklar klasoru acilamadi: %s" % e)
            return False

    def saved(self, key):
        state = self._states.get(key_id(key))
        if not state:
            return None
        full = new_state()
        full.update(state)
        return full

    def _save(self, key, state):
        with self._lock:
            self._states[key_id(key)] = state
            try:
                with open(self._path, "w", encoding="utf-8") as f:
                    json.dump(self._states, f, ensure_ascii=False)
            except OSError as e:
                log("[kaynak] durum kaydedilemedi: %s" % e)

    def store_for(self, key):
        """Bu anahtarla cevap istenirken kullanılacak depo: seçenek açık ve depoda hazır kaynak varsa adı, yoksa None."""
        if not self.s["use_sources"]:
            return None
        state = self.saved(key)
        return state["store"] if state and state["store"] and state["active"] else None

    def note_rejection(self, key, error):
        state = self.saved(key)
        if not state:
            return
        state["rejected"] = error.message[:160]
        if error.status == 404:
            state.update(store="", active=[], uploaded={})
        self._save(key, state)

    def lines(self):
        """Ayarlardaki durum satırları (seçenek kapalıysa boş)."""
        if not self.s["use_sources"]:
            return []
        files, skipped = scan(self.folder)
        out = ["Klasör: " + self.folder, "Klasörde kaynak yok." if not files else "Klasörde %s." % summary(files)]
        out += ["Yüklenmeyecek: " + s for s in skipped]
        groups = key_groups(self.profiles())
        if not groups:
            out.append("Gemini anahtarı yok: kaynaklar yüklenemez.")
        for key, members in groups:
            text = state_text(self.saved(key), files)
            out.append("%s: %s" % (group_label(members), text) if len(groups) > 1 else "Gemini deposu: " + text)
        return out

    def warning(self):
        """Tarama / gönderme başlarken gösterilecek uyarı; sorun yoksa ya da seçenek kapalıysa ""."""
        if not self.s["use_sources"]:
            return ""
        files, _ = scan(self.folder)
        if not files:
            return "Kaynaklara göre cevaplama açık ama Kaynaklar klasöründe dosya yok. Sorular kaynaksız cevaplanacak."
        groups = key_groups(self.profiles())
        ready = [key for key, _ in groups if self.store_for(key)]
        if not ready:
            return "Kaynaklar Gemini'ye yüklenmemiş. Sorular kaynaksız cevaplanacak. Ayarlardan dosyaları senkronize edin."
        stale = any(out_of_date(self.saved(key), files) or len((self.saved(key) or new_state())["active"]) < len(files) for key, _ in groups)
        if stale:
            return "Kaynaklar senkronize değil: cevaplar depodaki kaynaklara göre verilecek. Ayarlardan dosyaları senkronize edin."
        return ""

    # ---- senkron
    def sync_now(self):
        """"Dosyaları senkronize et" düğmesi. Dönüş: başladı mı."""
        with self._lock:
            if not self.s["use_sources"] or self.busy:
                return False
            self.prepare_folder()
            if self.busy_elsewhere():
                self.progress = "Tarama ya da gönderme sürerken senkron yapılmaz. Önce o işi bitirin."
                return False
            self.busy, self.report, self.progress = True, [], "Senkron başlıyor…"
            self._thread = threading.Thread(target=self._run, daemon=True, name="sk-kaynak")
            self._thread.start()
            return True

    def wait(self, timeout=None):
        t = self._thread
        if t is not None:
            t.join(timeout)

    def _run(self):
        folder = self.folder
        files, skipped = scan(folder)
        groups = key_groups(self.profiles())
        log("[kaynak] senkron basladi: klasorde %s; %d ayri anahtar%s" % (
            summary(files), len(groups), "; yuklenmeyecek: " + " | ".join(skipped) if skipped else ""))
        texts = [] if groups else ["Senkron yapılamadı: Gemini API anahtarı girilmemiş."]
        for key, members in groups:
            label = group_label(members) + ": " if len(groups) > 1 else ""
            texts.append(label + report_text(self._sync(key, label, files, folder)))
        self.busy, self.progress, self.report = False, "", texts
        log("[kaynak] senkron bitti: " + " | ".join(texts))
        if self.on_change:
            self.on_change()

    def _sync(self, key, prefix, files, folder):
        state = self.saved(key) or new_state()
        r = {"uploaded": [], "removed": 0, "unchanged": 0, "ready": [], "pending": 0, "failed": {}, "problem": "", "stopped": False}
        if not files and not state["store"]:
            state = new_state()
            state["date"] = time.time()
            self._save(key, state)
            return r
        try:
            self.progress = prefix + "Gemini deposuna bakılıyor…"
            store = G.source_store(state["store"], STORE_TITLE, key)
            if store != state["store"]:
                state["uploaded"] = {}
            state["store"] = store
            self._save(key, state)
            remote = G.source_documents(store, key)
            p = plan(files, remote, state["uploaded"])
            log("[kaynak] %sdepo %s: %d belge; yuklenecek %d, silinecek %d, yerinde %d" % (
                prefix, store, len(remote), len(p["upload"]), len(p["remove"]), len(p["keep"])))
            kept = {d["title"] for d in p["keep"]}
            for doc in p["remove"]:
                self.progress = prefix + "depodan siliniyor: " + doc["title"]
                try:
                    G.delete_source_document(doc["id"], key)
                    if doc["title"] not in kept:
                        state["uploaded"].pop(doc["title"], None)
                    r["removed"] += 1
                    log("[kaynak] %sdepodan silindi: %s" % (prefix, doc["title"]))
                except G.GeminiError as e:
                    log("[kaynak] %sdepodan silinemedi: %s (%s)" % (prefix, doc["title"], e.message))
            self._save(key, state)
            r["unchanged"] = len(p["keep"])
            sent, failed = [], {}
            for i, file in enumerate(p["upload"]):
                place = "%d/%d: %s (%s)" % (i + 1, len(p["upload"]), file["name"], size_text(file["bytes"]))
                self.progress = prefix + "yükleniyor " + place
                began = time.monotonic()
                try:
                    with open(os.path.join(folder, file["name"]), "rb") as f:
                        data = f.read()
                    name, done, error = G.upload_source(data, mime_type(file["name"]), file["name"], store, key)
                    state["uploaded"][file["name"]] = file["bytes"]
                    self._save(key, state)
                    sent.append(file)
                    log("[kaynak] %syuklendi (%d sn) %s" % (prefix, int(time.monotonic() - began), place))
                    problem = error or None
                    if not problem and not done:
                        self.progress = prefix + "Google işliyor " + place
                        problem = G.wait_source_operation(name, key, 90.0 + file["bytes"] / 1e6 * 8.0, sleep=self.sleep)
                    if problem:
                        failed[file["name"]] = problem
                        log("[kaynak] %sGoogle isleyemedi: %s (%s)" % (prefix, file["name"], problem))
                except (G.GeminiError, OSError) as e:
                    failed[file["name"]] = str(getattr(e, "message", e))[:200]
                    log("[kaynak] %syuklenemedi: %s (%s)" % (prefix, file["name"], failed[file["name"]]))
            remote = G.source_documents(store, key)
            polls = 0
            while _pending(files, remote) and polls < SETTLE_POLLS:
                self.progress = prefix + "Google %d kaynağı işliyor…" % len(_pending(files, remote))
                self.sleep(SETTLE_PAUSE)
                polls += 1
                remote = G.source_documents(store, key)
            active = [f["name"] for f in files if any(d["title"] == f["name"] and d["state"] == "STATE_ACTIVE" for d in remote)]
            for f in files:
                if f["name"] in failed or f["name"] in active:
                    continue
                if any(d["title"] == f["name"] and d["state"] == "STATE_FAILED" for d in remote):
                    failed[f["name"]] = "Google dosyayı işleyemedi"
                elif not any(d["title"] == f["name"] for d in remote):
                    failed[f["name"]] = "depoda görünmüyor"
            state.update(active=active, pending=_pending(files, remote), failed={k: v for k, v in failed.items() if k not in active},
                         synced=files, problem="", rejected="", date=time.time())
            self._save(key, state)
            r.update(uploaded=[f for f in sent if f["name"] not in state["failed"]], ready=[f for f in files if f["name"] in active],
                     pending=len(state["pending"]), failed=state["failed"])
        except G.GeminiError as e:
            state["problem"], state["date"] = e.message[:200], time.time()
            self._save(key, state)
            log("[kaynak] %ssenkronize edilemedi: %s" % (prefix, state["problem"]))
            r["problem"] = state["problem"]
        return r
