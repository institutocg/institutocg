#!/usr/bin/env bash
# Gera supabase/versao-teste/atualizar-tudo.sql: junta as atualizações recentes
# da versão de teste num só arquivo para colar no SQL Editor. Cada parte só roda
# se ainda não foi aplicada (pode colar mesmo que já tenha colado alguma antes).
#   ./scripts/gerar-atualizacao-teste.sh            → regrava o arquivo
#   ./scripts/gerar-atualizacao-teste.sh --conferir → falha se estiver desatualizado
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="$RAIZ/supabase/versao-teste/atualizar-tudo.sql"

# arquivo (relativo a supabase/) | condição para rodar ("sempre" = é seguro repetir).
# Inclui tudo desde a primeira versão de teste (indicadores): quem pulou alguma
# atualização antiga também fica em dia. As partes "sempre" refazem as funções de
# campanha na versão atual (uma parte antiga reaplicada não deixa versão velha).
PARTES=(
  "migrations/20261005120000_agenda_financeiro.sql|not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vendas' and column_name = 'agendamento_id')"
  "migrations/20261006120000_prontuario.sql|to_regclass('public.prontuarios') is null"
  "migrations/20261007120000_prontuario_simples.sql|to_regprocedure('public.procedimento_por_nome(uuid,text)') is null"
  "migrations/20261008120000_mais_campanhas.sql|to_regprocedure('public.campanha_de_relacionamento(text)') is null"
  "migrations/20261009120000_seguranca_producao.sql|sempre"
  "migrations/20261010120000_campanha_personalizada.sql|sempre"
  "migrations/20261012120000_campanhas_enxutas.sql|sempre"
  "migrations/20261013120000_receituario.sql|to_regclass('public.receitas') is null"
  "seed.sql|sempre"
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
-- Inclui tudo desde a primeira versão de teste: agenda, prontuário, campanhas,
-- segurança reforçada, "Criar a minha campanha" e receituário.
-- =============================================================================

CAB
  local n=0
  for parte in "${PARTES[@]}"; do
    n=$((n + 1))
    local arquivo="${parte%%|*}" condicao="${parte#*|}"
    [ "$condicao" = "sempre" ] && condicao="true"
    printf -- '-- ---------------------------------------------------------------------------\n'
    printf -- '-- Parte %d: %s\n' "$n" "$arquivo"
    printf -- '-- ---------------------------------------------------------------------------\n'
    printf 'do $parte%d$\nbegin\n  if %s then\n    execute $atualizacao%d$\n' "$n" "$condicao" "$n"
    # seed.sql: só as funções da versão de teste (sem recarregar os dados).
    grep -v '^select teste.carregar_dados_ficticios();$' "$RAIZ/supabase/$arquivo"
    printf '$atualizacao%d$;\n    raise notice %s;\n  else\n    raise notice %s;\n  end if;\nend $parte%d$;\n\n' \
      "$n" "'Parte $n aplicada.'" "'Parte $n já estava aplicada — pulada.'" "$n"
  done
  cat <<'SEG'
-- Ninguém sem login chama funções (vale também para o que foi criado acima).
revoke execute on all functions in schema public from public, anon;

SEG
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
