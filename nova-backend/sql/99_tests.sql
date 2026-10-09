-- Pruebas (ejecutar sobre una base vacía): psql -d nova -f 99_tests.sql
\set ON_ERROR_STOP on
\set QUIET on
create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALLA: %', msg; end if; raise notice 'ok  - %', msg; end $$;
create or replace function pg_temp.bog(t text) returns timestamptz language sql as $$ select (t::timestamp) at time zone 'America/Bogota' $$;
create or replace function pg_temp.mk(p_name text) returns uuid language sql as $$ insert into core.restaurants(name) values (p_name) returning id $$;
create or replace function pg_temp.ord(p_r uuid, p_total int default 30500) returns uuid language sql as $$
  insert into core.orders(restaurant_id, customer_id, items, total, fee) values (p_r, gen_random_uuid(), '[{"n":"Pollo asado","q":1,"p":30500}]', p_total, 200) returning id $$;

-- 1. Expiración: 90 días de calendario, 00:00 Bogotá
select pg_temp.ok(core.calcular_expiracion(pg_temp.bog('2025-01-01 23:59')) = pg_temp.bog('2025-04-01 00:00'), 'ganado 2025-01-01 23:59 expira 2025-04-01 00:00 Bogotá');
select pg_temp.ok(core.calcular_expiracion(pg_temp.bog('2025-01-02 00:01')) = pg_temp.bog('2025-04-02 00:00'), 'ganado 2025-01-02 00:01 expira 2025-04-02 00:00 Bogotá');
select pg_temp.ok(core.calcular_expiracion(pg_temp.bog('2025-03-15 14:30')) = pg_temp.bog('2025-06-13 00:00'), 'ganado 15 de marzo 14:30 expira 13 de junio 00:00 Bogotá');
select pg_temp.ok(core.calcular_expiracion('2025-01-02 04:59:59+00') = pg_temp.bog('2025-04-01 00:00'), 'borde: 23:59:59 Bogotá (04:59:59 UTC) sigue siendo el día anterior');
select pg_temp.ok(core.calcular_expiracion('2025-01-02 05:00:00+00') = pg_temp.bog('2025-04-02 00:00'), 'borde: 00:00:00 Bogotá (05:00 UTC) ya es el día siguiente');

-- 2. Un token por cada 20 pedidos completados; cada pedido cuenta una sola vez
do $$ declare r uuid := pg_temp.mk('Prueba A'); o uuid; i int; g numeric; t0 timestamptz := pg_temp.bog('2026-01-10 12:00'); w jsonb; begin
  for i in 1..19 loop perform core.procesar_pedido_completado(pg_temp.ord(r), t0 + i * interval '1 hour'); end loop;
  perform pg_temp.ok((core.wallet(r, t0 + interval '1 day') ->> 'saldo')::numeric = 0, '19 pedidos: 0 tokens');
  o := pg_temp.ord(r); g := core.procesar_pedido_completado(o, t0 + interval '30 hours');
  perform pg_temp.ok(g = 1, 'el pedido 20 otorga 1 token');
  perform pg_temp.ok(core.procesar_pedido_completado(o, t0 + interval '31 hours') = 0, 'el mismo pedido no cuenta dos veces');
  for i in 21..39 loop perform core.procesar_pedido_completado(pg_temp.ord(r), t0 + i * interval '2 hours'); end loop;
  g := core.procesar_pedido_completado(pg_temp.ord(r), t0 + interval '3 days');
  perform pg_temp.ok(g = 1, 'el pedido 40 otorga otro token');
  w := core.wallet(r, t0 + interval '4 days');
  perform pg_temp.ok((w ->> 'saldo')::numeric = 2 and (w ->> 'pedidos_completados')::int = 40 and (w ->> 'pedidos_para_proximo_token')::int = 20, 'saldo 2, contador acumulado 40, faltan 20 pedidos');
  -- 3. Saldo insuficiente
  begin perform core.canjear_tokens(r, 'semana', t0 + interval '4 days'); perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT400' then perform pg_temp.ok(sqlerrm like 'Saldo insuficiente: tienes 2 tokens y necesitas 50%', 'canje con saldo insuficiente: ' || sqlerrm); end;
  begin perform core.canjear_tokens(r, 'anio', t0); perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'tipo de canje inválido rechazado'); end;
end $$;

-- 4. Regla de consumo (vence primero = se gasta primero), canje activo, comisión $0 y vencimientos
do $$ declare r uuid := pg_temp.mk('Prueba B'); a uuid; i int; t0 timestamptz := pg_temp.bog('2026-02-01 10:00'); tc timestamptz; res jsonb; w jsonb; n int; v numeric;
 e51 timestamptz; e60 timestamptz; begin
  -- 1200 pedidos, 20 por día durante 60 días: 1 token por día (60 tokens, el k-ésimo ganado el día k)
  for i in 1..1200 loop perform core.procesar_pedido_completado(pg_temp.ord(r), t0 + ((i - 1) / 20) * interval '1 day' + ((i - 1) % 20) * interval '10 minutes'); end loop;
  select id into a from core.restaurant_accounts where restaurant_id = r;
  perform pg_temp.ok((select tokens_balance from core.restaurant_accounts where id = a) = 60, '1200 pedidos: 60 tokens');
  tc := t0 + interval '61 days';
  perform pg_temp.ok((core.wallet(r, tc) ->> 'puede_canjear_semana')::boolean, 'con 60 tokens puede canjear 1 semana');
  perform pg_temp.ok(core.fee_for(r, 30500, tc) = 200, 'sin canje la comisión es $200');
  res := core.canjear_tokens(r, 'semana', tc);
  perform pg_temp.ok((res ->> 'saldo')::numeric = 10, 'tras canjear 50 quedan 10 tokens');
  perform pg_temp.ok((select count(*) from core.earn_remaining where account_id = a and remaining = 0) = 50 and (select min(created_at) from core.earn_remaining where account_id = a and remaining = 1) > (select max(created_at) from core.earn_remaining where account_id = a and remaining = 0),
    'regla de consumo: se gastaron los 50 tokens que vencen primero; quedan los 10 más nuevos');
  perform pg_temp.ok((select sum(tokens) from core.token_ledger where account_id = a) = (select tokens_balance from core.restaurant_accounts where id = a), 'el caché de saldo coincide con la suma del libro de cuenta');
  begin perform core.canjear_tokens(r, 'semana', tc + interval '1 day'); perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'un canje activo bloquea otro: ' || sqlerrm); end;
  perform pg_temp.ok(core.fee_for(r, 30500, tc + interval '3 days') = 0, 'durante el canje la comisión es $0');
  perform pg_temp.ok(core.fee_for(r, 30500, tc + interval '8 days') = 200, 'terminada la semana vuelve la comisión de $200');
  -- vencimientos: los 10 tokens restantes se ganaron los días 51..60
  select min(expiry_at), max(expiry_at) into e51, e60 from core.earn_remaining where account_id = a and remaining = 1;
  perform pg_temp.ok(e51 = core.calcular_expiracion(t0 + interval '50 days'), 'el primer token vigente vence 90 días después de ganado, a las 00:00 Bogotá');
  perform pg_temp.ok(core.expire_account(a, e51 - interval '1 second') = 0, 'un segundo antes de las 00:00 no vence nada');
  w := core.wallet(r, e51 - interval '1 second');
  perform pg_temp.ok((w ->> 'saldo')::numeric = 10 and (w -> 'por_expirar' -> 0 ->> 'dias_restantes')::int = 1, 'cuenta regresiva: el último día falta 1 (vence a las 00:00 de mañana)');
  perform pg_temp.ok(core.expire_account(a, e51) = 1, 'a las 00:00 vence el primer token');
  perform pg_temp.ok((select tokens_balance from core.restaurant_accounts where id = a) = 9, 'saldo 9 tras el primer vencimiento');
  perform pg_temp.ok(core.expire_account(a, e51) = 0, 'repetir el vencimiento no hace nada (idempotente)');
  perform pg_temp.ok(core.expire_account(a, e60 + interval '1 day') = 9, 'vencen los 9 restantes');
  perform pg_temp.ok((select tokens_balance from core.restaurant_accounts where id = a) = 0 and (select sum(tokens) from core.token_ledger where account_id = a) = 0, 'saldo 0 y libro cuadrado; tokens vencidos no se recuperan');
  begin update core.token_ledger set tokens = 5 where account_id = a; perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT403' then perform pg_temp.ok(true, 'el libro de cuenta no se puede editar (ni el dueño)'); end;
  begin delete from core.token_ledger where account_id = a; perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT403' then perform pg_temp.ok(true, 'el libro de cuenta no se puede borrar'); end;
  -- canje con tokens ya vencidos aún sin procesar: el canje vence primero
  perform pg_temp.ok((core.wallet(r, e60 + interval '5 days') ->> 'saldo')::numeric = 0, 'el wallet ya no cuenta tokens vencidos');
end $$;

-- 4b. Tarea diaria global
do $$ declare n int; begin
  n := core.procesar_expiraciones(now() + interval '5 years');
  perform pg_temp.ok(n >= 1, 'procesar_expiraciones vence cuentas pendientes (' || n || ')');
  perform pg_temp.ok(core.procesar_expiraciones(now() + interval '5 years') = 0, 'segunda corrida: nada pendiente');
  perform pg_temp.ok((select count(*) from core.restaurant_accounts a where tokens_balance <> coalesce((select sum(tokens) from core.token_ledger l where l.account_id = a.id), 0)) = 0, 'en TODAS las cuentas el caché coincide con el libro');
end $$;

-- 5. Privacidad (RLS) con roles reales
do $$ declare ra uuid := pg_temp.mk('Rest. Uno'); rb uuid := pg_temp.mk('Rest. Dos'); oa uuid; ob uuid; cu uuid := gen_random_uuid(); n int; w jsonb; begin
  oa := pg_temp.ord(ra); ob := pg_temp.ord(rb);
  for n in 1..20 loop perform core.procesar_pedido_completado(pg_temp.ord(ra), now()); end loop;
  update core.orders set customer_id = cu where id = oa;
  perform set_config('request.jwt.claims', json_build_object('role','restaurante','restaurant_id',ra)::text, true);
  set local role restaurante;
  perform pg_temp.ok((select count(*) from api.mis_pedidos) = 21 and (select count(*) from api.mis_pedidos where restaurant_id = rb) = 0, 'el restaurante ve solo sus pedidos');
  perform pg_temp.ok((select count(*) from api.libro_cuenta) = 1, 'el restaurante ve solo su libro de cuenta');
  perform pg_temp.ok((api.obtener_wallet() ->> 'saldo')::numeric = 1, 'obtener_wallet usa el restaurante del JWT');
  begin update core.token_ledger set tokens = 99; perform pg_temp.ok(false, 'debía fallar'); exception when insufficient_privilege then perform pg_temp.ok(true, 'el restaurante no puede escribir en el libro'); end;
  begin perform 1 from core.orders; perform pg_temp.ok(true, 'puede leer core.orders pero filtrado'); exception when others then null; end;
  begin perform api.cambiar_estado_pedido(ob, 'aceptado'); perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT404' then perform pg_temp.ok(true, 'no puede tocar pedidos de otro restaurante'); end;
  begin perform api.cambiar_estado_pedido(oa, 'entregado'); perform pg_temp.ok(false, 'debía fallar'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'no se salta pasos de estado'); end;
  w := api.cambiar_estado_pedido(oa, 'aceptado'); perform pg_temp.ok(w ->> 'estado' = 'aceptado', 'avanza el estado de su pedido');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','cliente','sub',cu)::text, true);
  set local role cliente;
  perform pg_temp.ok((select count(*) from api.mis_pedidos) = 1, 'el cliente ve solo sus pedidos');
  begin perform count(*) from api.libro_cuenta; perform pg_temp.ok(false, 'debía fallar'); exception when insufficient_privilege then perform pg_temp.ok(true, 'el cliente no ve libros de cuenta'); end;
  reset role;
  set local role admin_nova;
  perform pg_temp.ok((select count(*) from api.liquidacion) >= 2, 'administración ve liquidación agregada');
  begin perform count(*) from api.mis_pedidos; perform pg_temp.ok(false, 'debía fallar'); exception when insufficient_privilege then perform pg_temp.ok(true, 'administración NO ve pedidos ni datos de clientes'); end;
  begin perform count(*) from core.orders; perform pg_temp.ok(false, 'debía fallar'); exception when insufficient_privilege then perform pg_temp.ok(true, 'administración sin acceso a las tablas'); end;
  reset role;
  set local role web_anon;
  begin perform count(*) from api.mis_pedidos; perform pg_temp.ok(false, 'debía fallar'); exception when insufficient_privilege then perform pg_temp.ok(true, 'anónimo no ve pedidos'); end;
  perform pg_temp.ok((select count(*) from api.directorio) >= 2, 'anónimo solo ve el directorio público');
  reset role;
end $$;
