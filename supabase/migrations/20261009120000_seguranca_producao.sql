-- =============================================================================
-- Migração 17: endurecimento para produção
--   A chave pública do Supabase (anon) fica no navegador. Quem não fez login não
--   deve conseguir chamar nenhuma função nem ler nenhuma tabela — nem as que já
--   checam acesso por dentro. O sistema conversa com o banco pelo servidor, sempre
--   como usuária logada ("authenticated"), então nada aqui muda para quem usa.
--   Funções internas que já eram fechadas para "authenticated" continuam fechadas.
-- =============================================================================

revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
