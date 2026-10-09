'use strict';
/* Pruebas del servicio. No necesita el paquete pg: usa un adaptador con psql y el rol "servicio" (permisos mínimos).
   Uso: PGHOST=/tmp/pgw PGPORT=5433 node test.js   (con la base 'nova' ya cargada con los scripts SQL) */
const { execFileSync } = require('child_process'), http = require('http'), crypto = require('crypto'), assert = require('assert');
const wompi = require('./wompi'), { crearApp, firmarJWT } = require('./server');
const PSQL = (sql) => execFileSync('psql', ['-h', process.env.PGHOST || '/tmp/pgw', '-p', process.env.PGPORT || '5433', '-U', 'postgres', '-d', 'nova', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8' }).trim();
const lit = (v) => (v === null || v === undefined ? 'null' : "'" + String(v).replace(/'/g, "''") + "'");
const pool = { async query(sql, params = []) {
  const s = sql.replace(/\$(\d+)/g, (_, i) => lit(params[i - 1]));
  try { const out = execFileSync('psql', ['-h', process.env.PGHOST || '/tmp/pgw', '-p', process.env.PGPORT || '5433', '-U', 'postgres', '-d', 'nova', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', `set role servicio; select row_to_json(t) from (${s}) t`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { rows: out.split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l)) };
  } catch (e) { const m = /ERROR:\s+(.*)/.exec(String(e.stderr)); const err = new Error(m ? m[1] : e.message); const c = /PT\d{3}/.exec(String(e.stderr)); if (c) err.code = c[0]; throw err; } } };
const env = { JWT_SECRET: 'secreto-de-pruebas-0123456789abcdef', WOMPI_PUBLIC_KEY: 'pub_test_x', WOMPI_INTEGRITY_SECRET: 'integ_x', WOMPI_EVENTS_SECRET: 'events_x', PUBLIC_URL: 'https://nova.test' };
const enviados = []; const app = crearApp({ pool, env, enviar: async (m) => { enviados.push(m); } });
let n = 0; const ok = (c, m) => { assert.ok(c, 'FALLA: ' + m); console.log('ok  - ' + m); n++; };

(async () => {
  // Firmas de la pasarela
  ok(wompi.firmaIntegridad('REF1', 3050000, 'COP', 'sec') === wompi.sha256('REF13050000COPsec'), 'firma de integridad = SHA256(referencia+centavos+moneda+secreto)');
  const ev = (st, amount, ref, secret = env.WOMPI_EVENTS_SECRET) => { const e = { event: 'transaction.updated', data: { transaction: { id: 'tx-' + ref + st, status: st, amount_in_cents: amount, reference: ref, payment_method_type: 'PSE' } }, timestamp: 1760000000, signature: { properties: ['transaction.id', 'transaction.status', 'transaction.amount_in_cents'] } };
    e.signature.checksum = wompi.sha256(e.signature.properties.map((p) => p.split('.').reduce((o, k) => o[k], e.data)).join('') + e.timestamp + secret); return e; };
  ok(wompi.verificarEvento(ev('APPROVED', 100, 'R'), env.WOMPI_EVENTS_SECRET), 'evento con firma válida aceptado');
  ok(!wompi.verificarEvento(ev('APPROVED', 100, 'R', 'otro-secreto'), env.WOMPI_EVENTS_SECRET), 'evento con firma falsa rechazado');
  const alt = ev('APPROVED', 100, 'R'); alt.data.transaction.amount_in_cents = 1; ok(!wompi.verificarEvento(alt, env.WOMPI_EVENTS_SECRET), 'evento alterado (monto) rechazado');

  const srv = http.createServer(app); await new Promise((r) => srv.listen(0, r)); const base = 'http://127.0.0.1:' + srv.address().port;
  const post = async (p, body, tok) => { const r = await fetch(base + p, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(tok ? { Authorization: 'Bearer ' + tok } : {}) }, body: JSON.stringify(body) }); return { s: r.status, j: await r.json() }; };

  // Recuperación por WhatsApp
  const tag = crypto.randomBytes(3).toString('hex'), user = 'cli' + tag;
  PSQL(`set role servicio; select core.registrar_usuario('${user}', 'Clave-Inicial-2026', 'cliente', '+573001112233', 'whatsapp')`);
  const r1 = await post('/auth/recuperar', { usuario: user }), r2 = await post('/auth/recuperar', { usuario: 'noexiste' + tag });
  ok(r1.s === 200 && r2.s === 200 && JSON.stringify(r1.j) === JSON.stringify(r2.j), 'misma respuesta exista o no el usuario');
  ok(enviados.length === 1 && enviados[0].channel === 'whatsapp' && enviados[0].phone === '+573001112233' && /^\d{6}$/.test(enviados[0].code), 'solo se envió un código, por WhatsApp al celular registrado');
  const mal = await post('/auth/restablecer', { usuario: user, codigo: '000000', clave_nueva: 'Nueva-Clave-2027!' }); ok(mal.s === 400, 'código malo: 400');
  const bien = await post('/auth/restablecer', { usuario: user, codigo: enviados[0].code, clave_nueva: 'Nueva-Clave-2027!' }); ok(bien.s === 200 && bien.j.ok, 'código bueno: contraseña cambiada');
  const lg = await post('/auth/login', { usuario: user, clave: 'Nueva-Clave-2027!' }); ok(lg.s === 200 && lg.j.token, 'login con la clave nueva entrega un token');
  const pl = JSON.parse(Buffer.from(lg.j.token.split('.')[1], 'base64url')); ok(pl.role === 'cliente' && pl.sub && pl.exp > Date.now() / 1000, 'el token lleva rol cliente y vencimiento');
  ok((await post('/auth/login', { usuario: user, clave: 'Clave-Inicial-2026' })).s === 401, 'la clave anterior ya no entra');

  // Pago: intención, checkout firmado, webhook
  const rid = PSQL("insert into core.restaurants(name) values ('Asadero Servicio') returning id").split('\n')[0];
  const it = PSQL(`set role servicio; select core.cargar_item('${rid}', 'Pollo', 'Pollo asado', 30500, null, 'https://ejemplo.invalid')`).split('\n').pop();
  const tok = firmarJWT({ role: 'cliente', sub: pl.sub }, env.JWT_SECRET);
  ok((await post('/pagos/iniciar', { restaurante: rid, items: [{ id: it, q: 1 }] })).s === 401, 'pagar sin sesión: 401');
  const pi = await post('/pagos/iniciar', { restaurante: rid, items: [{ id: it, q: 1 }], detalle: { dir: 'Cra 5 # 8-20' } }, tok);
  ok(pi.s === 200 && pi.j.total === 30500 && pi.j.comision === 200 && pi.j.para_el_negocio === 30300, 'intención de pago: $30.500 → comisión $200, negocio $30.300');
  const q = new URL(pi.j.checkout).searchParams;
  ok(q.get('amount-in-cents') === '3050000' && q.get('signature:integrity') === wompi.firmaIntegridad(pi.j.reference, 3050000, 'COP', env.WOMPI_INTEGRITY_SECRET), 'el checkout de la pasarela lleva el monto y la firma correctos');
  const hacker = await post('/pagos/webhook', ev('APPROVED', 3050000, pi.j.reference, 'falso')); ok(hacker.s === 401, 'webhook falso: 401, no crea pedido');
  const w1 = await post('/pagos/webhook', ev('APPROVED', 3050000, pi.j.reference)); ok(w1.s === 200 && w1.j.ok && w1.j.comision_nova === 200 && w1.j.para_el_negocio === 30300, 'webhook aprobado crea el pedido y el pago pendiente');
  const w2 = await post('/pagos/webhook', ev('APPROVED', 3050000, pi.j.reference)); ok(w2.j.repetido === true, 'webhook repetido no duplica');
  ok(PSQL(`select count(*) from core.orders where restaurant_id='${rid}'`) === '1' && PSQL(`select amount from core.payouts where restaurant_id='${rid}'`) === '30300', 'en la base: 1 pedido y $30.300 por pagar al restaurante');
  srv.close(); console.log(`\n${n} pruebas del servicio OK`);
})().catch((e) => { console.error(e.message); process.exit(1); });
