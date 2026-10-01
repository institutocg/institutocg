-- =============================================================================
-- Testes da versão de teste (roda por último: "recomeçar" apaga tudo).
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

\echo '— Modo de teste'
select testes.ok(public.ambiente_teste(), 'com os dados fictícios carregados, o sistema está em modo de teste');

\echo '— Logins de teste'
select set_config('t.logins', (select jsonb_agg(l)::text from teste.criar_logins_de_teste() l), false);
select testes.ok((select jsonb_array_length(current_setting('t.logins')::jsonb) = 2
                     and (current_setting('t.logins')::jsonb -> 0 ->> 'email') = 'dona@teste.institutocg.com.br'
                     and (current_setting('t.logins')::jsonb -> 0 ->> 'senha') ~ '^cg-[0-9a-f]{4}-[0-9a-f]{4}$'),
  'cria os logins da dona e da secretária, com senha');
select testes.ok((select string_agg(u.email || ':' || m.papel, ' ' order by u.email)
                    from public.membros m join public.usuarios u on u.id = m.usuario_id
                    join public.clinicas c on c.id = m.clinica_id
                   where u.email like '%@teste.institutocg.com.br' and c.nome = 'Instituto CG')
                 = 'dona@teste.institutocg.com.br:admin secretaria@teste.institutocg.com.br:comercial',
  'dona entra como administradora e secretária como comercial no Instituto CG');
select teste.criar_logins_de_teste();
select testes.ok((select count(*) from auth.users where email like '%@teste.institutocg.com.br') = 2,
  'rodar de novo não duplica os logins (só troca as senhas)');

\echo '— Recomeçar com dados de exemplo'
reset role; select testes.entrar('secretaria@teste.institutocg.com.br'); set role authenticated;
select testes.erro($$select teste.recomecar()$$, 'Só a administradora', 'a secretária não recomeça a versão de teste');
select testes.erro($$select teste.criar_logins_de_teste()$$, 'permission denied', 'logins de teste: só pelo SQL Editor');

reset role; select testes.entrar('dona@teste.institutocg.com.br'); set role authenticated;
insert into public.pessoas (clinica_id, nome, whatsapp_e164)
values ((select clinica_id from public.membros where usuario_id = auth.uid()), 'Paciente Criada no Teste', '+5511955550000');
select set_config('t.antes', (select clinica_id::text from public.membros where usuario_id = auth.uid()), false);
select teste.recomecar();
select testes.ok(not exists (select 1 from public.pessoas where nome = 'Paciente Criada no Teste')
             and exists (select 1 from public.pessoas where nome = 'Beatriz Almeida')
             and exists (select 1 from public.v_tarefas_abertas),
  'recomeçar apaga o que foi feito e recria as situações de exemplo (com tarefas)');
select testes.ok((select clinica_id::text <> current_setting('t.antes') and papel = 'admin'
                    from public.membros where usuario_id = auth.uid())
             and exists (select 1 from public.membros m join public.usuarios u on u.id = m.usuario_id
                          where u.email = 'secretaria@teste.institutocg.com.br' and m.papel = 'comercial'),
  'os logins continuam valendo, com os mesmos papéis');
reset role;
select testes.ok((select count(*) from public.clinicas) = 1, 'sobra só a clínica de exemplo');

\echo '✓ Versão de teste verificada.'
