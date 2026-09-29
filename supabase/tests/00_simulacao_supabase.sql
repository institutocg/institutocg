-- Simula o mínimo do Supabase (papéis, esquema auth e auth.uid()) para testar
-- as migrações num PostgreSQL comum. NÃO é aplicado no Supabase real.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text,
  raw_user_meta_data  jsonb not null default '{}'::jsonb
);

create function auth.uid() returns uuid
language sql stable
as $$
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    ), '')::uuid;
$$;

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Mesmos privilégios padrão que o Supabase concede (o RLS é quem restringe).
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
