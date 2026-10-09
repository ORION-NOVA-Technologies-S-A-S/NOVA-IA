const { chromium } = require('playwright');
const FILE = 'file:///home/claude/nova-ia/src/test.out.html';
const PW = 'Clave-Nova-2026!';
const click = (p, sel) => p.evaluate(s => document.querySelector(s).click(), sel);
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const c = await b.newContext({ viewport: { width: 1280, height: 900 } }); const p = await c.newPage();
  const seen = new Set();
  const grab = async () => { const r = await p.evaluate(() => { const out = []; const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n;
      while ((n = w.nextNode())) { const e = n.parentElement; if (!e || e.closest('script,style,#langBar')) continue; const t = n.nodeValue.replace(/\s+/g, ' ').trim(); if (t.length > 2) out.push(t); }
      document.querySelectorAll('[placeholder],[title],[aria-label]').forEach(e => ['placeholder', 'title', 'aria-label'].forEach(a => { const v = e.getAttribute(a); if (v && v.length > 2) out.push(v); })); return out; });
    r.forEach(x => seen.add(x)); };
  await p.goto(FILE); await p.waitForTimeout(1200); await grab();
  for (const v of ['dir', 'auth']) { await p.evaluate(v => document.querySelector('[data-go=' + v + ']').click(), v); await p.waitForTimeout(500); await grab(); }
  await click(p, '[data-go=auth][data-tab=reg]'); await p.waitForTimeout(300); await grab();
  await p.fill('#r-user', 'cli1'); await p.fill('#r-pass', PW); await p.fill('#r-pass2', PW); await p.fill('#r-phone', '3004440009');
  await click(p, '#regBtn'); await p.waitForFunction(() => window.__ev('!!S.session'), null, { timeout: 30000 }); await p.waitForTimeout(800); await grab();
  await p.evaluate(() => window.__ev("go('dir')")); await p.waitForTimeout(600); await grab();
  // elegir categoría y restaurante
  await p.evaluate(() => window.__ev("go('rest','demo-asadero-nova')")); await p.waitForTimeout(600); await grab();
  await p.evaluate(() => window.__ev("go('rest',S.list.filter(r=>!r.demo)[0].id)")); await p.waitForTimeout(600); await grab();
  await p.evaluate(() => window.__ev("go('orders')")); await p.waitForTimeout(600); await grab();
  // chat: flujo de pedido completo
  await click(p, '#fab'); await p.waitForTimeout(2500); await grab();
  await p.fill('#cin', 'Quiero comer pollo asado'); await p.press('#cin', 'Enter'); await p.waitForTimeout(3500); await grab();
  await p.evaluate(() => { const b = [...document.querySelectorAll('#cmsgs .opts button, #cmsgs .acts button')].find(x => /Demo Nova/.test(x.textContent)); b && b.click(); }); await p.waitForTimeout(3500); await grab();
  await p.evaluate(() => { const b = document.querySelector('#cmsgs .mcard button.plus, #cmsgs .mcard [data-plus], #cmsgs .mcard .qty button:last-child'); b && b.click(); });
  await p.fill('#cin', 'un pollo asado con dos gaseosas'); await p.press('#cin', 'Enter'); await p.waitForTimeout(3500); await grab();
  for (const q of ['Dirección', 'Teléfono', '¿Cómo funciona el pago?', 'Restaurantes de pizza', 'quiero un hotel por el rato']) { await p.fill('#cin', q); await p.press('#cin', 'Enter'); await p.waitForTimeout(3000); await grab(); }
  await p.evaluate(() => { window.__ev("toggleChat(false)"); });
  // admin
  const a = await b.newContext({ viewport: { width: 1280, height: 900 } }); const q = await a.newPage();
  await q.goto(FILE); await q.waitForTimeout(800); await q.evaluate(() => document.querySelector('[data-go=auth][data-tab=reg]').click());
  await q.fill('#r-user', 'adm1'); await q.fill('#r-pass', PW); await q.fill('#r-pass2', PW); await q.fill('#r-phone', '3004440009');
  await q.evaluate(() => document.querySelector('#regBtn').click()); await q.waitForFunction(() => window.__ev('!!S.session'), null, { timeout: 30000 });
  require('child_process').execSync(`su postgres -c "/usr/lib/postgresql/16/bin/psql -h /tmp/pgw -p 5433 -d sbtest -c \\"insert into admins select id from auth.users where email like 'adm1@%'\\""`);
  await q.goto(FILE); await q.waitForTimeout(1800);
  const grab2 = async () => { const r = await q.evaluate(() => { const out = []; const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n; while ((n = w.nextNode())) { const e = n.parentElement; if (!e || e.closest('script,style,#langBar')) continue; const t = n.nodeValue.replace(/\s+/g, ' ').trim(); if (t.length > 2) out.push(t); } document.querySelectorAll('[placeholder],[title],[aria-label]').forEach(e => ['placeholder', 'title', 'aria-label'].forEach(a => { const v = e.getAttribute(a); if (v && v.length > 2) out.push(v); })); return out; }); r.forEach(x => seen.add(x)); };
  await q.evaluate(() => window.__ev("go('admin')")); await q.waitForTimeout(600); await grab2();
  for (const t of ['ped', 'liq', 'reg', 'solic', 'kb', 'seg', 'rest', 'res']) { await q.evaluate(t => window.__ev("S.ptab='" + t + "'; renderAdmin()"), t); await q.waitForTimeout(500); await grab2(); }
  for (const v of ['restaurante', 'cliente']) { await q.evaluate(v => window.__ev("openPreview ? openPreview('" + v + "') : 0"), v).catch(() => {}); await q.waitForTimeout(600); await grab2(); }
  require('fs').writeFileSync('/tmp/seen.json', JSON.stringify([...seen]));
  console.log('collected', seen.size); await b.close();
})().catch(e => { console.log('ERR', e.message.slice(0, 300)); process.exit(1); });
