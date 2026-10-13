#!/usr/bin/env bash
# Gera supabase/versao-teste/atualizar-tudo.sql: junta as atualizações recentes
# da versão de teste num só arquivo para colar no SQL Editor. Cada parte só roda
# se ainda não foi aplicada (pode colar mesmo que já tenha colado alguma antes).
#   ./scripts/gerar-atualizacao-teste.sh            → regrava o arquivo
#   ./scripts/gerar-atualizacao-teste.sh --conferir → falha se estiver desatualizado
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$RAIZ/supabase/versao-teste"
DESTINO="$DIR/atualizar-tudo.sql"

# arquivo | condição que indica que ainda NÃO foi aplicado
PARTES=(
  "atualizar-seguranca-e-campanha-personalizada.sql|not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'campanhas' and column_name = 'filtros')"
  "atualizar-campanhas-simples.sql|to_regprocedure('public.vindas(uuid)') is null"
  "atualizar-receituario.sql|to_regclass('public.receitas') is null"
)

gerar() {
  cat <<'CAB'
-- =============================================================================
-- Instituto CG — ATUALIZAR A VERSÃO DE TESTE (tudo de uma vez)
--
-- Arquivo gerado por scripts/gerar-atualizacao-teste.sh — não edite à mão.
--
-- Cole no SQL Editor do projeto de TESTE e clique em "Run".
-- Pode colar mesmo que já tenha aplicado alguma atualização antes: o que já
-- existe é pulado. Os dados que você colocou continuam lá.
-- Inclui: segurança reforçada, campanhas novas ("Criar a minha campanha") e
-- receituário.
-- =============================================================================

CAB
  local n=0
  for parte in "${PARTES[@]}"; do
    n=$((n + 1))
    local arquivo="${parte%%|*}" condicao="${parte#*|}"
    printf -- '-- ---------------------------------------------------------------------------\n'
    printf -- '-- Parte %d: %s\n' "$n" "$arquivo"
    printf -- '-- ---------------------------------------------------------------------------\n'
    printf 'do $parte%d$\nbegin\n  if %s then\n    execute $atualizacao%d$\n' "$n" "$condicao" "$n"
    # Sem o begin/commit do arquivo (aqui tudo roda junto).
    sed -e '/^begin;$/d' -e '/^commit;$/d' "$DIR/$arquivo"
    printf '$atualizacao%d$;\n    raise notice %s;\n  else\n    raise notice %s;\n  end if;\nend $parte%d$;\n\n' \
      "$n" "'Parte $n aplicada.'" "'Parte $n já estava aplicada — pulada.'" "$n"
  done
  cat <<'FIM'
select 'Versão de teste atualizada. No site: Configurações → Versão de teste → "Recomeçar com dados de exemplo" para ver os exemplos novos.' as resultado;
FIM
}

if [ "${1:-}" = "--conferir" ]; then
  if ! diff -q <(gerar) "$DESTINO" >/dev/null 2>&1; then
    echo "supabase/versao-teste/atualizar-tudo.sql está desatualizado: rode ./scripts/gerar-atualizacao-teste.sh" >&2
    exit 1
  fi
  echo "✓ atualizar-tudo.sql em dia."
else
  gerar > "$DESTINO"
  echo "Gerado: supabase/versao-teste/atualizar-tudo.sql ($(wc -c < "$DESTINO") bytes)"
fi
