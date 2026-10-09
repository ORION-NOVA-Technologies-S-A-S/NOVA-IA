/* ============ Olvidé mi contraseña (demostración con mensaje simulado) ============ */
var RESET = null;
function maskPhone(p) { p = String(p || ''); return p.length >= 6 ? p.slice(0, 3) + ' ••• •• ' + p.slice(-2) : '••••'; }
function forgotModal() {
  openModal('<h3 id="modalTitle">Recuperar contraseña</h3><div id="fgStep1"><p class="hint">Escribe tu usuario. Te enviaremos un código al celular que registraste, por el canal que elegiste al crear la cuenta.</p>' +
    '<label for="fg-u">Usuario<input id="fg-u" maxlength="20" autocapitalize="none" spellcheck="false" autocomplete="username"></label>' +
    '<div class="rowbtns"><button class="btn primary" type="button" id="fg-send">Enviar código</button><button class="btn ghost" type="button" data-close>Cancelar</button></div></div>' +
    '<div id="fgStep2" hidden><div class="paynote" id="fgSim"></div><label for="fg-c">Código de 6 dígitos<input id="fg-c" inputmode="numeric" maxlength="6" autocomplete="one-time-code"></label>' +
    '<label for="fg-p">Contraseña nueva<input id="fg-p" type="password" maxlength="64" autocomplete="new-password"></label>' +
    '<div class="rowbtns"><button class="btn primary" type="button" id="fg-ok">Cambiar contraseña</button><button class="btn ghost" type="button" data-close>Cancelar</button></div></div><p class="msg" id="fgMsg" role="status"></p>', function (m) {
    $$('[data-close]', m).forEach(function (b) { b.addEventListener('click', function () { RESET = null; closeModal(); }); });
    var msg = $('#fgMsg', m);
    $('#fg-send', m).addEventListener('click', async function () {
      var u = $('#fg-u', m).value.trim().toLowerCase(); if (!needDb(msg)) return;
      if (!u) return setMsg(msg, 'Escribe tu usuario.', 'err');
      if (RESET && RESET.at && Date.now() - RESET.at < 30000) return setMsg(msg, 'Espera unos segundos antes de pedir otro código.', 'err');
      try {
        var s = await acctRef().get(), a = s.exists ? s.data() : null;
        if (!a || a.username !== u || !a.phone) { setMsg(msg, 'Si el usuario existe y tiene celular registrado, enviamos un código.', 'ok'); RESET = { at: Date.now() }; return; }
        var buf = crypto.getRandomValues(new Uint32Array(1)), code = String(buf[0] % 1000000).padStart(6, '0');
        RESET = { at: Date.now(), user: u, code: code, exp: Date.now() + 600000, tries: 0 };
        var canal = a.ch === 'sms' ? 'SMS' : 'WhatsApp';
        $('#fgSim', m).innerHTML = '<b>Demostración.</b> Nova aún no tiene ' + canal + ' conectado, por eso el mensaje se muestra aquí. En producción el código llega solo al celular y nunca aparece en pantalla.<div class="mmail" style="margin-top:8px">' + canal + ' a ' + esc(maskPhone(a.phone)) + '\nNova: tu código para recuperar la contraseña es ' + esc(code) + '. Vence en 10 minutos. Si no lo pediste, ignóralo.</div>';
        $('#fgStep1', m).hidden = true; $('#fgStep2', m).hidden = false; setMsg(msg, ''); $('#fg-c', m).focus(); audit('recuperacion-solicitada', canal);
      } catch (e) { setMsg(msg, dbErr(e), 'err'); }
    });
    $('#fg-ok', m).addEventListener('click', async function () {
      var code = $('#fg-c', m).value.trim(), np = $('#fg-p', m).value, bad = 'Código incorrecto o vencido.';
      if (!RESET || !RESET.code || RESET.exp < Date.now() || RESET.tries >= 5) return setMsg(msg, bad, 'err');
      if (code !== RESET.code) { RESET.tries++; return setMsg(msg, bad, 'err'); }
      var pol = pwPolicy(np, RESET.user); if (!pol.ok) return setMsg(msg, pol.msg, 'err');
      try {
        var salt = crypto.getRandomValues(new Uint8Array(16)), h = await hashPw(np, salt);
        await acctRef().update({ salt: b64(salt), hash: b64(h), iter: KDF_ITER, failed: 0, lockedUntil: 0 });
        audit('recuperacion-completada', ''); RESET = null; closeModal(); toast('Contraseña actualizada. Ya puedes ingresar.');
      } catch (e) { setMsg(msg, e && e.code ? dbErr(e) : 'No se pudo cambiar la contraseña.', 'err'); }
    });
  });
}
document.addEventListener('click', function (e) { if (e.target.closest('[data-forgot]')) { e.preventDefault(); forgotModal(); } });
