const { chromium } = require('playwright');
(async()=>{ const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'}); const p=await b.newPage({viewport:{width:420,height:860}});
p.on('console',m=>console.log('C',m.type(),m.text().slice(0,200))); p.on('pageerror',e=>console.log('PE',e.message)); p.on('requestfailed',r=>console.log('RF',r.url(),r.failure().errorText));
p.on('response',r=>{ if(/54321/.test(r.url())) console.log('R',r.status(),r.url().slice(0,100)); });
await p.goto('file:///home/claude/nova-ia/src/test.out.html'); await p.waitForTimeout(1500);
await p.evaluate(()=>document.querySelector('[data-go=auth][data-tab=reg]').click()); await p.waitForTimeout(300);
await p.fill('#r-user','dbg1'); await p.fill('#r-pass','Clave-Nova-2026!'); await p.fill('#r-pass2','Clave-Nova-2026!'); await p.fill('#r-phone','3004440009');
await p.evaluate(()=>document.querySelector('#regBtn').click()); await p.waitForTimeout(6000);
console.log('msg:', await p.innerText('#regMsg')); await b.close(); })();
