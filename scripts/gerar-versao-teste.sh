#!/usr/bin/env bash
# Gera supabase/versao-teste/instalar.sql: um único arquivo para colar no SQL
# Editor de um projeto Supabase NOVO e ter a versão de teste completa
# (estrutura + dados fictícios + logins de teste).
#   ./scripts/gerar-versao-teste.sh            → regrava o arquivo
#   ./scripts/gerar-versao-teste.sh --conferir → falha se o arquivo estiver desatualizado
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="$RAIZ/supabase/versao-teste/instalar.sql"

gerar() {
  cat <<'CAB'
-- =============================================================================
-- Instituto CG — VERSÃO DE TESTE (dados fictícios)
--
-- Arquivo gerado por scripts/gerar-versao-teste.sh — não edite à mão.
--
-- Como usar: num projeto Supabase NOVO, só para testes, abra o SQL Editor,
-- cole este arquivo inteiro e clique em "Run". No fim aparecem os e-mails e as
-- senhas dos logins de teste (anote).
--
-- NUNCA rode este arquivo no projeto de produção: ele cria pacientes fictícios
-- e liga o modo de teste.
-- =============================================================================

begin;

CAB
  for arquivo in "$RAIZ"/supabase/migrations/*.sql; do
    printf '\n-- ---------------------------------------------------------------------------\n'
    printf -- '-- %s\n' "$(basename "$arquivo")"
    printf -- '-- ---------------------------------------------------------------------------\n\n'
    cat "$arquivo"
  done
  printf '\n-- ---------------------------------------------------------------------------\n'
  printf -- '-- Dados fictícios e modo de teste (seed.sql)\n'
  printf -- '-- ---------------------------------------------------------------------------\n\n'
  cat "$RAIZ/supabase/seed.sql"
  cat <<'FIM'

commit;

-- Logins de teste: anote o e-mail e a senha de cada um.
-- (Para gerar senhas novas depois: select * from teste.criar_logins_de_teste();)
select * from teste.criar_logins_de_teste();
FIM
}

if [ "${1:-}" = "--conferir" ]; then
  if ! diff -q <(gerar) "$DESTINO" >/dev/null 2>&1; then
    echo "supabase/versao-teste/instalar.sql está desatualizado: rode ./scripts/gerar-versao-teste.sh" >&2
    exit 1
  fi
  echo "✓ instalar.sql em dia."
else
  gerar > "$DESTINO"
  echo "Gerado: supabase/versao-teste/instalar.sql ($(wc -c < "$DESTINO") bytes)"
fi
