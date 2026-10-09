'use strict';
const crypto = require('crypto');
const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

/** Firma de integridad del checkout: SHA256(referencia + montoEnCentavos + moneda + secretoIntegridad). */
function firmaIntegridad(reference, amountInCents, currency, secret) {
  return sha256(`${reference}${amountInCents}${currency}${secret}`);
}

/** URL del Web Checkout de Wompi (PSE, Nequi, tarjetas… según lo que tengas activo en tu cuenta). */
function urlCheckout({ publicKey, integritySecret, reference, amountInCents, redirectUrl, email }) {
  const q = new URLSearchParams({
    'public-key': publicKey, currency: 'COP', 'amount-in-cents': String(amountInCents), reference,
    'signature:integrity': firmaIntegridad(reference, amountInCents, 'COP', integritySecret), 'redirect-url': redirectUrl,
  });
  if (email) q.set('customer-data:email', email);
  return 'https://checkout.wompi.co/p/?' + q.toString();
}

function lookup(obj, path) { return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj); }

/** Verifica el evento (webhook): SHA256(valores de signature.properties en orden + timestamp + secretoEventos) === signature.checksum. */
function verificarEvento(evento, eventsSecret) {
  try {
    const props = evento.signature.properties, valores = props.map((p) => String(lookup(evento.data, p)));
    const calc = sha256(valores.join('') + evento.timestamp + eventsSecret);
    const a = Buffer.from(calc), b = Buffer.from(String(evento.signature.checksum || '').toLowerCase());
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch (e) { return false; }
}
module.exports = { firmaIntegridad, urlCheckout, verificarEvento, sha256 };
