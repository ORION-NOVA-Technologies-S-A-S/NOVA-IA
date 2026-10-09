-- Nova · Fase 2 · Domiciliarios propios de cada restaurante y seguimiento en mapa.
-- Solo ven el recorrido: el restaurante dueño del pedido y el cliente que lo pidió. Nadie más.
\set ON_ERROR_STOP on
create table core.couriers (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references core.restaurants(id),
  name text not null, phone text not null check (phone ~ '^\+573[0-9]{9}$'),
  active boolean not null default true, created_at timestamptz not null default now()
);
create table core.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references core.orders(id),
  courier_id uuid not null references core.couriers(id),
  status text not null default 'asignado' check (status in ('asignado','recogido','en-camino','entregado')),
  origin_lat double precision, origin_lng double precision,
  dest_lat double precision not null check (dest_lat between 0 and 13), dest_lng double precision not null check (dest_lng between -80 and -66),
  dest_label text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table core.courier_positions (
  id bigserial primary key, delivery_id uuid not null references core.deliveries(id) on delete cascade,
  lat double precision not null check (lat between 0 and 13), lng double precision not null check (lng between -80 and -66),
  recorded_at timestamptz not null default now()
);
create index on core.courier_positions (delivery_id, recorded_at desc);
create unique index one_active_delivery_per_courier on core.deliveries (courier_id) where status <> 'entregado';
alter table core.couriers owner to nova_owner; alter table core.deliveries owner to nova_owner; alter table core.courier_positions owner to nova_owner;
alter table core.couriers enable row level security; alter table core.deliveries enable row level security; alter table core.courier_positions enable row level security;
revoke all on core.couriers, core.deliveries, core.courier_positions from public, web_anon, restaurante, cliente, admin_nova, repartidor;
alter sequence core.courier_positions_id_seq owner to nova_owner;

create function core.claim_courier() returns uuid language sql stable as $$ select nullif(core.jwt() ->> 'courier_id', '')::uuid $$;
alter function core.claim_courier() owner to nova_owner;
grant execute on function core.claim_courier() to repartidor, restaurante, cliente;

-- El restaurante registra a SUS domiciliarios
create function api.registrar_repartidor(p_name text, p_phone text) returns uuid language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare id uuid;
begin
  if core.claim_restaurant() is null then raise exception 'Sesión de restaurante requerida.' using errcode = 'PT401'; end if;
  insert into core.couriers(restaurant_id, name, phone) values (core.claim_restaurant(), left(trim(p_name), 60), p_phone) returning core.couriers.id into id; return id;
exception when check_violation then raise exception 'El celular debe tener el formato +573XXXXXXXXX.' using errcode = 'PT400';
end $$;

create function api.mis_repartidores() returns table(id uuid, name text, phone text, active boolean) language sql stable security definer set search_path = core, pg_temp as $$
  select id, name, phone, active from core.couriers where restaurant_id = core.claim_restaurant() order by name $$;

-- El restaurante asigna un domiciliario a uno de sus pedidos y marca el destino (coordenadas del punto de entrega)
create function api.asignar_repartidor(p_order uuid, p_courier uuid, p_dest_lat double precision, p_dest_lng double precision, p_dest_label text default null, p_origin_lat double precision default null, p_origin_lng double precision default null) returns uuid
language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare id uuid;
begin
  if core.claim_restaurant() is null then raise exception 'Sesión de restaurante requerida.' using errcode = 'PT401'; end if;
  if not exists (select 1 from core.orders o where o.id = p_order and o.restaurant_id = core.claim_restaurant() and o.kind = 'food' and o.status in ('aceptado','preparando','en-camino')) then
    raise exception 'El pedido no existe, no es tuyo o aún no está listo para despacho.' using errcode = 'PT404'; end if;
  if not exists (select 1 from core.couriers c where c.id = p_courier and c.restaurant_id = core.claim_restaurant() and c.active) then
    raise exception 'Ese domiciliario no es de tu restaurante.' using errcode = 'PT404'; end if;
  insert into core.deliveries(order_id, courier_id, dest_lat, dest_lng, dest_label, origin_lat, origin_lng) values (p_order, p_courier, p_dest_lat, p_dest_lng, left(p_dest_label, 120), p_origin_lat, p_origin_lng) returning core.deliveries.id into id;
  return id;
exception when unique_violation then raise exception 'Ese pedido ya tiene domiciliario o el domiciliario ya tiene una entrega activa.' using errcode = 'PT409';
          when check_violation then raise exception 'Las coordenadas están fuera de Colombia.' using errcode = 'PT400';
end $$;

-- El domiciliario (JWT con courier_id) envía su ubicación desde el celular. Máximo 1 punto cada 3 s; se conservan los últimos 300.
create function api.reportar_posicion(p_lat double precision, p_lng double precision) returns void language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare d core.deliveries;
begin
  if core.claim_courier() is null then raise exception 'Sesión de domiciliario requerida.' using errcode = 'PT401'; end if;
  if p_lat is null or p_lng is null or p_lat not between 0 and 13 or p_lng not between -80 and -66 then raise exception 'Ubicación no válida.' using errcode = 'PT400'; end if;
  select * into d from core.deliveries where courier_id = core.claim_courier() and status <> 'entregado';
  if not found then return; end if;     -- sin entrega activa no se guarda nada (no se rastrea fuera de un pedido)
  if exists (select 1 from core.courier_positions where delivery_id = d.id and recorded_at > now() - interval '3 seconds') then return; end if;
  insert into core.courier_positions(delivery_id, lat, lng) values (d.id, p_lat, p_lng);
  delete from core.courier_positions where delivery_id = d.id and id < (select min(id) from (select id from core.courier_positions where delivery_id = d.id order by id desc limit 300) k);
exception when check_violation then raise exception 'Ubicación no válida.' using errcode = 'PT400';
end $$;

create function api.actualizar_entrega(p_estado text) returns jsonb language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare d core.deliveries; flow text[] := array['asignado','recogido','en-camino','entregado']; g numeric := 0;
begin
  if core.claim_courier() is null then raise exception 'Sesión de domiciliario requerida.' using errcode = 'PT401'; end if;
  select * into d from core.deliveries where courier_id = core.claim_courier() and status <> 'entregado' for update;
  if not found then raise exception 'No tienes una entrega activa.' using errcode = 'PT404'; end if;
  if array_position(flow, p_estado) is distinct from array_position(flow, d.status) + 1 then raise exception 'Cambio no permitido: % a %.', d.status, p_estado using errcode = 'PT409'; end if;
  update core.deliveries set status = p_estado, updated_at = now() where id = d.id;
  if p_estado = 'en-camino' then update core.orders set status = 'en-camino' where id = d.order_id and status in ('aceptado','preparando'); end if;
  if p_estado = 'entregado' then update core.orders set status = 'entregado' where id = d.order_id; g := core.procesar_pedido_completado(d.order_id, now()); end if;
  return jsonb_build_object('estado', p_estado, 'tokens_ganados_restaurante', g);
end $$;

-- Seguimiento: SOLO el restaurante del pedido o el cliente que lo pidió. Devuelve lo necesario para dibujar el mapa.
create function api.seguimiento(p_order uuid) returns jsonb language plpgsql stable security definer set search_path = core, pg_temp as $$
declare o core.orders; d core.deliveries; c core.couriers; last jsonb; ruta jsonb;
begin
  select * into o from core.orders where id = p_order and (restaurant_id = core.claim_restaurant() or customer_id = core.claim_sub());
  if not found then raise exception 'Pedido no encontrado.' using errcode = 'PT404'; end if;
  select * into d from core.deliveries where order_id = o.id;
  if not found then return jsonb_build_object('pedido', o.status, 'entrega', null); end if;
  select * into c from core.couriers where id = d.courier_id;
  select to_jsonb(p) into last from (select lat, lng, recorded_at from core.courier_positions where delivery_id = d.id order by id desc limit 1) p;
  select coalesce(jsonb_agg(jsonb_build_array(lat, lng) order by id), '[]') into ruta from (select id, lat, lng from core.courier_positions where delivery_id = d.id order by id desc limit 100) r;
  return jsonb_build_object('pedido', o.status, 'entrega', jsonb_build_object('estado', d.status,
    'repartidor', jsonb_build_object('nombre', c.name, 'telefono', c.phone),
    'origen', case when d.origin_lat is null then null else jsonb_build_array(d.origin_lat, d.origin_lng) end,
    'destino', jsonb_build_object('lat', d.dest_lat, 'lng', d.dest_lng, 'texto', d.dest_label),
    'ultima_posicion', last, 'ruta', ruta));
end $$;

alter function api.registrar_repartidor(text,text) owner to nova_owner; alter function api.mis_repartidores() owner to nova_owner;
alter function api.asignar_repartidor(uuid,uuid,double precision,double precision,text,double precision,double precision) owner to nova_owner;
alter function api.reportar_posicion(double precision,double precision) owner to nova_owner; alter function api.actualizar_entrega(text) owner to nova_owner; alter function api.seguimiento(uuid) owner to nova_owner;
revoke all on all functions in schema api from public;
grant usage on schema api to repartidor;
grant execute on function api.registrar_repartidor(text,text), api.mis_repartidores(), api.asignar_repartidor(uuid,uuid,double precision,double precision,text,double precision,double precision) to restaurante;
grant execute on function api.reportar_posicion(double precision,double precision), api.actualizar_entrega(text) to repartidor;
grant execute on function api.seguimiento(uuid) to restaurante, cliente;
grant execute on function api.obtener_wallet(), api.canjear(text), api.cambiar_estado_pedido(uuid, text) to restaurante;
grant execute on function api.crear_pedido(uuid, text, jsonb, integer, text) to cliente;
