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

echo "✓ Banco de dados verificado."
