#!/bin/bash
# Reinicia la base local de prueba y el servidor imitación de Supabase, y corre la prueba de punta a punta.
PGB=/usr/lib/postgresql/16/bin
su postgres -c "$PGB/psql -q -h /tmp/pgw -p 5433 -d sbtest -c 'truncate public.docs; delete from public.admins; delete from auth.users;'" >/dev/null
curl -s -m 2 localhost:54321/__reset >/dev/null || { node "$(dirname "$0")/mock-supabase.js" > /tmp/mock.log 2>&1 & sleep 1; }
node "$(dirname "$0")/e2e.js"
