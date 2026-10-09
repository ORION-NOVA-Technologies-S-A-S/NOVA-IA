-- Paso 2: convierte tu cuenta de la página en administración de Nova.
-- Primero crea tu cuenta en la página (Crear cuenta). Luego cambia el usuario si es otro y ejecuta.
insert into public.admins (uid)
select id from auth.users where email = lower('CarlosC06') || '@usuarios.novaia.app'
on conflict do nothing;
select email, 'ahora es administración' as estado
from auth.users where id in (select uid from public.admins);
