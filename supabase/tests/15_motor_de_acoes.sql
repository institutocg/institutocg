-- =============================================================================
-- Testes do motor de ações: cada situação gera (ou encerra) a ação certa.
-- Usa as ferramentas criadas em 10_integridade.sql.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('m', public.inicializar_clinica('Clínica do Motor'));
insert into auth.users (email, raw_user_meta_data) values
  ('dona@motor.local', '{"nome": "Dona"}'), ('sec@motor.local', '{"nome": "Secretária"}');
select public.adicionar_membro(testes.v('m'), 'dona@motor.local', 'admin');
select public.adicionar_membro(testes.v('m'), 'sec@motor.local', 'comercial');

-- Funções auxiliares deste arquivo
create function testes.etapa(marco text) returns uuid language sql as
  $$ select id from public.etapas_funil where clinica_id = testes.v('m') and marco = etapa.marco $$;
create function testes.etapa_nome(op uuid) returns text language sql as
  $$ select e.nome from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id where o.id = op $$;
create function testes.pendente(p uuid) returns public.tarefas language sql as
  $$ select * from public.tarefas where pessoa_id = p and status = 'pendente' order by vence_em, criado_em desc limit 1 $$;
create function testes.pendentes(p uuid) returns bigint language sql as
  $$ select count(*) from public.tarefas where pessoa_id = p and status = 'pendente' $$;
create function testes.util(dias int) returns date language sql as
  $$ select public.proximo_dia_util(testes.v('m'), testes.hoje() + dias) $$;
create function testes.nova_pessoa(nome text, fone text, tipo public.tipo_cadastro default 'novo_contato') returns uuid
language sql as $$
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164)
  values (testes.v('m'), tipo, nome, fone) returning id
$$;
create function testes.nova_op(p uuid, marco text default 'novo_contato') returns uuid language sql as $$
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (testes.v('m'), p,
          (select id from public.procedimentos where clinica_id = testes.v('m') and nome = 'Facetas de porcelana'),
          testes.etapa(marco))
  returning id
$$;
grant execute on all functions in schema testes to authenticated, anon;

\echo '— Calendário da clínica'
select testes.ok(not public.eh_dia_util(testes.v('m'), '2026-10-03')
             and not public.eh_dia_util(testes.v('m'), '2026-10-12')
             and not public.eh_dia_util(testes.v('m'), '2026-04-03')
             and public.eh_dia_util(testes.v('m'), '2026-02-16')
             and public.proximo_dia_util(testes.v('m'), '2026-10-03') = '2026-10-05'
             and public.dia_util_anterior(testes.v('m'), '2026-10-13') = '2026-10-09',
  'sábado, domingo e feriados (inclusive Sexta-feira Santa) não recebem tarefas; mesma regra do app');

reset role; select testes.entrar('sec@motor.local'); set role authenticated;

-- =============================================================================
\echo '— Novo contato → primeiro contato (regra "Novo lead": hoje, +1, +2 dias)'
-- =============================================================================

select testes.guardar('ana', testes.nova_pessoa('Ana Lead', '+5511910000001'));
select testes.guardar('op_ana', testes.nova_op(testes.v('ana')));
select testes.ok((select t.tipo = 'primeiro_contato' and t.prioridade = 'urgente' and t.passo = 1
                  and t.vence_em = testes.util(0) and t.origem = 'automatica'
                  and t.mensagem_sugerida like 'Olá, Ana!%facetas de porcelana%'
                  from testes.pendente(testes.v('ana')) t),
  'lead novo gera "primeiro contato" urgente para hoje, com mensagem sugerida personalizada');

select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'feito');
select testes.ok((select t.passo = 2 and t.vence_em = testes.util(1) from testes.pendente(testes.v('ana')) t)
             and testes.pendentes(testes.v('ana')) = 1,
  'concluir o 1º contato agenda sozinho a 2ª tentativa para o próximo dia útil');
select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'nao_respondeu');
select testes.ok((select t.passo = 3 and t.vence_em = testes.util(2) and t.regra = 'novo_contato'
                  from testes.pendente(testes.v('ana')) t),
  '"não respondeu" avança a cadência pelos intervalos da regra');
select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'nao_respondeu');
select testes.ok(testes.etapa_nome(testes.v('op_ana')) = 'Sem resposta'
             and (select t.tipo = 'reabrir_sem_resposta' and t.vence_em = testes.util(7)
                  from testes.pendente(testes.v('ana')) t)
             and testes.pendentes(testes.v('ana')) = 1,
  'tentativas esgotadas: vai para "Sem resposta" com nova tentativa em 7 dias (nunca fica esquecida)');
select testes.ok((select count(*) = 3 from public.interacoes where pessoa_id = testes.v('ana')),
  'cada tentativa ficou no histórico de follow-ups');
select testes.erro(
  format($$select public.registrar_acao(%L, 'feito')$$,
         (select id from public.tarefas where pessoa_id = testes.v('ana') and status = 'concluida' limit 1)),
  'já foi concluída', 'não é possível concluir duas vezes a mesma tarefa');

-- =============================================================================
\echo '— Respondeu → avaliação → orçamento → decisão'
-- =============================================================================

select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'respondeu_interesse', 'whatsapp');
select testes.ok(testes.etapa_nome(testes.v('op_ana')) = 'Em contato'
             and (select t.titulo = 'Conduzir Ana para a avaliação' and t.vence_em = testes.util(1)
                  from testes.pendente(testes.v('ana')) t),
  'respondeu com interesse: funil vai para "Em contato" e a próxima ação é conduzir para a avaliação');

select testes.erro(format($$select public.registrar_acao(%L, 'agendou')$$, (testes.pendente(testes.v('ana'))).id),
  'data e o horário', '"agendou" exige data e horário');
select set_config('t.dia_aval', testes.util(7)::text, false);
select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'agendou', 'whatsapp', null, null, null,
  (current_setting('t.dia_aval')::date + time '10:00') at time zone 'America/Sao_Paulo');
select testes.ok(testes.etapa_nome(testes.v('op_ana')) = 'Avaliação agendada'
             and (select t.tipo = 'confirmar_agendamento'
                     and t.vence_em = public.dia_util_anterior(testes.v('m'), current_setting('t.dia_aval')::date)
                     and t.mensagem_sugerida like '%10:00%'
                  from testes.pendente(testes.v('ana')) t)
             and testes.pendentes(testes.v('ana')) = 1,
  'agendou: cria o agendamento, move o funil e agenda a confirmação para a véspera útil');

select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'nao_respondeu');
select testes.ok((select t.passo = 2 and t.vence_em = current_setting('t.dia_aval')::date
                  from testes.pendente(testes.v('ana')) t),
  'confirmação sem resposta: nova tentativa no próprio dia da consulta');
select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'confirmou');
select testes.ok((select status = 'confirmado' from public.agendamentos where pessoa_id = testes.v('ana'))
             and testes.pendentes(testes.v('ana')) = 0,
  'confirmou: agendamento confirmado e nada pendente até a consulta');

-- A consulta passou e ninguém registrou: a rotina pergunta se compareceu.
reset role;
update public.agendamentos set inicio = now() - interval '1 day' where pessoa_id = testes.v('ana');
select public.preparar_dia(testes.v('m'), true);
select testes.ok((select t.titulo = 'Ana compareceu?' from testes.pendente(testes.v('ana')) t),
  'consulta que passou sem registro vira a pergunta "compareceu?"');
select testes.entrar('sec@motor.local'); set role authenticated;

update public.agendamentos set status = 'compareceu' where pessoa_id = testes.v('ana');
select testes.ok(testes.etapa_nome(testes.v('op_ana')) = 'Consulta realizada'
             and (select t.tipo = 'acompanhar_decisao' and t.regra = 'pos_consulta' and t.vence_em = testes.util(3)
                     and t.titulo = 'Retomar com Ana depois da consulta'
                     and t.mensagem_sugerida like 'Olá, Ana!%prazer receber você na consulta%'
                  from testes.pendente(testes.v('ana')) t),
  'compareceu: funil vai para "Consulta realizada" e o contato pós-consulta fica para 3 dias depois');

insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, apresentado_em)
values (testes.v('m'), testes.v('ana'), testes.v('op_ana'), 'apresentado', 1500000, testes.hoje());
select testes.ok(testes.etapa_nome(testes.v('op_ana')) = 'Consulta realizada'
             and (select vence_em = testes.util(3) from testes.pendente(testes.v('ana')))
             and testes.pendentes(testes.v('ana')) = 1,
  'orçamento registrado (apresentado na consulta): continua o mesmo contato, sem tarefa duplicada');

select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'nao_respondeu');
select testes.ok((select tipo = 'acompanhar_decisao' and passo = 2 and vence_em = testes.util(4)
                  from testes.pendente(testes.v('ana'))),
  'saiu da consulta sem fechar: sem resposta, nova tentativa 4 dias depois (intervalos da regra)');
select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'vai_pensar');
select testes.ok(testes.etapa_nome(testes.v('op_ana')) = 'Consulta realizada'
             and (select tipo = 'acompanhar_decisao' and passo = 1 and vence_em = testes.util(3) and descricao = 'Ficou de pensar'
                  from testes.pendente(testes.v('ana'))),
  'vai pensar: recomeça o acompanhamento sem pressão, na mesma etapa');

select testes.erro(format($$select public.registrar_acao(%L, 'nao_fechou')$$, (testes.pendente(testes.v('ana'))).id),
  'motivo', '"não fechou" exige motivo');
select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'nao_fechou', null, 'Achou caro', null,
  (select id from public.motivos where clinica_id = testes.v('m') and nome = 'Valor alto'));
select testes.ok((select status = 'perdida' from public.oportunidades where id = testes.v('op_ana'))
             and (select t.tipo = 'retorno_por_motivo' and t.vence_em = testes.util(30) and t.descricao = 'Não fechou: valor alto'
                  from testes.pendente(testes.v('ana')) t),
  'não fechou por valor alto: volta a falar em 30 dias (prazo do motivo)');

select public.registrar_acao((testes.pendente(testes.v('ana'))).id, 'respondeu_interesse');
select testes.ok((select count(*) from public.oportunidades where pessoa_id = testes.v('ana')) = 2
             and exists (select 1 from public.oportunidades where pessoa_id = testes.v('ana') and status = 'aberta'
                          and oportunidade_origem_id = testes.v('op_ana')),
  'retomada com interesse abre uma nova negociação ligada à anterior');

-- =============================================================================
\echo '— Desmarcou / faltou / remarcou'
-- =============================================================================

select testes.guardar('bia', testes.nova_pessoa('Bia Desmarca', '+5511910000002'));
select testes.guardar('op_bia', testes.nova_op(testes.v('bia'), 'em_contato'));
with novo as (
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, tipo, inicio)
  values (testes.v('m'), testes.v('bia'), testes.v('op_bia'), 'avaliacao', now() + interval '6 days') returning id
) select testes.guardar('ag_bia', id) from novo;
update public.agendamentos set status = 'desmarcado' where id = testes.v('ag_bia');
select testes.ok((select t.tipo = 'recuperar_desmarcacao' and t.prioridade = 'urgente' and t.vence_em = testes.util(1)
                     and t.titulo = 'Entrar em contato com Bia para remarcar' and t.regra = 'desmarcou'
                  from testes.pendente(testes.v('bia')) t)
             and not exists (select 1 from public.tarefas where agendamento_id = testes.v('ag_bia')
                              and tipo = 'confirmar_agendamento' and status = 'pendente'),
  'desmarcou (dia 10): "Entrar em contato para remarcar" no dia seguinte (11) e a confirmação é cancelada');
select public.registrar_acao((testes.pendente(testes.v('bia'))).id, 'agendou', 'ligacao', null, null, null,
  now() + interval '8 days');
select testes.ok((select remarcado_para_id is not null from public.agendamentos where id = testes.v('ag_bia')),
  'remarcou: o agendamento desmarcado aponta para o novo (conta como recuperado)');

select testes.guardar('caio', testes.nova_pessoa('Caio Falta', '+5511910000003'));
select testes.guardar('op_caio', testes.nova_op(testes.v('caio'), 'em_contato'));
insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, tipo, inicio)
values (testes.v('m'), testes.v('caio'), testes.v('op_caio'), 'avaliacao', now() + interval '1 day');
update public.agendamentos set status = 'faltou' where pessoa_id = testes.v('caio');
select testes.ok((select tipo = 'recuperar_falta' from testes.pendente(testes.v('caio'))),
  'faltou: tarefa de recuperação');
select public.registrar_acao((testes.pendente(testes.v('caio'))).id, 'pediu_retorno', 'whatsapp', null, testes.hoje() + 20);
select testes.ok((select t.vence_em = testes.util(20) and t.titulo like '%pediu retorno%' from testes.pendente(testes.v('caio')) t),
  'pediu retorno: próxima ação exatamente na data combinada (ajustada para dia útil)');

-- =============================================================================
\echo '— Sem resposta, não contatar, paciente antigo'
-- =============================================================================

select testes.guardar('davi', testes.nova_pessoa('Davi Sumido', '+5511910000004'));
select testes.guardar('op_davi', testes.nova_op(testes.v('davi'), 'em_contato'));
select public.mover_etapa(testes.v('op_davi'), (select id from public.etapas_funil where clinica_id = testes.v('m') and resultado = 'sem_resposta'));
select testes.ok((select t.tipo = 'reabrir_sem_resposta' and t.vence_em = testes.util(7) from testes.pendente(testes.v('davi')) t)
             and testes.pendentes(testes.v('davi')) = 1,
  'sem resposta: negociação pausada e nova tentativa leve em 7 dias');
select public.registrar_acao((testes.pendente(testes.v('davi'))).id, 'respondeu_interesse');
select testes.ok((select status = 'aberta' from public.oportunidades where id = testes.v('op_davi'))
             and (select count(*) from public.oportunidades where pessoa_id = testes.v('davi')) = 1,
  'quem estava sem resposta e voltou reabre a mesma negociação');

select public.registrar_acao((testes.pendente(testes.v('davi'))).id, 'nao_contatar', 'whatsapp', 'Pediu para parar');
select testes.ok((select nao_contatar from public.pessoas where id = testes.v('davi'))
             and testes.pendentes(testes.v('davi')) = 0
             and (select resultado = 'desistiu' from public.oportunidades where id = testes.v('op_davi')),
  'não quer contato: nenhuma tarefa futura e negociação encerrada como "desistiu"');
select testes.nova_op(testes.v('davi'));
select testes.ok(testes.pendentes(testes.v('davi')) = 0,
  'quem pediu para não ser contatado nunca recebe tarefas automáticas');

select testes.guardar('eva', testes.nova_pessoa('Eva Antiga', '+5511910000005', 'paciente_antigo'));
select testes.nova_op(testes.v('eva'), 'em_contato');
select testes.ok((select t.tipo = 'follow_up' and t.titulo = 'Conversar com Eva sobre facetas de porcelana'
                  from testes.pendente(testes.v('eva')) t),
  'paciente antigo com interesse: tarefa "conversar sobre" o procedimento');

-- =============================================================================
\echo '— Fechou e lembretes de pagamento'
-- =============================================================================

select testes.guardar('fabi', testes.nova_pessoa('Fabi Fecha', '+5511910000006'));
select testes.guardar('op_fabi', testes.nova_op(testes.v('fabi'), 'avaliacao_realizada'));
select public.registrar_acao((testes.pendente(testes.v('fabi'))).id, 'fechou');
select testes.ok((select status = 'ganha' from public.oportunidades where id = testes.v('op_fabi'))
             and (select tipo = 'agendar_tratamento' from testes.pendente(testes.v('fabi'))),
  'fechou: negociação ganha e próxima ação "agendar o início do tratamento"');

with novo as (
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, valor_total_centavos, condicao_pagamento,
                             quantidade_parcelas)
  values (testes.v('m'), testes.v('fabi'), testes.v('op_fabi'), 500000, 'parcelado', 2) returning id
) select testes.guardar('v_fabi', id) from novo;
select public.gerar_parcelas(testes.v('v_fabi'), testes.hoje());
select testes.guardar('t_pag', (select t.id from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                                 where p.venda_id = testes.v('v_fabi') and p.numero = 1));
select testes.erro(format($$select public.registrar_acao(%L, 'feito')$$, testes.v('t_pag')),
  'Marcar como pago', 'lembrete de pagamento não é "concluído" sem registrar o pagamento');
select public.registrar_acao(testes.v('t_pag'), 'prometeu_pagar', 'whatsapp', null, testes.hoje() + 3);
select testes.ok((select status = 'pendente' and vence_em = testes.util(3) from public.tarefas where id = testes.v('t_pag')),
  'combinou pagar em outra data: o lembrete muda para a data combinada');
select public.marcar_parcela_paga((select parcela_id from public.tarefas where id = testes.v('t_pag')));
select testes.ok((select status = 'concluida' from public.tarefas where id = testes.v('t_pag'))
             and (select p.status = 'paga' from public.parcelas p join public.tarefas t on t.parcela_id = p.id
                  where t.id = testes.v('t_pag')),
  'marcar como pago: parcela paga e lembrete concluído');
select testes.erro(format($$select public.marcar_parcela_paga(%L)$$,
                          (select parcela_id from public.tarefas where id = testes.v('t_pag'))),
  'não está em aberto', 'não marca como paga uma parcela já paga');

-- =============================================================================
\echo '— Rotina diária'
-- =============================================================================

-- Uma negociação ficou sem próxima ação (tarefa cancelada à mão).
update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste'
 where pessoa_id = testes.v('eva') and status = 'pendente';
insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, apresentado_em, valido_ate)
select testes.v('m'), testes.v('bia'), testes.v('op_bia'), 'apresentado', 100000, testes.hoje() - 40, testes.hoje() - 10;

select testes.ok((public.preparar_dia(testes.v('m')) ->> 'proximas_acoes_criadas')::int >= 1,
  'rotina diária cria "definir próximo passo" para negociação sem próxima ação');
select testes.ok((select tipo = 'definir_proxima_acao' from testes.pendente(testes.v('eva'))),
  '...inclusive para a Eva');
select testes.ok(exists (select 1 from public.orcamentos where pessoa_id = testes.v('bia') and status = 'expirado'),
  'rotina diária marca orçamentos vencidos como expirados');
select testes.ok((public.preparar_dia(testes.v('m')) ->> 'ja_executada')::boolean,
  'rotina roda uma única vez por dia');

-- Pacientes antigos para reativação/manutenção
select testes.guardar('gil', testes.nova_pessoa('Gil Inativo', '+5511910000007', 'paciente_antigo'));
select testes.guardar('hugo', testes.nova_pessoa('Hugo Limpeza', '+5511910000008', 'paciente_antigo'));
select testes.guardar('iris', testes.nova_pessoa('Iris Inativa', '+5511910000009', 'paciente_antigo'));
update public.pessoas set ultimo_atendimento_informado = testes.hoje() - 700 where id in (testes.v('gil'), testes.v('iris'));
update public.pessoas set ultimo_atendimento_informado = testes.hoje() - 250 where id = testes.v('hugo');
insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
values (testes.v('m'), testes.v('hugo'),
        (select id from public.procedimentos where clinica_id = testes.v('m') and nome = 'Manutenção e limpeza'),
        testes.hoje() - 250);

select public.preparar_dia(testes.v('m'), true);
select testes.ok(testes.pendentes(testes.v('gil')) = 0 and testes.pendentes(testes.v('hugo')) = 0,
  'reativação desligada (recadastramento): nenhum paciente antigo vira tarefa');

reset role; select testes.entrar('dona@motor.local'); set role authenticated;
update public.clinicas set configuracoes = configuracoes || '{"limite_reativacao_dia": 2}'::jsonb where id = testes.v('m');
update public.regras_followup set ativa = true
 where clinica_id = testes.v('m') and situacao in ('paciente_inativo', 'manutencao');
select public.preparar_dia(testes.v('m'), true);
select testes.ok((select tipo = 'manutencao' and descricao like 'manutenção e limpeza em%' from testes.pendente(testes.v('hugo')))
             and (select count(*) from public.tarefas where clinica_id = testes.v('m') and status = 'pendente'
                    and tipo in ('manutencao', 'reativacao')) = 2,
  'reativação ligada: manutenção devida e pacientes inativos, respeitando o limite diário (2)');
select public.preparar_dia(testes.v('m'), true);
select testes.ok(not exists (select 1 from public.tarefas where clinica_id = testes.v('m')
                    and tipo in ('manutencao', 'reativacao') group by pessoa_id having count(*) > 1)
             and testes.pendentes(testes.v('iris')) = 1,
  'rodar de novo (outro dia) não repete quem já recebeu e pega o próximo da fila (Iris)');

-- =============================================================================
\echo '— Segurança'
-- =============================================================================

reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.erro($$select public.preparar_dia(testes.v('m'))$$, 'Sem acesso', 'outra clínica não roda a rotina desta');
select testes.erro(format($$select public.registrar_acao(%L, 'feito')$$, (select id from public.tarefas limit 1)),
  'não encontrada', 'outra clínica não mexe nas tarefas desta');
select testes.ok((select count(*) from public.v_tarefas_abertas) = 0, 'outra clínica não vê as tarefas desta');
reset role;

select testes.ok(not exists (
  select 1 from public.oportunidades o join public.pessoas p on p.id = o.pessoa_id
   where o.clinica_id = testes.v('m') and o.status = 'aberta' and not p.nao_contatar
     and not public.tem_proxima_acao(o.id)),
  'varredura final: toda negociação aberta tem próxima ação');

\echo '✓ Motor de ações verificado.'

\echo '— Resgate de paciente antigo sob demanda'
reset role; select testes.entrar('sec@motor.local'); set role authenticated;
select testes.guardar('jonas', testes.nova_pessoa('Jonas Limpeza', '+5511910000020', 'paciente_antigo'));
insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
values (testes.v('m'), testes.v('jonas'),
        (select id from public.procedimentos where clinica_id = testes.v('m') and nome = 'Manutenção e limpeza'), '2025-01-10');
select public.criar_resgate(testes.v('jonas'));
select testes.ok((select t.tipo = 'manutencao' and t.descricao = 'manutenção e limpeza em 01/2025'
                  and t.mensagem_sugerida like 'Olá, Jonas!%manutenção%' from testes.pendente(testes.v('jonas')) t),
  'resgate com tratamento de ciclo (limpeza): tarefa de manutenção com mensagem');
select testes.ok((select e.marco = 'reativacao' from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                  where o.pessoa_id = testes.v('jonas') and o.status = 'aberta'),
  'o resgate coloca o paciente na coluna "Reativação" do funil');
select testes.erro($$select public.criar_resgate(testes.v('jonas'))$$, 'negociação em andamento',
  'não cria dois resgates para a mesma pessoa');
select testes.guardar('kaka', testes.nova_pessoa('Kaká Sumida', '+5511910000021', 'paciente_antigo'));
select public.criar_resgate(testes.v('kaka'));
select testes.ok((select tipo = 'reativacao' from testes.pendente(testes.v('kaka'))),
  'resgate sem tratamento com ciclo: reativação');
select testes.erro($$select public.criar_resgate(testes.v('eva'))$$, 'negociação em andamento',
  'quem já está negociando não recebe resgate');
reset role;
\echo '✓ Resgate verificado.'
select testes.ok(public.sem_acento('João Conceição') = 'joao conceicao', 'busca ignora acentos e maiúsculas');
