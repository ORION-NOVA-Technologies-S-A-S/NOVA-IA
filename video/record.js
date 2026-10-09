// Graba un recorrido real de la app (contra el servidor de prueba) y guarda las marcas de tiempo para los subtítulos.
const { chromium } = require('playwright'), fs = require('fs'), cp = require('child_process');
const FILE = 'file:///home/claude/nova-ia/src/test.out.html', PW = 'Clave-Nova-2026!', PSQL = '/usr/lib/postgresql/16/bin/psql';
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  // 1) usuario administrador de la demostración (sin grabar)
  const pre = await (await b.newContext({ viewport: { width: 1280, height: 720 } })).newPage();
  await pre.goto(FILE); await sleep(800);
  await pre.evaluate(() => document.querySelector('[data-go=auth][data-tab=reg]').click());
  await pre.fill('#r-user', 'carlos'); await pre.fill('#r-pass', PW); await pre.fill('#r-pass2', PW); await pre.fill('#r-phone', '3001234567');
  await pre.evaluate(() => document.querySelector('#regBtn').click());
  await pre.waitForFunction(() => window.__ev('!!S.session'), null, { timeout: 30000 });
  cp.execSync(`su postgres -c "${PSQL} -h /tmp/pgw -p 5433 -d sbtest -c \\"insert into admins select id from auth.users where email like 'carlos@%'\\""`);
  await pre.close();
  // 2) grabación
  const ctx = await b.newContext({ viewport: { width: 1280, height: 720 }, recordVideo: { dir: 'raw', size: { width: 1280, height: 720 } } });
  const p = await ctx.newPage(); const t0 = Date.now(); const marks = [];
  const mark = (t) => marks.push({ t: (Date.now() - t0) / 1000, text: t });
  await p.addInitScript(() => {
    window.addEventListener('DOMContentLoaded', () => {
      const d = document.createElement('div'); d.style.cssText = 'position:fixed;z-index:99999;width:22px;height:22px;border-radius:50%;background:rgba(120,170,255,.55);border:2px solid #fff;pointer-events:none;transform:translate(-50%,-50%);left:-50px;top:-50px;transition:left .04s,top .04s;box-shadow:0 0 12px #4c7dff';
      document.body.appendChild(d); document.addEventListener('mousemove', e => { d.style.left = e.clientX + 'px'; d.style.top = e.clientY + 'px'; });
    });
  });
  const tap = async (sel, o = {}) => { const el = o.text ? p.locator(sel).filter({ hasText: o.text }).first() : p.locator(sel).first(); await el.scrollIntoViewIfNeeded(); const bb = await el.boundingBox(); await p.mouse.move(bb.x + bb.width / 2, bb.y + bb.height / 2, { steps: 18 }); await sleep(350); await p.mouse.click(bb.x + bb.width / 2, bb.y + bb.height / 2); await sleep(o.after || 700); };
  const typeIn = async (sel, text, d = 55) => { await tap(sel, { after: 200 }); await p.keyboard.type(text, { delay: d }); await sleep(400); };
  const ev = c => p.evaluate(x => window.__ev(x), c);
  await p.goto(FILE); await sleep(1500);
  mark('Esta es Nova: el asistente humanoide para restaurantes y hoteles de Neiva.');
  await sleep(3500);
  await p.mouse.move(980, 330, { steps: 25 }); await sleep(600); await p.mouse.click(980, 330); await sleep(3500);
  if (await p.isVisible('#cpanel')) await tap('#chatClose', { after: 900 });
  mark('Entras con tu cuenta. Es real: usuario y contraseña protegidos.');
  await tap('[data-go=auth][data-tab=login]');
  await typeIn('#l-user', 'carlos'); await typeIn('#l-pass', PW, 40);
  await tap('#loginBtn', { after: 600 });
  await p.waitForFunction(() => window.__ev('!!S.session'), null, { timeout: 30000 }); await sleep(1800);
  mark('Pides con NOVA FLOW IA, escribiendo como hablas.');
  await ev("go('home')"); await sleep(1200);
  await tap('#fab', { after: 2200 });
  await typeIn('#cin', 'quiero comer pollo asado con gaseosa del Asadero Demo Nova', 45);
  await p.keyboard.press('Enter'); await sleep(6000);
  mark('Nova muestra la carta del restaurante con sus precios.');
  await tap('#cmsgs button', { text: 'Continuar', after: 1800 });
  await sleep(1500);
  mark('Confirmas tus datos y la dirección de entrega.');
  await tap('#cmsgs button', { text: 'Seguir con mi pedido', after: 2500 });
  await p.fill('#od-n', ''); await typeIn('#od-n', 'Carlos', 70); await typeIn('#od-p', '3101234567', 60); await typeIn('#od-a', 'Calle 8 # 5-10, Neiva', 50);
  await tap('#cmsgs button', { text: 'Revisar pedido', after: 3500 });
  mark('Revisas el pedido: el valor total y el cobro de Nova.');
  await sleep(3000);
  mark('Pagas por PSE. En esta demostración el pago es simulado.');
  await tap('#cmsgs button', { text: 'Pagar con PSE', after: 1500 });
  await tap('#p-ok', { after: 600 }); await tap('#p-go', { after: 5500 });
  mark('Pedido tomado. El restaurante recibe el aviso con todo el detalle.');
  await sleep(3500);
  await tap('#chatClose', { after: 800 });
  mark('El cliente sigue el estado de su pedido en Mis pedidos.');
  await ev("go('orders')"); await sleep(3500);
  mark('Y el restaurante ve solo sus pedidos y los gestiona.');
  await ev("previewAs('restaurante')"); await sleep(1500);
  await ev("go('orders')"); await sleep(3000);
  const acc = p.locator('[data-ost]').first();
  if (await acc.count()) { await tap('[data-ost]', { after: 2500 }); await tap('[data-ost]', { after: 2500 }); }
  mark('La administración de Nova controla pedidos y liquidación: $200 por pedido.');
  await ev("previewAs('admin')"); await sleep(1500);
  await ev("go('admin'); S.ptab='liq'; renderAdmin()"); await sleep(4500);
  mark('Nova: tecnología que atiende. Orion Nova Technologies.');
  await ev("go('home')"); await sleep(4000);
  const dur = (Date.now() - t0) / 1000;
  fs.writeFileSync('marks.json', JSON.stringify({ marks, dur }, null, 1));
  const vp = await p.video().path(); await ctx.close(); await b.close(); fs.copyFileSync(vp, 'raw.webm'); console.log('ok', dur);
})().catch(e => { console.log('FALLO', e.message.split('\n')[0]); process.exit(1); });
