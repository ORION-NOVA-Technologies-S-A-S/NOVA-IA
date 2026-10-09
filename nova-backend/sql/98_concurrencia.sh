#!/usr/bin/env bash
# Dos sesiones completan 20 pedidos cada una, al mismo tiempo, sobre el mismo restaurante: deben salir exactamente 2 tokens.
P="psql -h ${PGHOST:-/tmp/pgw} -p ${PGPORT:-5433} -U postgres -d ${PGDATABASE:-nova} -v ON_ERROR_STOP=1 -q -At"
R=$($P -c "insert into core.restaurants(name) values ('Concurrencia') returning id")
$P -c "insert into core.orders(restaurant_id, customer_id, items, total, fee) select '$R', gen_random_uuid(), '[]', 1000, 200 from generate_series(1,40)"
IDS=$($P -c "select id from core.orders where restaurant_id='$R' order by id")
echo "$IDS" | sed -n '1,20p'  > /tmp/pgw/a.ids; echo "$IDS" | sed -n '21,40p' > /tmp/pgw/b.ids
run() { while read -r id; do $P -c "select core.procesar_pedido_completado('$id')" >/dev/null; done < "$1"; }
run /tmp/pgw/a.ids & run /tmp/pgw/b.ids & wait
$P -c "select 'pedidos=' || orders_completed || ' tokens=' || tokens_balance || ' ledger_earn=' || (select count(*) from core.token_ledger where account_id=a.id and event_type='earn') from core.restaurant_accounts a where restaurant_id='$R'"
