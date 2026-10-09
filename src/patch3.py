import re, os
D = os.path.dirname(os.path.abspath(__file__))
rd = lambda n: open(os.path.join(D, n), encoding='utf-8').read()
def rep(s, a, b, cnt=1):
    assert a in s, 'FALTA: ' + a[:70]
    return s.replace(a, b, cnt)

# ---------- JS ----------
j = rd('new.js')
j = rep(j, "ov: {}, extra: {}, kb: {}, reg: null, req: null,", "ov: {}, extra: {}, kb: {}, reg: null, req: null, menus: {}, fee: 200, orders: [], ordMap: {}, flow: null, afterAuth: false,")
j = rep(j, "  all.forEach(function (r) {\n    var o = r.x ?", "  all.push({ id: 'demo-asadero-nova', n: 'Asadero Demo Nova', t: 1, a: 'Negocio de prueba para ensayar pedidos', p: '', s: 'admin', x: 0, demo: 1 });\n  all.push({ id: 'demo-hotel-nova', n: 'Hotel Demo Nova', t: 14, a: 'Negocio de prueba para ensayar reservas', p: '', s: 'admin', x: 0, demo: 1 });\n  all.forEach(function (r) {\n    var o = r.x ?")
j = rep(j, "var role = ($('input[name=role]:checked') || {}).value || 'usuario';", "var role = ($('input[name=role]:checked') || {}).value || 'cliente';")
j = rep(j, "    if (role === 'admin') { toast('Cuenta de administración creada.'); go('admin'); }", "    if (role === 'cliente') { toast('Cuenta de cliente creada.'); if (S.afterAuth) { go('dir'); resumeFlow(); } else go('dir'); }\n    else if (role === 'admin') { toast('Cuenta de administración creada.'); go('admin'); }")
j = rep(j, "var role = a.role === 'admin' && S.me.canEdit ? 'admin' : 'usuario';", "var role = a.role === 'cliente' ? 'cliente' : (a.role === 'admin' && S.me.canEdit ? 'admin' : 'usuario');")
j = rep(j, "    if (role === 'admin') go('admin');\n    else if (S.reg && S.map[S.reg.r]) go('rest', S.reg.r);", "    if (role === 'cliente') { if (S.afterAuth) { go('dir'); resumeFlow(); } else go('dir'); }\n    else if (role === 'admin') go('admin');\n    else if (S.afterAuth) { go('dir'); resumeFlow(); }\n    else if (S.reg && S.map[S.reg.r]) go('rest', S.reg.r);")
j = rep(j, "  if (view === 'auth' && S.session) {\n", "  if ((view === 'orders') && !S.session) { view = 'auth'; S.authTab = 'login'; }\n  if (view === 'auth' && S.session && S.session.role === 'cliente') view = 'dir';\n  if (view === 'auth' && S.session) {\n")
j = rep(j, "  else if (S.view === 'admin') renderAdmin();", "  else if (S.view === 'admin') renderAdmin();\n  else if (S.view === 'orders') renderOrders();")
j = rep(j, "    else if (S.reg && S.map[S.reg.r]) items.push(['rest', 'Mi restaurante', S.reg.r]);", "    else if (S.session.role === 'cliente') items.push(['orders', 'Mis pedidos', '']);\n    else if (S.reg && S.map[S.reg.r]) { items.push(['rest', 'Mi restaurante', S.reg.r]); items.push(['orders', 'Pedidos', '']); }")
j = rep(j, "(S.session.role === 'admin' ? 'administración' : 'usuario')", "(S.session.role === 'admin' ? 'administración' : S.session.role === 'cliente' ? 'cliente' : 'restaurante')")
j = rep(j, "  var adminOk = !!S.me.canEdit, ra = $('#roleAdmin'); ra.disabled = !adminOk; if (!adminOk && ra.checked) $('input[name=role][value=usuario]').checked = true;", "  var adminOk = !!S.me.canEdit, ra = $('#roleAdmin'); ra.disabled = !adminOk; if (!adminOk && ra.checked) $('input[name=role][value=cliente]').checked = true;")
j = rep(j, "  var d = el('div'); d.appendChild(el('b', '', r.n)); d.appendChild(el('span', '', T[r.t] + (r.a ? ' · ' + r.a : '')));", "  var d = el('div'); d.appendChild(el('b', '', r.n)); d.appendChild(el('span', '', T[r.t] + (r.a ? ' · ' + r.a : '') + (hasMenu(r) ? (r.t === 14 ? ' · Reserva con Nova' : ' · Pide con Nova') : '')));")
j = rep(j, "  var ask = el('button', 'btn ghost', 'Hablar con Nova');", "  if (hasMenu(r)) { var ob = el('button', 'btn primary', r.t === 14 ? 'Reservar con Nova' : 'Pedir con Nova'); ob.type = 'button'; ob.addEventListener('click', function () { S.chat.ctx = r.id; if (!S.chat.open) toggleChat(true); startFlow(r, ''); }); btns.appendChild(ob); }\n  var ask = el('button', 'btn ghost', 'Hablar con Nova');")
j = rep(j, "  if (S.session && S.session.role === 'admin') { var ed = el('button', 'btn ghost', 'Editar');", "  if (S.session && S.session.role === 'admin') { var em = el('button', 'btn ghost', r.t === 14 ? 'Cargar tarifas y correo' : 'Cargar carta y correo'); em.type = 'button'; em.addEventListener('click', function () { editMenu(r.id); }); btns.appendChild(em); }\n  if (S.session && S.session.role === 'admin') { var ed = el('button', 'btn ghost', 'Editar');")
j = rep(j, "  } else if (tab === 'seg') {", "  } else if (tab === 'ped') { html = adminPed();\n  } else if (tab === 'liq') { html = adminLiq();\n  } else if (tab === 'seg') {")
# cortar chat viejo
a = j.index("function renderChatHead()"); b = j.index("/* ============ arranque ============ */")
j = j[:a] + "/*V3CHAT*/\n" + j[b:]
j = rep(j, "watch('kb', function (o) { S.kb = o; });", "watch('kb', function (o) { S.kb = o; }); watch('menus', function (o) { S.menus = o; }); startOrderWatchers();")
j = rep(j, "function renderNav() {\n", "function renderNav() {\n  build();\n")
v3 = rd('v3.js'); orders = rd('orders.js')
j = rep(j, "/*V3CHAT*/", rd('i18n.js') + "\n" + orders + "\n" + rd('voice.js') + "\n" + rd('preview.js') + "\n" + rd('forgot.js') + "\n" + v3)

j = rep(j, "S.list = all.filter(function (r) { return !r.hidden; });", "var adm = !!(S.session && S.session.role === 'admin');\n  all.forEach(function (r) { if (r.demo && !adm) r.hidden = true; });\n  S.list = all.filter(function (r) { return !r.hidden; });")


j = rep(j, "  if (p !== p2) return setMsg(msg, 'Las contraseñas no coinciden.', 'err');", "  if (p !== p2) return setMsg(msg, 'Las contraseñas no coinciden.', 'err');\n  var ph = ($('#r-phone').value || '').replace(/[\\s()-]/g, '').replace(/^\\+?57/, ''), ch = ($('input[name=rch]:checked') || {}).value || 'whatsapp';\n  if (!/^3\\d{9}$/.test(ph)) return setMsg(msg, 'Escribe tu celular colombiano de 10 dígitos (empieza por 3).', 'err');")
j = rep(j, "await ref.set({ username: u, role: role, salt:", "await ref.set({ phone: '+57' + ph, ch: ch, username: u, role: role, salt:")


j = rep(j, "    if (S.session.role === 'admin') items.push(['admin', 'Panel', '']);", "    if (S.session.role === 'admin') { items.push(['admin', 'Panel', '']); items.push(['preview:restaurante', 'Ver como restaurante', '']); items.push(['preview:cliente', 'Ver como cliente', '']); }\n    else if (S.session.admin) items.push(['preview:admin', '← Volver a administración', '']);")
j = rep(j, "b2.setAttribute('data-go', it[0]);", "b2.setAttribute(it[0].indexOf('preview:') === 0 ? 'data-preview' : 'data-go', it[0].replace('preview:', ''));")
j = rep(j, "m.setAttribute('data-go', it[0]);", "m.setAttribute(it[0].indexOf('preview:') === 0 ? 'data-preview' : 'data-go', it[0].replace('preview:', ''));")
j = rep(j, "var adm = !!(S.session && S.session.role === 'admin');", "var adm = !!(S.session && (S.session.role === 'admin' || S.session.admin));")

# ---------- HTML ----------
views = rd('new.views.html')
views = re.sub(r'<span class="face">.*?</span>', '<span class="face" data-av></span>', views, flags=re.S)
views = rep(views, '<label><input type="radio" name="role" value="usuario" checked><span>Usuario<small>Registro mi restaurante en Nova</small></span></label>',
  '<label><input type="radio" name="role" value="cliente" checked><span>Cliente<small>Pido comida o reservo hotel</small></span></label>\n            <label><input type="radio" name="role" value="usuario"><span>Restaurante u hotel<small>Registro mi negocio en Nova</small></span></label>')
views = rep(views, '<h3 style="margin-bottom:6px">¿Qué tipo de restaurante vas a registrar?</h3>', '<h3 style="margin-bottom:6px">¿Qué tipo de negocio vas a registrar?</h3>')
views = rep(views, '<button type="button" role="tab" data-ptab="kb" aria-selected="false">', '<button type="button" role="tab" data-ptab="ped" aria-selected="false">Pedidos</button>\n      <button type="button" role="tab" data-ptab="liq" aria-selected="false">Liquidación</button>\n      <button type="button" role="tab" data-ptab="kb" aria-selected="false">')
views = rep(views, '<!-- Modal genérico -->', '''<main id="v-orders" class="view" data-view="orders" hidden>
  <div class="wrap">
    <div class="page-head"><p class="eyebrow">Nova</p><h1 id="ordTitle">Mis pedidos</h1><p class="lede" id="ordLede"></p></div>
    <div class="ordlist" id="ordList"></div>
  </div>
</main>

<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>
  <linearGradient id="avBody" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f2f5fc"/><stop offset=".55" stop-color="#c9d0e2"/><stop offset="1" stop-color="#8d96b3"/></linearGradient>
  <linearGradient id="avBlue" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#7cc4ff"/><stop offset="1" stop-color="#3a3fe0"/></linearGradient>
  <linearGradient id="avDark" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1a2046"/><stop offset="1" stop-color="#05060f"/></linearGradient>
  <radialGradient id="avEye" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff"/><stop offset=".45" stop-color="#8fd0ff"/><stop offset="1" stop-color="#3a7bff" stop-opacity="0"/></radialGradient>
</defs></svg>

<!-- Modal genérico -->''')
views = rep(views, 'placeholder="Pregúntale a Nova"', 'placeholder="Ej: quiero comer pollo asado"')


views = rep(views, '<label for="r-pass">Contraseña', '<label for="r-phone">Celular (para recuperar tu contraseña)\n            <input id="r-phone" name="phone" type="tel" inputmode="tel" autocomplete="tel" maxlength="16" placeholder="300 123 4567" required>\n          </label>\n          <fieldset class="roles" style="grid-template-columns:1fr 1fr"><legend>Enviar el código por</legend>\n            <label><input type="radio" name="rch" value="whatsapp" checked><span>WhatsApp<small>Mensaje a tu celular</small></span></label>\n            <label><input type="radio" name="rch" value="sms"><span>Mensaje de texto<small>SMS a tu celular</small></span></label>\n          </fieldset>\n          <label for="r-pass">Contraseña')
views = rep(views, '<p class="msg" id="loginMsg" role="status"></p>', '<button class="linkbtn" type="button" data-forgot style="justify-self:start;background:none;border:0;color:var(--blue);font:inherit;font-size:.88rem;cursor:pointer;padding:0;text-decoration:underline">¿Olvidaste tu contraseña?</button>\n        <p class="msg" id="loginMsg" role="status"></p>')

views = rep(views, '<button type="button" id="chatClose"', '<button type="button" id="voiceBtn" aria-pressed="true" aria-label="Silenciar la voz de Nova"></button>\n    <button type="button" id="chatClose"')
views = rep(views, '<input id="cin"', '<button type="button" class="mic" id="micBtn" aria-pressed="false" aria-label="Hablar con Nova" title="Hablar con Nova"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0014 0M12 18v3"/></svg></button>\n    <input id="cin"')
views = rep(views, '<radialGradient id="avEye"', '<radialGradient id="avAura" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#5b8dff" stop-opacity=".5"/><stop offset=".6" stop-color="#3a3fe0" stop-opacity=".16"/><stop offset="1" stop-color="#3a3fe0" stop-opacity="0"/></radialGradient>\n  <radialGradient id="avEye"')

home = rd('new.home.html')

s = rd('nova.src.html')
s = s.replace('__EMBLEM__', rd('emblem.b64')).replace('__LOGO__', rd('logo.b64'))
s = rep(s, '</style>', rd('new.css') + '\n' + rd('v3.css') + '\n' + rd('v4.css') + '\n</style>')
s = rep(s, '<a class="brand" href="#inicio" aria-label="Nova, inicio">', '<a class="brand" href="#inicio" data-go="home" aria-label="Nova, inicio">')
s = re.sub(r'<nav class="main" aria-label="Principal">.*?</nav>', '<nav class="main" aria-label="Principal"><span id="authSlot"></span></nav>', s, count=1, flags=re.S)
s = rep(s, '  </div>\n</header>', '  </div>\n  <div class="wrap mobnav" id="mobnav" aria-label="Navegación"></div>\n</header>')
s = rep(s, '<main id="inicio">', '<main id="v-home" class="view" data-view="home">')
s = rep(s, '<a class="btn primary" href="#app">Probar la app</a>\n        <a class="btn ghost" href="#sectores">Ver qué hace</a>',
  '<button class="btn primary" type="button" data-askNova="Quiero comer pollo asado">Pedir comida con Nova</button>\n        <button class="btn ghost" type="button" data-go="auth" data-tab="reg">Registrar mi negocio</button>\n        <button class="btn ghost" type="button" data-go="dir">Ver restaurantes de Neiva</button>')
s = rep(s, '  <section id="como">', home + '  <section id="como">')
s = rep(s, '</main>\n\n<footer>', '</main>\n\n' + views + '\n<footer>')
# hero animado
s = rep(s, '<div class="stage" aria-hidden="false">', '<div class="stage" id="heroStage" role="button" tabindex="0" aria-label="Saludar a Nova">\n      <div class="hero-say" id="heroSay" hidden role="status"></div><div class="hero-hint">Toca a Nova</div>')
s = rep(s, '<rect x="46" y="150" width="32" height="104" rx="16" fill="url(#gBody)"/>\n        <circle cx="62" cy="256" r="15" fill="url(#gDark)"/>', '<g class="hero-arm"><rect x="46" y="150" width="32" height="104" rx="16" fill="url(#gBody)"/>\n        <circle cx="62" cy="256" r="15" fill="url(#gDark)"/></g>')
s = rep(s, '<g class="blink">', '<g class="hero-eyes"><g class="blink">')
s = rep(s, '<ellipse cx="172" cy="70" rx="6" ry="4.5" fill="#fff"/>\n        </g>', '<ellipse cx="172" cy="70" rx="6" ry="4.5" fill="#fff"/>\n        </g></g>')
js = rd('catalog.js')
js = j.replace('/*CATALOG*/', js)
s = s.replace('</script>\n', '</script>\n<script>\n' + js + '</script>\n', 1) if not s.rstrip().endswith('</script>') else s.rstrip() + '\n<script>\n' + js + '</script>\n'
open(os.path.join(D, 'nova3.html'), 'w', encoding='utf-8').write(s)
open(os.path.join(D, 'check3.js'), 'w', encoding='utf-8').write(js)
print(len(s))
