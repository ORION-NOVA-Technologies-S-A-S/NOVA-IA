-- Nova · Fase 2 · Usuarios y recuperación de contraseña por WhatsApp o SMS (según lo elegido al crear la cuenta)
\set ON_ERROR_STOP on
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select from pg_roles where rolname='servicio') then create role servicio nologin; end if;     -- el servicio Node (pagos, mensajes). NUNCA expuesto por PostgREST
  if not exists (select from pg_roles where rolname='repartidor') then create role repartidor nologin; end if;
end $$;
grant repartidor to authenticator; alter role repartidor set timezone = 'America/Bogota';

create table core.users (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username ~ '^[a-z0-9_.]{3,20}$'),
  pass_hash text not null,                                   -- bcrypt (pgcrypto), nunca la clave
  role text not null check (role in ('cliente','restaurante','admin')),
  restaurant_id uuid references core.restaurants(id),
  phone text not null check (phone ~ '^\+573[0-9]{9}$'),      -- celular colombiano en formato +573XXXXXXXXX
  recovery_channel text not null default 'whatsapp' check (recovery_channel in ('whatsapp','sms')),
  failed integer not null default 0, locked_until timestamptz,
  created_at timestamptz not null default now(),
  check ((role = 'restaurante') = (restaurant_id is not null))
);
create table core.password_resets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references core.users(id),
  code_hash text not null, channel text not null,
  expires_at timestamptz not null, attempts integer not null default 0, used_at timestamptz,
  created_at timestamptz not null default now()
);
create index on core.password_resets (user_id, created_at desc);

create function core.validar_clave(p text, u text) returns text language sql immutable as $$
  select case
    when length(p) < 10 then 'La contraseña debe tener al menos 10 caracteres.'
    when ((p ~ '[a-z]')::int + (p ~ '[A-Z]')::int + (p ~ '[0-9]')::int + (p ~ '[^A-Za-z0-9]')::int) < 3 then 'Usa tres de estos: minúscula, mayúscula, número, símbolo.'
    when u is not null and position(lower(u) in lower(p)) > 0 then 'La contraseña no debe contener tu usuario.'
  end $$;

create function core.registrar_usuario(p_user text, p_pass text, p_role text, p_phone text, p_channel text default 'whatsapp', p_restaurant uuid default null) returns uuid language plpgsql as $$
declare e text := core.validar_clave(p_pass, p_user); id uuid;
begin
  if e is not null then raise exception '%', e using errcode = 'PT400'; end if;
  insert into core.users(username, pass_hash, role, phone, recovery_channel, restaurant_id)
  values (lower(p_user), crypt(p_pass, gen_salt('bf', 10)), p_role, p_phone, p_channel, p_restaurant) returning core.users.id into id;
  return id;
exception when unique_violation then raise exception 'Ese usuario ya existe.' using errcode = 'PT409';
          when check_violation then raise exception 'Revisa el usuario, el celular (+573XXXXXXXXX) y el tipo de cuenta.' using errcode = 'PT400';
end $$;

-- Ingreso con bloqueo: 5 intentos fallidos = 5 minutos. Devuelve {ok, id, role, restaurant_id} para que el servicio firme el JWT.
create function core.verificar_login(p_user text, p_pass text, p_now timestamptz default now()) returns jsonb language plpgsql as $$
declare u core.users;
begin
  select * into u from core.users where username = lower(p_user) for update;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Usuario o contraseña incorrectos.'); end if;
  if u.locked_until > p_now then return jsonb_build_object('ok', false, 'msg', 'Cuenta bloqueada por intentos fallidos. Intenta de nuevo en unos minutos.'); end if;
  if u.pass_hash = crypt(p_pass, u.pass_hash) then
    update core.users set failed = 0, locked_until = null where id = u.id;
    return jsonb_build_object('ok', true, 'id', u.id, 'role', u.role, 'restaurant_id', u.restaurant_id);
  end if;
  update core.users set failed = case when failed + 1 >= 5 then 0 else failed + 1 end, locked_until = case when failed + 1 >= 5 then p_now + interval '5 minutes' end where id = u.id;
  return jsonb_build_object('ok', false, 'msg', 'Usuario o contraseña incorrectos.');
end $$;

-- Paso 1 de "Olvidé mi contraseña". Devuelve el código SOLO al servicio, que lo manda por el canal elegido (WhatsApp o SMS).
-- Si el usuario no existe devuelve 0 filas: el servicio responde igual en ambos casos (no revela quién tiene cuenta).
create function core.solicitar_recuperacion(p_user text, p_now timestamptz default now()) returns table(user_id uuid, phone text, channel text, code text) language plpgsql as $$
declare u core.users; c text; b bytea;
begin
  select * into u from core.users where username = lower(p_user);
  if not found then return; end if;
  if (select count(*) from core.password_resets where core.password_resets.user_id = u.id and created_at > p_now - interval '1 hour') >= 3 then
    raise exception 'Pediste demasiados códigos. Espera una hora e inténtalo de nuevo.' using errcode = 'PT429'; end if;
  update core.password_resets set used_at = p_now where core.password_resets.user_id = u.id and used_at is null;
  b := gen_random_bytes(4);
  c := lpad((((get_byte(b,0)::bigint << 24) + (get_byte(b,1) << 16) + (get_byte(b,2) << 8) + get_byte(b,3)) % 1000000)::text, 6, '0');
  insert into core.password_resets(user_id, code_hash, channel, expires_at, created_at) values (u.id, crypt(c, gen_salt('bf', 8)), u.recovery_channel, p_now + interval '10 minutes', p_now);
  return query select u.id, u.phone, u.recovery_channel, c;
end $$;

-- Paso 2: código + clave nueva. El código sirve una vez, vence a los 10 minutos y se quema tras 5 errores.
-- Devuelve jsonb (no lanza error) para que el conteo de intentos fallidos quede guardado.
create function core.restablecer_clave(p_user text, p_code text, p_new text, p_now timestamptz default now()) returns jsonb language plpgsql as $$
declare u core.users; r core.password_resets; e text; bad constant jsonb := jsonb_build_object('ok', false, 'msg', 'Código incorrecto o vencido.');
begin
  select * into u from core.users where username = lower(p_user) for update;
  if not found then return bad; end if;
  select * into r from core.password_resets where user_id = u.id and used_at is null order by created_at desc limit 1 for update;
  if not found or r.expires_at <= p_now or r.attempts >= 5 then return bad; end if;
  if r.code_hash <> crypt(coalesce(p_code, ''), r.code_hash) then
    update core.password_resets set attempts = attempts + 1, used_at = case when attempts + 1 >= 5 then p_now end where id = r.id;
    return bad;
  end if;
  e := core.validar_clave(p_new, u.username);
  if e is not null then return jsonb_build_object('ok', false, 'msg', e); end if;   -- el código sigue vigente para corregir la clave
  update core.password_resets set used_at = p_now where id = r.id;
  update core.users set pass_hash = crypt(p_new, gen_salt('bf', 10)), failed = 0, locked_until = null where id = u.id;
  return jsonb_build_object('ok', true, 'msg', 'Contraseña actualizada. Ya puedes ingresar.');
end $$;

alter table core.users owner to nova_owner; alter table core.password_resets owner to nova_owner;
alter table core.users enable row level security; alter table core.password_resets enable row level security;
do $$ declare f record; begin for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='core' and p.proowner <> (select oid from pg_roles where rolname='nova_owner') loop execute format('alter function %s owner to nova_owner', f.sig); end loop; end $$;
revoke all on core.users, core.password_resets from public, web_anon, restaurante, cliente, admin_nova, repartidor;
revoke all on all functions in schema core from public;
grant usage on schema core to servicio;
grant execute on function core.registrar_usuario(text,text,text,text,text,uuid), core.verificar_login(text,text,timestamptz), core.solicitar_recuperacion(text,timestamptz), core.restablecer_clave(text,text,text,timestamptz) to servicio;
grant execute on function core.jwt(), core.claim_restaurant(), core.claim_sub(), core.setting(text) to restaurante, cliente, admin_nova, web_anon, repartidor;
-- El servicio no recibe permisos sobre tablas: llama estas funciones, que corren con los permisos del dueño.
alter function core.registrar_usuario(text,text,text,text,text,uuid) security definer set search_path = core, public, pg_temp;
alter function core.verificar_login(text,text,timestamptz) security definer set search_path = core, public, pg_temp;
alter function core.solicitar_recuperacion(text,timestamptz) security definer set search_path = core, public, pg_temp;
alter function core.restablecer_clave(text,text,text,timestamptz) security definer set search_path = core, public, pg_temp;
