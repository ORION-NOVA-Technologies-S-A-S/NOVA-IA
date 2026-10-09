-- Pruebas del paso 4 (sobre la misma base donde corrió 99_tests.sql, o una vacía)
\set ON_ERROR_STOP on
\set QUIET on
create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALLA: %', msg; end if; raise notice 'ok  - %', msg; end $$;

-- 1. Cuentas, login y bloqueo
do $$ declare r uuid; u uuid; c jsonb; i int; tk text; ch text; ph text; ok boolean; t0 timestamptz := '2026-10-08 12:00-05'; begin
  insert into core.restaurants(name) values ('Asadero Cuentas') returning id into r;
  u := core.registrar_usuario('maria.r', 'Clave-Segura-2026', 'restaurante', '+573001234567', 'whatsapp', r);
  perform pg_temp.ok(u is not null, 'registro de usuario del restaurante');
  begin perform core.registrar_usuario('pedro', 'corta1A', 'cliente', '+573001234568', 'sms'); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'contraseña débil rechazada'); end;
  begin perform core.registrar_usuario('maria.r', 'Otra-Clave-2026!', 'cliente', '+573001234569', 'sms'); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'usuario repetido rechazado'); end;
  begin perform core.registrar_usuario('ana', 'Clave-Segura-2026', 'cliente', '3001234567', 'sms'); perform pg_temp.ok(false, 'x'); exception when check_violation then perform pg_temp.ok(true, 'celular sin código de país rechazado'); end;
  c := core.verificar_login('MARIA.R', 'Clave-Segura-2026', t0);
  perform pg_temp.ok(c ->> 'role' = 'restaurante' and (c ->> 'restaurant_id')::uuid = r, 'login correcto devuelve los claims del JWT');
  perform pg_temp.ok((select password_hash from core.users where id = u) not like '%Clave-Segura%', 'la contraseña se guarda con hash bcrypt');
  perform pg_temp.ok(core.verificar_login('maria.r', 'mala', t0) is null and core.verificar_login('noexiste', 'mala', t0) is null, 'clave errónea y usuario inexistente responden igual');
  for i in 1..4 loop perform core.verificar_login('maria.r', 'mala', t0); end loop;
  begin perform core.verificar_login('maria.r', 'Clave-Segura-2026', t0 + interval '1 minute'); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT423' then perform pg_temp.ok(true, '5 intentos fallidos bloquean la cuenta (aun con la clave correcta)'); end;
  perform pg_temp.ok(core.verificar_login('maria.r', 'Clave-Segura-2026', t0 + interval '6 minutes') is not null, 'tras 5 minutos vuelve a entrar');

  -- 2. Recuperación por el canal elegido (whatsapp / sms)
  select phone, channel, token into ph, ch, tk from core.crear_recuperacion('maria.r', t0);
  perform pg_temp.ok(ch = 'whatsapp' and ph = '+573001234567' and length(tk) = 64, 'se envía al celular y canal que eligió al registrarse (WhatsApp)');
  perform pg_temp.ok((select count(*) from core.password_resets where token_hash = tk) = 0, 'en la base solo queda el hash del token');
  perform core.registrar_usuario('luis', 'Clave-Segura-2026', 'cliente', '+573009990000', 'sms');
  perform pg_temp.ok((select channel from core.crear_recuperacion('luis', t0)) = 'sms', 'quien eligió SMS la recibe por SMS');
  perform pg_temp.ok((select count(*) from core.crear_recuperacion('fantasma', t0)) = 0, 'usuario inexistente: sin envío');
  begin perform core.restablecer_clave(tk, 'corta', t0 + interval '1 minute'); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'la clave nueva también cumple la política'); end;
  perform pg_temp.ok(core.restablecer_clave(tk, 'Nueva-Clave-2027!', t0 + interval '5 minutes'), 'el enlace cambia la contraseña');
  begin perform core.restablecer_clave(tk, 'Otra-Clave-2028!', t0 + interval '6 minutes'); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'el enlace sirve una sola vez'); end;
  perform pg_temp.ok(core.verificar_login('maria.r', 'Nueva-Clave-2027!', t0 + interval '10 minutes') is not null and core.verificar_login('maria.r', 'Clave-Segura-2026', t0 + interval '10 minutes') is null, 'la clave vieja deja de servir');
  select token into tk from core.crear_recuperacion('maria.r', t0 + interval '1 hour');
  begin perform core.restablecer_clave(tk, 'Nueva-Clave-2029!', t0 + interval '1 hour 31 minutes'); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'el enlace vence a los 30 minutos'); end;
  perform core.crear_recuperacion('maria.r', t0 + interval '70 minutes'); perform core.crear_recuperacion('maria.r', t0 + interval '71 minutes');
  perform pg_temp.ok((select count(*) from core.crear_recuperacion('maria.r', t0 + interval '72 minutes')) = 0, 'máximo 3 solicitudes por hora');
end $$;

-- 3. Pago PSE confirmado: $30.500 → Nova $200, restaurante $30.300
do $$ declare r uuid; cu uuid := gen_random_uuid(); it uuid; dr uuid; res jsonb; oid uuid; o core.orders; pay core.payouts; again uuid; begin
  insert into core.restaurants(name) values ('Asadero Pagos') returning id into r;
  insert into core.menu_items(restaurant_id, category, name, price, source_url, captured_on) values (r, 'Pollo', 'Pollo asado', 30500, 'https://ejemplo.com/carta', '2026-10-08') returning id into it;
  begin insert into core.menu_items(restaurant_id, category, name, price, source_url, captured_on) values (r, 'X', 'Y', 1000, 'http://sin-https', '2026-10-08'); perform pg_temp.ok(false, 'x'); exception when check_violation then perform pg_temp.ok(true, 'no se puede cargar un precio sin fuente https'); end;
  res := core.iniciar_pago(cu, r, jsonb_build_array(jsonb_build_object('id', it, 'q', 1)), '{"lat":2.9273,"lng":-75.2819,"address":"Cra 5 # 8-10"}');
  perform pg_temp.ok((res ->> 'total')::int = 30500 and (res ->> 'amount_in_cents')::bigint = 3050000, 'el total sale de la carta en la base: $30.500 = 3.050.000 centavos');
  begin perform core.iniciar_pago(cu, r, jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'q', 1))); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'producto inexistente o de otro negocio rechazado'); end;
  begin perform core.confirmar_pago(res ->> 'reference', 'tx-1', 'APPROVED', 3000000); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'valor pagado distinto al pedido: se rechaza'); end;
  res := core.iniciar_pago(cu, r, jsonb_build_array(jsonb_build_object('id', it, 'q', 1)), '{"lat":2.9273,"lng":-75.2819,"address":"Cra 5 # 8-10"}');
  oid := core.confirmar_pago(res ->> 'reference', 'tx-2', 'APPROVED', 3050000);
  select * into o from core.orders where id = oid; select * into pay from core.payouts where order_id = oid;
  perform pg_temp.ok(o.total = 30500 and o.fee = 200 and o.net = 30300 and pay.amount = 30300, 'cliente paga $30.500; Nova recibe $200; el restaurante $30.300');
  again := core.confirmar_pago(res ->> 'reference', 'tx-2', 'APPROVED', 3050000);
  perform pg_temp.ok(again = oid and (select count(*) from core.orders where restaurant_id = r) = 1, 'el aviso de la pasarela repetido no duplica el pedido');
  res := core.iniciar_pago(cu, r, jsonb_build_array(jsonb_build_object('id', it, 'q', 2)));
  oid := core.confirmar_pago(res ->> 'reference', 'tx-3', 'DECLINED', 6100000);
  perform pg_temp.ok(oid is null and (select status from core.payments where reference = res ->> 'reference') = 'rechazado', 'un pago rechazado no crea pedido');
  -- con canje activo: comisión $0
  insert into core.restaurant_accounts(restaurant_id, tokens_balance) values (r, 0) on conflict do nothing;
  insert into core.token_ledger(account_id, event_type, tokens, balance_after, note) select id, 'redeem', -50, 0, 'prueba' from core.restaurant_accounts where restaurant_id = r;
  insert into core.active_benefits(account_id, kind, starts_at, ends_at, ledger_id) select a.id, 'semana', now() - interval '1 day', now() + interval '6 days', (select id from core.token_ledger where account_id = a.id limit 1) from core.restaurant_accounts a where a.restaurant_id = r;
  res := core.iniciar_pago(cu, r, jsonb_build_array(jsonb_build_object('id', it, 'q', 1)));
  oid := core.confirmar_pago(res ->> 'reference', 'tx-4', 'APPROVED', 3050000);
  perform pg_temp.ok((select fee from core.orders where id = oid) = 0 and (select amount from core.payouts where order_id = oid) = 30500, 'con canje activo: comisión $0 y el restaurante recibe los $30.500 completos');
end $$;

-- 4. Repartidores propios y mapa: privacidad
do $$ declare ra uuid; rb uuid; ca uuid; cb uuid; cu uuid := gen_random_uuid(); cu2 uuid := gen_random_uuid(); it uuid; res jsonb; oid uuid; d uuid; s jsonb; i int; n int; begin
  insert into core.restaurants(name) values ('Rest. Mapa A') returning id into ra; insert into core.restaurants(name) values ('Rest. Mapa B') returning id into rb;
  insert into core.menu_items(restaurant_id, category, name, price, source_url, captured_on) values (ra, 'Pollo', 'Pollo asado', 30500, 'https://ejemplo.com/a', '2026-10-08') returning id into it;
  insert into core.couriers(restaurant_id, name, phone) values (ra, 'Julián', '+573111111111') returning id into ca; insert into core.couriers(restaurant_id, name) values (rb, 'Otro') returning id into cb;
  insert into core.users(username, role, courier_id, phone, password_hash) values ('julian.rep', 'repartidor', ca, '+573111111111', 'x');
  res := core.iniciar_pago(cu, ra, jsonb_build_array(jsonb_build_object('id', it, 'q', 1)), '{"lat":2.93,"lng":-75.28,"address":"Calle 10 # 3-4"}');
  oid := core.confirmar_pago(res ->> 'reference', 'tx-m', 'APPROVED', 3050000);
  perform set_config('request.jwt.claims', json_build_object('role','restaurante','restaurant_id',ra)::text, true); set local role restaurante;
  begin perform api.asignar_repartidor(oid, ca); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'no se asigna repartidor a un pedido todavía "nuevo"'); end;
  perform api.cambiar_estado_pedido(oid, 'aceptado'); perform api.cambiar_estado_pedido(oid, 'preparando');
  begin perform api.asignar_repartidor(oid, cb); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT404' then perform pg_temp.ok(true, 'no se puede usar el repartidor de otro restaurante'); end;
  d := api.asignar_repartidor(oid, ca); perform pg_temp.ok(d is not null, 'el restaurante asigna a su repartidor');
  perform pg_temp.ok((select count(*) from api.mis_repartidores) = 1, 'el restaurante ve solo sus repartidores');
  perform api.cambiar_estado_pedido(oid, 'en-camino');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','repartidor','courier_id',ca)::text, true); set local role repartidor;
  perform api.iniciar_entrega();
  perform api.reportar_posicion(2.9273, -75.2819); perform pg_sleep(2.1); perform api.reportar_posicion(2.9280, -75.2825); perform api.reportar_posicion(2.9290, -75.2830);
  begin perform api.reportar_posicion(40.7, -74.0); perform pg_temp.ok(false, 'x'); exception when check_violation then perform pg_temp.ok(true, 'posiciones fuera de Colombia rechazadas'); end;
  begin perform count(*) from core.orders; perform pg_temp.ok(false, 'x'); exception when insufficient_privilege then perform pg_temp.ok(true, 'el repartidor no ve pedidos ni datos de clientes'); end;
  reset role;
  perform pg_temp.ok((select count(*) from core.courier_positions) = 2, 'se guardan las posiciones y se ignora la que llega en menos de 2 s');
  perform set_config('request.jwt.claims', json_build_object('role','cliente','sub',cu)::text, true); set local role cliente;
  s := api.seguimiento(oid);
  perform pg_temp.ok(s ->> 'estado' = 'en-camino' and s ->> 'repartidor' = 'Julián' and (s -> 'destino' ->> 'direccion') = 'Calle 10 # 3-4' and s -> 'posicion' ->> 'lat' = '2.929000', 'el cliente ve el mapa de su pedido: repartidor, destino y posición');
  perform pg_temp.ok(not (s::text like '%+57311%'), 'el cliente no ve el celular del repartidor');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','cliente','sub',cu2)::text, true); set local role cliente;
  begin perform api.seguimiento(oid); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT404' then perform pg_temp.ok(true, 'otro cliente NO ve el pedido ajeno'); end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','restaurante','restaurant_id',rb)::text, true); set local role restaurante;
  begin perform api.seguimiento(oid); perform pg_temp.ok(false, 'x'); exception when sqlstate 'PT404' then perform pg_temp.ok(true, 'otro restaurante NO ve el pedido ajeno'); end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','restaurante','restaurant_id',ra)::text, true); set local role restaurante;
  perform api.cambiar_estado_pedido(oid, 'entregado');
  perform pg_temp.ok(api.seguimiento(oid) ->> 'estado' = 'entregado' and not (api.seguimiento(oid) ? 'posicion'), 'al entregarse, el mapa deja de mostrar la ubicación');
  reset role;
  perform pg_temp.ok(core.purgar_posiciones(now() + interval '25 hours') = 2, 'las posiciones se borran 24 horas después de la entrega');
end $$;

-- 5. Administración: solo totales por pagar
do $$ begin
  set local role admin_nova;
  perform pg_temp.ok((select sum(monto) from api.por_pagar) > 0, 'administración ve cuánto debe pagar a cada negocio');
  begin perform count(*) from core.payouts; perform pg_temp.ok(false, 'x'); exception when insufficient_privilege then perform pg_temp.ok(true, 'pero no el detalle de los pedidos'); end;
  reset role;
  set local role cliente;
  begin perform count(*) from core.users; perform pg_temp.ok(false, 'x'); exception when insufficient_privilege then perform pg_temp.ok(true, 'nadie fuera del servicio lee la tabla de usuarios'); end;
  reset role;
end $$;
