-- =====================================================================
-- NOVA IA — Fase 1: documentos, roles y seguridad (Supabase / PostgreSQL)
-- Pégalo completo en Supabase > SQL Editor > New query > Run.
-- Es seguro ejecutarlo más de una vez.
-- =====================================================================

create table if not exists public.docs (
  path       text primary key,
  coll       text not null,
  id         text not null,
  subject    uuid,                       -- a quién pertenece (cuentas, solicitudes, auditoría)
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists docs_coll_idx on public.docs (coll);
create index if not exists docs_subject_idx on public.docs (subject) where subject is not null;
create index if not exists docs_ord_rid_idx  on public.docs ((data->>'rid'))  where coll = 'orders';
create index if not exists docs_ord_cust_idx on public.docs ((data->>'cust')) where coll = 'orders';

-- Administradores de Nova (solo se llenan desde este editor SQL, nunca desde la página)
create table if not exists public.admins (
  uid        uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;   -- sin políticas: nadie la lee desde la API

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.admins where uid = auth.uid()) $$;

-- Restaurante al que pertenece quien consulta (lo asigna administración en registrations/<uid>)
create or replace function public.my_restaurant() returns text
language sql stable security definer set search_path = public as
$$ select data->>'r' from public.docs where path = 'registrations/' || auth.uid()::text $$;

revoke all on function public.is_admin() from public;
revoke all on function public.my_restaurant() from public;
grant execute on function public.is_admin(), public.my_restaurant() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Validación y normalización antes de guardar
-- ---------------------------------------------------------------------
create or replace function public.docs_before_write() returns trigger
language plpgsql set search_path = public as $$
declare
  parts text[];
  fee int; total numeric; old_st text; new_st text; staff boolean; cust boolean; flow text[];
begin
  parts := string_to_array(new.path, '/');
  if new.path ~ '^data/users/[0-9a-f-]{36}/account$' then
    new.coll := 'account'; new.id := parts[3]; new.subject := parts[3]::uuid;
  elsif new.path ~ '^[a-zA-Z]{2,20}/[A-Za-z0-9_.-]{1,80}$' then
    new.coll := parts[1]; new.id := parts[2];
    if new.coll in ('registrations', 'requests', 'audit') then
      begin new.subject := parts[2]::uuid; exception when others then raise exception 'ruta inválida'; end;
    else
      new.subject := null;
    end if;
  else
    raise exception 'ruta inválida';
  end if;
  if new.coll not in ('account','registrations','requests','audit','settings','menus','extra','overrides','kb','menuReq','orders') then
    raise exception 'colección no permitida';
  end if;
  if pg_column_size(new.data) > 60000 then raise exception 'documento demasiado grande'; end if;
  new.updated_at := now();

  if new.coll = 'orders' then
    if tg_op = 'INSERT' then
      -- el pedido siempre nace "nuevo", a nombre de quien lo crea, con la comisión de la plataforma
      total := coalesce((new.data->>'total')::numeric, 0);
      select coalesce((data->>'fee')::int, 200) into fee from public.docs where path = 'settings/platform';
      fee := least(coalesce(fee, 200), total::int);
      new.data := new.data || jsonb_build_object(
        'cust', auth.uid()::text, 'st', 'nuevo', 'fee', fee, 'net', total - fee);
    else
      -- solo puede cambiar el estado; el resto del pedido queda congelado
      if (new.data - 'st') is distinct from (old.data - 'st') then
        raise exception 'solo se puede cambiar el estado del pedido';
      end if;
      old_st := old.data->>'st'; new_st := new.data->>'st';
      if new_st is distinct from old_st and not public.is_admin() then
        staff := (old.data->>'rid') = public.my_restaurant();
        cust  := (old.data->>'cust') = auth.uid()::text;
        flow  := case when old.data->>'k' = 'hotel'
                      then array['nuevo','confirmada','hospedado','finalizada']
                      else array['nuevo','aceptado','preparando','en-camino','entregado'] end;
        if new_st = 'cancelado' then
          if not (staff or cust) or old_st <> 'nuevo' then raise exception 'no se puede cancelar'; end if;
        elsif not staff or old_st = 'cancelado'
              or array_position(flow, new_st) is distinct from array_position(flow, old_st) + 1 then
          raise exception 'cambio de estado no permitido';
        end if;
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists docs_before_write on public.docs;
create trigger docs_before_write before insert or update on public.docs
  for each row execute function public.docs_before_write();

-- ---------------------------------------------------------------------
-- Seguridad por filas (RLS)
-- ---------------------------------------------------------------------
alter table public.docs enable row level security;

drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to anon, authenticated using (
  coll in ('settings','menus','extra','overrides','kb')
  or public.is_admin()
  or (coll in ('account','registrations','requests','audit') and subject = auth.uid())
  or (coll = 'orders' and (data->>'cust' = auth.uid()::text or data->>'rid' = public.my_restaurant()))
);

drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert to authenticated with check (
  public.is_admin()
  or (coll in ('account','requests','audit') and subject = auth.uid())
  or coll = 'menuReq'
  or coll = 'orders'
);

drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated using (
  public.is_admin()
  or (coll in ('account','requests','audit') and subject = auth.uid())
  or coll = 'menuReq'
  or (coll = 'orders' and (data->>'cust' = auth.uid()::text or data->>'rid' = public.my_restaurant()))
) with check (
  public.is_admin()
  or (coll in ('account','requests','audit') and subject = auth.uid())
  or coll = 'menuReq'
  or (coll = 'orders' and (data->>'cust' = auth.uid()::text or data->>'rid' = public.my_restaurant()))
);

drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated using (public.is_admin());

grant select on public.docs to anon;
grant select, insert, update, delete on public.docs to authenticated;

-- ---------------------------------------------------------------------
-- Guardar y mezclar documentos (la página usa estas dos funciones)
-- ---------------------------------------------------------------------
create or replace function public.doc_set(p_path text, p_data jsonb) returns void
language sql security invoker set search_path = public as $$
  insert into public.docs (path, coll, id, data) values (p_path, '', '', p_data)
  on conflict (path) do update set data = excluded.data;
$$;

create or replace function public.doc_merge(p_path text, p_patch jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  update public.docs set data = data || p_patch where path = p_path;
  if not found then raise exception 'el documento no existe'; end if;
end $$;

revoke all on function public.doc_set(text, jsonb), public.doc_merge(text, jsonb) from public;
grant execute on function public.doc_set(text, jsonb), public.doc_merge(text, jsonb) to authenticated;
