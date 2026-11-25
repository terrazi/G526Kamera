# -*- coding: utf-8 -*-
"""Programın ekranı (tek sayfa). Düğmeler /api/command ile, ayarlar /api/settings ile çalışır; durum saniyede birkaç kez yenilenir."""

PAGE = r"""<!doctype html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sesli Kontrol</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--ink:#1c2330;--muted:#5b6575;--line:#d9dde4;--accent:#1f6feb;--bad:#b42318;--badbg:#fdecea;--warn:#8a5a00;--warnbg:#fff4d6;--ok:#17703a}
*{box-sizing:border-box}body{margin:0;font:15px/1.45 "Segoe UI",Arial,sans-serif;background:var(--bg);color:var(--ink)}
header{background:#1c2330;color:#fff;padding:10px 18px;display:flex;gap:14px;align-items:baseline}
header h1{font-size:18px;margin:0}header span{opacity:.75;font-size:13px}
main{display:grid;grid-template-columns:minmax(360px,1.05fr) minmax(360px,1fr);gap:14px;padding:14px;max-width:1500px;margin:0 auto}
@media(max-width:900px){main{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;margin-bottom:14px}
h2{font-size:15px;margin:0 0 10px}
.status{font-size:17px;font-weight:600}
.box{border-radius:8px;padding:9px 12px;margin-top:8px;display:none}
.box.err{background:var(--badbg);color:var(--bad);border:1px solid #f3b8b1}
.box.note{background:var(--warnbg);color:var(--warn);border:1px solid #ecd28a}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:6px 0}
button{font:inherit;padding:9px 14px;border-radius:8px;border:1px solid var(--line);background:#fff;cursor:pointer}
button.main{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
button.stop{background:#fff;border-color:var(--bad);color:var(--bad);font-weight:600}
button:disabled{opacity:.45;cursor:default}
label.opt{display:flex;gap:7px;align-items:center;padding:7px 11px;border:1px solid var(--line);border-radius:8px;cursor:pointer}
label.opt.on{border-color:var(--accent);background:#eaf2ff}
input[type=text],input[type=number],select,textarea{font:inherit;padding:7px 9px;border:1px solid var(--line);border-radius:7px;width:100%}
textarea{min-height:62px}
.f{display:grid;grid-template-columns:190px 1fr;gap:8px;align-items:center;margin:6px 0}
.f small{grid-column:2;color:var(--muted)}
.muted{color:var(--muted);font-size:13px}
#preview{width:100%;background:#000;border-radius:8px;min-height:160px;display:block}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:13px;color:var(--muted);font-weight:600}td.n{font-weight:700;white-space:nowrap}td.o{font-weight:700;color:var(--accent)}
details{border-top:1px solid var(--line);padding:8px 0}details:first-of-type{border-top:0}summary{cursor:pointer;font-weight:600;padding:4px 0}
.prof{border:1px solid var(--line);border-radius:8px;padding:8px;margin:8px 0}
.prof .f{grid-template-columns:90px 1fr}
pre{white-space:pre-wrap;font:12px/1.4 Consolas,monospace;max-height:320px;overflow:auto;background:#f0f2f5;padding:8px;border-radius:8px}
.big{font-size:22px;font-weight:700}
</style></head><body>
<header><h1>Sesli Kontrol</h1><span id="ver">Windows</span><span id="camline"></span></header>
<main>
<div>
  <div class="card">
    <div class="status" id="status">Açılıyor…</div>
    <div class="muted" id="scaninfo"></div>
    <div class="box err" id="err"></div>
    <div class="box note" id="notes"></div>
    <div class="box note" id="flash"></div>
  </div>
  <div class="card">
    <h2>Sorular nereden gelsin</h2>
    <div class="row">
      <label class="opt" id="o-wifi"><input type="radio" name="src" value="wifi"> Wi-Fi kamera</label>
      <label class="opt" id="o-webcam"><input type="radio" name="src" value="webcam"> USB / dizüstü kamerası</label>
      <label class="opt" id="o-pdf"><input type="radio" name="src" value="pdf"> PDF dosyası</label>
    </div>
    <div class="row" id="webcamrow" style="display:none">
      <select id="webcam_device" style="max-width:420px"></select><button id="webcamrefresh">Kameraları yenile</button>
    </div>
    <div class="muted" id="camtext"></div>
    <img id="preview" alt="Kamera görüntüsü">
    <div id="pdfbox" style="display:none">
      <p class="muted">Soru metinlerinin olduğu PDF dosyasını seçin. Program dosyayı, çözüm isteği ve açıklamasıyla (ayrı metin olarak) birlikte Gemini'ye gönderir.</p>
      <input type="file" id="pdffile" accept="application/pdf,.pdf">
      <div class="muted" id="pdfname"></div>
    </div>
  </div>
  <div class="card">
    <h2>Komutlar <span class="muted">(aynı komutlar sesle de verilebilir)</span></h2>
    <div class="row">
      <button class="main" id="b-scan">Taramayı başlat</button>
      <button class="main" id="b-pdf" style="display:none">PDF'i gönder</button>
      <button class="stop" id="b-stop">Durdur</button>
      <button id="b-repeat">Cevapları yeniden oku</button>
      <button id="b-silence">Sustur</button>
      <button id="b-new">Yeni test</button>
    </div>
    <div class="row"><span class="big" id="left"></span></div>
    <div class="muted">Sesli komutlar: “taramayı başlat”, “durdur”, “PDF gönder”, “tekrar oku”, “yeni test”, “durum”. <span id="heard"></span></div>
  </div>
</div>
<div>
  <div class="card">
    <h2>Cevaplar <span class="muted" id="next"></span></h2>
    <table><thead><tr><th>Soru</th><th>Şık</th><th>Cevap</th><th>Nereden</th><th>Model</th></tr></thead><tbody id="answers"></tbody></table>
    <div class="row"><button id="b-folder">Kayıt klasörünü aç</button><span class="muted" id="sessiondir"></span></div>
  </div>
  <div class="card">
    <h2>Ayarlar</h2>
    <details><summary>Kamera ve tarama</summary>
      <div class="f"><label>Kamera adı (UID)</label><input type="text" data-k="uid"></div>
      <div class="f"><label>Kamera IP</label><input type="text" data-k="camera_ip" placeholder="boş bırakın: program kendisi bulur"></div>
      <div class="f"><label>Kamera parolası</label><input type="text" data-k="camera_password"></div>
      <div class="f"><label>Görüntü</label><select data-k="stream_quality" data-int="1"><option value="1">Yüksek 1920×1080</option><option value="2">Düşük 640×360</option></select></div>
      <div class="f"><label>Tarama süresi (sn)</label><input type="number" data-k="scan_seconds" min="10" max="300"></div>
      <div class="f"><label>Saniyede seçilen kare</label><input type="number" data-k="scan_rate" min="1" max="4"></div>
      <div class="f"><label>Benzer ve bulanık kareleri azalt</label><input type="checkbox" data-k="thin_frames" style="justify-self:start"></div>
      <p class="muted">Wi-Fi kamerada bilgisayar kameranın Wi-Fi ağına bağlı olmalıdır; Gemini'ye gönderim için ayrıca internet gerekir (kablo ya da telefondan USB ile).</p>
    </details>
    <details><summary>Gemini (modeller, anahtarlar, kaynaklar)</summary>
      <div id="profiles"></div>
      <div class="f"><label>Model başına bekleme (sn)</label><input type="number" data-k="wait_limit" min="20" max="600"></div>
      <div class="f"><label>Düşünme düzeyi</label><select data-k="thinking"><option value="high">Yüksek (önerilen: daha dikkatli çözer, biraz daha geç cevaplar)</option><option value="auto">Modelin kendi ayarı</option></select></div>
      <div class="f"><label>PDF: istek başına sayfa</label><input type="number" data-k="pdf_pages" min="1" max="20"><small>PDF dosyası bu kadar sayfalık parçalar hâlinde gönderilir; az sayfa = soru başına daha çok dikkat.</small></div>
      <div class="f"><label>Görüntüyü yüksek çözünürlükte oku</label><input type="checkbox" data-k="high_resolution" style="justify-self:start"></div>
      <div class="f"><label>Ek talimat (isteğe bağlı)</label><textarea data-k="extra_instruction" placeholder="Program kendi talimatını zaten gönderir; buraya yazdığınız metin ona eklenir."></textarea></div>
      <div class="f"><label><b>Soruları verilen kaynaklara göre cevapla</b></label><input type="checkbox" data-k="use_sources" style="justify-self:start"></div>
      <div id="srcbox" style="display:none">
        <div id="srclines" class="muted"></div>
        <div class="row"><button id="b-sync">Dosyaları senkronize et</button><button id="b-srcfolder">Kaynaklar klasörünü aç</button></div>
        <div id="srcprogress"></div><div id="srcreport"></div>
      </div>
      <p class="muted">Kaynaklar: seçenek kapalıyken program kaynaksız çalışır. Açıkken kitaplarınızı (PDF, .docx, metin; dosya başına en çok 100 MB) Kaynaklar klasörüne koyup “Dosyaları senkronize et”e basın. Program kendiliğinden yüklemez; klasörü değiştirince yeniden basın.</p>
    </details>
    <details><summary>Ses</summary>
      <div class="f"><label>Cevapları sesli oku</label><input type="checkbox" data-k="read_answers" style="justify-self:start"></div>
      <div class="f"><label>Cevaplar arası bekleme (sn)</label><input type="number" data-k="answer_gap" min="0" max="10"></div>
      <div class="f"><label>Sesli komutlar</label><input type="checkbox" data-k="voice_enabled" style="justify-self:start"></div>
      <div class="f"><label>Ses tanıma</label><select data-k="voice_engine"><option value="auto">Otomatik</option><option value="vosk">Çevrimdışı Türkçe (Vosk)</option><option value="windows">Windows</option></select></div>
      <div class="f"><label>Mikrofon</label><select data-k="mic_device" id="mic_device"><option value="">Otomatik</option></select></div>
      <div class="f"><label>Okuma hızı (−10 … 10)</label><input type="number" data-k="tts_rate" min="-10" max="10"></div>
      <div class="muted" id="voicestatus"></div>
    </details>
    <details><summary>Dosyalar</summary>
      <div class="f"><label>Kayıt klasörü</label><input type="text" data-k="local_dir" placeholder="boş: Belgelerim\Sesli Kontrol"><small id="localdir"></small></div>
      <p class="muted">Her testin taramaları (PDF) ve cevapları (cevaplar.txt) bu klasörde, tarih-saat adlı bir alt klasöre yazılır.</p>
    </details>
    <details id="logd"><summary>Günlük</summary><div class="row"><button id="b-copylog">Günlüğü kopyala</button></div><pre id="log"></pre></details>
  </div>
</div>
</main>
<script>
const K = new URLSearchParams(location.search).get('k') || '';
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function api(path, body, raw) {
  const opt = {method: body === undefined ? 'GET' : 'POST', headers: {'X-SK-Key': K}};
  if (raw) { opt.body = body; opt.headers['Content-Type'] = 'application/pdf'; }
  else if (body !== undefined) { opt.body = JSON.stringify(body); opt.headers['Content-Type'] = 'application/json'; }
  const r = await fetch(path, opt); return r.json();
}
function show(el, text) { el.style.display = text ? 'block' : 'none'; el.textContent = text || ''; }
let S = null, built = false, lastAnswers = '';
function buildProfiles() {
  let h = '';
  for (let n = 1; n <= 4; n++) h += `<div class="prof"><b>${n}. model</b>
    <div class="f"><label>Ad</label><input type="text" data-k="p${n}_name"></div>
    <div class="f"><label>Model</label><input type="text" data-k="p${n}_model"></div>
    <div class="f"><label>API anahtarı</label><input type="text" data-k="p${n}_key" placeholder="anahtarı yapıştırın"></div>
    <div class="row"><button data-test="${n}">Anahtarı dene</button><span class="muted" id="kt${n}"></span></div></div>`;
  $('profiles').innerHTML = h;
  document.querySelectorAll('[data-test]').forEach(b => b.onclick = async () => {
    const n = b.dataset.test; $('kt' + n).textContent = 'Deneniyor…';
    const r = await api('/api/key/test', {slot: +n}); $('kt' + n).textContent = (r.ok ? '✓ ' : '✗ ') + (r.message || '');
  });
}
function bindInputs() {
  document.querySelectorAll('[data-k]').forEach(el => {
    const send = () => { let v = el.type === 'checkbox' ? el.checked : el.value; if (el.type === 'number' || el.dataset.int) v = Number(v); api('/api/settings', {[el.dataset.k]: v}); };
    el.addEventListener('change', send);
  });
}
function fillInputs(s) {
  document.querySelectorAll('[data-k]').forEach(el => {
    if (document.activeElement === el) return;
    const v = s[el.dataset.k]; if (v === undefined) return;
    if (el.type === 'checkbox') el.checked = !!v; else if (String(el.value) !== String(v)) el.value = v;
  });
}
async function loadWebcams(refresh) {
  const r = await api('/api/webcams' + (refresh ? '?refresh=1' : ''));
  const sel = $('webcam_device');
  sel.innerHTML = '<option value="">İlk bulunan kamera</option>' + (r.cameras || []).map(c => `<option value="${esc(c.id)}">${esc(c.label)}</option>`).join('');
  sel.value = r.selected || '';
  if (r.error && !(r.cameras || []).length) $('camtext').textContent = r.error;
}
async function loadMics() {
  try { const r = await api('/api/mics'); const sel = $('mic_device');
    sel.innerHTML = '<option value="">Otomatik</option>' + (r.devices || []).map(d => `<option value="${esc(d.name)}">${esc(d.name)}</option>`).join('');
    sel.value = r.selected || ''; } catch (e) {}
}
function render(s) {
  S = s; const f = s.flow, set = s.settings, busy = f.phase !== 'idle';
  $('ver').textContent = 'Windows ' + s.version;
  $('status').textContent = f.status;
  $('scaninfo').textContent = f.scan_report || '';
  show($('err'), f.error); show($('notes'), (f.notes || []).join(' ')); show($('flash'), s.flash.text);
  const src = set.source;
  document.querySelectorAll('input[name=src]').forEach(r => { r.checked = r.value === src; r.parentElement.classList.toggle('on', r.value === src); });
  $('webcamrow').style.display = src === 'webcam' ? 'flex' : 'none';
  $('preview').style.display = src === 'pdf' ? 'none' : 'block';
  $('pdfbox').style.display = src === 'pdf' ? 'block' : 'none';
  $('b-scan').style.display = src === 'pdf' ? 'none' : ''; $('b-pdf').style.display = src === 'pdf' ? '' : 'none';
  const c = s.camera;
  $('camtext').textContent = src === 'pdf' ? '' : c.text + (c.live ? ` (${c.width}×${c.height}, ${c.fps} kare/sn)` : '');
  $('camline').textContent = src === 'pdf' ? 'Kaynak: PDF dosyası' : (c.live ? 'Kamera canlı' : 'Kamera: ' + c.state);
  $('b-scan').disabled = busy || !c.live; $('b-pdf').disabled = busy; $('b-stop').disabled = !busy; $('b-repeat').disabled = busy || !f.answers.length; $('b-new').disabled = busy;
  $('left').textContent = f.phase === 'scanning' ? `Kalan süre: ${f.scan_left} sn` : '';
  $('next').textContent = `(sıradaki soru: ${f.expected})`;
  const key = JSON.stringify(f.answers);
  if (key !== lastAnswers) { lastAnswers = key;
    $('answers').innerHTML = f.answers.map(a => `<tr><td class="n">${a.number}</td><td class="o">${esc(a.option)}</td><td>${esc(a.text)}</td><td>${esc(a.origin)}</td><td class="muted">${esc(a.model)}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">Henüz cevap yok.</td></tr>'; }
  $('sessiondir').textContent = f.session_dir || ''; $('pdfname').textContent = f.last_pdf ? 'Son gönderilen: ' + f.last_pdf : '';
  $('localdir').textContent = 'Kullanılan klasör: ' + set.local_dir_effective;
  $('srcbox').style.display = set.use_sources ? 'block' : 'none';
  $('srclines').innerHTML = (s.sources.lines || []).map(esc).join('<br>');
  $('b-sync').disabled = s.sources.busy; $('b-sync').textContent = s.sources.busy ? 'Senkronize ediliyor…' : 'Dosyaları senkronize et';
  $('srcprogress').textContent = s.sources.progress || ''; $('srcreport').innerHTML = (s.sources.report || []).map(t => '<b>' + esc(t) + '</b>').join('<br>');
  $('voicestatus').textContent = (s.voice.status || '') ; $('heard').textContent = s.voice.heard ? 'Duyulan: ' + s.voice.heard : '';
  fillInputs(set);
}
async function tick() {
  try { const s = await api('/api/state'); if (!built) { buildProfiles(); bindInputs(); built = true; loadWebcams(false); loadMics(); } render(s);
    if ($('logd').open) { const l = await api('/api/log'); $('log').textContent = (l.lines || []).join('\n'); }
  } catch (e) { $('status').textContent = 'Programa ulaşılamıyor (siyah pencere kapandıysa programı yeniden açın).'; }
  setTimeout(tick, 700);
}
async function command(name) { const r = await api('/api/command', {name}); if (!r.ok && r.message) show($('flash'), r.message); }
$('b-scan').onclick = () => command('scan'); $('b-stop').onclick = () => command('stop'); $('b-repeat').onclick = () => command('repeat');
$('b-new').onclick = () => { if (confirm('Cevaplar silinip soru sayacı 1\'e dönsün mü? (Dosyalar yerinde kalır.)')) command('new'); };
$('b-silence').onclick = () => api('/api/silence', {});
$('b-pdf').onclick = () => { if ($('pdffile').files.length) sendPdf(); else $('pdffile').click(); };
$('pdffile').onchange = () => { if ($('pdffile').files.length) sendPdf(); };
async function sendPdf() { const file = $('pdffile').files[0]; show($('flash'), 'PDF yükleniyor: ' + file.name);
  const r = await api('/api/pdf?name=' + encodeURIComponent(file.name), file, true); show($('flash'), r.ok ? '' : (r.message || 'PDF gönderilemedi.')); }
document.querySelectorAll('input[name=src]').forEach(r => r.onchange = () => { api('/api/settings', {source: r.value}); if (r.value === 'webcam') loadWebcams(false); });
$('webcam_device').onchange = () => api('/api/settings', {webcam_device: $('webcam_device').value});
$('webcamrefresh').onclick = () => loadWebcams(true);
$('b-sync').onclick = () => api('/api/sources/sync', {}); $('b-srcfolder').onclick = () => api('/api/open', {which: 'sources'});
$('b-folder').onclick = () => api('/api/open', {which: 'session'});
$('b-copylog').onclick = async () => { const l = await api('/api/log'); try { await navigator.clipboard.writeText((l.lines || []).join('\n')); $('b-copylog').textContent = 'Kopyalandı'; } catch (e) { $('b-copylog').textContent = 'Kopyalanamadı: metni elle seçin'; } };
$('preview').src = '/video.mjpg?k=' + encodeURIComponent(K);
tick();
</script></body></html>
"""
