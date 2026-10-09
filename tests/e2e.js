const { chromium } = require('playwright');
const FILE = 'file:///home/claude/nova-ia/src/test.out.html';
const PW = 'Clave-Nova-2026!';
async function ctx(b) { const c = await b.newContext({ viewport: { width: 420, height: 860 } }); const p = await c.newPage(); p.errs = []; p.on('pageerror', e => p.errs.push('PE ' + e.message)); p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|favicon/.test(m.text())) p.errs.push('CE ' + m.text()); }); return p; }
const ev = (p, code) => p.evaluate(c => window.__ev(c), code);
const click = (p, sel) => p.evaluate(s => document.querySelector(s).click(), sel);
async function register(p, user, role) {
  await p.goto(FILE); await p.waitForTimeout(800);
  await click(p, '[data-go=auth][data-tab=reg]'); await p.waitForTimeout(300);
  await p.fill('#r-user', user); await p.fill('#r-pass', PW); await p.fill('#r-pass2', PW); await p.fill('#r-phone', '3004440009');
  await p.evaluate(r => { document.querySelector('input[name=role][value=' + r + ']').checked = true; }, role);
  await click(p, '#regBtn'); await p.waitForFunction(() => window.__ev('!!S.session'), null, { timeout: 30000 }); await p.waitForTimeout(500);
}
(async () => { let out = [];  try {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });

  // 1) registro cliente
  const c = await ctx(b); await register(c, 'cliente1', 'cliente');
  out.push('cliente registrado, nav: ' + (await c.innerText('#mobnav')).replace(/\n/g, '|'));
  // 2) registro dueño y solicitud de restaurante
  const o = await ctx(b); await register(o, 'duenoa', 'usuario');
  out.push('dueño wizard paso2: ' + await o.isVisible('#regStep2'));
  const rid = await ev(o, 'S.list.filter(r => !r.demo)[0].id');
  const rname = await ev(o, 'S.list.filter(r => !r.demo)[0].n');
  await ev(o, 'chooseRest(S.map[' + JSON.stringify(rid) + '])'); await o.waitForTimeout(1200);
  out.push('solicitud: ' + await ev(o, 'JSON.stringify(S.req && S.req.status)'));
  // 3) admin: crear cuenta y volverla admin en la BD, volver a ingresar
  const a = await ctx(b); await register(a, 'adminx', 'usuario');
  require('child_process').execSync(`su postgres -c "/usr/lib/postgresql/16/bin/psql -h /tmp/pgw -p 5433 -d sbtest -c \\"insert into admins select id from auth.users where email like 'adminx@%'\\""`);
  await a.goto(FILE); await a.waitForTimeout(1500);
  out.push('admin tras recargar: role=' + await ev(a, 'S.session && S.session.role') + ' canEdit=' + await ev(a, 'S.me.canEdit'));
  await ev(a, "go('admin')"); await a.waitForTimeout(500);
  await ev(a, "S.ptab = 'solic'; renderAdmin()"); await a.waitForTimeout(1500);
  out.push('admin ve solicitud: ' + (await a.innerText('#adminPane')).replace(/\s+/g, ' ').slice(0, 160));
  await a.evaluate(() => document.querySelector('[data-approve]').click()); await a.waitForTimeout(1500);
  // 4) el dueño ya es del restaurante (poll 7s)
  await o.waitForTimeout(9000);
  out.push('dueño reg: ' + await ev(o, 'JSON.stringify(S.reg)'));
  // 5) cliente hace un pedido
  await ev(c, "S.db.doc('orders/pt1').set({ k: 'food', rid: " + JSON.stringify(rid) + ", rn: 'X', cust: 'falso', items: [{ n: 'Pollo', q: 1, p: 30500, u: '' }], total: 30500, fee: 0, net: 30500, det: { n: 'Cli', p: '3001112233', m: 'recoger', a: '', o: '' }, st: 'entregado', pay: 'pse-prueba', bank: 'b', email: '', ts: Date.now() })");
  await c.waitForTimeout(8500);
  out.push('cliente ve su pedido: ' + await ev(c, 'JSON.stringify(S.orders.map(o => [o.st, o.fee, o.net]))'));
  await o.waitForTimeout(8000);
  out.push('dueño ve pedido: ' + await ev(o, 'JSON.stringify(S.orders.map(o => [o.st, o.fee, o.net]))'));
  // 6) otro cliente NO lo ve
  const x = await ctx(b); await register(x, 'cliente2', 'cliente'); await x.waitForTimeout(8000);
  out.push('otro cliente ve: ' + await ev(x, 'S.orders.length'));
  // 7) el dueño acepta; salir/entrar
  await ev(o, "S.db.doc('orders/pt1').update({ st: 'aceptado' })"); await o.waitForTimeout(500);
  out.push('estado tras aceptar: ' + await ev(o, "(async()=>(await S.db.doc('orders/pt1').get()).data().st)()"));
  await ev(o, 'logout()'); await o.waitForTimeout(1500);
  await click(o, '[data-go=auth][data-tab=login]'); await o.fill('#l-user', 'duenoa'); await o.fill('#l-pass', PW); await click(o, '#loginBtn'); await o.waitForTimeout(2500);
  out.push('login dueño: ' + await ev(o, 'JSON.stringify(S.session)') + ' view=' + await ev(o, 'S.view'));
  const bad = await ctx(b); await bad.goto(FILE); await bad.waitForTimeout(800); await click(bad, '[data-go=auth][data-tab=login]'); await bad.fill('#l-user', 'duenoa'); await bad.fill('#l-pass', 'mala-clave-1A!'); await click(bad, '#loginBtn'); await bad.waitForTimeout(1500);
  out.push('login malo: ' + await bad.innerText('#loginMsg'));
  console.log(out.join('\n'));
  for (const p of [c, o, a, x, bad]) if (p.errs.length) console.log('ERRORES', p.errs.slice(0, 4));
  await o.screenshot({ path: '/home/claude/nova-ia/tests/o.png' });
  await b.close();
  } catch (e) { console.log(out.join('\n')); console.log('FALLO', e.message.split('\n')[0]); process.exit(1); }
})();
