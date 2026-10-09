-- Nova · Fase 2 · Pagos. La pasarela (PSE/Nequi/tarjetas) cobra a Nova el valor completo; Nova se queda $200 y registra lo que debe pagar al restaurante.
-- El valor SIEMPRE lo calcula la base con los precios guardados, nunca el navegador.
\set ON_ERROR_STOP on
create table core.menu_items (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references core.restaurants(id),
  category text not null default 'Carta', name text not null,
  modality text check (modality in ('hora','noche','dia')),       -- solo hoteles
  price integer not null check (price > 0 and price <= 5000000),
  description text, source_url text, loaded_at timestamptz not null default now(),
  active boolean not null default true
);
create index on core.menu_items (restaurant_id) where active;
create table core.payments (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  customer_id uuid not null, restaurant_id uuid not null references core.restaurants(id),
  kind text not null check (kind in ('food','hotel')), items jsonb not null, detail jsonb,
  total integer not null check (total > 0), fee integer not null check (fee >= 0), net integer generated always as (total - fee) stored,
  status text not null default 'pendiente' check (status in ('pendiente','aprobado','rechazado','anulado','error')),
  provider text not null default 'wompi', provider_tx text unique, method text,
  order_id uuid references core.orders(id), created_at timestamptz not null default now(), paid_at timestamptz
);
create table core.payouts (        -- lo que Nova debe transferir a cada restaurante por pedido pagado
  id uuid primary key default gen_random_uuid(), order_id uuid not null unique references core.orders(id), restaurant_id uuid not null references core.restaurants(id),
  amount integer not null check (amount >= 0), status text not null default 'pendiente' check (status in ('pendiente','pagado','fallido')),
  paid_ref text, created_at timestamptz not null default now(), paid_at timestamptz
);
alter table core.menu_items owner to nova_owner; alter table core.payments owner to nova_owner; alter table core.payouts owner to nova_owner;
alter table core.menu_items enable row level security; alter table core.payments enable row level security; alter table core.payouts enable row level security;
revoke all on core.menu_items, core.payments, core.payouts from public, web_anon, restaurante, cliente, admin_nova, repartidor;

-- Carga de carta con su fuente (solo administración o servicio). Solo precios publicados por el propio negocio.
create function core.cargar_item(p_restaurant uuid, p_category text, p_name text, p_price integer, p_desc text, p_source text, p_modality text default null) returns uuid language sql as $$
  insert into core.menu_items(restaurant_id, category, name, price, description, source_url, modality) values (p_restaurant, p_category, p_name, p_price, p_desc, p_source, p_modality) returning id $$;

-- Paso 1: el servicio recibe el carrito [{id, q}] y lo valora con los precios de la base. Devuelve la referencia y el monto en centavos para la pasarela.
create function core.crear_intencion_pago(p_customer uuid, p_restaurant uuid, p_items jsonb, p_detail jsonb default null, p_now timestamptz default now()) returns jsonb language plpgsql as $$
declare tot integer := 0; lines jsonb := '[]'; r record; k text := 'food'; fee integer; ref text;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then raise exception 'El pedido está vacío o es demasiado grande.' using errcode = 'PT400'; end if;
  for r in select m.id, m.name, m.price, m.modality, greatest(1, least(coalesce((i ->> 'q')::int, 1), 99)) as q
           from jsonb_array_elements(p_items) i join core.menu_items m on m.id = (i ->> 'id')::uuid and m.restaurant_id = p_restaurant and m.active loop
    tot := tot + r.price * r.q; if r.modality is not null then k := 'hotel'; end if;
    lines := lines || jsonb_build_object('n', r.name, 'q', r.q, 'p', r.price, 'u', coalesce(r.modality, ''));
  end loop;
  if tot <= 0 or jsonb_array_length(lines) <> jsonb_array_length(p_items) then raise exception 'Hay productos que ya no están en la carta.' using errcode = 'PT400'; end if;
  fee := core.fee_for(p_restaurant, tot, p_now);
  ref := 'NOVA-' || upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 12));
  insert into core.payments(reference, customer_id, restaurant_id, kind, items, detail, total, fee, created_at) values (ref, p_customer, p_restaurant, k, lines, p_detail, tot, fee, p_now);
  return jsonb_build_object('reference', ref, 'total', tot, 'amount_in_cents', tot::bigint * 100, 'fee', fee, 'net', tot - fee);
end $$;

-- Paso 2: la pasarela avisa (webhook ya verificado por el servicio). Idempotente: repetir el aviso no duplica pedidos ni pagos.
create function core.confirmar_pago(p_reference text, p_provider_tx text, p_status text, p_amount_cents bigint, p_method text default null, p_now timestamptz default now()) returns jsonb language plpgsql as $$
declare p core.payments; oid uuid; st text;
begin
  select * into p from core.payments where reference = p_reference for update;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Referencia desconocida'); end if;
  if p.status = 'aprobado' then return jsonb_build_object('ok', true, 'order_id', p.order_id, 'repetido', true); end if;
  st := case upper(p_status) when 'APPROVED' then 'aprobado' when 'DECLINED' then 'rechazado' when 'VOIDED' then 'anulado' when 'ERROR' then 'error' else 'pendiente' end;
  if st = 'aprobado' and p_amount_cents <> p.total::bigint * 100 then
    update core.payments set status = 'error', provider_tx = p_provider_tx where id = p.id;
    return jsonb_build_object('ok', false, 'msg', 'El monto pagado no coincide con el pedido');
  end if;
  update core.payments set status = st, provider_tx = p_provider_tx, method = p_method, paid_at = case when st = 'aprobado' then p_now end where id = p.id;
  if st = 'aprobado' then
    insert into core.orders(restaurant_id, customer_id, kind, items, total, fee, payment_ref, created_at) values (p.restaurant_id, p.customer_id, p.kind, p.items, p.total, p.fee, p.reference, p_now) returning id into oid;
    update core.payments set order_id = oid where id = p.id;
    insert into core.payouts(order_id, restaurant_id, amount, created_at) values (oid, p.restaurant_id, p.total - p.fee, p_now);
    return jsonb_build_object('ok', true, 'order_id', oid, 'comision_nova', p.fee, 'para_el_negocio', p.total - p.fee);
  end if;
  return jsonb_build_object('ok', true, 'estado', st);
end $$;

create function core.marcar_payout_pagado(p_payout uuid, p_ref text, p_now timestamptz default now()) returns void language sql as $$
  update core.payouts set status = 'pagado', paid_ref = p_ref, paid_at = p_now where id = p_payout and status <> 'pagado' $$;

-- Administración: cuánto debe Nova a cada negocio (sin datos de clientes)
create view api.por_pagar as
  select r.id as restaurant_id, r.name, count(p.*) filter (where p.status = 'pendiente') as pedidos_pendientes, coalesce(sum(p.amount) filter (where p.status = 'pendiente'), 0) as monto_pendiente,
         coalesce(sum(p.amount) filter (where p.status = 'pagado'), 0) as monto_pagado
  from core.restaurants r left join core.payouts p on p.restaurant_id = r.id group by r.id, r.name;
alter view api.por_pagar owner to nova_owner; grant select on api.por_pagar to admin_nova;
-- El restaurante ve lo que Nova le va a pagar por SUS pedidos
create policy payouts_propios on core.payouts for select to restaurante using (restaurant_id = core.claim_restaurant());
grant select on core.payouts to restaurante;
create view api.mis_pagos with (security_invoker = true) as select id, order_id, amount, status, paid_ref, created_at, paid_at from core.payouts;
alter view api.mis_pagos owner to nova_owner; grant select on api.mis_pagos to restaurante;
-- Carta pública (solo lo cargado con su fuente)
create view api.carta as select id, restaurant_id, category, name, modality, price, description, source_url, loaded_at from core.menu_items where active;
alter view api.carta owner to nova_owner; grant select on api.carta to web_anon, restaurante, cliente, admin_nova;

do $$ declare f record; begin for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='core' and p.proowner <> (select oid from pg_roles where rolname='nova_owner') loop execute format('alter function %s owner to nova_owner', f.sig); end loop; end $$;
revoke all on all functions in schema core from public;
grant execute on function core.crear_intencion_pago(uuid,uuid,jsonb,jsonb,timestamptz), core.confirmar_pago(text,text,text,bigint,text,timestamptz), core.marcar_payout_pagado(uuid,text,timestamptz), core.cargar_item(uuid,text,text,integer,text,text,text) to servicio;
grant execute on function core.jwt(), core.claim_restaurant(), core.claim_sub(), core.claim_courier(), core.setting(text) to restaurante, cliente, admin_nova, web_anon, repartidor;
alter function core.crear_intencion_pago(uuid,uuid,jsonb,jsonb,timestamptz) security definer set search_path = core, public, pg_temp;
alter function core.confirmar_pago(text,text,text,bigint,text,timestamptz) security definer set search_path = core, public, pg_temp;
alter function core.marcar_payout_pagado(uuid,text,timestamptz) security definer set search_path = core, public, pg_temp;
alter function core.cargar_item(uuid,text,text,integer,text,text,text) security definer set search_path = core, public, pg_temp;
