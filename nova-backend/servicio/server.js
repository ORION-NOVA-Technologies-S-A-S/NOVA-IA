'use strict';
/* Servicio de Nova: lo que PostgREST no puede hacer (claves secretas, mensajes, webhooks).
   No tiene permisos sobre tablas: solo llama a las funciones de la base con el rol "servicio". */
const http = require('http'), crypto = require('crypto');
const wompi = require('./wompi'), { enviarCodigo } = require('./notify');

const b64u = (b) => Buffer.from(b).toString('base64url');
function firmarJWT(payload, secret, ttl = 3600) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), p = b64u(JSON.stringify({ ...payload, exp: Math.floor(Date.now() / 1000) + ttl }));
  return `${h}.${p}.${crypto.createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url')}`;
}
function json(res, code, obj) { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); }
function leer(req, max = 100000) { return new Promise((ok, no) => { let d = ''; req.on('data', (c) => { d += c; if (d.length > max) { req.destroy(); no(new Error('grande')); } }); req.on('end', () => { try { ok(JSON.parse(d || '{}')); } catch (e) { no(e); } }); }); }
const GENERICO = { ok: true, msg: 'Si el usuario existe, enviamos un código al celular registrado.' };

function crearApp({ pool, env = process.env, enviar = enviarCodigo }) {
  const claims = (req) => { try { const [h, p, s] = (req.headers.authorization || '').replace('Bearer ', '').split('.'); const ok = crypto.createHmac('sha256', env.JWT_SECRET).update(`${h}.${p}`).digest('base64url') === s; const c = JSON.parse(Buffer.from(p, 'base64url')); return ok && c.exp > Date.now() / 1000 ? c : null; } catch (e) { return null; } };
  return async (req, res) => {
    try {
      const u = new URL(req.url, 'http://x');
      if (req.method === 'POST' && u.pathname === '/auth/login') {
        const b = await leer(req), { rows } = await pool.query('select core.verificar_login($1,$2) r', [String(b.usuario || ''), String(b.clave || '')]); const r = rows[0].r;
        if (!r.ok) return json(res, 401, { ok: false, msg: r.msg });
        const c = r.role === 'restaurante' ? { role: 'restaurante', restaurant_id: r.restaurant_id, sub: r.id } : r.role === 'cliente' ? { role: 'cliente', sub: r.id } : { role: 'admin_nova', sub: r.id };
        return json(res, 200, { ok: true, token: firmarJWT(c, env.JWT_SECRET) });
      }
      if (req.method === 'POST' && u.pathname === '/auth/recuperar') {         // "Olvidé mi contraseña"
        const b = await leer(req);
        try {
          const { rows } = await pool.query('select * from core.solicitar_recuperacion($1)', [String(b.usuario || '').slice(0, 20)]);
          if (rows[0]) await enviar({ channel: rows[0].channel, phone: rows[0].phone, code: rows[0].code }, env);
        } catch (e) { if (e.code === 'PT429') return json(res, 429, { ok: false, msg: e.message }); console.error('recuperar:', e.message); }
        return json(res, 200, GENERICO);                                         // misma respuesta exista o no el usuario
      }
      if (req.method === 'POST' && u.pathname === '/auth/restablecer') {
        const b = await leer(req), { rows } = await pool.query('select core.restablecer_clave($1,$2,$3) r', [String(b.usuario || ''), String(b.codigo || ''), String(b.clave_nueva || '')]);
        return json(res, rows[0].r.ok ? 200 : 400, rows[0].r);
      }
      if (req.method === 'POST' && u.pathname === '/pagos/iniciar') {          // el cliente pide pagar; el valor sale de la base
        const c = claims(req); if (!c || c.role !== 'cliente') return json(res, 401, { ok: false, msg: 'Inicia sesión como cliente.' });
        const b = await leer(req), { rows } = await pool.query('select core.crear_intencion_pago($1,$2,$3,$4) r', [c.sub, b.restaurante, JSON.stringify(b.items || []), JSON.stringify(b.detalle || {})]);
        const q = rows[0].r;
        return json(res, 200, { ok: true, total: q.total, comision: q.fee, para_el_negocio: q.net, reference: q.reference,
          checkout: wompi.urlCheckout({ publicKey: env.WOMPI_PUBLIC_KEY, integritySecret: env.WOMPI_INTEGRITY_SECRET, reference: q.reference, amountInCents: q.amount_in_cents, redirectUrl: `${env.PUBLIC_URL}/gracias` }) });
      }
      if (req.method === 'POST' && u.pathname === '/pagos/webhook') {           // la pasarela avisa; solo se acepta si la firma es válida
        const ev = await leer(req);
        if (!wompi.verificarEvento(ev, env.WOMPI_EVENTS_SECRET)) return json(res, 401, { ok: false });
        const t = ev.data && ev.data.transaction; if (ev.event !== 'transaction.updated' || !t) return json(res, 200, { ok: true });
        const { rows } = await pool.query('select core.confirmar_pago($1,$2,$3,$4,$5) r', [t.reference, t.id, t.status, t.amount_in_cents, t.payment_method_type || null]);
        return json(res, 200, rows[0].r);
      }
      json(res, 404, { ok: false });
    } catch (e) { console.error(e.message); json(res, e.code && String(e.code).startsWith('PT') ? Number(String(e.code).slice(2)) : 500, { ok: false, msg: e.code && String(e.code).startsWith('PT') ? e.message : 'Error interno.' }); }
  };
}
module.exports = { crearApp, firmarJWT };
if (require.main === module) {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  http.createServer(crearApp({ pool })).listen(process.env.PORT || 4000, () => console.log('Servicio Nova en puerto', process.env.PORT || 4000));
}
