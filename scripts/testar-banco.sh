#!/usr/bin/env bash
# Sobe um PostgreSQL temporário, aplica as migrações e roda os testes de
# integridade do banco. Uso: npm run test:db
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PORTA="${PORTA:-54329}"
DADOS="$(mktemp -d)"
LOG="$DADOS/postgres.log"

# O PostgreSQL não roda como root: usa o usuário "postgres" quando necessário.
rodar() {
  if [ "$(id -u)" = "0" ]; then runuser -u postgres -- "$@"; else "$@"; fi
}

limpar() {
  rodar "$PG_BIN/pg_ctl" -D "$DADOS/pg" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$DADOS"
}
trap limpar EXIT

[ "$(id -u)" = "0" ] && chown postgres "$DADOS"
rodar "$PG_BIN/initdb" -D "$DADOS/pg" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
rodar "$PG_BIN/pg_ctl" -D "$DADOS/pg" -l "$LOG" -o "-p $PORTA -k $DADOS -c listen_addresses=''" -w start >/dev/null

PSQL=(psql -h "$DADOS" -p "$PORTA" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)

echo "→ Simulação do Supabase"
"${PSQL[@]}" -f "$RAIZ/supabase/tests/00_simulacao_supabase.sql"

for arquivo in "$RAIZ"/supabase/migrations/*.sql; do
  echo "→ Migração $(basename "$arquivo")"
  "${PSQL[@]}" -f "$arquivo"
done

if [ "${COM_SEED:-1}" = "1" ] && [ -f "$RAIZ/supabase/seed.sql" ]; then
  echo "→ Dados fictícios (seed.sql)"
  "${PSQL[@]}" -f "$RAIZ/supabase/seed.sql"
fi

for arquivo in "$RAIZ"/supabase/tests/[1-9]*.sql; do
  [ -e "$arquivo" ] || continue
  echo "→ Testes $(basename "$arquivo")"
  "${PSQL[@]}" -f "$arquivo" 2>&1 | sed 's/^psql:[^ ]* NOTICE:  /  /'
done

echo "→ Versão de teste (supabase/versao-teste/instalar.sql)"
"$RAIZ/scripts/gerar-versao-teste.sh" --conferir
"${PSQL[@]}" -c "create database instalacao" >/dev/null
INST=(psql -h "$DADOS" -p "$PORTA" -U postgres -d instalacao -v ON_ERROR_STOP=1 -q -X)
"${INST[@]}" -f "$RAIZ/supabase/tests/00_simulacao_supabase_real.sql"
LOGINS="$("${INST[@]}" -At -F '|' -f "$RAIZ/supabase/versao-teste/instalar.sql" | grep '@teste.institutocg.com.br')"
[ "$(echo "$LOGINS" | wc -l)" = "2" ] || { echo "FALHOU: instalar.sql não mostrou os 2 logins" >&2; exit 1; }
while IFS='|' read -r _perfil email senha; do
  ok="$("${INST[@]}" -At -c "select count(*) from auth.users u join auth.identities i on i.user_id = u.id and i.provider = 'email'
    join public.membros m on m.usuario_id = u.id
    where u.email = '$email' and u.encrypted_password = extensions.crypt('$senha', u.encrypted_password)
      and u.email_confirmed_at is not null and u.confirmation_token = '' and u.recovery_token = ''
      and u.email_change_token_new = '' and u.email_change = '' and u.aud = 'authenticated'")"
  [ "$ok" = "1" ] || { echo "FALHOU: login de teste $email" >&2; exit 1; }
  echo "  ok - login de teste $email (senha confere, e-mail confirmado, acesso à clínica)"
done <<< "$LOGINS"
[ "$("${INST[@]}" -At -c "select public.ambiente_teste() and (select count(*) from public.pessoas) > 10")" = "t" ] \
  || { echo "FALHOU: dados fictícios / modo de teste" >&2; exit 1; }
echo "  ok - estrutura, dados fictícios e modo de teste instalados num único arquivo"

echo "→ Versão oficial (supabase/producao/instalar.sql + equipe.sql)"
"$RAIZ/scripts/gerar-versao-oficial.sh" --conferir
"${PSQL[@]}" -c "create database oficial" >/dev/null
OFI=(psql -h "$DADOS" -p "$PORTA" -U postgres -d oficial -v ON_ERROR_STOP=1 -q -X)
"${OFI[@]}" -f "$RAIZ/supabase/tests/00_simulacao_supabase_real.sql"
"${OFI[@]}" -f "$RAIZ/supabase/producao/instalar.sql" >/dev/null
[ "$("${OFI[@]}" -At -c "select not public.ambiente_teste() and (select count(*) from public.clinicas) = 1
    and (select nome from public.clinicas) = 'Instituto CG' and not exists (select 1 from public.pessoas)
    and not exists (select 1 from pg_namespace where nspname = 'teste')
    and exists (select 1 from public.procedimentos) and exists (select 1 from public.etapas_funil)")" = "t" ] \
  || { echo "FALHOU: versão oficial deveria ter só a clínica configurada, sem dados fictícios" >&2; exit 1; }
echo "  ok - versão oficial: Instituto CG configurado, sem pacientes, sem modo de teste"
# Logins criados pelo painel do Supabase ("Add user"), depois equipe.sql com os e-mails trocados.
"${OFI[@]}" -c "insert into auth.users (id, email, aud, role, email_confirmed_at) values
  (gen_random_uuid(), 'dra@clinica.com.br', 'authenticated', 'authenticated', now()),
  (gen_random_uuid(), 'secretaria@clinica.com.br', 'authenticated', 'authenticated', now())" >/dev/null
EQUIPE="$(sed -e 's/email-da-dra-cristina@exemplo.com/dra@clinica.com.br/' -e 's/email-da-secretaria@exemplo.com/secretaria@clinica.com.br/' \
  "$RAIZ/supabase/producao/equipe.sql")"
for _ in 1 2; do echo "$EQUIPE" | "${OFI[@]}" >/dev/null; done
[ "$("${OFI[@]}" -At -c "select string_agg(u.email || ':' || m.papel || ':' || (m.papel = 'admin' or m.pode_ver_prontuario), ' ' order by u.email)
    from public.membros m join public.usuarios u on u.id = m.usuario_id")" = "dra@clinica.com.br:admin:true secretaria@clinica.com.br:comercial:false" ] \
  || { echo "FALHOU: equipe.sql" >&2; exit 1; }
echo "  ok - equipe.sql: administradora e secretária com os acessos certos (rodar de novo não duplica)"
grep -q "email-da-dra-cristina@exemplo.com" "$RAIZ/supabase/producao/equipe.sql" \
  && ! (echo "select 1" | "${OFI[@]}" -f "$RAIZ/supabase/producao/equipe.sql" >/dev/null 2>&1) \
  && echo "  ok - equipe.sql sem trocar os e-mails avisa que o login não existe"

echo "→ Atualizações da versão de teste (sobre a versão anterior)"
"${PSQL[@]}" -c "create database atualizacao" >/dev/null
ATU=(psql -h "$DADOS" -p "$PORTA" -U postgres -d atualizacao -v ON_ERROR_STOP=1 -q -X)
"${ATU[@]}" -f "$RAIZ/supabase/tests/00_simulacao_supabase_real.sql"
for arquivo in "$RAIZ"/supabase/migrations/*.sql; do
  case "$(basename "$arquivo")" in 20261009120000_*|20261010120000_*|20261012120000_*) continue ;; esac
  "${ATU[@]}" -f "$arquivo" >/dev/null
done
"${ATU[@]}" -f "$RAIZ/supabase/seed.sql" >/dev/null
"${ATU[@]}" -f "$RAIZ/supabase/versao-teste/atualizar-seguranca-e-campanha-personalizada.sql" >/dev/null
"${ATU[@]}" -f "$RAIZ/supabase/versao-teste/atualizar-campanhas-simples.sql" >/dev/null
[ "$("${ATU[@]}" -At -c "select public.ambiente_teste() and (select count(*) from public.pessoas) > 10
    and not has_function_privilege('anon', 'public.prever_campanha(uuid, text, int, uuid, boolean, jsonb)', 'execute')
    and has_function_privilege('authenticated', 'public.prever_campanha(uuid, text, int, uuid, boolean, jsonb)', 'execute')
    and has_function_privilege('authenticated', 'public.vindas(uuid)', 'execute')")" = "t" ] \
  || { echo "FALHOU: atualização da versão de teste" >&2; exit 1; }
echo "  ok - aplica sobre a versão de teste anterior sem perder os dados"

echo "✓ Banco de dados verificado."
