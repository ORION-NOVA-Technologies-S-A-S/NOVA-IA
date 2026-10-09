-- Nova · Paso 4: cuentas y recuperación de clave, cartas con fuente, pagos y liquidación, repartidores y seguimiento.
\set ON_ERROR_STOP on
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select from pg_roles where rolname='servicio_nova') then create role servicio_nova nologin; end if;  -- el servicio Node (cobros, mensajes, login)
  if not exists (select from pg_roles where rolname='repartidor') then create role repartidor nologin; end if;
end $$;
grant servicio_nova, repartidor to authenticator;
alter role servicio_nova set timezone = 'America/Bogota'; alter role repartidor set timezone = 'America/Bogota';

-- ===== Cartas: solo con fuente pública y fecha. Sin fuente no se puede cargar. =====
create table core.menu_items (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references core.restaurants(id),
  category text not null, name text not null, description text,
  unit text check (unit in ('hora','noche','dia')),            -- solo hoteles: la cantidad del pedido son horas, noches o días
  price integer not null check (price > 0 and price <= 5000000),
  source_url text not null check (source_url ~ '^https://'),   -- de dónde salió el precio
  captured_on date not null, active boolean not null default true
);
create index on core.menu_items (restaurant_id) where active;

-- ===== Usuarios =====
create function core.password_ok(p_pw text, p_user text) returns boolean language sql immutable as $$
  select length(p_pw) between 10 and 64
    and ((p_pw ~ '[a-z]')::int + (p_pw ~ '[A-Z]')::int + (p_pw ~ '[0-9]')::int + (p_pw ~ '[^A-Za-z0-9]')::int) >= 3
    and position(lower(p_user) in lower(p_pw)) = 0
$$;
create table core.users (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username ~ '^[a-z0-9_.]{3,20}$'),
  role text not null check (role in ('cliente','restaurante','repartidor','admin_nova')),
  restaurant_id uuid references core.restaurants(id),
  courier_id uuid,
  phone text not null check (phone ~ '^\+[1-9][0-9]{7,14}$'),                 -- formato internacional: +573001234567
  recovery_channel text not null default 'whatsapp' check (recovery_channel in ('whatsapp','sms')),
  password_hash text not null,
  failed_attempts integer not null default 0, locked_until timestamptz,
  created_at timestamptz not null default now(),
  check ((role = 'restaurante') = (restaurant_id is not null))
);
create table core.password_resets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references core.users(id),
  token_hash text not null unique,                 -- se guarda el hash; el enlace con el token solo viaja por el mensaje
  expires_at timestamptz not null, used_at timestamptz, created_at timestamptz not null default now()
);

create function core.registrar_usuario(p_user text, p_pw text, p_role text, p_phone text, p_channel text, p_restaurant uuid default null) returns uuid language plpgsql as $$
declare id uuid;
begin
  if not core.password_ok(p_pw, p_user) then raise exception 'La contraseña debe tener entre 10 y 64 caracteres, tres tipos (minúscula, mayúscula, número, símbolo) y no incluir tu usuario.' using errcode = 'PT400'; end if;
  insert into core.users(username, role, restaurant_id, phone, recovery_channel, password_hash)
  values (lower(p_user), p_role, p_restaurant, p_phone, p_channel, crypt(p_pw, gen_salt('bf', 12))) returning core.users.id into id;
  return id;
exception when unique_violation then raise exception 'Ese usuario ya existe.' using errcode = 'PT409';
end $$;

-- Verifica usuario y clave con bloqueo de 5 minutos tras 5 intentos fallidos. Devuelve los claims del JWT o null.
create function core.verificar_login(p_user text, p_pw text, p_now timestamptz default now()) returns jsonb language plpgsql as $$
declare u core.users;
begin
  select * into u from core.users where username = lower(p_user) for update;
  if not found then perform crypt(p_pw, gen_salt('bf', 12)); return null; end if;           -- mismo costo: no revela si el usuario existe
  if u.locked_until is not null and u.locked_until > p_now then raise exception 'Cuenta bloqueada por intentos fallidos. Intenta de nuevo en unos minutos.' using errcode = 'PT423'; end if;
  if u.password_hash = crypt(p_pw, u.password_hash) then
    update core.users set failed_attempts = 0, locked_until = null where id = u.id;
    return jsonb_strip_nulls(jsonb_build_object('role', u.role, 'sub', u.id, 'restaurant_id', u.restaurant_id, 'courier_id', u.courier_id));
  end if;
  update core.users set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
                        locked_until = case when failed_attempts + 1 >= 5 then p_now + interval '5 minutes' end where id = u.id;
  return null;
end $$;

-- Recuperación: devuelve (celular, canal, token) SOLO si el usuario existe. El servicio envía el enlace por WhatsApp o SMS
-- según el canal que el usuario eligió al crear la cuenta. Máximo 3 solicitudes por hora. El enlace vence en 30 minutos y sirve una vez.
create function core.crear_recuperacion(p_user text, p_now timestamptz default now()) returns table(phone text, channel text, token text) language plpgsql as $$
declare u core.users; t text;
begin
  select * into u from core.users where username = lower(p_user);
  if not found then return; end if;
  if (select count(*) from core.password_resets where user_id = u.id and created_at > p_now - interval '1 hour') >= 3 then return; end if;
  update core.password_resets set used_at = p_now where user_id = u.id and used_at is null;
  t := encode(gen_random_bytes(32), 'hex');
  insert into core.password_resets(user_id, token_hash, expires_at, created_at) values (u.id, encode(digest(t, 'sha256'), 'hex'), p_now + interval '30 minutes', p_now);
  return query select u.phone, u.recovery_channel, t;
end $$;

create function core.restablecer_clave(p_token text, p_new text, p_now timestamptz default now()) returns boolean language plpgsql as $$
declare r core.password_resets; u core.users;
begin
  select * into r from core.password_resets where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') for update;
  if not found or r.used_at is not null or r.expires_at <= p_now then raise exception 'El enlace no es válido o ya venció. Pide uno nuevo.' using errcode = 'PT400'; end if;
  select * into u from core.users where id = r.user_id for update;
  if not core.password_ok(p_new, u.username) then raise exception 'La contraseña debe tener entre 10 y 64 caracteres, tres tipos (minúscula, mayúscula, número, símbolo) y no incluir tu usuario.' using errcode = 'PT400'; end if;
  update core.users set password_hash = crypt(p_new, gen_salt('bf', 12)), failed_attempts = 0, locked_until = null where id = u.id;
  update core.password_resets set used_at = p_now where user_id = u.id and used_at is null;
  return true;
end $$;

-- ===== Pagos, comisión y liquidación =====
alter table core.orders add column dest_lat numeric(9,6), add column dest_lng numeric(9,6), add column dest_address text;
create table core.payments (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  customer_id uuid not null, restaurant_id uuid not null references core.restaurants(id),
  kind text not null default 'food' check (kind in ('food','hotel')),
  items jsonb not null, total integer not null check (total > 0), dest jsonb,
  status text not null default 'pendiente' check (status in ('pendiente','aprobado','rechazado','error')),
  gateway_tx text, order_id uuid references core.orders(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
-- Lo que Nova debe entregar a cada negocio (total menos la comisión de $200). Se marca pagado cuando se dispersa.
create table core.payouts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references core.orders(id), restaurant_id uuid not null references core.restaurants(id),
  amount integer not null check (amount >= 0), status text not null default 'pendiente' check (status in ('pendiente','pagado')),
  paid_ref text, created_at timestamptz not null default now(), paid_at timestamptz
);

-- El total sale de la carta en la base de datos; el cliente solo manda ids y cantidades.
create function core.iniciar_pago(p_customer uuid, p_restaurant uuid, p_items jsonb, p_dest jsonb default null) returns jsonb language plpgsql as $$
declare it jsonb; m core.menu_items; tot integer := 0; snap jsonb := '[]'; ref text; q integer; kind text := 'food'; pid uuid;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then raise exception 'El pedido está vacío.' using errcode = 'PT400'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it ->> 'q')::integer;
    select * into m from core.menu_items where id = (it ->> 'id')::uuid and restaurant_id = p_restaurant and active;
    if not found or q is null or q < 1 or q > 99 then raise exception 'Hay un producto que ya no está disponible. Revisa el pedido.' using errcode = 'PT400'; end if;
    if m.unit is not null then kind := 'hotel'; end if;
    tot := tot + m.price * q;
    snap := snap || jsonb_build_object('n', m.name || coalesce(' (' || m.unit || ')', ''), 'q', q, 'p', m.price, 'u', coalesce(m.unit, ''));
  end loop;
  ref := 'NOVA-' || upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 14));
  insert into core.payments(reference, customer_id, restaurant_id, kind, items, total, dest) values (ref, p_customer, p_restaurant, kind, snap, tot, p_dest) returning id into pid;
  return jsonb_build_object('reference', ref, 'total', tot, 'amount_in_cents', tot::bigint * 100);
end $$;

-- Confirmación de la pasarela (idempotente). Crea el pedido, calcula la comisión y deja registrado lo que se debe al negocio.
create function core.confirmar_pago(p_reference text, p_gateway_tx text, p_status text, p_amount_cents bigint, p_now timestamptz default now()) returns uuid language plpgsql as $$
declare p core.payments; oid uuid; fee integer;
begin
  select * into p from core.payments where reference = p_reference for update;
  if not found then raise exception 'Referencia de pago desconocida.' using errcode = 'PT404'; end if;
  if p.status = 'aprobado' then return p.order_id; end if;
  if p_status <> 'APPROVED' then
    update core.payments set status = case when p_status in ('DECLINED','VOIDED') then 'rechazado' else 'error' end, gateway_tx = p_gateway_tx, updated_at = p_now where id = p.id; return null;
  end if;
  if p_amount_cents <> p.total::bigint * 100 then
    update core.payments set status = 'error', gateway_tx = p_gateway_tx, updated_at = p_now where id = p.id;
    raise exception 'El valor pagado no coincide con el pedido.' using errcode = 'PT409';
  end if;
  fee := core.fee_for(p.restaurant_id, p.total, p_now);
  insert into core.orders(restaurant_id, customer_id, kind, items, total, fee, payment_ref, created_at, dest_lat, dest_lng, dest_address)
  values (p.restaurant_id, p.customer_id, p.kind, p.items, p.total, fee, p.reference, p_now, (p.dest ->> 'lat')::numeric, (p.dest ->> 'lng')::numeric, left(p.dest ->> 'address', 120)) returning id into oid;
  insert into core.payouts(order_id, restaurant_id, amount, created_at) values (oid, p.restaurant_id, p.total - fee, p_now);
  update core.payments set status = 'aprobado', gateway_tx = p_gateway_tx, order_id = oid, updated_at = p_now where id = p.id;
  return oid;
end $$;

-- ===== Repartidores del restaurante y seguimiento =====
create table core.couriers (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references core.restaurants(id), name text not null, phone text, active boolean not null default true
);
alter table core.users add constraint users_courier_fk foreign key (courier_id) references core.couriers(id);
alter table core.users add constraint users_courier_role check ((role = 'repartidor') = (courier_id is not null));
create table core.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references core.orders(id), courier_id uuid not null references core.couriers(id),
  status text not null default 'asignado' check (status in ('asignado','en-camino','entregado')),
  created_at timestamptz not null default now(), started_at timestamptz, ended_at timestamptz
);
create table core.courier_positions (
  id bigserial primary key, delivery_id uuid not null references core.deliveries(id),
  lat numeric(9,6) not null check (lat between -5 and 14), lng numeric(9,6) not null check (lng between -80 and -66),   -- Colombia
  recorded_at timestamptz not null default now()
);
create index on core.courier_positions (delivery_id, recorded_at desc);

do $$ declare t record; begin
  for t in select tablename from pg_tables where schemaname = 'core' and tableowner <> 'nova_owner' loop execute format('alter table core.%I owner to nova_owner', t.tablename); end loop;
  for t in select sequencename from pg_sequences where schemaname = 'core' loop execute format('alter sequence core.%I owner to nova_owner', t.sequencename); end loop;
end $$;
alter table core.menu_items enable row level security; alter table core.users enable row level security; alter table core.password_resets enable row level security;
alter table core.payments enable row level security; alter table core.payouts enable row level security;
alter table core.couriers enable row level security; alter table core.deliveries enable row level security; alter table core.courier_positions enable row level security;

create policy carta_publica on core.menu_items for select to web_anon, cliente, restaurante using (active);
create policy repartidores_propios on core.couriers for all to restaurante using (restaurant_id = core.claim_restaurant()) with check (restaurant_id = core.claim_restaurant());
create policy pagos_propios on core.payouts for select to restaurante using (restaurant_id = core.claim_restaurant());
grant select on core.menu_items to web_anon, cliente, restaurante;
grant select, insert, update on core.couriers to restaurante;
grant select on core.payouts to restaurante;
grant select on core.deliveries to restaurante;  create policy entregas_propias on core.deliveries for select to restaurante using (exists (select 1 from core.orders o where o.id = order_id and o.restaurant_id = core.claim_restaurant()));

-- ===== Funciones de cada rol =====
-- (nova_owner es el dueño; el servicio llama estas funciones con un JWT de rol servicio_nova)
create function api.svc_iniciar_pago(p_customer uuid, p_restaurant uuid, p_items jsonb, p_dest jsonb default null) returns jsonb language sql volatile security definer set search_path = core, pg_temp as $$ select core.iniciar_pago(p_customer, p_restaurant, p_items, p_dest) $$;
create function api.svc_confirmar_pago(p_reference text, p_gateway_tx text, p_status text, p_amount_cents bigint) returns uuid language sql volatile security definer set search_path = core, pg_temp as $$ select core.confirmar_pago(p_reference, p_gateway_tx, p_status, p_amount_cents) $$;
create function api.svc_verificar_login(p_user text, p_pw text) returns jsonb language sql volatile security definer set search_path = core, pg_temp as $$ select core.verificar_login(p_user, p_pw) $$;
create function api.svc_registrar_usuario(p_user text, p_pw text, p_role text, p_phone text, p_channel text, p_restaurant uuid default null) returns uuid language sql volatile security definer set search_path = core, pg_temp as $$ select core.registrar_usuario(p_user, p_pw, p_role, p_phone, p_channel, p_restaurant) $$;
create function api.svc_crear_recuperacion(p_user text) returns table(phone text, channel text, token text) language sql volatile security definer set search_path = core, pg_temp as $$ select * from core.crear_recuperacion(p_user) $$;
-- Público: el enlace que llegó por WhatsApp o SMS trae el token.
create function api.restablecer_clave(token text, nueva text) returns boolean language sql volatile security definer set search_path = core, pg_temp as $$ select core.restablecer_clave(token, nueva) $$;

-- El restaurante asigna uno de SUS repartidores a uno de SUS pedidos.
create function api.asignar_repartidor(p_order uuid, p_courier uuid) returns uuid language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare id uuid; o core.orders;
begin
  if core.claim_restaurant() is null then raise exception 'Sesión de restaurante requerida.' using errcode = 'PT401'; end if;
  select * into o from core.orders where core.orders.id = p_order and restaurant_id = core.claim_restaurant();
  if not found or o.kind <> 'food' or o.status not in ('aceptado','preparando','en-camino') then raise exception 'Este pedido no se puede asignar a un repartidor ahora.' using errcode = 'PT409'; end if;
  if not exists (select 1 from core.couriers c where c.id = p_courier and c.restaurant_id = o.restaurant_id and c.active) then raise exception 'Ese repartidor no pertenece a tu restaurante.' using errcode = 'PT404'; end if;
  insert into core.deliveries(order_id, courier_id) values (p_order, p_courier)
    on conflict (order_id) do update set courier_id = excluded.courier_id where core.deliveries.status = 'asignado' returning core.deliveries.id into id;
  if id is null then raise exception 'El pedido ya salió con otro repartidor.' using errcode = 'PT409'; end if;
  return id;
end $$;
create function api.iniciar_entrega() returns jsonb language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare d core.deliveries; cid uuid := nullif(core.jwt() ->> 'courier_id', '')::uuid;
begin
  if cid is null then raise exception 'Sesión de repartidor requerida.' using errcode = 'PT401'; end if;
  select * into d from core.deliveries where courier_id = cid and status = 'asignado' order by created_at limit 1 for update;
  if not found then raise exception 'No tienes pedidos asignados.' using errcode = 'PT404'; end if;
  update core.deliveries set status = 'en-camino', started_at = now() where id = d.id;
  return jsonb_build_object('delivery_id', d.id, 'order_id', d.order_id);
end $$;
-- El celular del repartidor manda su ubicación cada pocos segundos. Se ignora si pasó menos de 2 s desde la anterior.
create function api.reportar_posicion(lat numeric, lng numeric) returns void language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare d core.deliveries; cid uuid := nullif(core.jwt() ->> 'courier_id', '')::uuid; last timestamptz;
begin
  if cid is null then raise exception 'Sesión de repartidor requerida.' using errcode = 'PT401'; end if;
  select * into d from core.deliveries where courier_id = cid and status = 'en-camino' order by started_at desc limit 1;
  if not found then return; end if;
  select max(recorded_at) into last from core.courier_positions where delivery_id = d.id;
  if last is not null and last > now() - interval '2 seconds' then return; end if;
  insert into core.courier_positions(delivery_id, lat, lng) values (d.id, lat, lng);
end $$;
-- Mapa: solo el restaurante dueño del pedido y el cliente que lo hizo, y solo mientras va en camino. Sin celular del repartidor para el cliente.
create function api.seguimiento(p_order uuid) returns jsonb language plpgsql stable security definer set search_path = core, pg_temp as $$
declare o core.orders; d core.deliveries; c core.couriers; pts jsonb; own boolean;
begin
  select * into o from core.orders where core.orders.id = p_order;
  own := found and (o.restaurant_id = core.claim_restaurant() or o.customer_id = core.claim_sub());
  if not own then raise exception 'Pedido no encontrado.' using errcode = 'PT404'; end if;
  select * into d from core.deliveries where order_id = p_order;
  if not found then return jsonb_build_object('estado', 'sin_repartidor'); end if;
  select * into c from core.couriers where id = d.courier_id;
  if d.status <> 'en-camino' then return jsonb_build_object('estado', d.status, 'repartidor', c.name); end if;
  select coalesce(jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'at', recorded_at) order by recorded_at), '[]') into pts
    from (select * from core.courier_positions where delivery_id = d.id order by recorded_at desc limit 30) x;
  return jsonb_build_object('estado', d.status, 'repartidor', c.name, 'destino', jsonb_build_object('lat', o.dest_lat, 'lng', o.dest_lng, 'direccion', o.dest_address),
    'posicion', case when jsonb_array_length(pts) > 0 then pts -> (jsonb_array_length(pts) - 1) end, 'rastro', pts);
end $$;
create function core.purgar_posiciones(p_now timestamptz default now()) returns integer language plpgsql as $$
declare n integer;
begin
  delete from core.courier_positions p using core.deliveries d where p.delivery_id = d.id and d.status = 'entregado' and d.ended_at < p_now - interval '24 hours';
  get diagnostics n = row_count; return n;
end $$;

-- Al entregarse el pedido se cierra la entrega. (Reemplaza la función del paso 3.)
create or replace function api.cambiar_estado_pedido(p_order uuid, p_estado text) returns jsonb language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare o core.orders; flow text[]; i int; j int; ganado numeric := 0;
begin
  if core.claim_restaurant() is null then raise exception 'Sesión de restaurante requerida.' using errcode = 'PT401'; end if;
  select * into o from core.orders where id = p_order and restaurant_id = core.claim_restaurant() for update;
  if not found then raise exception 'Pedido no encontrado.' using errcode = 'PT404'; end if;
  flow := case o.kind when 'hotel' then array['nuevo','confirmada','hospedado','finalizada'] else array['nuevo','aceptado','preparando','en-camino','entregado'] end;
  i := array_position(flow, o.status); j := array_position(flow, p_estado);
  if p_estado = 'cancelado' then
    if o.status not in ('nuevo','aceptado','confirmada') then raise exception 'Este pedido ya no se puede cancelar.' using errcode = 'PT409'; end if;
  elsif j is null or i is null or j <> i + 1 then raise exception 'Cambio de estado no permitido: % a %.', o.status, p_estado using errcode = 'PT409'; end if;
  update core.orders set status = p_estado where id = p_order;
  if p_estado = 'entregado' then update core.deliveries set status = 'entregado', ended_at = now() where order_id = p_order; end if;
  if p_estado in ('entregado','finalizada') then ganado := core.procesar_pedido_completado(p_order, now()); end if;
  return jsonb_build_object('estado', p_estado, 'tokens_ganados', ganado);
end $$;

create or replace view api.mis_pedidos with (security_invoker = true) as
  select id, restaurant_id, kind, items, total, fee, net, status, payment_ref, created_at, completed_at, dest_lat, dest_lng, dest_address from core.orders;
create view api.carta with (security_invoker = true) as select id, restaurant_id, category, name, description, unit, price, source_url, captured_on from core.menu_items;
create view api.mis_repartidores with (security_invoker = true) as select id, name, phone, active from core.couriers;
create view api.mis_liquidaciones with (security_invoker = true) as select order_id, amount, status, paid_ref, created_at, paid_at from core.payouts;
-- Administración: lo que debe entregar a cada negocio (solo totales).
create view api.por_pagar as select r.id as restaurant_id, r.name, count(*) as pedidos, sum(p.amount) as monto from core.payouts p join core.restaurants r on r.id = p.restaurant_id where p.status = 'pendiente' group by r.id, r.name;
do $$ declare v text; begin foreach v in array array['carta','mis_repartidores','mis_liquidaciones','por_pagar'] loop execute format('alter view api.%I owner to nova_owner', v); end loop; end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('core','api') and pg_get_userbyid(p.proowner) <> 'nova_owner' loop
    execute format('alter function %s owner to nova_owner', f.sig);
  end loop;
end $$;
revoke all on all functions in schema api from public; revoke all on all functions in schema core from public;
grant execute on function core.jwt(), core.claim_restaurant(), core.claim_sub(), core.setting(text) to restaurante, cliente, admin_nova, web_anon, repartidor, servicio_nova;
grant usage on schema api to servicio_nova, repartidor; grant usage on schema core to servicio_nova, repartidor;
grant execute on function api.svc_iniciar_pago(uuid, uuid, jsonb, jsonb), api.svc_confirmar_pago(text, text, text, bigint), api.svc_verificar_login(text, text),
  api.svc_registrar_usuario(text, text, text, text, text, uuid), api.svc_crear_recuperacion(text) to servicio_nova;
grant execute on function api.restablecer_clave(text, text) to web_anon;
grant execute on function api.asignar_repartidor(uuid, uuid), api.cambiar_estado_pedido(uuid, text), api.obtener_wallet(), api.canjear(text) to restaurante;
grant execute on function api.iniciar_entrega(), api.reportar_posicion(numeric, numeric) to repartidor;
grant execute on function api.seguimiento(uuid) to restaurante, cliente;
grant select on api.carta to web_anon, cliente, restaurante; grant select on api.mis_repartidores, api.mis_liquidaciones to restaurante;
grant select on api.mis_pedidos to restaurante, cliente; grant select on api.por_pagar to admin_nova;
grant select on api.directorio to web_anon, cliente, restaurante, admin_nova, repartidor;
-- Los pedidos ya solo nacen de un pago confirmado.
drop function if exists api.crear_pedido(uuid, text, jsonb, integer, text);
