/* ============ Vista previa para administración: ver Nova como restaurante o como cliente ============ */
function previewAs(mode) {
  var s = S.session; if (!s) return;
  if (!s.admin) { if (s.role !== 'admin' || !S.me.canEdit) return; s.admin = true; s.savedReg = S.reg; }
  if (mode === 'admin') { s.role = 'admin'; S.reg = s.savedReg || null; renderNav(); go('admin'); return; }
  if (mode === 'restaurante') { s.role = 'usuario'; S.reg = { r: 'demo-asadero-nova', t: 1 }; toast('Vista de ejemplo: así ve Nova un restaurante.'); renderNav(); go('rest', 'demo-asadero-nova'); return; }
  s.role = 'cliente'; S.reg = null; toast('Vista de ejemplo: así ve Nova un cliente.'); renderNav(); go('dir');
}
document.addEventListener('click', function (e) { var p = e.target.closest('[data-preview]'); if (p) { e.preventDefault(); previewAs(p.getAttribute('data-preview')); } });
