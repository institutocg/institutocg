#!/usr/bin/env bash
# Banco PostgreSQL local para desenvolvimento e testes de tela (sem Supabase).
#   ./scripts/banco-local.sh iniciar   → cria (se preciso) e sobe o banco com dados fictícios
#   ./scripts/banco-local.sh recriar   → apaga e cria de novo (dados fictícios "frescos")
#   ./scripts/banco-local.sh parar
# Conexão: postgres://postgres@localhost:54330/postgres
#
# Usuárias de teste (login de desenvolvimento, só e-mail):
#   dona@institutocg.local        administradora do Instituto CG (dados fictícios)
#   secretaria@institutocg.local  secretária do Instituto CG
#   vazia@teste.local             administradora de uma clínica sem nenhuma tarefa
#   semacesso@teste.local         login sem acesso liberado
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PORTA="${PORTA_BANCO_LOCAL:-54330}"
DIR="${DIR_BANCO_LOCAL:-${TMPDIR:-/tmp}/crm-banco-local}"

rodar() { if [ "$(id -u)" = "0" ]; then runuser -u postgres -- "$@"; else "$@"; fi; }
PSQL=(psql -h localhost -p "$PORTA" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)

ativo() { rodar "$PG_BIN/pg_ctl" -D "$DIR/pg" status >/dev/null 2>&1; }

parar() { ativo && rodar "$PG_BIN/pg_ctl" -D "$DIR/pg" -m fast stop >/dev/null || true; }

iniciar() {
  if [ ! -d "$DIR/pg" ]; then
    mkdir -p "$DIR"; [ "$(id -u)" = "0" ] && chown postgres "$DIR"
    rodar "$PG_BIN/initdb" -D "$DIR/pg" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
    NOVO=1
  fi
  ativo || rodar "$PG_BIN/pg_ctl" -D "$DIR/pg" -l "$DIR/postgres.log" \
    -o "-p $PORTA -k $DIR -c listen_addresses=localhost" -w start >/dev/null

  if [ "${NOVO:-0}" = "1" ]; then
    "${PSQL[@]}" -f "$RAIZ/supabase/tests/00_simulacao_supabase.sql"
    for f in "$RAIZ"/supabase/migrations/*.sql; do "${PSQL[@]}" -f "$f"; done
    "${PSQL[@]}" -f "$RAIZ/supabase/seed.sql"
    "${PSQL[@]}" -o /dev/null <<'SQL'
insert into auth.users (email, raw_user_meta_data) values
  ('dona@institutocg.local', '{"nome": "Dra. Cristina"}'),
  ('secretaria@institutocg.local', '{"nome": "Júlia Andrade"}'),
  ('vazia@teste.local', '{"nome": "Teste Vazio"}'),
  ('semacesso@teste.local', '{"nome": "Sem Acesso"}');
select public.adicionar_membro((select id from public.clinicas where nome = 'Instituto CG'), 'dona@institutocg.local', 'admin');
select public.adicionar_membro((select id from public.clinicas where nome = 'Instituto CG'), 'secretaria@institutocg.local', 'comercial');
select public.adicionar_membro(public.inicializar_clinica('Clínica Vazia'), 'vazia@teste.local', 'admin');
SQL
    echo "Banco local criado com dados fictícios."
  fi
  echo "DATABASE_URL=postgres://postgres@localhost:$PORTA/postgres"
}

case "${1:-iniciar}" in
  iniciar) iniciar ;;
  parar) parar ;;
  recriar) parar; rm -rf "$DIR"; iniciar ;;
  *) echo "uso: $0 iniciar|recriar|parar"; exit 1 ;;
esac
