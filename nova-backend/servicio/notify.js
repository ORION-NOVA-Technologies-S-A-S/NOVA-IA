'use strict';
/** Envía el código de recuperación por el canal que el usuario eligió al crear su cuenta. */
async function enviarCodigo({ channel, phone, code }, env = process.env, fetchFn = fetch) {
  const texto = `Nova: tu código para recuperar la contraseña es ${code}. Vence en 10 minutos. Si no lo pediste, ignóralo.`;
  if (channel === 'whatsapp') {
    // WhatsApp Cloud API con plantilla de autenticación (obligatoria para iniciar la conversación).
    const r = await fetchFn(`https://graph.facebook.com/v20.0/${env.WHATSAPP_PHONE_ID}/messages`, {
      method: 'POST', headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', to: phone.replace('+', ''), type: 'template',
        template: { name: env.WHATSAPP_TEMPLATE, language: { code: 'es' },
          components: [{ type: 'body', parameters: [{ type: 'text', text: code }] }, { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: code }] }] } }) });
    if (!r.ok) throw new Error('WhatsApp respondió ' + r.status);
  } else {
    const r = await fetchFn(env.SMS_PROVIDER_URL, { method: 'POST', headers: { Authorization: `Bearer ${env.SMS_PROVIDER_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ to: phone, text: texto }) });
    if (!r.ok) throw new Error('El proveedor de SMS respondió ' + r.status);
  }
}
module.exports = { enviarCodigo };
