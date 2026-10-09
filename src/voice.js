/* ============ Voz de Nova (síntesis y reconocimiento del navegador: gratis, sin servidor) ============ */
var VOICE = { on: true, token: 0, voices: [] };
try { VOICE.on = localStorage.getItem('nova.voice') !== 'off'; } catch (e) { /* ok */ }
function hasTTS() { return !!(window.speechSynthesis && window.SpeechSynthesisUtterance); }
function loadVoices() { try { VOICE.voices = (speechSynthesis.getVoices() || []).filter(function (v) { return new RegExp('^' + I18N.get(), 'i').test(v.lang); }); } catch (e) { VOICE.voices = []; } }
if (hasTTS()) { loadVoices(); try { speechSynthesis.addEventListener('voiceschanged', loadVoices); } catch (e) { /* ok */ } }
function canSpeak() { return VOICE.on && hasTTS() && VOICE.voices.length > 0; }
function pickVoice() {
  var best = null, bs = -1;
  VOICE.voices.forEach(function (v) {
    var s = 0, l = v.lang.replace('_', '-').toLowerCase();
    s += I18N.get() !== 'es' ? (l === I18N.loc().toLowerCase() ? 50 : 20) : l === 'es-co' ? 50 : l === 'es-mx' ? 40 : l === 'es-us' ? 36 : l === 'es-419' ? 34 : l.indexOf('es-') === 0 ? 20 : 0;
    if (/natural|neural|online|google|sabina|dalia|paola|salome|helena|monica|laura|female|mujer/i.test(v.name)) s += 25;
    if (/male|jorge|pablo|raul|diego|juan/i.test(v.name) && !/female/i.test(v.name)) s -= 15;
    if (s > bs) { bs = s; best = v; }
  });
  return best;
}
function n2w(n) {
  if (n === 0) return 'cero';
  var u = ['', 'uno', 'dos', 'tres', 'cuatro', 'cinco', 'seis', 'siete', 'ocho', 'nueve', 'diez', 'once', 'doce', 'trece', 'catorce', 'quince', 'dieciséis', 'diecisiete', 'dieciocho', 'diecinueve', 'veinte', 'veintiún', 'veintidós', 'veintitrés', 'veinticuatro', 'veinticinco', 'veintiséis', 'veintisiete', 'veintiocho', 'veintinueve'];
  var d = ['', '', '', 'treinta', 'cuarenta', 'cincuenta', 'sesenta', 'setenta', 'ochenta', 'noventa'], c = ['', 'ciento', 'doscientos', 'trescientos', 'cuatrocientos', 'quinientos', 'seiscientos', 'setecientos', 'ochocientos', 'novecientos'];
  function lt(x) { if (x === 100) return 'cien'; var s = []; if (x >= 100) { s.push(c[Math.floor(x / 100)]); x %= 100; } if (x > 0) { if (x < 30) s.push(u[x]); else { var t = d[Math.floor(x / 10)]; s.push(x % 10 ? t + ' y ' + u[x % 10] : t); } } return s.join(' '); }
  var o = [], m = Math.floor(n / 1e6); n %= 1e6;
  if (m) o.push(m === 1 ? 'un millón' : lt(m) + ' millones');
  var k = Math.floor(n / 1000); n %= 1000;
  if (k) o.push(k === 1 ? 'mil' : lt(k).replace(/uno$/, 'ún') + ' mil');
  if (n) o.push(lt(n));
  return o.join(' ');
}
function speakable(t) {
  if (I18N.get() !== 'es') return String(t).replace(/\$\s?([\d.]+)/g, function (m, d) { return d.replace(/\./g, '') + ' pesos'; }).replace(/×/g, ' x ').replace(/[•·→←]/g, ',').replace(/\s*\n+\s*/g, '. ').replace(/\s+/g, ' ').trim();
  return String(t).replace(/\$\s?([\d.]+)/g, function (m, d) { var n = parseInt(d.replace(/\./g, ''), 10); return isFinite(n) && n < 1e9 ? n2w(n) + ' pesos' : m; })
    .replace(/×/g, ' por ').replace(/[•·→←]/g, ',').replace(/\s*\n+\s*/g, '. ').replace(/\(8\)\s?/g, '').replace(/\s+/g, ' ').trim();
}
function stopSpeech() { VOICE.token++; try { if (hasTTS()) speechSynthesis.cancel(); } catch (e) { /* ok */ } avSet('talk', false); }
function speak(text) {
  if (!canSpeak()) return Promise.resolve();
  text = I18N.tr(text);
  var tok = ++VOICE.token, parts = speakable(text).match(/[^.!?¿]+[.!?]?/g) || [], v = pickVoice(), i = 0;
  try { speechSynthesis.cancel(); } catch (e) { /* ok */ }
  return new Promise(function (res) {
    function next() {
      if (tok !== VOICE.token || i >= parts.length) { if (tok === VOICE.token) avSet('talk', false); return res(); }
      var s = parts[i++].trim(); if (s.length < 2) return next();
      var u = new SpeechSynthesisUtterance(s); if (v) { u.voice = v; u.lang = v.lang; } else u.lang = I18N.loc();
      u.rate = 1.02; u.pitch = 1.08; u.volume = 1;
      var started = false, guard = setTimeout(function () { if (!started) { stopSpeech(); res(); } }, 2500);
      u.onstart = function () { started = true; clearTimeout(guard); avSet('talk', true); };
      u.onend = function () { clearTimeout(guard); next(); };
      u.onerror = function () { clearTimeout(guard); if (tok === VOICE.token) avSet('talk', false); res(); };
      try { speechSynthesis.speak(u); } catch (e) { clearTimeout(guard); res(); }
    }
    next();
  });
}
/* estado visible junto al avatar */
function avLabel() {
  var s = $('#chatSub'); if (!s) return; var a = $('.chead .av');
  if (a && a.classList.contains('talk')) s.textContent = 'Hablando…';
  else if (a && a.classList.contains('think')) s.textContent = 'Pensando…';
  else if (a && a.classList.contains('listen')) s.textContent = 'Te escucho…';
  else renderChatHead();
}
/* botón de voz y micrófono */
function paintVoiceBtn() {
  var b = $('#voiceBtn'); if (!b) return; if (!hasTTS()) { b.hidden = true; return; }
  b.setAttribute('aria-pressed', String(VOICE.on)); b.setAttribute('aria-label', VOICE.on ? 'Silenciar la voz de Nova' : 'Activar la voz de Nova'); b.title = b.getAttribute('aria-label');
  b.innerHTML = VOICE.on ? '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9z"/><path d="M16.5 8.5a5 5 0 010 7M19 6a8.5 8.5 0 010 12"/></svg>' : '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9z"/><path d="M17 9l5 6M22 9l-5 6"/></svg>';
}
if ($('#voiceBtn')) $('#voiceBtn').addEventListener('click', function () { VOICE.on = !VOICE.on; try { localStorage.setItem('nova.voice', VOICE.on ? 'on' : 'off'); } catch (e) { /* ok */ } if (!VOICE.on) stopSpeech(); paintVoiceBtn(); toast(VOICE.on ? 'Voz de Nova activada.' : 'Voz de Nova silenciada.'); });
paintVoiceBtn();
var SR = window.SpeechRecognition || window.webkitSpeechRecognition, recog = null;
if ($('#micBtn')) {
  if (!SR) $('#micBtn').hidden = true;
  else $('#micBtn').addEventListener('click', function () {
    if (recog) { try { recog.stop(); } catch (e) { /* ok */ } return; }
    stopSpeech(); recog = new SR(); recog.lang = I18N.loc(); recog.interimResults = false; recog.maxAlternatives = 1;
    recog.onstart = function () { avSet('listen', true); $('#micBtn').setAttribute('aria-pressed', 'true'); };
    recog.onresult = function (e) { var t = e.results && e.results[0] && e.results[0][0] && e.results[0][0].transcript; if (t) sendChat(t); };
    recog.onerror = function (e) { toast(e.error === 'not-allowed' || e.error === 'service-not-allowed' ? 'Este navegador no dio permiso al micrófono. Escribe tu mensaje.' : 'No pude escucharte. Intenta de nuevo o escribe.'); };
    recog.onend = function () { recog = null; avSet('listen', false); $('#micBtn').setAttribute('aria-pressed', 'false'); };
    try { recog.start(); } catch (e) { recog = null; }
  });
}
/* vida propia: mira a su alrededor cuando nadie la toca */
var lastPtr = Date.now();
document.addEventListener('pointermove', function () { lastPtr = Date.now(); }, { passive: true });
setInterval(function () {
  if (document.hidden || Date.now() - lastPtr < 4000) return;
  var x = (Math.random() * 2 - 1) * .8, y = (Math.random() * 2 - 1) * .5;
  $$('.av').forEach(function (a) { a.style.setProperty('--ex', x.toFixed(2)); a.style.setProperty('--ey', y.toFixed(2)); });
}, 3200);
