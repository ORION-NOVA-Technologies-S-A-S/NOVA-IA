/* Mapa de seguimiento del pedido (dueño del restaurante o cliente). Usa Leaflet (https://leafletjs.com) cargado antes que este archivo.
   Uso:  Seguimiento.montar(document.getElementById('mapa'), { api: 'https://api.tudominio.com', token: JWT, pedido: 'uuid' });
   Lee POST {api}/rpc/seguimiento cada 5 s. PostgREST solo responde si el JWT es del restaurante del pedido o del cliente que lo pidió. */
(function (g) {
  'use strict';
  function el(t, c, x) { var e = document.createElement(t); if (c) e.className = c; if (x != null) e.textContent = x; return e; }
  var ESTADOS = { asignado: 'Asignado', recogido: 'Recogió el pedido', 'en-camino': 'En camino', entregado: 'Entregado' };
  function montar(box, o) {
    box.textContent = '';
    var info = el('div', 'seg-info'), mapa = el('div', 'seg-mapa'); mapa.style.cssText = 'height:360px;border-radius:14px;overflow:hidden';
    box.appendChild(info); box.appendChild(mapa);
    var map = L.map(mapa).setView([2.9273, -75.2819], 13);      // Neiva
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);   // para producción usa un proveedor de mapas con plan comercial
    var dest, rider, line, fitted = false, timer;
    function pintar(s) {
      info.textContent = '';
      if (!s.entrega) { info.appendChild(el('p', '', 'Pedido ' + s.pedido + '. Aún no tiene domiciliario asignado.')); return; }
      var e = s.entrega, r = e.repartidor;
      info.appendChild(el('p', '', 'Domiciliario: ' + r.nombre + ' · ' + r.telefono + ' · ' + (ESTADOS[e.estado] || e.estado)));
      var d = [e.destino.lat, e.destino.lng];
      if (!dest) dest = L.marker(d).addTo(map).bindTooltip(e.destino.texto || 'Destino'); else dest.setLatLng(d);
      var pts = (e.ruta || []).map(function (p) { return [p[0], p[1]]; });
      if (line) line.setLatLngs(pts); else line = L.polyline(pts, { color: '#3a7bff', weight: 4 }).addTo(map);
      if (e.ultima_posicion) {
        var p = [e.ultima_posicion.lat, e.ultima_posicion.lng];
        if (!rider) rider = L.circleMarker(p, { radius: 9, color: '#fff', fillColor: '#ff7a00', fillOpacity: 1 }).addTo(map).bindTooltip(r.nombre); else rider.setLatLng(p);
        if (!fitted) { map.fitBounds(L.latLngBounds([p, d]).pad(.3)); fitted = true; }
      } else if (!fitted) { map.setView(d, 15); }
      if (e.estado === 'entregado') clearInterval(timer);
    }
    function cargar() {
      fetch(o.api + '/rpc/seguimiento', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + o.token }, body: JSON.stringify({ p_order: o.pedido }) })
        .then(function (r) { return r.json(); }).then(function (j) { if (j && j.pedido) pintar(j); else info.textContent = (j && j.message) || 'No se pudo cargar el seguimiento.'; })
        .catch(function () { info.textContent = 'Sin conexión. Reintentando…'; });
    }
    cargar(); timer = setInterval(cargar, 5000);
    return { detener: function () { clearInterval(timer); map.remove(); } };
  }
  /* Celular del domiciliario: envía su ubicación mientras tiene una entrega activa (el servidor ignora lo demás). */
  function transmitir(o) {
    if (!navigator.geolocation) return null;
    return navigator.geolocation.watchPosition(function (p) {
      fetch(o.api + '/rpc/reportar_posicion', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + o.token }, body: JSON.stringify({ p_lat: p.coords.latitude, p_lng: p.coords.longitude }) }).catch(function () { });
    }, function () { }, { enableHighAccuracy: true, maximumAge: 4000 });
  }
  g.Seguimiento = { montar: montar, transmitir: transmitir };
})(window);
