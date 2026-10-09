-- Nova · PostgreSQL + PostgREST · Paso 1: esquema (ledger append-only)
-- Zona horaria de negocio: America/Bogota (UTC-5, sin horario de verano).
\set ON_ERROR_STOP on
create extension if not exists btree_gist;
create schema if not exists core;   -- tablas y lógica (NO expuesto por PostgREST)
create schema if not exists api;    -- lo único que PostgREST expone

-- Roles. 'authenticator' es el único que inicia sesión; PostgREST cambia al rol del JWT.
do $$ begin
  if not exists (select from pg_roles where rolname='nova_owner') then create role nova_owner nologin; end if;
  if not exists (select from pg_roles where rolname='authenticator') then create role authenticator noinherit login password 'CAMBIAR_ESTA_CLAVE'; end if;
  if not exists (select from pg_roles where rolname='web_anon') then create role web_anon nologin; end if;
  if not exists (select from pg_roles where rolname='restaurante') then create role restaurante nologin; end if;   -- personal del restaurante u hotel registrado
  if not exists (select from pg_roles where rolname='cliente') then create role cliente nologin; end if;
  if not exists (select from pg_roles where rolname='admin_nova') then create role admin_nova nologin; end if;
end $$;
grant web_anon, restaurante, cliente, admin_nova to authenticator;
alter role web_anon set timezone = 'America/Bogota';
alter role restaurante set timezone = 'America/Bogota';
alter role cliente set timezone = 'America/Bogota';
alter role admin_nova set timezone = 'America/Bogota';

create table core.settings (key text primary key, value numeric not null);
insert into core.settings values ('fee_cop', 200), ('pedidos_por_token', 20), ('canje_semana_tokens', 50), ('canje_mes_tokens', 1000), ('dias_vencimiento', 90)
  on conflict do nothing;

create table core.restaurants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null default 'restaurante' check (kind in ('restaurante','hotel')),
  email text, whatsapp text,
  created_at timestamptz not null default now()
);

create table core.restaurant_accounts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null unique references core.restaurants(id),
  tokens_balance numeric not null default 0 check (tokens_balance >= 0),     -- caché; la verdad es el ledger
  orders_completed bigint not null default 0,                                -- acumulativo, nunca se reinicia
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table core.orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references core.restaurants(id),
  customer_id uuid not null,
  kind text not null default 'food' check (kind in ('food','hotel')),
  items jsonb not null,
  total integer not null check (total > 0),
  fee integer not null check (fee >= 0),
  net integer generated always as (total - fee) stored,
  status text not null default 'nuevo',
  payment_ref text,
  counted boolean not null default false,        -- ya sumó al contador de fidelización
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check (fee <= total)
);
create index on core.orders (restaurant_id, created_at desc);
create index on core.orders (customer_id, created_at desc);

create table core.token_ledger (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references core.restaurant_accounts(id),
  order_id uuid references core.orders(id),
  event_type text not null check (event_type in ('earn','redeem','expire','admin_adjust')),
  tokens numeric not null,
  balance_after numeric not null check (balance_after >= 0),
  expiry_at timestamptz,
  source_ledger_id uuid references core.token_ledger(id),
  note text,
  created_at timestamptz not null default now(),
  check ((event_type = 'earn') = (expiry_at is not null)),
  check ((event_type = 'earn' and tokens > 0) or (event_type in ('redeem','expire') and tokens < 0) or event_type = 'admin_adjust'),
  check ((event_type = 'expire') = (source_ledger_id is not null))
);
create index on core.token_ledger (account_id, created_at desc);
create index on core.token_ledger (expiry_at) where event_type = 'earn';
create unique index token_ledger_one_earn_per_order on core.token_ledger (order_id) where event_type = 'earn';
create unique index token_ledger_one_expire_per_earn on core.token_ledger (source_ledger_id) where event_type = 'expire';

-- Regla de consumo: qué 'earn' paga cada canje (vence primero = se gasta primero). También append-only.
create table core.token_consumption (
  id uuid primary key default gen_random_uuid(),
  redeem_ledger_id uuid not null references core.token_ledger(id),
  earn_ledger_id uuid not null references core.token_ledger(id),
  tokens numeric not null check (tokens > 0),
  created_at timestamptz not null default now()
);
create index on core.token_consumption (earn_ledger_id);

create table core.active_benefits (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references core.restaurant_accounts(id),
  kind text not null check (kind in ('semana','mes')),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  ledger_id uuid not null references core.token_ledger(id),
  exclude using gist (account_id with =, tstzrange(starts_at, ends_at) with &&)   -- un canje a la vez, a nivel de base de datos
);

-- El libro de cuenta no se edita ni se borra, ni siquiera por el dueño de la tabla.
create function core.ledger_inmutable() returns trigger language plpgsql as $$
begin raise exception 'El libro de cuenta es de solo inserción: no se puede % ', lower(tg_op) using errcode = 'PT403'; end $$;
create trigger token_ledger_append_only before update or delete on core.token_ledger for each row execute function core.ledger_inmutable();
create trigger token_consumption_append_only before update or delete on core.token_consumption for each row execute function core.ledger_inmutable();

-- Tokens vigentes por 'earn': lo ganado menos lo consumido por canjes y lo vencido.
create view core.earn_remaining as
select e.id, e.account_id, e.expiry_at, e.created_at,
       e.tokens
       - coalesce((select sum(c.tokens) from core.token_consumption c where c.earn_ledger_id = e.id), 0)
       - coalesce((select -sum(x.tokens) from core.token_ledger x where x.source_ledger_id = e.id and x.event_type = 'expire'), 0) as remaining
from core.token_ledger e where e.event_type = 'earn';

alter schema core owner to nova_owner; alter schema api owner to nova_owner;
do $$ declare t record; begin
  for t in select tablename from pg_tables where schemaname = 'core' loop execute format('alter table core.%I owner to nova_owner', t.tablename); end loop;
  alter view core.earn_remaining owner to nova_owner;
end $$;
