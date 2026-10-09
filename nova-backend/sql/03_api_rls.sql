-- Nova · Paso 3: API de PostgREST + privacidad (RLS). Solo el personal del restaurante registrado ve SU información.
\set ON_ERROR_STOP on

-- Datos del JWT (los pone PostgREST en la sesión): { "role":"restaurante", "restaurant_id":"<uuid>" } o { "role":"cliente", "sub":"<uuid>" }
create function core.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function core.claim_restaurant() returns uuid language sql stable as $$ select nullif(core.jwt() ->> 'restaurant_id', '')::uuid $$;
create function core.claim_sub() returns uuid language sql stable as $$ select nullif(core.jwt() ->> 'sub', '')::uuid $$;

alter table core.restaurants enable row level security;
alter table core.restaurant_accounts enable row level security;
alter table core.orders enable row level security;
alter table core.token_ledger enable row level security;
alter table core.token_consumption enable row level security;
alter table core.active_benefits enable row level security;
-- (nova_owner es dueño de las tablas y las funciones SECURITY DEFINER, por eso no queda sujeto a RLS)

create policy acct_propia on core.restaurant_accounts for select to restaurante using (restaurant_id = core.claim_restaurant());
create policy ledger_propio on core.token_ledger for select to restaurante using (account_id in (select id from core.restaurant_accounts));
create policy benef_propio on core.active_benefits for select to restaurante using (account_id in (select id from core.restaurant_accounts));
create policy pedidos_restaurante on core.orders for select to restaurante using (restaurant_id = core.claim_restaurant());
create policy pedidos_cliente on core.orders for select to cliente using (customer_id = core.claim_sub());

revoke all on all tables in schema core from public, web_anon, restaurante, cliente, admin_nova;
grant usage on schema core to restaurante, cliente;
grant select on core.restaurant_accounts, core.token_ledger, core.active_benefits, core.orders to restaurante;
grant select on core.orders to cliente;
grant execute on function core.jwt(), core.claim_restaurant(), core.claim_sub() to restaurante, cliente, admin_nova, web_anon;
grant execute on function core.setting(text) to restaurante, cliente;

-- ===== Vistas de la API (con los permisos de quien consulta, así RLS sí aplica) =====
create view api.libro_cuenta with (security_invoker = true) as
  select id, event_type, tokens, balance_after, expiry_at, order_id, source_ledger_id, note, created_at from core.token_ledger;
create view api.mis_pedidos with (security_invoker = true) as
  select id, restaurant_id, kind, items, total, fee, net, status, payment_ref, created_at, completed_at from core.orders;
create view api.mis_beneficios with (security_invoker = true) as
  select id, kind, starts_at, ends_at, ledger_id from core.active_benefits;
-- Público: solo nombre y tipo. Sin correo ni WhatsApp.
create view api.directorio as select id, name, kind from core.restaurants;
-- Administración de Nova: SOLO totales por negocio. Nunca ve teléfono ni dirección de clientes ni detalle de pedidos.
create view api.liquidacion as
  select r.id as restaurant_id, r.name, count(o.*) filter (where o.status <> 'cancelado') as pedidos, coalesce(sum(o.total) filter (where o.status <> 'cancelado'), 0) as cobrado,
         coalesce(sum(o.fee) filter (where o.status <> 'cancelado'), 0) as comision_nova, coalesce(sum(o.net) filter (where o.status <> 'cancelado'), 0) as para_el_negocio
  from core.restaurants r left join core.orders o on o.restaurant_id = r.id group by r.id, r.name;
alter function core.jwt() owner to nova_owner; alter function core.claim_restaurant() owner to nova_owner; alter function core.claim_sub() owner to nova_owner;
alter view api.libro_cuenta owner to nova_owner; alter view api.mis_pedidos owner to nova_owner; alter view api.mis_beneficios owner to nova_owner;
alter view api.directorio owner to nova_owner; alter view api.liquidacion owner to nova_owner;

-- ===== Funciones RPC (SECURITY DEFINER; la identidad sale SIEMPRE del JWT, nunca de parámetros) =====
create function api.obtener_wallet() returns jsonb language plpgsql stable security definer set search_path = core, pg_temp as $$
begin
  if core.claim_restaurant() is null then raise exception 'Sesión de restaurante requerida.' using errcode = 'PT401'; end if;
  return core.wallet(core.claim_restaurant(), now());
end $$;

create function api.canjear(tipo text) returns jsonb language plpgsql volatile security definer set search_path = core, pg_temp as $$
begin
  if core.claim_restaurant() is null then raise exception 'Sesión de restaurante requerida.' using errcode = 'PT401'; end if;
  return core.canjear_tokens(core.claim_restaurant(), tipo, now());
end $$;

-- Crea el pedido ya pagado (la pasarela confirma por webhook en el servicio de pagos). La comisión la calcula la base, no el cliente.
create function api.crear_pedido(p_restaurant uuid, p_kind text, p_items jsonb, p_total integer, p_payment_ref text) returns uuid language plpgsql volatile security definer set search_path = core, pg_temp as $$
declare id uuid;
begin
  if core.claim_sub() is null then raise exception 'Inicia sesión para pedir.' using errcode = 'PT401'; end if;
  if not exists (select 1 from core.restaurants where core.restaurants.id = p_restaurant) then raise exception 'El negocio no existe.' using errcode = 'PT404'; end if;
  insert into core.orders(restaurant_id, customer_id, kind, items, total, fee, payment_ref)
  values (p_restaurant, core.claim_sub(), case when p_kind = 'hotel' then 'hotel' else 'food' end, p_items, p_total, core.fee_for(p_restaurant, p_total), p_payment_ref) returning core.orders.id into id;
  return id;
end $$;

-- El restaurante avanza el estado SOLO de sus pedidos, sin saltarse pasos. Al completarse suma al contador de tokens.
create function api.cambiar_estado_pedido(p_order uuid, p_estado text) returns jsonb language plpgsql volatile security definer set search_path = core, pg_temp as $$
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
  if p_estado in ('entregado','finalizada') then ganado := core.procesar_pedido_completado(p_order, now()); end if;
  return jsonb_build_object('estado', p_estado, 'tokens_ganados', ganado);
end $$;

alter function api.obtener_wallet() owner to nova_owner; alter function api.canjear(text) owner to nova_owner;
alter function api.crear_pedido(uuid, text, jsonb, integer, text) owner to nova_owner; alter function api.cambiar_estado_pedido(uuid, text) owner to nova_owner;
revoke all on all functions in schema api from public;
revoke all on all functions in schema core from public;
grant execute on function core.jwt(), core.claim_restaurant(), core.claim_sub() to restaurante, cliente, admin_nova, web_anon;
grant execute on function core.setting(text) to restaurante, cliente;
grant usage on schema api to web_anon, restaurante, cliente, admin_nova;
grant select on api.directorio to web_anon, restaurante, cliente, admin_nova;
grant select on api.libro_cuenta, api.mis_beneficios to restaurante;
grant select on api.mis_pedidos to restaurante, cliente;
grant select on api.liquidacion to admin_nova;
grant execute on function api.obtener_wallet(), api.canjear(text), api.cambiar_estado_pedido(uuid, text) to restaurante;
grant execute on function api.crear_pedido(uuid, text, jsonb, integer, text) to cliente;
