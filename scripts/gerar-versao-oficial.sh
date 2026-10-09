#!/usr/bin/env bash
# Gera supabase/producao/instalar.sql: um único arquivo para colar no SQL Editor
# do projeto Supabase OFICIAL (uso real). Só a estrutura e a configuração inicial
# do Instituto CG — sem pacientes fictícios e sem modo de teste.
#   ./scripts/gerar-versao-oficial.sh            → regrava o arquivo
#   ./scripts/gerar-versao-oficial.sh --conferir → falha se o arquivo estiver desatualizado
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="$RAIZ/supabase/producao/instalar.sql"

gerar() {
  cat <<'CAB'
-- =============================================================================
-- Instituto CG — VERSÃO OFICIAL (uso real)
--
-- Arquivo gerado por scripts/gerar-versao-oficial.sh — não edite à mão.
--
-- Como usar: no projeto Supabase OFICIAL (novo e vazio, separado do de teste),
-- abra o SQL Editor, cole este arquivo inteiro e clique em "Run" (uma vez só).
-- Depois siga docs/PUBLICACAO_OFICIAL.md (criar os logins com equipe.sql).
--
-- Não contém pacientes fictícios nem o modo de teste.
-- =============================================================================

begin;

CAB
  for arquivo in "$RAIZ"/supabase/migrations/*.sql; do
    printf '\n-- ---------------------------------------------------------------------------\n'
    printf -- '-- %s\n' "$(basename "$arquivo")"
    printf -- '-- ---------------------------------------------------------------------------\n\n'
    cat "$arquivo"
  done
  cat <<'FIM'

-- ---------------------------------------------------------------------------
-- Configuração inicial do Instituto CG (procedimentos, etapas, regras e
-- mensagens padrão). Tudo pode ser ajustado depois em Configurações.
-- ---------------------------------------------------------------------------

select public.inicializar_clinica('Instituto CG');

commit;

select 'Instalado. Agora crie os logins (docs/PUBLICACAO_OFICIAL.md, passo 3).' as resultado;
FIM
}

if [ "${1:-}" = "--conferir" ]; then
  if ! diff -q <(gerar) "$DESTINO" >/dev/null 2>&1; then
    echo "supabase/producao/instalar.sql está desatualizado: rode ./scripts/gerar-versao-oficial.sh" >&2
    exit 1
  fi
  echo "✓ versão oficial (instalar.sql) em dia."
else
  gerar > "$DESTINO"
  echo "Gerado: supabase/producao/instalar.sql ($(wc -c < "$DESTINO") bytes)"
fi
