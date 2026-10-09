// Servidor de prueba: imita Supabase (Auth + PostgREST) usando el PostgreSQL local real con RLS.
const http = require('http'), { execFileSync } = require('child_process'), crypto = require('crypto');
const PSQL = ['/usr/lib/postgresql/16/bin/psql', '-h', '/tmp/pgw', '-p', '5433', '-d', 'sbtest', '-At', '-q', '-v', 'ON_ERROR_STOP=1'];
const users = {}, tokens = {}, refresh = {};
const lit = s => "$q$" + s + "$q$";
function sql(role, uid, body) {
  const pre = role === 'anon' ? "set local role anon; select set_config('request.jwt.claim.sub','',true);" : `set local role authenticated; select set_config('request.jwt.claim.sub','${uid}',true);`;
  try { return { ok: true, out: execFileSync('su', ['postgres', '-c', PSQL.map(a => `'${a}'`).join(' ') + ' -c ' + `'begin; ${(pre + body).replace(/'/g, "'\\''")} commit;'`], { encoding: 'utf8' }) }; }
  catch (e) { return { ok: false, err: String(e.stderr || e.message) }; }
}
function lastLine(o) { const l = o.trim().split('\n').filter(x => x && !/^(SET|BEGIN|COMMIT|set_config|\s*)$/.test(x)); return l[l.length - 1] || ''; }
function mkSession(u) { const at = crypto.randomUUID(), rt = crypto.randomUUID(); tokens[at] = u.id; refresh[rt] = u.id; return { access_token: at, refresh_token: rt, expires_in: 3600, token_type: 'bearer', user: { id: u.id, email: u.email, user_metadata: { username: u.username } } }; }
const srv = http.createServer((req, res) => {
  const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*', 'Content-Type': 'application/json' };
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  let b = ''; req.on('data', c => b += c); req.on('end', () => {
    const send = (code, o) => { res.writeHead(code, cors); res.end(o === undefined ? '' : JSON.stringify(o)); };
    const url = new URL(req.url, 'http://x'), body = b ? JSON.parse(b) : {};
    const tk = (req.headers.authorization || '').replace('Bearer ', ''), uid = tokens[tk], role = uid ? 'authenticated' : 'anon';
    if (url.pathname === '/__reset') { for (const k in users) delete users[k]; for (const k in tokens) delete tokens[k]; for (const k in refresh) delete refresh[k]; return send(200, {}); }
    if (url.pathname === '/auth/v1/signup') {
      if (users[body.email]) return send(422, { error_code: 'user_already_exists', msg: 'User already registered' });
      const u = { id: crypto.randomUUID(), email: body.email, username: body.data.username }; users[body.email] = { ...u, pw: body.password };
      execFileSync('su', ['postgres', '-c', PSQL.join(' ') + ` -c "insert into auth.users(id,email) values ('${u.id}','${u.email}')"`]);
      return send(200, mkSession(u));
    }
    if (url.pathname === '/auth/v1/token') {
      if (url.searchParams.get('grant_type') === 'refresh_token') { const id = refresh[body.refresh_token]; const u = Object.values(users).find(x => x.id === id); return u ? send(200, mkSession(u)) : send(400, {}); }
      const u = users[body.email]; if (!u || u.pw !== body.password) return send(400, { error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
      return send(200, mkSession(u));
    }
    if (url.pathname === '/auth/v1/logout') { delete tokens[tk]; return send(204); }
    let m;
    if ((m = url.pathname.match(/^\/rest\/v1\/rpc\/(\w+)$/))) {
      let call;
      if (m[1] === 'is_admin') call = 'select public.is_admin();';
      else if (m[1] === 'doc_set') call = `select public.doc_set(${lit(body.p_path)}, ${lit(JSON.stringify(body.p_data))}::jsonb);`;
      else if (m[1] === 'doc_merge') call = `select public.doc_merge(${lit(body.p_path)}, ${lit(JSON.stringify(body.p_patch))}::jsonb);`;
      else return send(404, {});
      const r = sql(role, uid, call);
      if (!r.ok) return send(/row-level security/.test(r.err) ? 403 : 400, { message: r.err.split('\n')[0], code: /row-level/.test(r.err) ? '42501' : 'P0001' });
      const v = lastLine(r.out); return send(200, m[1] === 'is_admin' ? v === 't' : null);
    }
    if (url.pathname === '/rest/v1/docs') {
      const cond = [];
      for (const [k, v] of url.searchParams) {
        if (k === 'path' || k === 'coll') cond.push(`${k} = ${lit(v.replace(/^eq\./, ''))}`);
        if (k === 'subject') cond.push(`subject in (${v.replace(/^in\.\(|\)$/g, '').split(',').map(x => `'${x}'::uuid`).join(',')})`);
      }
      const w = cond.length ? 'where ' + cond.join(' and ') : '';
      if (req.method === 'DELETE') { const r = sql(role, uid, `delete from docs ${w};`); return r.ok ? send(204) : send(403, { message: r.err }); }
      const cols = (url.searchParams.get('select') || 'path,data');
      const r = sql(role, uid, `select replace(coalesce(json_agg(t),'[]'::json)::text, E'\\n', ' ') from (select ${cols} from docs ${w} order by path limit 1000) t;`);
      try { return r.ok ? send(200, JSON.parse(lastLine(r.out))) : send(400, { message: r.err }); } catch (e) { return send(500, { message: String(e) }); }
    }
    send(404, {});
  });
});
srv.listen(54321, () => console.log('mock listo'));
