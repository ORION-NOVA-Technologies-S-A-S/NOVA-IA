# Nova · base de datos (PostgreSQL + PostgREST)

Tokens de fidelización B2B, libro de cuenta por restaurante/hotel y privacidad por rol.

## Instalar
```
psql -d nova -f sql/01_schema.sql
psql -d nova -f sql/02_functions.sql
psql -d nova -f sql/03_api_rls.sql
psql -d nova -f sql/99_tests.sql      # sobre una base vacía; debe terminar sin "FALLA"
sql/98_concurrencia.sh                # dos sesiones a la vez: exactamente 2 tokens por 40 pedidos
```
Cambia la clave del rol `authenticator` en `01_schema.sql` antes de usarlo en serio.

## Reglas implementadas
- 1 token por cada 20 pedidos **completados** (contador acumulativo, nunca se reinicia). Cada pedido cuenta una sola vez.
- Cada token vence **90 días de calendario después del día (hora Bogotá) en que se ganó, a las 00:00 hora Bogotá** (`core.calcular_expiracion`). Ganado el 15 de marzo a las 14:30 → vence el 13 de junio a las 00:00. Vencido = perdido.
- Canje (uno a la vez, por restricción en la base): 50 tokens = 1 semana, 1.000 tokens = 1 mes sin la comisión de $200. La semana son 7 días y el mes 1 mes de calendario, contados desde el momento del canje.
- **Regla de consumo:** al canjear se gastan primero los tokens que vencen antes. Queda registrado en `token_consumption` qué tokens pagó cada canje.
- El libro `token_ledger` es solo de inserción (un trigger bloquea UPDATE y DELETE incluso para el dueño). `restaurant_accounts.tokens_balance` es solo caché y las pruebas verifican que siempre coincide con la suma del libro.
- Comisión por pedido: `core.fee_for()` devuelve $200, o $0 mientras haya un canje activo. La calcula la base, no el cliente.

## Privacidad
| Rol | Ve |
|---|---|
| `restaurante` (JWT con `restaurant_id`) | solo sus pedidos, su libro de cuenta, su wallet y sus canjes |
| `cliente` (JWT con `sub`) | solo sus propios pedidos |
| `admin_nova` | solo `api.liquidacion` (totales por negocio). No ve pedidos, teléfonos ni direcciones |
| `web_anon` | solo `api.directorio` (nombre y tipo) |

## API (PostgREST)
- `POST /rpc/obtener_wallet` · saldo, tokens por vencer con días restantes, progreso a 50/1.000, canje activo
- `POST /rpc/canjear` `{"tipo":"semana"|"mes"}`
- `GET /libro_cuenta?order=created_at.desc&limit=20&offset=0` · filtro por tipo: `&event_type=eq.earn`
- `GET /mis_pedidos` · `POST /rpc/cambiar_estado_pedido` `{"p_order":"…","p_estado":"aceptado"}` (al completarse suma al contador)
- `POST /rpc/crear_pedido` · `GET /liquidacion` (admin) · `GET /directorio`
Errores en español con código HTTP (400 saldo insuficiente, 409 canje activo, 404, 401).

## Tarea diaria de vencimientos (00:05 hora Bogotá = 05:05 UTC)
Con pg_cron: `select cron.schedule('vencimientos-nova', '5 5 * * *', 'select core.procesar_expiraciones()');`
Sin pg_cron: `5 5 * * * psql -d nova -c "select core.procesar_expiraciones()"`. Un candado asesor impide que corran dos a la vez (devuelve -1 si otra instancia ya la ejecuta). El saldo mostrado en la wallet ya excluye lo vencido aunque la tarea no haya corrido.

## Fase 2
Scripts `04_usuarios_recuperacion.sql`, `05_entregas.sql`, `06_pagos.sql`; pruebas `97_tests_fase2.sql`; servicio en `servicio/`; mapa en `mapa/`.
- `sql/reset.sh` recrea la base y carga todo (solo para pruebas). Crea además el usuario de conexión del servicio: `create role servicio_login login password '…' in role servicio;` y úsalo en `DATABASE_URL`.
- **Recuperar contraseña:** `POST /auth/recuperar` `{usuario}` y `POST /auth/restablecer` `{usuario, codigo, clave_nueva}`. El código (6 dígitos, vence a los 10 min, un solo uso, 5 intentos, 3 pedidos por hora) va por WhatsApp o SMS según lo elegido al crear la cuenta. La respuesta es la misma exista o no el usuario.
- **Pagos:** `POST /pagos/iniciar` (valor calculado por la base con la carta guardada) devuelve el enlace firmado del checkout; `POST /pagos/webhook` solo acepta eventos con firma válida y es idempotente. Cada pago aprobado crea el pedido y una fila en `payouts` con lo que Nova debe transferir al restaurante (total menos $200).
- **Domiciliarios y mapa:** cada restaurante registra y asigna a SUS domiciliarios. El celular del domiciliario envía su ubicación solo mientras tiene una entrega activa. Solo el restaurante del pedido y el cliente que lo pidió pueden consultar `rpc/seguimiento`. Componente: `mapa/seguimiento.js` (Leaflet).
- La cuenta de Nova (Nequi/banco) que recibe el dinero se configura en el panel de la pasarela como cuenta de liquidación; no se guarda en el código.
- Pruebas del servicio: `cd servicio && PGHOST=/tmp/pgw PGPORT=5433 node test.js`.

## Lo que falta (necesita decisiones o cuentas tuyas)
Pasarela PSE/Wompi (servicio con claves secretas), WhatsApp para recuperar contraseña, tablas de usuarios y repartidores, mapa y seguimiento. Ver el mensaje de entrega.
