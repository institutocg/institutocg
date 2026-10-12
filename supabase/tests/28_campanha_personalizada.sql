-- =============================================================================
-- Testes da campanha personalizada: a administradora escolhe quem entra.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('cp', public.inicializar_clinica('Clínica Personalizada'));
insert into auth.users (email, raw_user_meta_data) values ('dra@pers.local', '{"nome": "Dra. Pers"}'), ('sec@pers.local', '{"nome": "Sec"}');
select public.adicionar_membro(testes.v('cp'), 'dra@pers.local', 'admin');
select public.adicionar_membro(testes.v('cp'), 'sec@pers.local', 'comercial');

create function testes.p_cp(n text, fone text, tipo public.tipo_cadastro, nasc date, bairro text, ult date default null) returns uuid language sql as
  $$ insert into public.pessoas (clinica_id, nome, whatsapp_e164, tipo_cadastro, data_nascimento, bairro, cidade,
                                 ultimo_atendimento_informado, consentimento_marketing)
     values (testes.v('cp'), n, fone, tipo, nasc, bairro, 'São Paulo', ult, true) returning id $$;
create function testes.proc_cp(n text) returns uuid language sql as
  $$ select id from public.procedimentos where clinica_id = testes.v('cp') and nome = n $$;
create function testes.quem_cp(f jsonb, proc uuid default null) returns text language sql as
  $$ select coalesce(string_agg(nome, ', ' order by nome), '')
       from public.prever_campanha(testes.v('cp'), 'personalizada', 1, proc, false, f) $$;
grant execute on all functions in schema testes to authenticated, anon;

select testes.guardar('ana', testes.p_cp('Ana Moema', '+5511900003001', 'paciente_antigo', (testes.hoje() - interval '35 years')::date, 'Moema', testes.hoje() - 400));
select testes.guardar('bia', testes.p_cp('Bia Pinheiros', '+5511900003002', 'paciente_antigo', (testes.hoje() - interval '62 years')::date, 'Pinheiros', testes.hoje() - 40));
select testes.guardar('caio', testes.p_cp('Caio Contato', '+5511900003003', 'novo_contato', (testes.hoje() - interval '28 years')::date, 'Moema'));
insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
values (testes.v('cp'), testes.v('ana'), testes.proc_cp('Clareamento dental'), testes.hoje() - 400);
update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste' where clinica_id = testes.v('cp') and status = 'pendente';

insert into public.agendamentos (clinica_id, pessoa_id, tipo, inicio, status, status_em)
values (testes.v('cp'), testes.v('bia'), 'avaliacao', now() - interval '90 days', 'compareceu', now() - interval '90 days'),
       (testes.v('cp'), testes.v('bia'), 'procedimento', now() - interval '40 days', 'compareceu', now() - interval '40 days');
insert into public.prontuarios (clinica_id, pessoa_id) values (testes.v('cp'), testes.v('bia')) on conflict do nothing;
insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, data)
select testes.v('cp'), id, testes.v('bia'), ((now() - interval '40 days') at time zone 'America/Sao_Paulo')::date
  from public.prontuarios where pessoa_id = testes.v('bia');
update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste' where clinica_id = testes.v('cp') and status = 'pendente';

reset role; select testes.entrar('dra@pers.local'); set role authenticated;
select testes.ok(public.vindas(testes.v('bia')) = 2 and public.vindas(testes.v('caio')) = 0,
  'vindas à clínica: agenda (compareceu) e prontuário, o mesmo dia conta uma vez');

\echo '— Quem entra'
select testes.ok(testes.quem_cp('{}') = 'Ana Moema, Bia Pinheiros, Caio Contato', 'sem filtro: todos que aceitam contato');
select testes.ok(testes.quem_cp('{"publico": "pacientes"}') = 'Ana Moema, Bia Pinheiros', 'só pacientes');
select testes.ok(testes.quem_cp('{"publico": "contatos"}') = 'Caio Contato', 'só contatos que ainda não vieram');
select testes.ok(testes.quem_cp('{"sem_vir_meses": 6}') = 'Ana Moema', 'sem vir há mais de 6 meses');
select testes.ok(testes.quem_cp('{"idade_min": 50}') = 'Bia Pinheiros', 'idade mínima');
select testes.ok(testes.quem_cp('{"idade_min": 25, "idade_max": 40}') = 'Ana Moema, Caio Contato', 'faixa de idade');
select testes.ok(testes.quem_cp('{"local": "moema"}') = 'Ana Moema, Caio Contato', 'bairro, sem diferenciar maiúsculas');
select testes.ok(testes.quem_cp('{"relacao": "fez"}', testes.proc_cp('Clareamento dental')) = 'Ana Moema', 'quem fez o procedimento');
select testes.ok(testes.quem_cp('{"relacao": "interesse"}', testes.proc_cp('Clareamento dental')) = '', 'interesse: quem só fez não entra');
select testes.erro($$select * from public.prever_campanha(testes.v('cp'), 'personalizada', 1, null, false, '{"idade_min": 60, "idade_max": 20}')$$,
  'idade mínima é maior', 'faixa de idade invertida é recusada');
select testes.erro($$select * from public.prever_campanha(testes.v('cp'), 'personalizada', 1, null, false, '{"publico": "x"}')$$,
  'Filtro inválido', 'filtro desconhecido é recusado');

\echo '— Criar'
select public.criar_campanha(testes.v('cp'), 'Moema', 'personalizada', 1, null, false,
  'Olá, {{nome}}! Novidade para quem mora perto: estamos com novos horários.', 10, testes.hoje(), null, '{"local": "Moema"}');
select testes.ok((select count(*) = 2 and bool_and(t.oportunidade_id is null) and bool_and(t.titulo like 'Contato com % — Moema')
                    from public.tarefas t where t.clinica_id = testes.v('cp') and t.status = 'pendente'),
  'só contato do dia (sem negociação no funil), com o nome da campanha');
select testes.ok((select filtros = '{"local": "Moema"}' from public.campanhas where nome = 'Moema'), 'guarda os filtros usados');
select public.criar_campanha(testes.v('cp'), 'Volta', 'personalizada', 1, null, false,
  'Olá, {{nome}}! Que tal uma revisão?', 10, testes.hoje(), null, '{"publico": "pacientes", "negociacao": true}');
select testes.ok(exists (select 1 from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                          where o.pessoa_id = testes.v('bia') and o.status = 'aberta' and e.marco = 'reativacao'),
  'com "abrir negociação": vai para Reativação no funil');
reset role;

select testes.entrar('sec@pers.local'); set role authenticated;
select testes.erro($$select public.criar_campanha(testes.v('cp'), 'X', 'personalizada', 1, null, false, 'Olá, {{nome}}!', 10, testes.hoje(), null, '{}')$$,
  'Somente a administradora', 'a secretária não cria campanha');
reset role;

\echo '✓ Campanha personalizada verificada.'
