# NOVA-IA

Nova (Orion Nova Technologies): asistente humanoide para restaurantes y hoteles de Neiva. Pedidos por chat, avatar animado con voz, hoteles por hora/noche/día, y panel de administración.

## Contenido
- `index.html` — la aplicación (una sola página; se publica con GitHub Pages).
- `supabase/` — base de datos y seguridad (RLS) para Supabase. Guía en `supabase/LEEME.md`.
- `src/` — código fuente y scripts que generan `index.html` (`python3 patch3.py && NOVA_OUT=../index.html python3 patch4.py`).
- `tests/` — pruebas de punta a punta contra un servidor de prueba con la misma seguridad.
- `nova-backend/` — diseño completo del servidor propio (tokens de fidelización, pagos Wompi, mensajes, mapa de repartidores) que se conecta en las siguientes fases.

## Estado
- **Conectado a Supabase:** cuentas reales (registro/ingreso), solicitudes de restaurante con aprobación de administración, pedidos por restaurante, comisión fijada por el servidor, panel de administración.
- **Simulado todavía:** pago PSE, avisos por WhatsApp/SMS (Twilio) y recuperación de contraseña. Se conectan en las fases siguientes.
- No hay contraseñas ni claves secretas en este repositorio; solo la clave pública de Supabase.
