/* ============ pedidos, liquidación y cartas ============ */
var ST_FOOD = ['nuevo', 'aceptado', 'preparando', 'en-camino', 'entregado'];
var ST_HOTEL = ['nuevo', 'confirmada', 'hospedado', 'finalizada'];
var ST_LBL = { nuevo: 'Nuevo', aceptado: 'Aceptado', preparando: 'Preparando', 'en-camino': 'En camino', entregado: 'Entregado', cancelado: 'Cancelado', confirmada: 'Confirmada', hospedado: 'Hospedado', finalizada: 'Finalizada' };
var ST_BTN = { aceptado: 'Aceptar pedido', preparando: 'Empezar a preparar', 'en-camino': 'Enviar al cliente', entregado: 'Marcar entregado', confirmada: 'Confirmar reserva', hospedado: 'Cliente llegó', finalizada: 'Finalizar' };
var ordReady = false;
function cleanOrder(id, d) {
  if (!d || typeof d !== 'object' || typeof d.rid !== 'string') return null;
  var det = d.det && typeof d.det === 'object' ? d.det : {};
  return { id: id, k: d.k === 'hotel' ? 'hotel' : 'food', rid: clip(d.rid, 80), rn: clip(d.rn, 80), cust: clip(d.cust, 80),
    items: (Array.isArray(d.items) ? d.items : []).slice(0, 40).map(function (l) { return { n: clip(l && l.n, 70), q: num(l && l.q, 99), p: num(l && l.p, 5e6), u: clip(l && l.u, 8) }; }),
    total: num(d.total, 2e7), fee: num(d.fee, 5000), net: num(d.net, 2e7), st: ST_LBL[d.st] ? d.st : 'nuevo', email: emailOk(d.email) ? d.email : '', bank: clip(d.bank, 40), ts: num(d.ts, 4e12),
    det: { n: clip(det.n, 60), p: clip(det.p, 14), m: clip(det.m, 12), a: clip(det.a, 120), o: clip(det.o, 140), w: clip(det.w, 20), g: num(det.g, 20) } };
}
function startOrderWatchers() {
  if (!S.db) return;
  try {
    S.db.collection('orders').onSnapshot(function (snap) {
      var map = {}, fresh = [];
      snap.docs.forEach(function (d) { var o = cleanOrder(d.id, d.data()); if (o) { map[d.id] = o; if (ordReady && !S.ordMap[d.id]) fresh.push(o); } });
      S.ordMap = map; S.orders = Object.keys(map).map(function (k) { return map[k]; }).sort(function (a, b) { return b.ts - a.ts; });
      if (ordReady) fresh.forEach(function (o) { if (S.session && S.session.role !== 'admin' && S.reg && S.reg.r === o.rid && o.cust !== S.me.id) { toast('Pedido nuevo en ' + o.rn); avPulse('happy', 1200); } });
      ordReady = true; if (S.view === 'orders') renderOrders(); if (S.view === 'admin' && (S.ptab === 'ped' || S.ptab === 'liq')) renderAdmin(); renderNav();
    }, function () { });
    S.db.doc('settings/platform').onSnapshot(function (s) { var f = s.exists ? s.data().fee : null; S.fee = typeof f === 'number' && f >= 0 && f <= 5000 ? Math.round(f) : 200; if (S.view === 'admin' && S.ptab === 'liq') renderAdmin(); }, function () { });
  } catch (e) { /* ok */ }
}
function myOrders() {
  if (!S.session) return [];
  if (S.session.role === 'admin') return S.orders;
  return S.orders.filter(function (o) { return o.cust === S.me.id || (S.reg && S.reg.r === o.rid); });
}
function orderHTML(o, owner) {
  var hotel = o.k === 'hotel', flow = hotel ? ST_HOTEL : ST_FOOD, i = flow.indexOf(o.st), nxt = i > -1 && i < flow.length - 1 ? flow[i + 1] : null, d = o.det;
  var h = '<article class="ocard"><header><b>' + esc(o.rn) + '</b><span><span class="st ' + esc(o.st) + '">' + esc(ST_LBL[o.st]) + '</span> <span class="tag sim">PSE prueba</span></span></header>' +
    '<p class="fine">N.º ' + esc(o.id.slice(-6).toUpperCase()) + ' · ' + esc(when(o.ts)) + ' · ' + (hotel ? 'Reserva' : 'Pedido') + '</p><ul>' +
    o.items.map(function (l) { return '<li>' + (hotel ? '' : l.q + ' × ') + esc(l.n) + ' — ' + cop(l.q * l.p) + '</li>'; }).join('') + '</ul>' +
    '<p class="fine">' + esc(d.n) + ' · ' + esc(d.p) + (hotel ? ' · Llegada ' + esc(when(d.w)) + ' · ' + d.g + ' persona(s)' : (d.m === 'domicilio' ? ' · Entrega: ' + esc(d.a) : ' · Recoge en el local') + (d.o ? ' · Nota: ' + esc(d.o) : '')) + '</p>' +
    '<div class="tot"><div><span>Total pagado por el cliente</span><b>' + cop(o.total) + '</b></div>' + (owner ? '<div><span>Comisión Nova</span><span>− ' + cop(o.fee) + '</span></div><div><span>Para el negocio</span><b>' + cop(o.net) + '</b></div>' : '') + '</div><div class="rowbtns">';
  if (owner && nxt && o.st !== 'cancelado') h += '<button type="button" class="good" data-ost="' + esc(o.id) + '" data-to="' + nxt + '">' + esc(ST_BTN[nxt]) + '</button>';
  if ((owner || o.cust === S.me.id) && o.st === 'nuevo') h += '<button type="button" class="bad" data-ost="' + esc(o.id) + '" data-to="cancelado">Cancelar</button>';
  if (owner) h += '<button type="button" data-omail="' + esc(o.id) + '">Copiar correo</button>';
  return h + '</div></article>';
}
function isOwnerOf(o) { return S.session && (S.session.role === 'admin' || (S.reg && S.reg.r === o.rid)); }
function renderOrders() {
  var box = $('#ordList'); if (!box) return;
  var list = myOrders(), role = S.session && S.session.role;
  $('#ordTitle').textContent = role === 'admin' ? 'Todos los pedidos' : (S.reg ? 'Pedidos y mis compras' : 'Mis pedidos');
  $('#ordLede').textContent = S.db ? 'Estado en vivo. Los pagos por PSE son de prueba.' : 'Abre la página con tu cuenta de Claude para ver tus pedidos.';
  box.innerHTML = list.length ? list.map(function (o) { return orderHTML(o, isOwnerOf(o)); }).join('') : '<div class="empty">Todavía no tienes pedidos. Pídele a Nova algo de comer o un hotel.</div>';
}
document.addEventListener('click', async function (e) {
  var b = e.target.closest('[data-ost],[data-omail]'); if (!b) return;
  if (b.dataset.omail) { var o = S.ordMap[b.dataset.omail]; if (o) copyText(mailText(o)); return; }
  var o2 = S.ordMap[b.dataset.ost], to = b.dataset.to; if (!o2 || !ST_LBL[to]) return;
  if (!(isOwnerOf(o2) || (o2.cust === S.me.id && to === 'cancelado'))) return;
  b.disabled = true;
  try { await S.db.doc('orders/' + o2.id).update({ st: to }); audit('pedido-' + to, o2.id); toast('Estado: ' + ST_LBL[to]); } catch (er) { toast(dbErr(er)); b.disabled = false; }
});
/* administración */
function adminPed() {
  var rows = S.orders.slice(0, 60).map(function (o) { return '<tr><td>' + esc(o.id.slice(-6).toUpperCase()) + '</td><td>' + esc(o.rn) + '</td><td>' + (o.k === 'hotel' ? 'Hotel' : 'Comida') + '</td><td>' + cop(o.total) + '</td><td>' + cop(o.fee) + '</td><td>' + cop(o.net) + '</td><td>' + esc(ST_LBL[o.st]) + '</td><td>' + esc(when(o.ts)) + '</td></tr>'; });
  return tbl(['N.º', 'Negocio', 'Tipo', 'Total', 'Comisión', 'Para el negocio', 'Estado', 'Fecha'], rows, 'Aún no hay pedidos.');
}
function adminLiq() {
  var g = {}, tf = 0, tt = 0;
  S.orders.forEach(function (o) { if (o.st === 'cancelado') return; var x = g[o.rid] || (g[o.rid] = { n: o.rn, c: 0, t: 0, f: 0, nt: 0 }); x.c++; x.t += o.total; x.f += o.fee; x.nt += o.net; tf += o.fee; tt += o.total; });
  var rows = Object.keys(g).map(function (k) { var x = g[k]; return '<tr><td>' + esc(x.n) + '</td><td>' + x.c + '</td><td>' + cop(x.t) + '</td><td>' + cop(x.f) + '</td><td>' + cop(x.nt) + '</td></tr>'; });
  return '<div class="kpis"><div><b>' + cop(tf) + '</b><span>Comisión Nova acumulada</span></div><div><b>' + cop(tt) + '</b><span>Total cobrado a clientes</span></div><div><b>' + cop(tt - tf) + '</b><span>Por entregar a negocios</span></div><div><b>' + cop(num(S.fee, 5000)) + '</b><span>Comisión por pedido</span></div></div>' +
    '<form class="kbform" id="feeForm"><h3>Comisión por pedido</h3><label for="fee-v">Pesos descontados al negocio por cada pedido<input id="fee-v" type="number" min="0" max="5000" step="50" value="' + num(S.fee, 5000) + '"></label><div class="rowbtns"><button class="btn primary small" type="submit">Guardar</button></div><p class="msg" id="feeMsg"></p></form>' +
    tbl(['Negocio', 'Pedidos', 'Cobrado', 'Comisión Nova', 'Para el negocio'], rows, 'Sin movimientos.') +
    '<p class="fine">Estas cifras son un registro de prueba. Los pagos reales y las transferencias a tu cuenta bancaria y a los negocios requieren una pasarela de pagos autorizada; Nova no guarda números de cuenta.</p>';
}
document.addEventListener('submit', async function (e) {
  if (e.target.id !== 'feeForm') return; e.preventDefault();
  var v = parseInt($('#fee-v').value, 10), m = $('#feeMsg');
  if (!(v >= 0 && v <= 5000)) return setMsg(m, 'Escribe un valor entre 0 y 5.000.', 'err');
  try { await S.db.doc('settings/platform').set({ fee: v, ts: Date.now() }); audit('admin-comision', String(v)); setMsg(m, 'Guardado.', 'ok'); } catch (er) { setMsg(m, dbErr(er), 'err'); }
});
/* editor de carta, tarifas y correo */
function editMenu(id) {
  var r = S.map[id]; if (!r) return;
  var d = menuDoc(id) || { text: '', email: '' }, hotel = isHotel(r);
  var help = hotel ? 'Una línea por tarifa: Habitación | hora, noche o día | precio | nota. Ejemplo: Habitación sencilla | noche | 80000 | Salida 12 m' : 'Una categoría por línea con #, luego: Plato | precio | descripción. Ejemplo: # Pollo, y debajo Pollo asado | 30500 | Con papa';
  openModal('<h3 id="modalTitle">' + (hotel ? 'Tarifas' : 'Carta') + ' de ' + esc(r.n) + '</h3><form id="menuForm"><label for="mn-e">Correo del dueño (recibe los pedidos)<input id="mn-e" type="email" maxlength="120" value="' + esc(d.email || '') + '"></label><label for="mn-t">' + (hotel ? 'Tarifas' : 'Carta') + '<textarea id="mn-t" rows="10" maxlength="4000" style="font-family:monospace;font-size:.82rem">' + esc(d.text || '') + '</textarea><span class="hint">' + esc(help) + ' Copia los precios de la página oficial del negocio.</span></label><div class="rowbtns"><button class="btn primary" type="submit">Guardar</button><button class="btn ghost" type="button" data-close>Cancelar</button></div><p class="msg" id="mnMsg"></p></form>', function (m) {
    m.querySelector('[data-close]').addEventListener('click', closeModal);
    m.querySelector('#menuForm').addEventListener('submit', async function (ev) {
      ev.preventDefault(); var mm = $('#mnMsg'), em = $('#mn-e').value.trim(), tx = $('#mn-t').value.trim();
      if (em && !emailOk(em)) return setMsg(mm, 'El correo no es válido.', 'err');
      var cnt = hotel ? parseRates(tx).length : parseMenu(tx).items.length;
      if (tx && !cnt) return setMsg(mm, 'No pude leer ninguna línea. Revisa el formato.', 'err');
      try { await S.db.doc('menus/' + id).set({ text: tx, email: em, ts: Date.now() }); audit('admin-carta', id); closeModal(); toast('Guardado: ' + cnt + (hotel ? ' tarifas.' : ' platos.')); } catch (er) { setMsg(mm, dbErr(er), 'err'); }
    });
  });
}
