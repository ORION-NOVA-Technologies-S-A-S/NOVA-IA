# Conectar Nova con Supabase (Fase 1)

1. **SQL Editor** → New query → pega `01_nova_fase1.sql` → Run. Debe terminar sin errores.
2. **Authentication → Providers → Email**: desactiva **Confirm email** (las cuentas usan usuario + contraseña, sin correo real) y guarda.
3. Abre la página, entra a **Crear cuenta** y crea tu usuario.
4. Vuelve al **SQL Editor** y ejecuta `02_hacer_admin.sql` (cambia el usuario si usaste otro). Cierra sesión y vuelve a ingresar: verás el panel de administración.
5. Los restaurantes piden ser asignados a su negocio desde la página; tú lo apruebas en **Panel → Solicitudes**.

Seguridad: la página solo usa la clave pública (`sb_publishable_…`). La seguridad real está en las reglas RLS de `01_nova_fase1.sql`: cada restaurante ve únicamente sus pedidos, el cliente solo los suyos, y la comisión y el estado inicial los fija el servidor. Nunca pongas la clave `secret`/`service_role` en este repositorio.
