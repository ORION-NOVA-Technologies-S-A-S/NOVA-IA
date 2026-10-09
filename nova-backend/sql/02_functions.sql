-- Nova · Paso 2: lógica de tokens. Todo en 'core' (no expuesto). Las funciones *_at reciben "ahora"
-- como parámetro para poder probar fechas; la API pública siempre usa now().
\set ON_ERROR_STOP on

create function core.setting(p_key text) returns numeric language sql stable as $$ select value from core.settings where key = p_key $$;

-- 90 días de CALENDARIO desde el día Bogotá en que se ganó, a las 00:00 hora Bogotá. Nunca "90*24 horas".
create function core.calcular_expiracion(p_ganado timestamptz) returns timestamptz
language sql immutable as $$
  select (((p_ganado at time zone 'America/Bogota')::date + 90)::timestamp) at time zone 'America/Bogota'
$$;

create function core.lock_account(p_restaurant uuid) returns core.restaurant_accounts language plpgsql as $$
declare a core.restaurant_accounts;
begin
  insert into core.restaurant_accounts(restaurant_id) values (p_restaurant) on conflict (restaurant_id) do nothing;
  select * into a from core.restaurant_accounts where restaurant_id = p_restaurant for update;
  return a;
end $$;

-- Vence (en el ledger) los tokens de una cuenta cuyo expiry_at ya pasó. Idempotente.
create function core.expire_account(p_acct uuid, p_now timestamptz) returns numeric language plpgsql as $$
declare bal numeric; tot numeric := 0; r record;
begin
  select tokens_balance into bal from core.restaurant_accounts where id = p_acct for update;
  for r in select id, remaining from core.earn_remaining
           where account_id = p_acct and expiry_at <= p_now and remaining > 0 order by expiry_at, id loop
    bal := bal - r.remaining;
    insert into core.token_ledger(account_id, event_type, tokens, balance_after, source_ledger_id, note, created_at)
    values (p_acct, 'expire', -r.remaining, bal, r.id, 'Vencimiento a los 90 días', p_now);
    tot := tot + r.remaining;
  end loop;
  if tot > 0 then update core.restaurant_accounts set tokens_balance = bal, updated_at = p_now where id = p_acct; end if;
  return tot;
end $$;

-- Tarea diaria (00:05 hora Bogotá). El candado asesor evita que corra dos veces en paralelo.
-- Devuelve cuántas cuentas tuvieron vencimientos, o -1 si otra instancia ya la está ejecutando.
create function core.procesar_expiraciones(p_now timestamptz default now()) returns integer language plpgsql as $$
declare a uuid; n integer := 0;
begin
  if not pg_try_advisory_xact_lock(727001) then return -1; end if;
  for a in select distinct account_id from core.earn_remaining where expiry_at <= p_now and remaining > 0 order by 1 loop
    perform core.expire_account(a, p_now); n := n + 1;
  end loop;
  return n;
end $$;

-- Gancho de pedido completado: 1 token por cada 20 completados (acumulativo). Cada pedido cuenta una sola vez.
-- Devuelve los tokens otorgados (0 o 1).
create function core.procesar_pedido_completado(p_order uuid, p_now timestamptz default now()) returns numeric language plpgsql as $$
declare o core.orders; a core.restaurant_accounts; n bigint; bal numeric; per integer := core.setting('pedidos_por_token');
begin
  select * into o from core.orders where id = p_order for update;
  if not found then raise exception 'El pedido no existe.' using errcode = 'PT404'; end if;
  if o.counted then return 0; end if;
  a := core.lock_account(o.restaurant_id);
  update core.orders set counted = true, completed_at = p_now where id = p_order;
  n := a.orders_completed + 1; bal := a.tokens_balance;
  if n % per = 0 then
    bal := bal + 1;
    insert into core.token_ledger(account_id, order_id, event_type, tokens, balance_after, expiry_at, note, created_at)
    values (a.id, p_order, 'earn', 1, bal, core.calcular_expiracion(p_now), 'Pedido completado n.º ' || n, p_now);
  end if;
  update core.restaurant_accounts set orders_completed = n, tokens_balance = bal, updated_at = p_now where id = a.id;
  return case when n % per = 0 then 1 else 0 end;
end $$;

create function core.beneficio_activo(p_restaurant uuid, p_now timestamptz default now()) returns core.active_benefits
language sql stable as $$
  select b.* from core.active_benefits b join core.restaurant_accounts a on a.id = b.account_id
  where a.restaurant_id = p_restaurant and b.starts_at <= p_now and b.ends_at > p_now order by b.ends_at desc limit 1
$$;

-- Comisión por pedido: $200, o $0 mientras haya un canje activo.
create function core.fee_for(p_restaurant uuid, p_total integer, p_now timestamptz default now()) returns integer language sql stable as $$
  select case when (core.beneficio_activo(p_restaurant, p_now)).id is not null then 0 else least(core.setting('fee_cop')::integer, p_total) end
$$;

-- Canje: 50 tokens = 1 semana, 1000 = 1 mes sin la comisión. Un canje a la vez.
-- Regla de consumo: se gastan primero los tokens que vencen antes (empate: el más antiguo).
create function core.canjear_tokens(p_restaurant uuid, p_tipo text, p_now timestamptz default now()) returns jsonb language plpgsql as $$
declare a core.restaurant_accounts; cost numeric; bal numeric; need numeric; take numeric; r record; lid uuid; ends timestamptz; act core.active_benefits;
begin
  cost := case p_tipo when 'semana' then core.setting('canje_semana_tokens') when 'mes' then core.setting('canje_mes_tokens') end;
  if cost is null then raise exception 'Tipo de canje no válido. Usa "semana" o "mes".' using errcode = 'PT400'; end if;
  a := core.lock_account(p_restaurant);
  perform core.expire_account(a.id, p_now);
  select * into a from core.restaurant_accounts where id = a.id;
  act := core.beneficio_activo(p_restaurant, p_now);
  if act.id is not null then
    raise exception 'Ya tienes un canje activo hasta el %. Podrás canjear de nuevo cuando termine.', to_char(act.ends_at at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI') using errcode = 'PT409';
  end if;
  if a.tokens_balance < cost then
    raise exception 'Saldo insuficiente: tienes % tokens y necesitas % para canjear 1 %.', a.tokens_balance, cost, p_tipo using errcode = 'PT400';
  end if;
  bal := a.tokens_balance - cost;
  insert into core.token_ledger(account_id, event_type, tokens, balance_after, note, created_at)
  values (a.id, 'redeem', -cost, bal, 'Canje: 1 ' || p_tipo || ' sin comisión', p_now) returning id into lid;
  need := cost;
  for r in select id, remaining from core.earn_remaining where account_id = a.id and remaining > 0 and expiry_at > p_now order by expiry_at, id loop
    exit when need <= 0;
    take := least(r.remaining, need);
    insert into core.token_consumption(redeem_ledger_id, earn_ledger_id, tokens, created_at) values (lid, r.id, take, p_now);
    need := need - take;
  end loop;
  if need > 0 then raise exception 'Inconsistencia de saldo: el libro de cuenta no cubre el canje.' using errcode = 'PT500'; end if;
  ends := (((p_now at time zone 'America/Bogota') + case p_tipo when 'semana' then interval '7 days' else interval '1 month' end)) at time zone 'America/Bogota';
  insert into core.active_benefits(account_id, kind, starts_at, ends_at, ledger_id) values (a.id, p_tipo, p_now, ends, lid);
  update core.restaurant_accounts set tokens_balance = bal, updated_at = p_now where id = a.id;
  return jsonb_build_object('canje', p_tipo, 'tokens_usados', cost, 'saldo', bal, 'sin_comision_desde', p_now, 'sin_comision_hasta', ends);
end $$;

-- Wallet (solo lectura): saldo vigente, tokens por vencer con cuenta regresiva en días de calendario Bogotá, canje activo.
create function core.wallet(p_restaurant uuid, p_now timestamptz default now()) returns jsonb language plpgsql stable as $$
declare a core.restaurant_accounts; saldo numeric := 0; porv jsonb; act core.active_benefits; per integer := core.setting('pedidos_por_token'); cs numeric := core.setting('canje_semana_tokens'); cm numeric := core.setting('canje_mes_tokens');
begin
  select * into a from core.restaurant_accounts where restaurant_id = p_restaurant;
  if found then
    select coalesce(sum(remaining), 0) into saldo from core.earn_remaining where account_id = a.id and remaining > 0 and expiry_at > p_now;
    select coalesce(jsonb_agg(jsonb_build_object('tokens', remaining, 'expira', expiry_at,
             'dias_restantes', (expiry_at at time zone 'America/Bogota')::date - (p_now at time zone 'America/Bogota')::date) order by expiry_at), '[]'::jsonb)
      into porv from core.earn_remaining where account_id = a.id and remaining > 0 and expiry_at > p_now;
  else porv := '[]'::jsonb; end if;
  act := core.beneficio_activo(p_restaurant, p_now);
  return jsonb_build_object(
    'saldo', saldo,
    'pedidos_completados', coalesce(a.orders_completed, 0),
    'pedidos_para_proximo_token', per - (coalesce(a.orders_completed, 0) % per),
    'faltan_para_semana', greatest(0, cs - saldo), 'faltan_para_mes', greatest(0, cm - saldo),
    'puede_canjear_semana', saldo >= cs and act.id is null, 'puede_canjear_mes', saldo >= cm and act.id is null,
    'por_expirar', porv,
    'canje_activo', case when act.id is null then null else jsonb_build_object('tipo', act.kind, 'desde', act.starts_at, 'hasta', act.ends_at) end,
    'comision_actual', core.fee_for(p_restaurant, 1000000, p_now));
end $$;

alter function core.setting(text) owner to nova_owner;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'core' loop
    execute format('alter function %s owner to nova_owner', f.sig);
  end loop;
end $$;
