/* Nova IA — conexión con Supabase (PostgREST + Auth).
   Ofrece a la página la misma interfaz que usaba antes (db.doc / db.collection / user),
   pero guardando todo en la tabla public.docs de tu proyecto, protegida por RLS. */
(function () {
  var C = window.NOVA_CONFIG || {};
  if (!C.url || !C.key) return;
  var BASE = C.url.replace(/\/+$/, ''), KEY = C.key, LSK = 'nova.auth.v1', DOM = '@usuarios.novaia.app';
  var sess = null, admin = null;
  function lsGet() { try { return JSON.parse(localStorage.getItem(LSK) || 'null'); } catch (e) { return null; } }
  function lsSet(v) { try { if (v) localStorage.setItem(LSK, JSON.stringify(v)); else localStorage.removeItem(LSK); } catch (e) { /* sin almacenamiento */ } }
  sess = lsGet();
  function fail(code, msg, status) { var e = new Error(msg || code); e.code = code; e.msg = msg; e.status = status; return e; }
  function emailOf(u) { return String(u).toLowerCase() + DOM; }
  function pack(j) { return { access_token: j.access_token, refresh_token: j.refresh_token, exp: Date.now() + (j.expires_in || 3600) * 1000, user: { id: j.user.id, username: (j.user.user_metadata && j.user.user_metadata.username) || String(j.user.email || '').split('@')[0] } }; }

  var refreshing = null;
  async function fresh() {
    if (!sess) return null;
    if (sess.exp - Date.now() > 60000) return sess.access_token;
    if (!refreshing) refreshing = (async function () {
      try {
        var r = await fetch(BASE + '/auth/v1/token?grant_type=refresh_token', { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: sess.refresh_token }) });
        if (!r.ok) { sess = null; lsSet(null); return null; }
        sess = pack(await r.json()); lsSet(sess); return sess.access_token;
      } catch (e) { return sess ? sess.access_token : null; } finally { refreshing = null; }
    })();
    return refreshing;
  }
  async function req(method, path, body, extra) {
    var h = { apikey: KEY, 'Content-Type': 'application/json' }, t = await fresh();
    if (t) h.Authorization = 'Bearer ' + t;
    if (extra) for (var k in extra) h[k] = extra[k];
    var r;
    try { r = await fetch(BASE + path, { method: method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) }); }
    catch (e) { throw fail('unavailable', 'Sin conexión con el servidor.'); }
    if (!r.ok) {
      var j = null; try { j = await r.json(); } catch (e) { /* sin cuerpo */ }
      throw fail(r.status === 429 ? 'resource_exhausted' : (r.status === 401 || r.status === 403 || (j && j.code === '42501')) ? 'invalid_argument' : 'error', j && (j.message || j.msg || j.error_description), r.status);
    }
    if (r.status === 204) return null;
    var tx = await r.text(); return tx ? JSON.parse(tx) : null;
  }

  /* ---------- cuentas ---------- */
  var Auth = {
    user: function () { return sess ? sess.user : null; },
    async signUp(username, pw) {
      var r;
      try { r = await fetch(BASE + '/auth/v1/signup', { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: emailOf(username), password: pw, data: { username: username } }) }); }
      catch (e) { throw fail('unavailable', 'Sin conexión con el servidor.'); }
      var j = await r.json().catch(function () { return {}; });
      if (!r.ok) {
        var m = String(j.msg || j.message || j.error_description || '');
        if (/already|registered|exists/i.test(m) || j.error_code === 'user_already_exists') throw fail('exists', 'Ese usuario ya existe. Elige otro o ingresa.');
        if (/weak|password/i.test(m)) throw fail('weak', 'La contraseña es muy débil para el servidor. Prueba una más larga.');
        if (r.status === 429) throw fail('resource_exhausted', 'Demasiados intentos. Espera unos minutos.');
        throw fail('error', 'No se pudo crear la cuenta. ' + m);
      }
      if (!j.access_token) throw fail('confirm', 'El servidor pide confirmar el correo. En Supabase desactiva Authentication > Providers > Email > Confirm email.');
      sess = pack(j); lsSet(sess); admin = null; pokeAll(); return sess;
    },
    async signIn(username, pw) {
      var r;
      try { r = await fetch(BASE + '/auth/v1/token?grant_type=password', { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: emailOf(username), password: pw }) }); }
      catch (e) { throw fail('unavailable', 'Sin conexión con el servidor.'); }
      var j = await r.json().catch(function () { return {}; });
      if (!r.ok) {
        if (r.status === 429) throw fail('resource_exhausted', 'Demasiados intentos. Espera unos minutos.');
        if (r.status === 400 || r.status === 401) throw fail('bad_credentials', 'Usuario o contraseña incorrectos.');
        throw fail('error', 'No se pudo ingresar.');
      }
      sess = pack(j); lsSet(sess); admin = null; pokeAll(); return sess;
    },
    async signOut() {
      var t = sess && sess.access_token; sess = null; admin = null; lsSet(null);
      if (t) { try { await fetch(BASE + '/auth/v1/logout', { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + t } }); } catch (e) { /* ya salió */ } }
    }
  };
  window.NovaAuth = Auth;

  /* ---------- documentos ---------- */
  function q(v) { return encodeURIComponent(v); }
  var watchers = [], timer = null;
  function pokeAll() { setTimeout(tick, 250); }
  function tick() { watchers.forEach(function (w) { w.run(); }); }
  function schedule() { if (!timer) timer = setInterval(function () { if (!document.hidden) tick(); }, 6000); }
  document.addEventListener('visibilitychange', function () { if (!document.hidden) tick(); });
  function watch(fetcher, cb, errCb) {
    var last = null, w = { run: async function () {
      try { var v = await fetcher(), s = JSON.stringify(v); if (s !== last) { last = s; cb(v); } }
      catch (e) { if (last === null && errCb) { last = ''; errCb(e); } }
    } };
    watchers.push(w); schedule(); w.run(); return function () { watchers = watchers.filter(function (x) { return x !== w; }); };
  }
  function snapOf(path, row) { return { exists: !!row, id: path.split('/').pop(), data: function () { return row ? JSON.parse(JSON.stringify(row.data)) : undefined; } }; }
  function doc(path) {
    var self = {
      async get() { var r = await req('GET', '/rest/v1/docs?path=eq.' + q(path) + '&select=path,data'); return snapOf(path, r && r[0]); },
      async set(d) { await req('POST', '/rest/v1/rpc/doc_set', { p_path: path, p_data: d }); pokeAll(); },
      async update(d) { await req('POST', '/rest/v1/rpc/doc_merge', { p_path: path, p_patch: d }); pokeAll(); },
      async delete() { await req('DELETE', '/rest/v1/docs?path=eq.' + q(path)); pokeAll(); },
      onSnapshot(cb, errCb) { return watch(function () { return req('GET', '/rest/v1/docs?path=eq.' + q(path) + '&select=path,data').then(function (r) { return r && r[0] ? r[0] : null; }); }, function (row) { cb(snapOf(path, row)); }, errCb); }
    };
    return self;
  }
  function listSnap(rows) { return { docs: rows.map(function (r) { return { id: r.path.split('/').pop(), data: function () { return JSON.parse(JSON.stringify(r.data)); } }; }) }; }
  function collection(name) {
    var url = '/rest/v1/docs?coll=eq.' + q(name) + '&select=path,data&order=path.asc&limit=1000';
    return {
      async get() { return listSnap(await req('GET', url)); },
      async add(d) { var id = 'd' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7); await doc(name + '/' + id).set(d); return { id: id }; },
      onSnapshot(cb, errCb) { return watch(function () { return req('GET', url); }, function (rows) { cb(listSnap(rows)); }, errCb); }
    };
  }
  var userApi = {
    id: async function () { return sess ? sess.user.id : null; },
    me: async function () { return { name: sess ? sess.user.username : '' }; },
    canEdit: async function () {
      if (!sess) return false;
      if (admin === null) { try { admin = (await req('POST', '/rest/v1/rpc/is_admin', {})) === true; } catch (e) { admin = false; } }
      return admin;
    },
    can: async function () { return true; },
    profiles: async function (ids) {
      var o = {}; if (!ids.length) return o;
      var rows = await req('GET', '/rest/v1/docs?coll=eq.account&select=subject,data&subject=in.(' + ids.map(q).join(',') + ')');
      (rows || []).forEach(function (r) { o[r.subject] = { name: r.data && r.data.username || '' }; });
      return o;
    }
  };
  var parts = { db: { doc: doc, collection: collection }, user: userApi, sample: null };
  if (!window.claude) window.claude = { use: async function (n) { return parts[n]; } };
})();
