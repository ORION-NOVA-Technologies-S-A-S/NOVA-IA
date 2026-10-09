const { chromium } = require('playwright');
const FILE = 'file:///home/claude/nova-ia/src/test.out.html';
const SH = process.env.SHOTS || '/tmp/i18n';
require('fs').mkdirSync(SH, { recursive: true });
const ES_RE = /\b(el|la|los|las|de|del|tu|tus|para|con|una|un|que|por|pedido|restaurante|carta|nuestro|elige|escribe|puedes|cuenta|ingresa|hola|quiero|aquí|todavía|aún|sin|más|también)\b/i;
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const c = await b.newContext({ viewport: { width: 1280, height: 800 }, permissions: [] }); const p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto(FILE); await p.waitForTimeout(1200);
  const left = async (tag) => {
    const r = await p.evaluate((src) => { const re = new RegExp(src, 'i'); const out = []; const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n;
      while ((n = w.nextNode())) { const e = n.parentElement; if (!e || e.closest('script,style,[hidden],#langBar,.bub.me')) continue; const cs = getComputedStyle(e); if (cs.display === 'none' || cs.visibility === 'hidden') continue; const t = n.nodeValue.trim(); if (t.length > 2 && re.test(t)) out.push(t.slice(0, 90)); } return out; }, ES_RE.source);
    console.log(tag, 'spanish-looking leftovers:', r.length); r.slice(0, 12).forEach(x => console.log('   -', x));
  };
  for (const l of ['en', 'pt', 'it', 'es']) {
    await p.click('#langBar [data-lang=' + l + ']'); await p.waitForTimeout(500);
    console.log('==', l, 'lang attr:', await p.evaluate(() => document.documentElement.lang), '| h1:', await p.innerText('h1'));
    await p.screenshot({ path: SH + '/home_' + l + '.png' });
    if (l !== 'es') await left('home ' + l);
  }
  // directorio + chat en italiano
  await p.click('#langBar [data-lang=it]'); await p.waitForTimeout(300);
  await p.evaluate(() => document.querySelector('[data-go=dir]').click()); await p.waitForTimeout(600);
  await p.screenshot({ path: SH + '/dir_it.png' }); await left('dir it');
  await p.evaluate(() => document.querySelector('#fab').click()); await p.waitForTimeout(2500);
  await p.screenshot({ path: SH + '/chat_it.png' });
  console.log('chat head:', await p.innerText('#cpanel'));
  await p.evaluate(() => { const b = document.querySelector('#csug button'); b.click(); }); await p.waitForTimeout(3500);
  await p.fill('#cin', 'voglio un hotel a ore'); await p.press('#cin', 'Enter'); await p.waitForTimeout(3500);
  await p.screenshot({ path: SH + '/chat_it2.png' });
  console.log('chat text:\n' + (await p.innerText('#cmsgs')).slice(0, 900));
  await p.click('#langBar [data-lang=en]'); await p.waitForTimeout(400); await p.screenshot({ path: SH + '/chat_en.png' });
  console.log('errors:', errs);
  await b.close();
})();
