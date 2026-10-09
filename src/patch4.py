# Convierte la página (nova3.html, hecha con patch3.py) en la versión con servidor real (Supabase).
import os, re, sys, json
D = os.path.dirname(os.path.abspath(__file__))
rd = lambda n: open(os.path.join(D, n), encoding='utf-8').read()
def rep(s, a, b, cnt=1):
    assert a in s, 'FALTA: ' + a[:80]
    return s.replace(a, b, cnt)

cfg = json.load(open(os.path.join(D, os.environ.get('NOVA_CONFIG', 'config.json')), encoding='utf-8'))
s = rd('nova3.html')

# 1) configuración + conexión antes de todo script
boot = '<script>window.NOVA_CONFIG=' + json.dumps({'url': cfg['url'], 'key': cfg['key']}) + ';</script>\n<script>\n' + rd('supabase.js') + '\n</script>\n'
i = s.index('<script>')
s = s[:i] + boot + s[i:]

# 2) acceso: needDb ya no exige sesión de Claude
a = s.index('function needDb(msgEl) {'); b = s.index('async function onRegister')
s = s[:a] + '''function needDb(msgEl, anon) {
  if (!S.db) { setMsg(msgEl, 'No hay conexión con el servidor de Nova. Revisa tu internet e intenta de nuevo.', 'err'); return false; }
  if (!anon && !S.me.id) { setMsg(msgEl, 'Ingresa primero a tu cuenta.', 'err'); return false; }
  return true;
}
function authErr(e, fallback) { return e && e.msg ? e.msg : (e && e.code ? dbErr(e) : fallback); }
async function bindUser(u) {
  S.me.id = u.id; S.me.name = u.username || ''; S.me.canWrite = true;
  try { S.me.canEdit = !!(await S.user.canEdit()); } catch (e) { S.me.canEdit = false; }
  try { var g1 = await S.db.doc('registrations/' + u.id).get(); S.reg = g1.exists ? g1.data() : null; var g2 = await S.db.doc('requests/' + u.id).get(); S.req = g2.exists ? g2.data() : null; } catch (e) { /* se actualizará solo */ }
  bindWatchers();
}
var boundUid = null;
function bindWatchers() {
  if (!S.db || !S.me.id || boundUid === S.me.id) return; boundUid = S.me.id;
  try { S.db.doc('registrations/' + S.me.id).onSnapshot(function (s) { S.reg = s.exists ? s.data() : null; renderNav(); }, function () { }); } catch (e) { /* ok */ }
  try { S.db.doc('requests/' + S.me.id).onSnapshot(function (s) { S.req = s.exists ? s.data() : null; if (S.view === 'auth') renderAuth(); }, function () { }); } catch (e) { /* ok */ }
}
function roleOf(a) { return S.me.canEdit ? 'admin' : (a && a.role === 'cliente' ? 'cliente' : 'usuario'); }
async function restoreSession() {
  try {
    var snap = await acctRef().get();
    if (!snap.exists) return;
    var a = snap.data(); S.session = { role: roleOf(a), username: a.username || S.me.name }; touch();
    try { var g1 = await S.db.doc('registrations/' + S.me.id).get(); S.reg = g1.exists ? g1.data() : null; } catch (e) { /* ok */ }
    renderNav(); if (S.view === 'auth') go('auth');
  } catch (e) { /* sin sesión */ }
}

''' + s[b:]

# 3) registro y entrada con cuentas reales
a = s.index('async function onRegister'); b = s.index('function logout(why)')
s = s[:a] + '''async function onRegister(ev) {
  ev.preventDefault();
  var msg = $('#regMsg'), btn = $('#regBtn');
  var role = ($('input[name=role]:checked') || {}).value || 'cliente';
  var u = $('#r-user').value.trim().toLowerCase(), p = $('#r-pass').value, p2 = $('#r-pass2').value;
  if (!needDb(msg, true)) return;
  if (!/^[a-z0-9_.]{3,20}$/.test(u)) return setMsg(msg, 'El usuario debe tener 3 a 20 caracteres: letras, números, punto o guion bajo.', 'err');
  var pol = pwPolicy(p, u); if (!pol.ok) return setMsg(msg, pol.msg, 'err');
  if (p !== p2) return setMsg(msg, 'Las contraseñas no coinciden.', 'err');
  var ph = ($('#r-phone').value || '').replace(/[\\s()-]/g, '').replace(/^\\+?57/, ''), ch = ($('input[name=rch]:checked') || {}).value || 'whatsapp';
  if (!/^3\\d{9}$/.test(ph)) return setMsg(msg, 'Escribe tu celular colombiano de 10 dígitos (empieza por 3).', 'err');
  if (role === 'admin') role = 'usuario';
  btn.disabled = true; setMsg(msg, 'Creando tu cuenta…');
  try {
    var au = await NovaAuth.signUp(u, p);
    await bindUser(au.user);
    await acctRef().set({ phone: '+57' + ph, ch: ch, username: u, role: role, created: Date.now() });
    S.session = { role: roleOf({ role: role }), username: u };
    audit('registro', role); touch();
    $('#r-pass').value = ''; $('#r-pass2').value = ''; setMsg(msg, '');
    renderNav();
    if (S.session.role === 'cliente') { toast('Cuenta de cliente creada.'); if (S.afterAuth) { go('dir'); resumeFlow(); } else go('dir'); }
    else if (S.session.role === 'admin') { toast('Cuenta de administración creada.'); go('admin'); }
    else { S.wizard = 2; renderAuth(); toast('Cuenta creada. Ahora elige tu restaurante.'); }
  } catch (e) { setMsg(msg, authErr(e, 'No se pudo crear la cuenta.'), 'err'); }
  finally { btn.disabled = false; }
}

async function onLogin(ev) {
  ev.preventDefault();
  var msg = $('#loginMsg'), btn = $('#loginBtn');
  var u = $('#l-user').value.trim().toLowerCase(), p = $('#l-pass').value;
  if (!needDb(msg, true)) return;
  if (!u || !p) return setMsg(msg, 'Escribe tu usuario y tu contraseña.', 'err');
  btn.disabled = true; setMsg(msg, 'Verificando…');
  try {
    var au;
    try { au = await NovaAuth.signIn(u, p); }
    catch (e) { if (e && e.code === 'bad_credentials') { setMsg(msg, 'Usuario o contraseña incorrectos.', 'err'); return; } throw e; }
    await bindUser(au.user);
    var snap = await acctRef().get(), a = snap.exists ? snap.data() : null;
    if (!a) { a = { username: u, role: 'cliente', created: Date.now() }; try { await acctRef().set(a); } catch (e) { /* sigue */ } }
    S.session = { role: roleOf(a), username: a.username || u };
    audit('ingreso', S.session.role); touch();
    $('#l-pass').value = ''; setMsg(msg, '');
    renderNav();
    var role = S.session.role;
    if (role === 'cliente') { if (S.afterAuth) { go('dir'); resumeFlow(); } else go('dir'); }
    else if (role === 'admin') go('admin');
    else if (S.afterAuth) { go('dir'); resumeFlow(); }
    else if (S.reg && S.map[S.reg.r]) go('rest', S.reg.r);
    else { S.authTab = 'reg'; S.wizard = 2; go('auth'); }
  } catch (e) { setMsg(msg, authErr(e, 'No se pudo ingresar.'), 'err'); }
  finally { btn.disabled = false; }
}

''' + s[b:]

# 4) salir de verdad
s = rep(s, "  S.session = null; clearTimeout(idleT); S.wizard = 1; S.authTab = 'login';\n  renderNav(); go('home'); if (why) toast(why);",
 "  S.session = null; clearTimeout(idleT); S.wizard = 1; S.authTab = 'login';\n  try { NovaAuth.signOut().then(function () { try { sessionStorage.setItem('nova.msg', why || ''); } catch (e) { /* ok */ } location.hash = ''; location.reload(); }); } catch (e) { location.reload(); }")

# 5) arranque: sesión guardada y vigilancia por usuario
s = rep(s, "    if (S.me.id) {\n      try { S.db.doc('registrations/' + S.me.id).onSnapshot(function (s) { S.reg = s.exists ? s.data() : null; renderNav(); }, function () { }); } catch (e) { /* ok */ }\n      try { S.db.doc('requests/' + S.me.id).onSnapshot(function (s) { S.req = s.exists ? s.data() : null; if (S.view === 'auth') renderAuth(); }, function () { }); } catch (e) { /* ok */ }\n    }\n  }",
 "    if (S.me.id) { bindWatchers(); await restoreSession(); }\n  }\n  try { var pm = sessionStorage.getItem('nova.msg'); if (pm) { sessionStorage.removeItem('nova.msg'); toast(pm); } } catch (e) { /* ok */ }")

# 6) pedir ser parte de un restaurante pasa por aprobación de administración
a = s.index('async function chooseRest(r) {'); b = s.index("$('#regBack').addEventListener")
s = s[:a] + '''async function chooseRest(r) {
  var msg = $('#regMsg'); if (!needDb(msg)) return;
  try {
    var rq = { n: clip(r.n, 80), t: r.t, a: clip(r.a || '', 120), p: '', w: '', claim: r.id, status: 'pendiente', ts: Date.now() };
    await S.db.doc('requests/' + S.me.id).set(rq);
    audit('solicitud-restaurante', r.id);
    S.req = rq; setMsg(msg, 'Solicitud enviada. Administración confirmará que eres de «' + r.n + '» y entonces verás sus pedidos.', 'ok');
    toast('Solicitud enviada a administración.');
  } catch (e) { setMsg(msg, dbErr(e), 'err'); }
}
''' + s[b:]
s = rep(s, "if (S.req && S.req.status) setMsg(m, 'Tu solicitud de nuevo restaurante está ' + S.req.status + '.');",
 "if (S.req && S.req.status) setMsg(m, S.req.claim ? 'Tu solicitud para «' + S.req.n + '» está ' + S.req.status + '.' : 'Tu solicitud de nuevo restaurante está ' + S.req.status + '.');")
s = rep(s, "      var id = slug(rq.n) + '-' + rand4();\n      await S.db.doc('extra/' + id).set(",
 "      if (rq.claim) {\n        await S.db.doc('registrations/' + uid).set({ r: String(rq.claim), t: rq.t, ts: Date.now() });\n        await S.db.doc('requests/' + uid).update({ status: 'aprobado', r: String(rq.claim) });\n        audit('admin-aprueba', String(rq.claim)); toast('Persona asignada al restaurante.'); await loadAdmin(); renderAdmin(); return;\n      }\n      var id = slug(rq.n) + '-' + rand4();\n      await S.db.doc('extra/' + id).set(")

# 7) recuperar contraseña: la parte por WhatsApp/SMS llega en la fase siguiente
a = s.index('function forgotModal() {'); b = s.index("document.addEventListener('click', function (e) { if (e.target.closest('[data-forgot]'))")
s = s[:a] + '''function forgotModal() {
  openModal('<h3 id="modalTitle">Recuperar contraseña</h3><p class="hint">El envío del código por WhatsApp o SMS al celular que registraste se activa cuando Nova tenga conectado su proveedor de mensajes. Mientras tanto, escribe a administración de Nova y ellos restablecen tu acceso.</p><div class="rowbtns"><button class="btn ghost" type="button" data-close>Cerrar</button></div>', function (m) {
    m.querySelector('[data-close]').addEventListener('click', closeModal);
  });
}
''' + s[b:]

# 8) textos
s = s.replace("Abre la página con tu cuenta de Claude para ver tus pedidos.", "No hay conexión con el servidor.")
s = s.replace("Abre esta página con tu cuenta de Claude para guardar cuentas y registros.", "No hay conexión con el servidor de Nova.")
s = rep(s, "'Administración se activa solo para quien tiene permisos de editor sobre esta página.'", "'La cuenta de administración la asigna Nova directamente.'")

if os.environ.get('NOVA_DEBUG'):
    s = rep(s, '\ninit();\n})();', '\nwindow.__ev = function (c) { return eval(c); };\ninit();\n})();')
open(os.path.join(D, os.environ.get('NOVA_OUT', 'index.out.html')), 'w', encoding='utf-8').write(s)
m = re.findall(r'<script>\n(.*?)</script>', s, flags=re.S)
open(os.path.join(D, 'check4.js'), 'w', encoding='utf-8').write('\n;\n'.join(m))
print(len(s))
