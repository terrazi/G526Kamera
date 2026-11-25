# -*- coding: utf-8 -*-
import io
import json
import os
import time
import urllib.request

import numpy as np
import pytest

from conftest import FakeSpeaker


def pdf_bytes(pages=2):
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf)
    for i in range(pages):
        c.drawString(72, 720, "1. Soru metni %d  A) bir B) iki C) uc D) dort E) bes" % i)
        c.showPage()
    c.save()
    return buf.getvalue()


def page(seed, w=640, h=360, blur=0, blocks=False, shift=0):
    """Yazı benzeri çizgileri olan sahte kare (gri ve renkli)."""
    rng = np.random.RandomState(seed)
    gray = np.full((h, w), 235, np.uint8)
    for row in range(20 + shift, h - 10, 14):
        for col in range(10, w - 10, 3):
            if rng.rand() < 0.55:
                gray[row:row + 6, col:col + 2] = 30
    if blur:
        import cv2
        gray = cv2.GaussianBlur(gray, (0, 0), blur)
    if blocks:
        for by in range(0, h, 16):
            for bx in range(0, w, 16):
                gray[by:by + 16, bx:bx + 16] = int(rng.randint(40, 220))
    return np.dstack([gray] * 3), gray


# ------------------------------------------------------------------ cevap satırları ve talimat
def test_cevap_satirlari_iphone_ile_ayni_bicimde_cozulur():
    from sk import answers as A
    rows = A.parse_lines("Soru 4, Denizli, Örgütsel Davranış\n**Soru 5**, Adana, Yönetim\nSoru 4, Bursa, tekrar\n\n7) Ceyhan - Planlama")
    assert [(r["number"], r["option"], r["text"]) for r in rows] == [(4, "Denizli", "Örgütsel Davranış"), (5, "Adana", "Yönetim"), (7, "Ceyhan", "Planlama")]
    assert rows[0]["spoken"] == "Soru 4, Denizli, Örgütsel Davranış"
    assert A.parse_lines("SORU YOK.") == [] and A.is_no_question("soru yok") and not A.is_no_question("Soru 1, Adana, x")


def test_talimat_iphone_surumunden_aynen_alinir():
    from sk import answers as A, prompts as PR
    assert "Sen bir sınav okuyucu asistansın" in PR.PAGE_SYSTEM and "A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum" in PR.PAGE_SYSTEM
    assert "SORU YOK" in PR.PAGE_SYSTEM and "\\" not in PR.PAGE_SYSTEM
    text = A.page_text(12, 2, ["0,0–0,5 sn", "0,5–1,0 sn (bulanık kare)"], "kısa yaz")
    assert "ona Soru 12 de" in text and "Bu mesajda 2 fotoğraflık PDF" in text
    assert '1) 0,0–0,5 sn; 2) 0,5–1,0 sn (bulanık kare)' in text and '"(bozuk kare)"' in text
    assert text.endswith("Kullanıcının ek talimatı: kısa yaz") and "\\(" not in text and "\\n" not in text
    doc = A.doc_text(3, "deneme.pdf", "")
    assert "bütün soruları çöz" in doc and "Soru 3" in doc and "deneme.pdf" in doc
    assert "Şık için HER ZAMAN bu sözcüğü yaz" in A.DOC_SYSTEM and "SORU YOK" in A.DOC_SYSTEM


# ------------------------------------------------------------------ kare seçimi
def test_bozuk_ve_bulanik_kare_olculur():
    from sk import frames as F
    _, sharp = page(1)
    _, blurry = page(1, blur=3)
    _, broken = page(1, blocks=True)
    assert F.sharpness(sharp) > 4 * F.sharpness(blurry)
    assert F.blockiness(sharp) < F.DAMAGED_BLOCKINESS < F.blockiness(broken)
    assert F.clean_score(100, 1.0) == 100 and F.clean_score(100, 1.15) == pytest.approx(50)
    assert F.difference(F.signature(sharp), F.signature(sharp)) == 0


def test_her_dilimin_en_temiz_karesi_secilir_ve_pdf_olur():
    from sk import frames as F
    c = F.ScanCollector(seconds=3, rate=2, quality=0.8)
    t = 100.0
    for i in range(30):                      # 3 sn, saniyede 10 kare; her dilimde bir net, bir bulanık, bir bozuk kare
        kind = i % 5
        rgb, gray = page(i // 5, blur=3 if kind in (0, 1, 3) else 0, blocks=(kind == 4), shift=(i // 5) * 3)
        assert c.add(rgb, gray, t + i * 0.1, clean=(kind != 4))
    assert not c.add(*page(99), t + 3.2), "süre dolunca kare alınmaz"
    shots = c.finish()
    assert len(shots) == 6 and c.seen == 30 and c.damaged == 6
    assert all(s.valid for s in shots), "her dilimde bozuk olmayan kare seçilir"
    median = np.median([F.sharpness(page(n, blur=3)[1]) for n in range(6)])
    assert all(s.sharp > 2 * median for s in shots), "her dilimin net karesi seçilir"
    pdf, labels, report = F.build(shots, 2, True)
    assert pdf.startswith(b"%PDF") and len(labels) == report["pages"] and labels[0].startswith("0,0–0,5 sn")
    from pypdf import PdfReader
    assert len(PdfReader(io.BytesIO(pdf)).pages) == report["pages"]


def test_ayni_goruntunun_tekrari_ve_cok_bulanik_kare_azaltilir():
    from sk import frames as F
    shots = []
    for i in range(6):                       # aynı yer altı kez
        rgb, gray = page(7)
        shots.append(F.Shot(b"jpeg%d" % i, i * 0.5, F.sharpness(gray) + i, F.blockiness(gray), True, F.signature(gray)))
    for i in range(3):                       # sonra üç ayrı yer; ortadaki çok bulanık
        rgb, gray = page(20 + i, blur=6 if i == 1 else 0, shift=i * 5)
        shots.append(F.Shot(b"x%d" % i, 3 + i * 0.5, F.sharpness(gray), F.blockiness(gray), True, F.signature(gray)))
    kept, report = F.thin(shots)
    assert report["repeats"] == 4 and report["blurry"] == 1
    assert [s.jpeg for s in kept] == [b"jpeg4", b"jpeg5", b"x0", b"x2"], "tekrarın en iyi ikisi kalır, zaman sırası korunur"
    assert F.thin(shots[:2])[0] == shots[:2]


# ------------------------------------------------------------------ Gemini isteği ve model sırası
def test_pdf_ve_talimat_ayri_parcalar_olarak_gider(fake, settings):
    from sk import answers as A
    fake.answer("Soru 1, Adana, Bir\nSoru 2, Bursa, İki")
    reply = A.AnswerService(settings).ask(pdf_bytes(), A.DOC_SYSTEM, A.doc_text(1, "s.pdf"), "s.pdf")
    assert [r["number"] for r in reply.answers] == [1, 2] and reply.model == "Ücretli Gemini 4 Argon"
    body = fake.bodies()[0]
    parts = body["contents"][0]["parts"]
    assert parts[0]["inlineData"]["mimeType"] == "application/pdf" and "bütün soruları çöz" in parts[1]["text"]
    assert body["systemInstruction"]["parts"][0]["text"] == A.DOC_SYSTEM and "tools" not in body
    assert body["systemInstruction"]["parts"][1]["text"] == A.SOLVE_SECTION, "çözüm kuralları okuma talimatına eklenir"
    assert body["generationConfig"] == {"mediaResolution": "MEDIA_RESOLUTION_HIGH", "thinkingConfig": {"thinkingLevel": "high"}}
    method, path, headers, _ = fake.requests[0]
    assert path == "/v1beta/models/gemini-4-argon:generateContent" and headers["x-goog-api-key"] == "ANAHTAR-1"


def test_model_hata_verirse_siradaki_model_cevaplar(fake, settings):
    from sk import answers as A
    settings.update({"p2_key": "ANAHTAR-2"})
    fake.answer("yoğun", status=503)
    fake.answer("Soru 9, Ceyhan, Dokuz")
    reply = A.AnswerService(settings, sleep=lambda s: None).ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    assert reply.model == "Ücretli Gemini 3.8 Flash" and reply.notes == ["Cevap Ücretli Gemini 3.8 Flash modelinden geldi."]
    assert [p for p in fake.paths() if "generateContent" in p] == ["POST /v1beta/models/gemini-4-argon:generateContent",
                                                                  "POST /v1beta/models/gemini-3.8-flash:generateContent"]


def test_anahtar_yoksa_acik_bir_hata_verilir(home):
    from sk import answers as A, gemini as G
    from sk.settings import Settings
    with pytest.raises(G.GeminiError) as e:
        A.AnswerService(Settings()).ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    assert "anahtarı girilmemiş" in e.value.message


def test_buyuk_pdf_dosya_olarak_yuklenir(fake, settings, monkeypatch):
    from sk import answers as A
    monkeypatch.setattr(A, "INLINE_LIMIT", 100)
    fake.answer("Soru 1, Adana, Bir")
    A.AnswerService(settings).ask(pdf_bytes(), A.DOC_SYSTEM, "x", "tarama.pdf")
    part = fake.bodies()[0]["contents"][0]["parts"][0]
    assert part["fileData"]["fileUri"].startswith("https://ornek/files/") and "inlineData" not in part
    start = fake.requests[0]
    assert start[1] == "/upload/v1beta/files" and start[2]["x-goog-upload-command"] == "start"
    assert json.loads(start[3].decode())["file"]["displayName"] == "tarama.pdf"
    assert fake.requests[1][2]["x-goog-upload-command"] == "upload, finalize" and fake.requests[1][3].startswith(b"%PDF")


def test_sik_sozcugu_beklenen_sozcuge_cevrilir():
    from sk import answers as A
    assert A.parse("Soru 6, Edirne, 105")["spoken"] == "Soru 6, Erzurum, 105", "aynı harfle başlayan başka şehir düzeltilir"
    assert A.parse("Soru 7, E, 105")["option"] == "Erzurum" and A.parse("Soru 8, B şıkkı, Yağmur")["option"] == "Bursa"
    assert A.parse("Soru 9, İ, x")["option"] == "İ" and A.parse("Soru 9, Denizli, x")["option"] == "Denizli"
    assert A.parse("Soru 3, Ankara")["spoken"] == "Soru 3, Ankara", "şıksız sorunun şehir adlı cevabına dokunulmaz"


def test_eski_ayar_dosyasinda_bekleme_suresi_yukselir(home):
    import json
    from sk.settings import Settings
    path = home / "eski"
    path.mkdir()
    (path / "ayarlar.json").write_text(json.dumps({"wait_limit": 150, "scan_seconds": 45}), encoding="utf-8")
    s = Settings(str(path))
    assert s["wait_limit"] == 240 and s["scan_seconds"] == 45 and s["thinking"] == "high" and s["pdf_pages"] == 2
    (path / "ayarlar.json").write_text(json.dumps({"wait_limit": 150, "thinking": "high"}), encoding="utf-8")
    assert Settings(str(path))["wait_limit"] == 150, "kullanıcının sonradan seçtiği değere dokunulmaz"


def test_cozum_kurallari_dort_alani_kapsar():
    from sk import answers as A
    text = A.SOLVE_SECTION
    for word in ("GENEL:", "SAYISAL", "TÜRKÇE VE SÖZEL", "İNGİLİZCE", "ALAN BİLGİSİ", "Türk Dili ve Edebiyatı", "olamaz", "en az",
                 "şıklarda yoksa", "sağlamasını yap", "yalnız metinde söylenene dayan", "çeviride", "Eser-yazar"):
        assert word in text, word
    assert "cevap biçimi yukarıda anlatıldığı gibidir" in text, "kurallar cevap biçimini değiştirmez"


def test_dusunme_duzeyi_modele_gore_istenir(fake, settings):
    from sk import answers as A, gemini as G
    assert G.thinking_level("gemini-4-argon", "high") == "high" and G.thinking_level("gemini-3.5-flash-lite", "high") == "high"
    assert G.thinking_level("gemini-2.5-pro", "high") is None, "Gemini 2.x bu ayarı tanımaz"
    assert G.thinking_level("gemini-4-argon", "auto") is None and G.thinking_level("gemma-4-27b-it", "auto") == "high"
    settings.update({"thinking": "auto"})
    fake.answer("Soru 1, Adana, Bir")
    A.AnswerService(settings).ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    assert "thinkingConfig" not in fake.bodies()[0]["generationConfig"]

    # model ayarı reddederse aynı istek ayarsız yeniden gönderilir ve o modele bir daha gönderilmez
    settings.update({"thinking": "high", "p1_model": "gemini-9-deneme"})
    fake.answer("Unknown name thinkingLevel: thinking is not supported", status=400)
    fake.answer("Soru 2, Bursa, İki")
    reply = A.AnswerService(settings).ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    assert reply.answers[0]["number"] == 2
    assert "thinkingConfig" in fake.bodies()[1]["generationConfig"] and "thinkingConfig" not in fake.bodies()[2]["generationConfig"]
    fake.answer("Soru 3, Ceyhan, Üç")
    A.AnswerService(settings).ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    assert "thinkingConfig" not in fake.bodies()[3]["generationConfig"]


def test_pdf_az_sayfali_parcalar_halinde_gonderilir(fake, settings, home):
    import base64
    from pypdf import PdfReader
    from sk import pdfsplit
    parts, total = pdfsplit.split(pdf_bytes(5), 2)
    assert total == 5 and [(a, b) for _, a, b in parts] == [(1, 2), (3, 4), (5, 5)]
    assert [len(PdfReader(io.BytesIO(p)).pages) for p, _, _ in parts] == [2, 2, 1]
    assert pdfsplit.split(pdf_bytes(2), 2)[0][0][1:] == (1, 2) and pdfsplit.split(b"pdf degil", 2) == ([(b"pdf degil", 1, 0)], 0)

    settings.update({"pdf_pages": 2})
    flow, speaker = make_flow(settings)
    flow.parallel = 1                   # sahte sunucu cevapları geliş sırasıyla verir: bu sınamada parçalar sırayla sorulur
    path = str(home / "bes.pdf")
    open(path, "wb").write(pdf_bytes(5))
    fake.answer("Soru 1, Adana, Bir\nSoru 2, Bursa, İki")
    fake.answer("yoğun", status=503)
    fake.answer("yoğun", status=503)
    fake.answer("Soru 5, Erzurum, Beş")
    flow.send_pdf(path); flow.wait(30)
    state = flow.state()
    assert [a["number"] for a in state["answers"]] == [1, 2, 5], "cevaplanan parçaların soruları birleşir"
    assert state["error"] == "" and any("Sayfa 3-4 cevaplanamadı" in n for n in state["notes"]), state["notes"]
    bodies = fake.bodies()
    first, last = bodies[0]["contents"][0]["parts"], bodies[-1]["contents"][0]["parts"]
    assert len(PdfReader(io.BytesIO(base64.b64decode(first[0]["inlineData"]["data"]))).pages) == 2
    assert len(PdfReader(io.BytesIO(base64.b64decode(last[0]["inlineData"]["data"]))).pages) == 1
    assert "5 sayfalık belgenin 1-2. sayfalarıdır" in first[1]["text"] and "5 sayfalık belgenin 5-5. sayfalarıdır" in last[1]["text"]
    assert "ilk soruya Soru 1 de" in first[1]["text"], "sıradaki soru ipucu ilk parçada verilir"
    assert "ilk soruya" not in last[1]["text"] and "Soru numaralarını belgeden oku" in last[1]["text"]
    assert speaker.said[-4:] == ["Soru 1, Adana, Bir", "Soru 2, Bursa, İki", "Soru 5, Erzurum, Beş", "Sıradaki soru 6."]


def test_pdf_parcalari_birkaci_birden_sorulur_cevaplar_sirayla_islenir(fake, settings, home):
    import threading
    from sk import answers as A
    from sk.flow import Flow
    settings.update({"pdf_pages": 1})
    gate, active, peak, lock = threading.Event(), [0], [0], threading.Lock()

    class Service:
        """Her parçaya sayfa numarasına göre cevap verir; ilk parça en son biter (sıra yine de belge sırası olmalı)."""
        def ask(self, pdf, system, text, name, cancelled):
            page = int(text.split("belgenin ")[1].split("-")[0])
            with lock:
                active[0] += 1
                peak[0] = max(peak[0], active[0])
            if page == 1:
                gate.wait(10)
            else:
                time.sleep(0.05)
                if page == 4:
                    gate.set()
            with lock:
                active[0] -= 1
            return A.Reply(A.parse_lines("Soru %d, Adana, Sayfa %d" % (page, page)), "Sahte", "", False, "", [])

    speaker = FakeSpeaker()
    flow = Flow(settings, Service(), speaker, camera_live=lambda: True)
    path = str(home / "dort.pdf")
    open(path, "wb").write(pdf_bytes(4))
    flow.send_pdf(path); flow.wait(30)
    state = flow.state()
    assert [a["number"] for a in state["answers"]] == [1, 2, 3, 4] and state["error"] == ""
    assert 2 <= peak[0] <= 3, "aynı anda en çok üç parça sorulur: %d" % peak[0]
    assert speaker.said[-5:-1] == ["Soru %d, Adana, Sayfa %d" % (n, n) for n in (1, 2, 3, 4)], "okuma belge sırasıyladır"


# ------------------------------------------------------------------ kaynaklar
def put(folder, name, size):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, name), "wb") as f:
        f.write(b"K" * size)


def make_sync(settings):
    from sk import answers as A
    from sk.sources import SourceSync
    return SourceSync(settings, os.environ["SK_HOME"], lambda: A.profiles(settings), sleep=lambda s: None)


def test_secenek_kapaliyken_kaynaklara_dokunulmaz(fake, settings):
    sync = make_sync(settings)
    put(sync.folder, "A.pdf", 2000)
    assert sync.sync_now() is False and sync.lines() == [] and sync.warning() == "" and sync.store_for("ANAHTAR-1") is None
    assert fake.requests == []


def test_senkron_klasoru_depoya_isler_ve_rapor_verir(fake, settings):
    from sk import answers as A
    settings.update({"use_sources": True})
    sync = make_sync(settings)
    put(sync.folder, "A.pdf", 2000)
    put(sync.folder, "B.txt", 3000)
    put(sync.folder, "resim.jpg", 10)
    assert fake.requests == [] and "henüz yüklenmedi, senkronize edin" in " ".join(sync.lines())
    assert "yüklenmemiş" in sync.warning(), "kendiliğinden yükleme yok: kullanıcı düğmeye basar"
    assert sync.sync_now()
    sync.wait(20)
    assert sync.report == ["Senkron tamamlandı: 5 KB boyutunda 2 dosya senkronize edildi (yüklenen 2 (5 KB), depodan silinen 0, değişmeyen 0)."]
    store = sync.store_for("ANAHTAR-1")
    assert store and sync.warning() == "" and "2 kaynak hazır" in " ".join(sync.lines())
    assert any("resim.jpg: desteklenmeyen tür" in l for l in sync.lines())

    # ikinci senkron: değişmeyen dosya yeniden gönderilmez
    before = len(fake.requests)
    sync.sync_now(); sync.wait(20)
    assert sync.report[0].endswith("(yüklenen 0, depodan silinen 0, değişmeyen 2).")
    assert not any("upload" in p for p in fake.paths()[before:])

    # klasörden silinen depodan silinir, yeni konan yüklenir
    os.remove(os.path.join(sync.folder, "B.txt"))
    put(sync.folder, "C.pdf", 4000)
    assert "klasör değişmiş, senkronize edin" in " ".join(sync.lines()) and "senkronize değil" in sync.warning()
    sync.sync_now(); sync.wait(20)
    assert sync.report == ["Senkron tamamlandı: 6 KB boyutunda 2 dosya senkronize edildi (yüklenen 1 (4 KB), depodan silinen 1, değişmeyen 1)."]
    assert sorted(d["displayName"] for d in fake.stores[store]["docs"].values()) == ["A.pdf", "C.pdf"]

    # cevap isteğine dosya arama aracı ve kaynak talimatı girer; günlüğe hangi kaynağa dayandığı yazılır
    fake.answer("Soru 1, Adana, Bir", chunks=["A.pdf", "A.pdf", "C.pdf"])
    service = A.AnswerService(settings, source_store=sync.store_for, on_source_rejected=sync.note_rejection)
    reply = service.ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    body = fake.bodies()[-1]
    assert body["tools"] == [{"file_search": {"file_search_store_names": [store]}}]
    assert "KAYNAĞA uy" in body["systemInstruction"]["parts"][2]["text"]
    assert reply.sources == "cevap 3 kaynak parçasına dayandı: A.pdf ×2, C.pdf ×1"

    # Gemini depoyu reddederse cevap kaynaksız alınır ve kullanıcı uyarılır
    fake.answer("File search is not supported", status=400)
    fake.answer("Soru 2, Bursa, İki")
    reply = service.ask(pdf_bytes(), A.DOC_SYSTEM, "x")
    assert reply.answers[0]["number"] == 2 and "tools" not in fake.bodies()[-1]
    assert reply.notes == ["Gemini kaynak deposunu kabul etmedi; cevap kaynaksız verildi."]
    assert "Gemini depoyu kabul etmedi" in " ".join(sync.lines())


def test_yuklenemeyen_dosya_raporda_adiyla_yer_alir(fake, settings):
    settings.update({"use_sources": True})
    sync = make_sync(settings)
    put(sync.folder, "A.pdf", 2000)
    put(sync.folder, "B.txt", 3000)
    fake.fail_uploads.add("A.pdf")
    sync.sync_now(); sync.wait(20)
    text = sync.report[0]
    assert text.startswith("Senkron eksik kaldı: 3 KB boyutunda 1 dosya senkronize edildi (yüklenen 1 (3 KB)")
    assert "Yüklenemeyen 1 dosya: A.pdf (" in text and "Unsupported file" in text


# ------------------------------------------------------------------ akış: PDF ve kamera taraması
def make_flow(settings, live=True):
    from sk import answers as A
    from sk.flow import Flow
    speaker = FakeSpeaker()
    flow = Flow(settings, A.AnswerService(settings, sleep=lambda s: None), speaker, camera_live=lambda: live)
    return flow, speaker


def test_pdf_ile_soru_gonderilir_cevaplar_kaydedilir_ve_okunur(fake, settings, home):
    flow, speaker = make_flow(settings)
    path = str(home / "sorular.pdf")
    with open(path, "wb") as f:
        f.write(pdf_bytes(3))
    fake.answer("Soru 1, Adana, Bir\nSoru 2, Denizli, İki\nSoru 3, Erzurum, Üç")
    ok, why = flow.send_pdf(path)
    assert ok, why
    flow.wait(20)
    state = flow.state()
    assert state["phase"] == "idle" and state["error"] == "" and state["expected"] == 4
    assert [(a["number"], a["option"], a["origin"]) for a in state["answers"]] == [(1, "Adana", "pdf"), (2, "Denizli", "pdf"), (3, "Erzurum", "pdf")]
    assert speaker.said == ["PDF gönderiliyor.", "Soru 1, Adana, Bir", "Soru 2, Denizli, İki", "Soru 3, Erzurum, Üç", "Sıradaki soru 4."]
    saved = open(os.path.join(state["session_dir"], "cevaplar.txt"), encoding="utf-8").read()
    assert "Soru 2, Denizli, İki" in saved
    body = fake.bodies()[0]
    assert body["systemInstruction"]["parts"][0]["text"].startswith("Sen bir sınav okuyucu asistansın. Mesajda bir soru belgesi (PDF) var")

    # ikinci gönderimde sıradaki soru ipucu olarak gider; cevaplar yeniden okunabilir
    fake.answer("Soru 4, Bursa, Dört")
    flow.send_pdf(path); flow.wait(20)
    assert "ilk soruya Soru 4 de" in fake.bodies()[1]["contents"][0]["parts"][1]["text"] and flow.state()["expected"] == 5
    speaker.said.clear()
    assert flow.repeat()[0]
    flow.wait(20)
    assert speaker.said == ["Soru 1, Adana, Bir", "Soru 2, Denizli, İki", "Soru 3, Erzurum, Üç", "Soru 4, Bursa, Dört"]
    assert flow.clear()[0] and flow.state()["answers"] == [] and flow.state()["expected"] == 1


def test_gemini_hatasi_ekrana_yazilir_ve_program_hazir_kalir(fake, settings, home):
    flow, speaker = make_flow(settings)
    path = str(home / "s.pdf")
    open(path, "wb").write(pdf_bytes())
    fake.answer("API key not valid", status=400)
    flow.send_pdf(path); flow.wait(20)
    state = flow.state()
    assert state["phase"] == "idle" and "anahtarı geçersiz" in state["error"] and speaker.said[-1] == state["error"]
    assert flow.send_pdf(str(home / "yok.pdf")) == (False, "PDF dosyası bulunamadı.")


def test_kamera_taramasi_kareleri_secer_pdf_yapar_ve_gonderir(fake, settings):
    from sk.decoder import DecodedFrame
    settings.update({"scan_seconds": 10, "scan_rate": 2})
    flow, speaker = make_flow(settings)
    now = [1000.0]
    flow.clock = lambda: now[0]
    flow.sleep = lambda s: time.sleep(0.001)
    fake.answer("Soru 27, Adana, Bir\nSoru 28, Bursa, İki")
    flow.expected = 27
    ok, why = flow.start_scan()
    assert ok, why
    deadline = time.time() + 5
    while flow.phase != "scanning" or flow._collector is None:
        assert time.time() < deadline
        time.sleep(0.005)
    for i in range(110):                     # 11 sn boyunca saniyede 10 kare; görüntü yavaşça kayar
        rgb, gray = page(i // 20, shift=(i // 10) % 6)
        now[0] = 1000.0 + i * 0.1
        flow.feed(DecodedFrame(rgb, gray, now[0], True))
    flow.wait(30)
    state = flow.state()
    assert state["error"] == "" and [a["number"] for a in state["answers"]] == [27, 28] and state["answers"][0]["origin"] == "kamera"
    assert "kare seçildi" in state["scan_report"] and state["last_pdf"].startswith("tarama_")
    body = fake.bodies()[0]
    text = body["contents"][0]["parts"][1]["text"]
    assert "ona Soru 27 de" in text and "Çekim serbest taramaydı" in text and "fotoğraflık PDF" in text
    assert body["systemInstruction"]["parts"][0]["text"].startswith("Sen bir sınav okuyucu asistansın. Mesajda bir sınav kitapçığının görüntüleri var")
    assert speaker.said[0] == "Tarama başladı. 10 saniye." and "Tarama bitti. Gönderiliyor." in speaker.said and speaker.said[-1] == "Sıradaki soru 29."
    assert os.path.getsize(os.path.join(state["session_dir"], state["last_pdf"])) > 1000


def test_kamera_goruntusu_yokken_tarama_baslamaz(settings):
    flow, _ = make_flow(settings, live=False)
    ok, why = flow.start_scan()
    assert not ok and "Kamera görüntüsü yok" in why


# ------------------------------------------------------------------ uygulama ve ekran: düğmeler, ayarlar, PDF yükleme
class FakeVoice:
    def __init__(self):
        self.on_status = self.on_heard = self.on_command = None
        self.commands, self.only_commands, self.mic_name, self.started = {}, None, "", None

    def set_commands(self, commands):
        self.commands = commands

    def start(self, trigger, threshold, engine):
        self.started = (trigger, threshold, engine)

    def stop(self):
        pass


def call(server, path, body=None, raw=None):
    url = "http://127.0.0.1:%d%s" % (server.port, path)
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, headers={"X-SK-Key": server.key, "Host": "127.0.0.1:%d" % server.port})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())


def test_ekran_dugmeleri_ve_sesli_komutlar_ayni_isi_yapar(fake, settings, home):
    from sk.app import App, COMMANDS
    from sk.webui import start_server
    settings.update({"source": "pdf"})
    voice, speaker = FakeVoice(), FakeSpeaker()
    app = App(os.environ["SK_HOME"], speaker=speaker, voice=voice)
    server = start_server(app, "gizli-anahtar-123456", 0)
    try:
        app.start()
        assert voice.commands == COMMANDS and voice.started is not None, "sesli komutlar dinlenir"
        state = call(server, "/api/state")
        assert state["source"] == "pdf" and state["flow"]["phase"] == "idle" and state["settings"]["p1_key"] == "ANAHTAR-1"
        assert state["sources"]["lines"] == [], "kaynak seçeneği kapalıyken satır yok"
        page_html = urllib.request.urlopen("http://127.0.0.1:%d/?k=%s" % (server.port, server.key)).read().decode()
        assert "Taramayı başlat" in page_html and "PDF dosyası" in page_html and "Dosyaları senkronize et" in page_html
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen("http://127.0.0.1:%d/api/state" % server.port)

        assert call(server, "/api/command", {"name": "scan"})["ok"] is False, "PDF kaynağında kamera taraması başlamaz"
        assert call(server, "/api/command", {"name": "pdf"}) == {"ok": False, "message": "Önce ekrandan bir PDF dosyası seçin."}
        fake.answer("Soru 1, Adana, Bir")
        assert call(server, "/api/pdf?name=deneme.pdf", raw=pdf_bytes())["ok"] is True
        app.flow.wait(20)
        assert call(server, "/api/state")["flow"]["answers"][0]["option"] == "Adana"
        assert call(server, "/api/pdf?name=x.pdf", raw=b"pdf degil")["ok"] is False

        # sesli komut: "PDF gönder" son seçilen dosyayı yeniden gönderir; "yeni test" cevapları siler
        fake.answer("Soru 2, Bursa, İki")
        voice.on_command("pdf", "pdf gönder")
        app.flow.wait(20)
        assert [a["number"] for a in app.flow.state()["answers"]] == [1, 2]
        voice.on_command("new", "yeni test")
        assert app.flow.state()["answers"] == []

        assert call(server, "/api/settings", {"use_sources": True, "scan_seconds": 45})["changed"] == ["scan_seconds", "use_sources"]
        state = call(server, "/api/state")
        assert state["settings"]["scan_seconds"] == 45 and any("Klasörde kaynak yok" in l for l in state["sources"]["lines"])
        assert os.path.isdir(app.sources.folder), "seçenek açılınca Kaynaklar klasörü hazırlanır"
        fake.answer("tamam")
        assert call(server, "/api/key/test", {"slot": 1})["ok"] is True
        assert call(server, "/api/key/test", {"slot": 2}) == {"ok": False, "message": "Anahtar girilmemiş."}
    finally:
        app.stop()
        server.shutdown()
