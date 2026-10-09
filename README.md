# NOVA-IA

Nova (Orion Nova Technologies): asistente humanoide para restaurantes y hoteles de Neiva. Pedidos por chat, avatar animado con voz, hoteles por hora/noche/día, tokens de fidelización y panel de administración.

## Contenido
- `index.html` — la aplicación (una sola página, lista para GitHub Pages).
- `nova-backend/` — base de datos PostgreSQL + PostgREST, servicio Node (Wompi/PSE, WhatsApp/SMS) y mapa de repartidores. Ver `nova-backend/README.md`.

## Importante: qué funciona en esta copia
Esta copia publicada en GitHub Pages es una **demostración**. Se ve el diseño, el avatar con voz y el chat, pero **no tiene cuentas de usuario, pedidos guardados ni base de datos**: la versión publicada en Claude usa el almacenamiento propio de Claude, que no existe fuera de esa plataforma. El pago PSE y los avisos por WhatsApp/correo están simulados.

Para una versión realmente funcional hay que conectar `nova-backend` a un servidor real (PostgreSQL + PostgREST), contratar la pasarela de pagos (Wompi/PSE) y un proveedor de WhatsApp/SMS, y cargar los menús reales de los restaurantes.

No se incluye ninguna contraseña, clave ni secreto en este repositorio. Las claves van en variables de entorno (`nova-backend/servicio/.env.example`).
