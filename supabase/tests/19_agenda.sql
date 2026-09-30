-- =============================================================================
-- Testes da agenda comercial: agendar, confirmar, desmarcar, remarcar, faltar,
-- cancelar — e a garantia de que nenhuma desmarcação fica sem ação comercial.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('ag', public.inicializar_clinica('Clínica da Agenda'));
insert into auth.users (email, raw_user_meta_data) values ('sec@agenda.local', '{"nome": "Secretária Agenda"}');
select public.adicionar_membro(testes.v('ag'), 'sec@agenda.local', 'comercial');
select testes.guardar('prof', (select id from public.profissionais where clinica_id = testes.v('ag') limit 1));
select testes.guardar('facetas', (select id from public.procedimentos where clinica_id = testes.v('ag') and nome = 'Facetas de porcelana'));

-- Dia útil daqui a N dias, no horário pedido (fuso de São Paulo).
create function testes.quando(dias int, hora text) returns timestamptz language sql as
  $$ select (public.proximo_dia_util(testes.v('ag'), testes.hoje() + dias) + hora::time) at time zone 'America/Sao_Paulo' $$;
create function testes.util_ag(dias int) returns date language sql as
  $$ select public.proximo_dia_util(testes.v('ag'), testes.hoje() + dias) $$;
create function testes.pend_ag(p uuid) returns public.tarefas language sql as
  $$ select * from public.tarefas where pessoa_id = p and status = 'pendente' and categoria <> 'financeiro'
      order by vence_em, criado_em desc limit 1 $$;
create function testes.rec(a uuid) returns public.v_recuperacao language sql as
  $$ select * from public.v_recuperacao where agendamento_id = a $$;
grant execute on all functions in schema testes to authenticated, anon;

reset role; select testes.entrar('sec@agenda.local'); set role authenticated;

\echo '— Agendar'
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('ag'), 'Lia Campos', '+5511940000001')
  returning id
) select testes.guardar('lia', id) from x;
select set_config('t.r', public.agendar(testes.v('ag'), testes.v('lia'), 'avaliacao', testes.v('facetas'),
  testes.quando(5, '10:00'), 60, testes.v('prof'))::text, false);
select testes.guardar('ag_lia', (current_setting('t.r')::jsonb ->> 'id')::uuid);
select testes.ok((select a.status = 'agendado' and a.procedimento_id = testes.v('facetas') and a.profissional_id = testes.v('prof')
                     and a.oportunidade_id is not null
                  from public.agendamentos a where a.id = testes.v('ag_lia'))
             and (select e.nome = 'Avaliação agendada' from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                   where o.pessoa_id = testes.v('lia') and o.status = 'aberta')
             and (select t.tipo = 'confirmar_agendamento' and t.vence_em = public.dia_util_anterior(testes.v('ag'), testes.util_ag(5))
                  from testes.pend_ag(testes.v('lia')) t),
  'agendar avaliação: consulta com procedimento e profissional, negociação em "Avaliação agendada" e confirmação na véspera');

select set_config('t.r', public.agendar(testes.v('ag'), null, 'avaliacao', testes.v('facetas'),
  testes.quando(6, '14:00'), 60, testes.v('prof'), true, 'Prefere à tarde', false, 'Nora Dias', '+5511940000002')::text, false);
select testes.guardar('nora', (current_setting('t.r')::jsonb ->> 'pessoa_id')::uuid);
select testes.ok((current_setting('t.r')::jsonb ->> 'pessoa_nova')::boolean
             and (select nome = 'Nora Dias' and tipo_cadastro = 'novo_contato' from public.pessoas where id = testes.v('nora'))
             and (select status = 'confirmado' and confirmado_em is not null from public.agendamentos where pessoa_id = testes.v('nora'))
             and not exists (select 1 from public.tarefas where pessoa_id = testes.v('nora') and status = 'pendente'
                              and tipo = 'confirmar_agendamento'),
  'paciente novo cadastrado no próprio agendamento; já confirmado → sem tarefa de confirmação');
select set_config('t.r', public.agendar(testes.v('ag'), null, 'retorno', null,
  testes.quando(8, '09:00'), 30, testes.v('prof'), false, null, false, 'Outro Nome', '+5511940000002')::text, false);
select testes.ok((current_setting('t.r')::jsonb ->> 'pessoa_id')::uuid = testes.v('nora')
             and not (current_setting('t.r')::jsonb ->> 'pessoa_nova')::boolean,
  'WhatsApp já cadastrado: usa o cadastro existente (sem duplicar)');

select testes.erro(format($$select public.agendar(%L, %L, 'avaliacao', null, %L, 60, %L)$$,
                          testes.v('ag'), testes.v('lia'), testes.quando(5, '10:30'), testes.v('prof')),
  'Horário ocupado: Lia Campos às 10:00', 'conflito com outra consulta do mesmo profissional');
-- Outra dentista no mesmo horário: sem conflito (cada dentista tem a sua agenda).
reset role;
insert into public.profissionais (clinica_id, nome, cor) values (testes.v('ag'), 'Dra. Paula', '#5F8A6A');
select testes.entrar('sec@agenda.local'); set role authenticated;
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('ag'), 'Téo Braga', '+5511940000009')
  returning id
) select testes.guardar('teo', id) from x;
select set_config('t.r', public.agendar(testes.v('ag'), testes.v('teo'), 'avaliacao', null, testes.quando(5, '10:00'), 60,
  (select id from public.profissionais where clinica_id = testes.v('ag') and nome = 'Dra. Paula'))::text, false);
select testes.ok((select pf.nome = 'Dra. Paula' from public.agendamentos a join public.profissionais pf on pf.id = a.profissional_id
                   where a.pessoa_id = testes.v('teo')),
  'outra dentista no mesmo horário: sem conflito, cada dentista com a sua agenda');
select testes.erro(format($$select public.agendar(%L, %L, 'avaliacao', null, %L, 60, %L)$$,
                          testes.v('ag'), testes.v('lia'), testes.quando(5, '18:30'), testes.v('prof')),
  'Fora do horário', 'fora do horário de atendimento (08h–19h)');
select testes.erro(format($$select public.agendar(%L, %L, 'avaliacao', null, %L, 60, %L)$$,
                          testes.v('ag'), testes.v('lia'), (date '2026-10-10' + time '10:00') at time zone 'America/Sao_Paulo', testes.v('prof')),
  'não atende neste dia', 'sábado: a clínica não atende');
select testes.erro(format($$select public.agendar(%L, %L, 'avaliacao', null, %L, 60, %L)$$,
                          testes.v('ag'), testes.v('lia'), now() - interval '3 days', testes.v('prof')),
  'já passou', 'não agenda no passado');

\echo '— Desmarcou'
select set_config('t.r', public.desmarcar_consulta(testes.v('ag_lia'),
  (select id from public.motivos where clinica_id = testes.v('ag') and aplica_a = 'desmarcou' and nome = 'Trabalho'),
  'Reunião de última hora')::text, false);
select testes.ok((select status = 'desmarcado' and m.nome = 'Trabalho' from public.agendamentos a
                    join public.motivos m on m.id = a.motivo_id where a.id = testes.v('ag_lia'))
             and exists (select 1 from public.interacoes where agendamento_id = testes.v('ag_lia') and tipo = 'paciente_desmarcou'
                          and descricao like 'Desmarcou a consulta de %motivo: trabalho — Reunião de última hora'),
  '1-2) desmarcou: evento registrado no histórico (com motivo) e status alterado');
select testes.ok((select t.tipo = 'recuperar_desmarcacao' and t.categoria = 'recuperacao' and t.prioridade = 'urgente'
                     and t.vence_em = testes.util_ag(1) and t.agendamento_id = testes.v('ag_lia')
                     and t.titulo = 'Entrar em contato com Lia para remarcar'
                  from testes.pend_ag(testes.v('lia')) t)
             and (select count(*) from public.tarefas where pessoa_id = testes.v('lia') and status = 'pendente') = 1,
  '3) tarefa de recuperação criada sozinha (dia seguinte, urgente) e a confirmação foi cancelada');
select testes.ok((select mensagem_sugerida = 'Olá, Lia! Tudo bem? Vi que você precisou desmarcar a avaliação do dia '
                    || to_char(testes.util_ag(5), 'DD/MM') || '. Sem problema! Quando for melhor para você, encontramos um novo horário — é só me dizer os dias e horários que ficam mais fáceis.'
                  from testes.pend_ag(testes.v('lia'))),
  '5) mensagem específica para remarcação, citando a consulta desmarcada');
select testes.ok((select situacao = 'a_recuperar' from testes.rec(testes.v('ag_lia')))
             and exists (select 1 from public.v_tarefas_abertas where pessoa_id = testes.v('lia') and tipo = 'recuperar_desmarcacao'
                          and vence_em = testes.util_ag(1)),
  '4) aparece em "a recuperar" e no painel "O que eu tenho que fazer hoje" na data definida');
select testes.erro(format($$select public.desmarcar_consulta(%L)$$, testes.v('ag_lia')), 'Só é possível desmarcar',
  'não desmarca duas vezes');

\echo '— Remarcou'
select set_config('t.r', public.remarcar_consulta(testes.v('ag_lia'), testes.quando(9, '11:00'))::text, false);
select testes.guardar('ag_lia2', (current_setting('t.r')::jsonb ->> 'id')::uuid);
select testes.ok((select remarcado_para_id = testes.v('ag_lia2') and status = 'desmarcado' from public.agendamentos where id = testes.v('ag_lia'))
             and (select status = 'agendado' and procedimento_id = testes.v('facetas') from public.agendamentos where id = testes.v('ag_lia2'))
             and (select status = 'concluida' and resultado like 'Remarcou para %' from public.tarefas
                   where pessoa_id = testes.v('lia') and tipo = 'recuperar_desmarcacao')
             and (select t.tipo = 'confirmar_agendamento' and t.agendamento_id = testes.v('ag_lia2') from testes.pend_ag(testes.v('lia')) t)
             and (select situacao = 'recuperado' from testes.rec(testes.v('ag_lia'))),
  'remarcou: agenda atualizada, recuperação encerrada, nova confirmação criada e desmarcação contada como recuperada');

select set_config('t.r', public.remarcar_consulta(testes.v('ag_lia2'), testes.quando(10, '15:00'))::text, false);
select testes.ok((select status = 'remarcado' from public.agendamentos where id = testes.v('ag_lia2'))
             and (select status = 'cancelada' from public.tarefas where agendamento_id = testes.v('ag_lia2') and tipo = 'confirmar_agendamento')
             and (select count(*) from public.tarefas where pessoa_id = testes.v('lia') and status = 'pendente') = 1,
  'mudou a data antes da consulta: status "remarcado", confirmação antiga cancelada e só a nova pendente');

\echo '— Faltou e cancelado'
select testes.guardar('ag_nora', (select id from public.agendamentos where pessoa_id = testes.v('nora') and tipo = 'avaliacao'));
select testes.erro(format($$select public.mudar_status_consulta(%L, 'faltou')$$, testes.v('ag_nora')),
  'no dia da consulta ou depois', 'falta só pode ser registrada a partir do dia da consulta');
reset role;
update public.agendamentos set inicio = now() - interval '2 hours' where id = testes.v('ag_nora');
select testes.entrar('sec@agenda.local'); set role authenticated;
select public.mudar_status_consulta(testes.v('ag_nora'), 'faltou');
select testes.ok((select t.tipo = 'recuperar_falta' and t.titulo = 'Entrar em contato com Nora para remarcar'
                     and t.mensagem_sugerida like 'Olá, Nora! Sentimos sua falta na consulta do dia %'
                  from testes.pend_ag(testes.v('nora')) t)
             and exists (select 1 from public.interacoes where pessoa_id = testes.v('nora') and tipo = 'paciente_faltou'),
  'faltou: ação específica de recuperação, com mensagem de quem faltou');

with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('ag'), 'Rui Prado', '+5511940000003')
  returning id
) select testes.guardar('rui', id) from x;
select set_config('t.r', public.agendar(testes.v('ag'), testes.v('rui'), 'avaliacao', null,
  testes.quando(4, '16:00'), 60, testes.v('prof'))::text, false);
select testes.guardar('ag_rui', (current_setting('t.r')::jsonb ->> 'id')::uuid);
select testes.erro(format($$select public.mudar_status_consulta(%L, 'cancelado_clinica')$$, testes.v('ag_rui')),
  'motivo do cancelamento', 'cancelar exige o motivo');
select public.mudar_status_consulta(testes.v('ag_rui'), 'cancelado_clinica', 'Doutora em congresso');
select testes.ok((select t.titulo = 'Remarcar o horário de Rui' and t.mensagem_sugerida like '%pedimos desculpas pelo transtorno%'
                  from testes.pend_ag(testes.v('rui')) t)
             and (select situacao = 'a_recuperar' from testes.rec(testes.v('ag_rui'))),
  'cancelado pela clínica: tarefa para remarcar com pedido de desculpas');

\echo '— Nenhuma desmarcação desaparece'
reset role;
select testes.erro(format($$delete from public.agendamentos where id = %L$$, testes.v('ag_lia')),
  'não são apagadas', 'consultas não podem ser apagadas (nem pelo administrador do banco)');
select testes.erro(format($$update public.agendamentos set status = 'agendado' where id = %L$$, testes.v('ag_lia')),
  'use Remarcar', 'desmarcada não "volta" a ficar agendada sem remarcar (nem pelo sistema)');

-- Regra desligada: mesmo assim a recuperação é criada.
update public.regras_followup set ativa = false where clinica_id = testes.v('ag') and situacao = 'desmarcou';
select testes.entrar('sec@agenda.local'); set role authenticated;
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('ag'), 'Sol Menezes', '+5511940000004')
  returning id
) select testes.guardar('sol', id) from x;
select set_config('t.r', public.agendar(testes.v('ag'), testes.v('sol'), 'avaliacao', null,
  testes.quando(3, '08:00'), 60, testes.v('prof'))::text, false);
select testes.guardar('ag_sol', (current_setting('t.r')::jsonb ->> 'id')::uuid);
select public.desmarcar_consulta(testes.v('ag_sol'), null, null, testes.hoje() + 7);
select testes.ok((select t.tipo = 'recuperar_desmarcacao' and t.chave_dedupe like 'rec:%' and t.vence_em = testes.util_ag(7)
                  from testes.pend_ag(testes.v('sol')) t),
  'regra desligada: a garantia da agenda cria a recuperação mesmo assim, na data combinada com a paciente');

-- Tarefa sumiu por qualquer motivo: a rotina diária recria.
reset role;
update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste' where pessoa_id = testes.v('sol') and status = 'pendente';
select testes.ok((select situacao = 'sem_acao' from testes.rec(testes.v('ag_sol'))),
  'sem nenhuma ação, a desmarcação aparece como "sem ação" (alerta)');
select public.preparar_dia(testes.v('ag'), true);
select testes.ok((select situacao = 'a_recuperar' from testes.rec(testes.v('ag_sol')))
             and (select vence_em = testes.hoje() and prioridade = 'urgente' from testes.pend_ag(testes.v('sol'))),
  'a rotina diária recria a recuperação para hoje: nenhuma desmarcação fica sem ação comercial');

-- Desfecho registrado ("não tem interesse"): sai de "a recuperar", com o desfecho visível.
update public.regras_followup set ativa = true where clinica_id = testes.v('ag') and situacao = 'desmarcou';
select testes.entrar('sec@agenda.local'); set role authenticated;
select public.registrar_acao((testes.pend_ag(testes.v('sol'))).id, 'sem_interesse', 'whatsapp');
select testes.ok((select situacao in ('acompanhando', 'encerrado') and desfecho = 'Não tem interesse no momento'
                  from testes.rec(testes.v('ag_sol'))),
  'desfecho registrado: a desmarcação sai de "a recuperar" com o resultado da conversa');

\echo '— Busca e segurança'
select testes.ok((select count(*) = 1 from public.buscar_pacientes(testes.v('ag'), 'lia'))
             and (select nome = 'Nora Dias' from public.buscar_pacientes(testes.v('ag'), '0000002')),
  'busca de paciente por nome (sem acento) ou telefone');
reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.erro(format($$select public.agendar(%L, %L, 'avaliacao', null, %L, 60, null)$$,
                          testes.v('ag'), testes.v('lia'), testes.quando(12, '10:00')),
  'Sem acesso', 'outra clínica não agenda nesta');
select testes.erro(format($$select public.desmarcar_consulta(%L)$$, testes.v('ag_lia2')),
  'não encontrada', 'outra clínica não desmarca consultas desta');
select testes.ok((select count(*) from public.v_recuperacao where clinica_id = testes.v('ag')) = 0,
  'outra clínica não vê a recuperação desta');
reset role;

\echo '✓ Agenda verificada.'
