-- Pruebas de la fase 2 (usuarios, recuperación, entregas, pagos). Ejecutar después de los scripts 01 a 06.
\set ON_ERROR_STOP on
\set QUIET on
create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALLA: %', msg; end if; raise notice 'ok  - %', msg; end $$;

-- 1. Recuperación de contraseña por el canal elegido
do $$ declare s record; j jsonb; t0 timestamptz := now(); u1 uuid; code text; code2 text; n int; begin
  set local role servicio;
  u1 := core.registrar_usuario('maria.lopez', 'Clave-Inicial-2026', 'cliente', '+573001112233', 'whatsapp');
  perform core.registrar_usuario('pedro.sms', 'Otra-Clave-2026!', 'cliente', '+573009998877', 'sms');
  begin perform core.registrar_usuario('maria.lopez', 'Clave-Inicial-2026', 'cliente', '+573001112233'); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'usuario repetido rechazado'); end;
  begin perform core.registrar_usuario('debil', 'corta', 'cliente', '+573001112233'); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'clave débil rechazada'); end;
  begin perform core.registrar_usuario('mal.cel', 'Clave-Inicial-2026', 'cliente', '3001112233'); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'celular sin +57 rechazado'); end;
  perform pg_temp.ok((core.verificar_login('maria.lopez', 'Clave-Inicial-2026') ->> 'ok')::boolean, 'login correcto');
  select * into s from core.solicitar_recuperacion('pedro.sms', t0); perform pg_temp.ok(s.channel = 'sms' and s.phone = '+573009998877' and s.code ~ '^[0-9]{6}$', 'el código va por SMS al celular registrado');
  select * into s from core.solicitar_recuperacion('maria.lopez', t0); code := s.code;
  perform pg_temp.ok(s.channel = 'whatsapp' and s.phone = '+573001112233', 'el código va por WhatsApp al celular registrado');
  perform pg_temp.ok((select count(*) from core.solicitar_recuperacion('no.existe', t0)) = 0, 'usuario inexistente: 0 filas (el servicio responde igual)');
  perform pg_temp.ok(not (core.restablecer_clave('maria.lopez', '000000', 'Nueva-Clave-2027!', t0 + interval '1 minute') ->> 'ok')::boolean, 'código incorrecto rechazado');
  perform pg_temp.ok(not (core.restablecer_clave('maria.lopez', code, 'corta', t0 + interval '2 minutes') ->> 'ok')::boolean, 'clave nueva débil rechazada (el código sigue vigente)');
  perform pg_temp.ok((core.restablecer_clave('maria.lopez', code, 'Nueva-Clave-2027!', t0 + interval '3 minutes') ->> 'ok')::boolean, 'con el código correcto cambia la contraseña');
  perform pg_temp.ok(not (core.restablecer_clave('maria.lopez', code, 'Otra-Mas-2028!x', t0 + interval '4 minutes') ->> 'ok')::boolean, 'el código sirve una sola vez');
  perform pg_temp.ok((core.verificar_login('maria.lopez', 'Nueva-Clave-2027!') ->> 'ok')::boolean and not (core.verificar_login('maria.lopez', 'Clave-Inicial-2026') ->> 'ok')::boolean, 'la clave vieja ya no entra');
  select * into s from core.solicitar_recuperacion('maria.lopez', t0 + interval '10 minutes'); code2 := s.code;
  perform pg_temp.ok(not (core.restablecer_clave('maria.lopez', code2, 'Nueva-Clave-2029!', t0 + interval '21 minutes') ->> 'ok')::boolean, 'el código vence a los 10 minutos');
  select * into s from core.solicitar_recuperacion('maria.lopez', t0 + interval '30 minutes');
  for n in 1..5 loop perform core.restablecer_clave('maria.lopez', '111111', 'Nueva-Clave-2030!', t0 + interval '31 minutes'); end loop;
  perform pg_temp.ok(not (core.restablecer_clave('maria.lopez', s.code, 'Nueva-Clave-2030!', t0 + interval '32 minutes') ->> 'ok')::boolean, '5 intentos erróneos queman el código aunque luego acierten');
  begin perform core.solicitar_recuperacion('maria.lopez', t0 + interval '33 minutes'); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT429' then perform pg_temp.ok(true, 'máximo 3 códigos por hora: ' || sqlerrm); end;
  for n in 1..5 loop perform core.verificar_login('pedro.sms', 'mala-clave', t0); end loop;
  perform pg_temp.ok((core.verificar_login('pedro.sms', 'Otra-Clave-2026!', t0 + interval '1 minute') ->> 'msg') like 'Cuenta bloqueada%', '5 logins fallidos bloquean la cuenta');
  perform pg_temp.ok((core.verificar_login('pedro.sms', 'Otra-Clave-2026!', t0 + interval '6 minutes') ->> 'ok')::boolean, 'el bloqueo termina a los 5 minutos');
  reset role;
  begin set local role restaurante; perform count(*) from core.users; perform pg_temp.ok(false,'x'); exception when insufficient_privilege then perform pg_temp.ok(true, 'ningún rol de la API puede leer usuarios ni hashes'); end;
  reset role;
end $$;

-- 2. Pagos: valor calculado por la base, comisión de $200, el resto al restaurante, idempotencia
do $$ declare r uuid; cu uuid := gen_random_uuid(); i1 uuid; i2 uuid; i3 uuid; q jsonb; res jsonb; res2 jsonb; ord uuid; begin
  insert into core.restaurants(name) values ('Asadero Pago') returning id into r;
  set local role servicio;
  i1 := core.cargar_item(r, 'Pollo', 'Pollo asado', 30500, 'Entero', 'https://ejemplo.invalid/carta');
  i2 := core.cargar_item(r, 'Bebidas', 'Gaseosa', 3500, null, 'https://ejemplo.invalid/carta');
  q := core.crear_intencion_pago(cu, r, jsonb_build_array(jsonb_build_object('id', i1, 'q', 1), jsonb_build_object('id', i2, 'q', 2)));
  perform pg_temp.ok((q ->> 'total')::int = 37500 and (q ->> 'fee')::int = 200 and (q ->> 'net')::int = 37300 and (q ->> 'amount_in_cents')::bigint = 3750000, 'total 37.500: comisión 200, restaurante 37.300 (calculado por la base)');
  begin perform core.crear_intencion_pago(cu, r, jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'q', 1))); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'producto que no está en la carta rechazado'); end;
  res := core.confirmar_pago(q ->> 'reference', 'tx-1', 'APPROVED', 100);
  perform pg_temp.ok(not (res ->> 'ok')::boolean, 'monto pagado distinto al pedido: no crea pedido');
  q := core.crear_intencion_pago(cu, r, jsonb_build_array(jsonb_build_object('id', i1, 'q', 1)));
  res := core.confirmar_pago(q ->> 'reference', 'tx-2', 'DECLINED', 3050000);
  reset role; perform pg_temp.ok((select count(*) from core.orders where payment_ref = q ->> 'reference') = 0, 'pago rechazado: no hay pedido'); set local role servicio;
  q := core.crear_intencion_pago(cu, r, jsonb_build_array(jsonb_build_object('id', i1, 'q', 1)));
  res := core.confirmar_pago(q ->> 'reference', 'tx-3', 'APPROVED', 3050000, 'PSE'); ord := (res ->> 'order_id')::uuid;
  perform pg_temp.ok((res ->> 'ok')::boolean and (res ->> 'comision_nova')::int = 200 and (res ->> 'para_el_negocio')::int = 30300, 'pago de $30.500 aprobado: Nova $200, restaurante $30.300');
  res2 := core.confirmar_pago(q ->> 'reference', 'tx-3', 'APPROVED', 3050000, 'PSE'); reset role;
  perform pg_temp.ok((res2 ->> 'repetido')::boolean and (select count(*) from core.orders where restaurant_id = r) = 1 and (select count(*) from core.payouts where restaurant_id = r) = 1, 'el aviso repetido de la pasarela no duplica pedido ni pago');
  perform pg_temp.ok((select amount from core.payouts where order_id = ord) = 30300 and (select status from core.payouts where order_id = ord) = 'pendiente', 'queda un pago pendiente de $30.300 para el restaurante');
  set local role admin_nova; perform pg_temp.ok((select monto_pendiente from api.por_pagar where restaurant_id = r) = 30300, 'administración ve cuánto debe pagar a cada negocio'); reset role;
  -- con un canje activo la comisión es $0
  perform core.lock_account(r); update core.restaurant_accounts set tokens_balance = 50 where restaurant_id = r;
  insert into core.token_ledger(account_id, event_type, tokens, balance_after, expiry_at) select id, 'earn', 50, 50, now() + interval '30 days' from core.restaurant_accounts where restaurant_id = r;
  perform core.canjear_tokens(r, 'semana');
  set local role servicio; q := core.crear_intencion_pago(cu, r, jsonb_build_array(jsonb_build_object('id', i1, 'q', 1))); reset role;
  perform pg_temp.ok((q ->> 'fee')::int = 0 and (q ->> 'net')::int = 30500, 'con canje activo: comisión $0, el restaurante recibe los $30.500');
end $$;

-- 3. Entregas y mapa: privacidad entre restaurantes y clientes
do $$ declare ra uuid; rb uuid; cu uuid := gen_random_uuid(); cu2 uuid := gen_random_uuid(); oa uuid; ca uuid; cb uuid; did uuid; sg jsonb; begin
  insert into core.restaurants(name) values ('Rest A') returning id into ra; insert into core.restaurants(name) values ('Rest B') returning id into rb;
  insert into core.orders(restaurant_id, customer_id, items, total, fee, status) values (ra, cu, '[]', 20000, 200, 'preparando') returning id into oa;
  perform set_config('request.jwt.claims', json_build_object('role','restaurante','restaurant_id',ra)::text, true);
  set local role restaurante;
  ca := api.registrar_repartidor('Juan Domiciliario', '+573101234567');
  begin perform api.registrar_repartidor('X', '123'); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'celular de repartidor inválido rechazado'); end;
  did := api.asignar_repartidor(oa, ca, 2.9273, -75.2819, 'Cra 5 # 8-20, Neiva', 2.9300, -75.2900);
  perform pg_temp.ok(did is not null, 'el restaurante asigna SU domiciliario a SU pedido');
  begin perform api.asignar_repartidor(oa, ca, 2.93, -75.28); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'un pedido no puede tener dos domiciliarios'); end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','repartidor','courier_id',ca)::text, true);
  set local role repartidor;
  perform api.reportar_posicion(2.9290, -75.2880); perform api.reportar_posicion(2.9289, -75.2879);
  reset role; perform pg_temp.ok((select count(*) from core.courier_positions) = 1, 'un segundo punto antes de 3 s se descarta (límite de frecuencia)'); update core.courier_positions set recorded_at = recorded_at - interval '10 seconds'; set local role repartidor;
  perform api.reportar_posicion(2.9285, -75.2850);
  reset role; perform pg_temp.ok((select count(*) from core.courier_positions) = 2, 'el domiciliario envía su ubicación (máx. 1 cada 3 s)'); set local role repartidor;
  begin perform api.reportar_posicion(40.0, -3.7); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT400' then perform pg_temp.ok(true, 'ubicación fuera de Colombia rechazada'); end;
  perform api.actualizar_entrega('recogido'); perform api.actualizar_entrega('en-camino');
  begin perform api.actualizar_entrega('asignado'); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT409' then perform pg_temp.ok(true, 'no se retrocede de estado'); end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','cliente','sub',cu)::text, true);
  set local role cliente; sg := api.seguimiento(oa);
  perform pg_temp.ok(sg #>> '{entrega,repartidor,nombre}' = 'Juan Domiciliario' and jsonb_array_length(sg #> '{entrega,ruta}') = 2 and (sg #>> '{entrega,destino,lat}')::numeric = 2.9273, 'el cliente ve su repartidor, el destino y la ruta recorrida');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('role','cliente','sub',cu2)::text, true);
  set local role cliente; begin perform api.seguimiento(oa); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT404' then perform pg_temp.ok(true, 'otro cliente NO puede ver ese recorrido'); end; reset role;
  perform set_config('request.jwt.claims', json_build_object('role','restaurante','restaurant_id',rb)::text, true);
  set local role restaurante; begin perform api.seguimiento(oa); perform pg_temp.ok(false,'x'); exception when sqlstate 'PT404' then perform pg_temp.ok(true, 'otro restaurante NO puede ver ese recorrido'); end; reset role;
  perform set_config('request.jwt.claims', json_build_object('role','repartidor','courier_id',ca)::text, true);
  set local role repartidor; perform api.actualizar_entrega('entregado');
  begin perform count(*) from core.deliveries; perform pg_temp.ok(false,'x'); exception when insufficient_privilege then perform pg_temp.ok(true, 'el domiciliario no lee tablas, solo envía su ubicación'); end; reset role;
  perform pg_temp.ok((select status from core.orders where id = oa) = 'entregado' and (select orders_completed from core.restaurant_accounts where restaurant_id = ra) = 1, 'al entregar, el pedido queda entregado y suma al contador de tokens');
  set local role repartidor; perform api.reportar_posicion(2.9, -75.2); reset role;
  perform pg_temp.ok((select count(*) from core.courier_positions) = 2, 'sin entrega activa no se guarda ubicación (no hay rastreo fuera del pedido)');
end $$;
