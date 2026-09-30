-- =============================================================================
-- Testes das regras de follow-up configuráveis, do acompanhamento do tratamento
-- e das campanhas de reativação.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('r', public.inicializar_clinica('Clínica das Regras'));
insert into auth.users (email, raw_user_meta_data) values
  ('dona@regras.local', '{"nome": "Dona Regras"}'), ('sec@regras.local', '{"nome": "Secretária Regras"}');
select public.adicionar_membro(testes.v('r'), 'dona@regras.local', 'admin');
select public.adicionar_membro(testes.v('r'), 'sec@regras.local', 'comercial');

create function testes.etr(nome text) returns uuid language sql as
  $$ select id from public.etapas_funil where clinica_id = testes.v('r') and nome = etr.nome $$;
create function testes.pessoa_r(nome text, fone text, tipo public.tipo_cadastro default 'novo_contato') returns uuid
language sql as $$
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164) values (testes.v('r'), tipo, nome, fone) returning id
$$;
create function testes.op_r(p uuid, etapa text) returns uuid language sql as $$
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (testes.v('r'), p, (select id from public.procedimentos where clinica_id = testes.v('r') and nome = 'Clareamento dental'),
          testes.etr(etapa))
  returning id
$$;
create function testes.pend_r(p uuid) returns public.tarefas language sql as
  $$ select * from public.tarefas where pessoa_id = p and status = 'pendente' order by vence_em, criado_em desc limit 1 $$;
create function testes.util_r(dias int) returns date language sql as
  $$ select public.proximo_dia_util(testes.v('r'), testes.hoje() + dias) $$;
create function testes.regra_r(sit text) returns public.regras_followup language sql as
  $$ select * from public.regras_followup where clinica_id = testes.v('r') and situacao = sit $$;
grant execute on all functions in schema testes to authenticated, anon;

\echo '— Regras padrão'
select testes.ok((select count(*) = 15 from public.regras_followup where clinica_id = testes.v('r'))
             and (select prazo_dias = 1 and titulo_modelo = 'Entrar em contato com {primeiro_nome} para remarcar'
                  from testes.regra_r('desmarcou'))
             and (select not ativa and periodo_meses = 6 from testes.regra_r('paciente_inativo'))
             and (select ao_esgotar = 'reativacao' and espera_reativacao_dias = 60 from testes.regra_r('sem_resposta')),
  'cada situação comercial tem uma regra: o que fazer, quando e com qual mensagem');

reset role; select testes.entrar('sec@regras.local'); set role authenticated;
update public.regras_followup set prazo_dias = 9 where clinica_id = testes.v('r') and situacao = 'desmarcou';
select testes.ok((select prazo_dias = 1 from testes.regra_r('desmarcou')),
  'secretária vê as regras, mas não altera');

reset role; select testes.entrar('dona@regras.local'); set role authenticated;
select testes.erro($$update public.regras_followup set intervalos = '{1,2,3,4,5,6}' where clinica_id = testes.v('r') and situacao = 'pensando'$$,
  'check', 'no máximo 5 tentativas extras (evita insistência)');
update public.regras_followup set prazo_dias = 2, titulo_modelo = 'Ligar para {primeiro_nome} e remarcar'
 where clinica_id = testes.v('r') and situacao = 'desmarcou';
select testes.ok(exists (select 1 from public.auditoria where tabela = 'regras_followup' and acao = 'update'),
  'alteração de regra fica na auditoria');

reset role; select testes.entrar('sec@regras.local'); set role authenticated;

\echo '— Regra alterada muda o comportamento'
select testes.guardar('al', testes.pessoa_r('Alice Reis', '+5511930000001'));
select testes.guardar('op_al', testes.op_r(testes.v('al'), 'Em contato'));
with ag as (
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, tipo, inicio)
  values (testes.v('r'), testes.v('al'), testes.v('op_al'), 'avaliacao', now() + interval '5 days') returning id
) select testes.guardar('ag_al', id) from ag;
update public.agendamentos set status = 'desmarcado' where id = testes.v('ag_al');
select testes.ok((select t.titulo = 'Ligar para Alice e remarcar' and t.vence_em = testes.util_r(2) and t.regra = 'desmarcou'
                  from testes.pend_r(testes.v('al')) t),
  'desmarcou: prazo e título seguem a regra editada (2 dias, "Ligar para Alice e remarcar")');
select testes.ok((select regra_nome = 'Paciente desmarcou' from public.v_tarefas_abertas where pessoa_id = testes.v('al')),
  'o painel sabe qual regra criou a tarefa');

\echo '— Registrar contato: não tem interesse / outro'
select testes.erro(format($$select public.registrar_acao(%L, 'outro')$$, (testes.pend_r(testes.v('al'))).id),
  'Descreva', '"outro" exige uma descrição');
select public.registrar_acao((testes.pend_r(testes.v('al'))).id, 'outro', 'whatsapp', 'Vai ver a agenda do trabalho',
  testes.hoje() + 6);
select testes.ok((select t.vence_em = testes.util_r(6) and t.descricao = 'Vai ver a agenda do trabalho'
                  from testes.pend_r(testes.v('al')) t)
             and exists (select 1 from public.interacoes where pessoa_id = testes.v('al')
                          and descricao = 'Contato registrado — Vai ver a agenda do trabalho'),
  '"outro" com data: histórico registrado e próximo contato na data escolhida');
select public.registrar_acao((testes.pend_r(testes.v('al'))).id, 'sem_interesse', 'whatsapp');
select testes.ok((select o.resultado = 'desistiu' and m.nome = 'Sem interesse no momento'
                  from public.oportunidades o join public.motivos m on m.id = o.motivo_id where o.id = testes.v('op_al'))
             and (select vence_em = testes.util_r(180) from testes.pend_r(testes.v('al'))),
  '"não tem interesse": encerra como desistiu e agenda uma retomada leve em 180 dias');

\echo '— Tentativas esgotadas'
reset role; select testes.entrar('dona@regras.local'); set role authenticated;
update public.regras_followup set intervalos = '{}', ao_esgotar = 'encerrar'
 where clinica_id = testes.v('r') and situacao = 'orcamento_apresentado';
update public.regras_followup set intervalos = '{2}', ao_esgotar = 'decidir'
 where clinica_id = testes.v('r') and situacao = 'pensando';
reset role; select testes.entrar('sec@regras.local'); set role authenticated;

select testes.guardar('bea', testes.pessoa_r('Beatriz Nunes', '+5511930000002'));
select testes.guardar('op_bea', testes.op_r(testes.v('bea'), 'Em contato'));
insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, apresentado_em)
values (testes.v('r'), testes.v('bea'), testes.v('op_bea'), 'apresentado', 150000, testes.hoje());
select public.registrar_acao((testes.pend_r(testes.v('bea'))).id, 'nao_respondeu');
select testes.ok((select o.resultado = 'nao_fechou' and m.nome = 'Parou de responder'
                  from public.oportunidades o join public.motivos m on m.id = o.motivo_id where o.id = testes.v('op_bea'))
             and (select tipo = 'retorno_por_motivo' and vence_em = testes.util_r(90) from testes.pend_r(testes.v('bea'))),
  'regra com "encerrar": sem resposta vira "Não fechou — parou de responder" com retomada em 90 dias');

select testes.guardar('cris', testes.pessoa_r('Cristiane Melo', '+5511930000003'));
select testes.guardar('op_cris', testes.op_r(testes.v('cris'), 'Em contato'));
select public.mover_etapa_manual(testes.v('op_cris'), testes.etr('Negociação / pensando'), null, null, '{"criar": true}');
select public.registrar_acao((testes.pend_r(testes.v('cris'))).id, 'nao_respondeu');
select testes.ok((select passo = 2 and vence_em = testes.util_r(2) from testes.pend_r(testes.v('cris'))),
  'pensando: 2ª tentativa com o intervalo editado (2 dias)');
select public.registrar_acao((testes.pend_r(testes.v('cris'))).id, 'nao_respondeu');
select testes.ok((select tipo = 'definir_proxima_acao' and descricao like '%2 tentativas%' from testes.pend_r(testes.v('cris'))),
  'regra com "decidir": depois das tentativas, a usuária decide o próximo passo');

-- Proteção: regra "Sem resposta" apontando para a própria etapa não deixa ninguém esquecido.
reset role; select testes.entrar('dona@regras.local'); set role authenticated;
update public.regras_followup set intervalos = '{}', ao_esgotar = 'sem_resposta'
 where clinica_id = testes.v('r') and situacao = 'sem_resposta';
reset role; select testes.entrar('sec@regras.local'); set role authenticated;
select testes.guardar('fe', testes.pessoa_r('Fernanda Sá', '+5511930000006'));
select testes.guardar('op_fe', testes.op_r(testes.v('fe'), 'Em contato'));
select public.mover_etapa_manual(testes.v('op_fe'), testes.etr('Sem resposta'), null, null, '{"criar": true}');
select public.registrar_acao((testes.pend_r(testes.v('fe'))).id, 'nao_respondeu');
select testes.ok((select tipo = 'definir_proxima_acao' from testes.pend_r(testes.v('fe'))),
  'regra que apontaria para a própria etapa: a decisão volta para a usuária');

\echo '— Regra desligada'
reset role; select testes.entrar('dona@regras.local'); set role authenticated;
update public.regras_followup set ativa = false where clinica_id = testes.v('r') and situacao = 'compareceu';
reset role; select testes.entrar('sec@regras.local'); set role authenticated;
select testes.guardar('dani', testes.pessoa_r('Daniela Paz', '+5511930000004'));
select testes.guardar('op_dani', testes.op_r(testes.v('dani'), 'Em contato'));
select testes.ok((select s ->> 'tipo' is null and s ->> 'explicacao' like '%desligada%'
                  from public.sugerir_acao(testes.v('op_dani'), testes.etr('Compareceu')) s),
  'regra desligada: o funil avisa que não haverá ação automática');
select public.mover_etapa(testes.v('op_dani'), testes.etr('Compareceu'));
update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste' where pessoa_id = testes.v('dani') and status = 'pendente';
reset role;
select public.preparar_dia(testes.v('r'), true);
select testes.ok((select tipo = 'definir_proxima_acao' from testes.pend_r(testes.v('dani'))),
  '...mas a rotina diária garante que ninguém fique esquecido');

\echo '— Fechou → tratamento → retorno'
select testes.entrar('sec@regras.local'); set role authenticated;
select testes.guardar('eli', testes.pessoa_r('Elisa Prado', '+5511930000005'));
select testes.guardar('op_eli', testes.op_r(testes.v('eli'), 'Negociação / pensando'));
select public.mover_etapa_manual(testes.v('op_eli'), testes.etr('Fechou'), null, null, '{"criar": true}');
select testes.ok((select em_tratamento from public.pessoas where id = testes.v('eli'))
             and (select status_atual = 'em_tratamento' from public.v_contatos where id = testes.v('eli')),
  'fechou: sai do funil de vendas e fica "em tratamento"');
select public.concluir_tratamento(testes.v('eli'));
select testes.ok((select retorno_previsto_em = (testes.hoje() + interval '6 months')::date from public.pessoas where id = testes.v('eli'))
             and (select not em_tratamento and ultimo_atendimento_informado = testes.hoje()
                  from public.pessoas where id = testes.v('eli'))
             and not exists (select 1 from public.tarefas where pessoa_id = testes.v('eli') and status = 'pendente'
                              and tipo = 'agendar_tratamento'),
  'concluir o tratamento agenda o retorno para daqui a 6 meses (regra "Retorno após o tratamento")');
select testes.erro(format($$select public.concluir_tratamento(%L, %L)$$, testes.v('eli'), testes.hoje() - 1),
  'futura', 'a data de retorno escolhida precisa ser futura');

reset role;
update public.pessoas set retorno_previsto_em = testes.hoje() where id = testes.v('eli');
select set_config('t.dia', public.preparar_dia(testes.v('r'), true)::text, false);
select testes.ok((current_setting('t.dia')::jsonb ->> 'pos_tratamento')::int = 1
             and (select t.titulo = 'Convidar Elisa para a revisão' and t.regra = 'pos_tratamento'
                     and t.mensagem_sugerida like 'Olá, Elisa!%revisão%'
                  from testes.pend_r(testes.v('eli')) t)
             and (select retorno_previsto_em is null from public.pessoas where id = testes.v('eli')),
  'chegou a data do retorno: a paciente vai para "Reativação" com o convite e a mensagem');

\echo '— Campanhas de reativação'
select testes.guardar('g1', testes.pessoa_r('Gustavo Antigo', '+5511930000011', 'paciente_antigo'));
select testes.guardar('g2', testes.pessoa_r('Helena Antiga', '+5511930000012', 'paciente_antigo'));
select testes.guardar('g3', testes.pessoa_r('Igor Antigo', '+5511930000013', 'paciente_antigo'));
select testes.guardar('g4', testes.pessoa_r('Joana Recente', '+5511930000014', 'paciente_antigo'));
select testes.guardar('g5', testes.pessoa_r('Lara Bloqueada', '+5511930000015', 'paciente_antigo'));
update public.pessoas set ultimo_atendimento_informado = testes.hoje() - 800, consentimento_marketing = true
 where id in (testes.v('g1'), testes.v('g2'), testes.v('g5'));
update public.pessoas set ultimo_atendimento_informado = testes.hoje() - 800 where id = testes.v('g3');
update public.pessoas set ultimo_atendimento_informado = testes.hoje() - 60 where id = testes.v('g4');
update public.pessoas set nao_contatar = true, nao_contatar_motivo = 'Pediu' where id = testes.v('g5');

select testes.entrar('sec@regras.local'); set role authenticated;
select testes.ok((select array_agg(nome order by nome) from public.prever_campanha(testes.v('r'), 'inativos', 12))
                   = array['Gustavo Antigo', 'Helena Antiga', 'Igor Antigo']
             and (select count(*) from public.prever_campanha(testes.v('r'), 'inativos', 12, null, true)) = 2,
  'prévia: inativos há 12 meses, sem quem não aceita contato; filtro de consentimento de marketing');
select testes.erro($$select public.criar_campanha(testes.v('r'), 'Teste', 'inativos', 12, null, false, 'Oi', 5, testes.hoje())$$,
  'Somente a administradora', 'secretária não cria campanhas');

reset role; select testes.entrar('dona@regras.local'); set role authenticated;
select set_config('t.camp', (public.criar_campanha(testes.v('r'), 'Volta às aulas', 'inativos', 12, null, false,
  'Olá, {primeiro_nome}! Sentimos sua falta. Que tal uma avaliação?', 2, testes.hoje())) ->> 'id', false);
select testes.ok((select count(*) = 3 from public.campanha_destinatarios where campanha_id = current_setting('t.camp')::uuid)
             and (select count(distinct contato_em) = 2 from public.campanha_destinatarios
                   where campanha_id = current_setting('t.camp')::uuid)
             and (select t.mensagem_sugerida = 'Olá, Gustavo! Sentimos sua falta. Que tal uma avaliação?'
                     and t.titulo = 'Convidar Gustavo — Volta às aulas' and t.regra = 'campanha'
                  from testes.pend_r(testes.v('g1')) t)
             and (select e.marco = 'reativacao' from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                   where o.pessoa_id = testes.v('g1') and o.status = 'aberta'),
  'campanha: 3 pessoas, no máximo 2 por dia, mensagem personalizada e cartão em "Reativação"');
select testes.ok((select count(*) from public.prever_campanha(testes.v('r'), 'inativos', 12)) = 0,
  'quem já está numa campanha não entra em outra (sem excesso de contatos)');

reset role; select testes.entrar('sec@regras.local'); set role authenticated;
select public.registrar_acao((testes.pend_r(testes.v('g1'))).id, 'respondeu_interesse', 'whatsapp');
select testes.ok((select pessoas = 3 and contatadas = 1 and responderam = 1 and a_contatar = 2
                  from public.v_campanhas where id = current_setting('t.camp')::uuid),
  'resultado da campanha: contatadas, responderam e a contatar');
select testes.erro(format($$select public.encerrar_campanha(%L)$$, current_setting('t.camp')),
  'não encontrada', 'secretária não encerra campanhas');

reset role; select testes.entrar('dona@regras.local'); set role authenticated;
select set_config('t.enc', public.encerrar_campanha(current_setting('t.camp')::uuid)::text, false);
select testes.ok(current_setting('t.enc') = '2'
             and not exists (select 1 from public.oportunidades where pessoa_id = testes.v('g2') and status = 'aberta')
             and exists (select 1 from public.oportunidades where pessoa_id = testes.v('g1') and status = 'aberta'),
  'encerrar: contatos não feitos são cancelados; quem respondeu segue no funil');

select testes.guardar('clar', (select id from public.procedimentos where clinica_id = testes.v('r') and nome = 'Clareamento dental'));
insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
values (testes.v('r'), testes.v('g4'), testes.v('clar'), testes.hoje() - 400);
select testes.ok((select array_agg(nome) from public.prever_campanha(testes.v('r'), 'procedimento', 12, testes.v('clar')))
                   = array['Joana Recente'],
  'segmento por procedimento: quem fez clareamento há mais de 12 meses');
-- Pagamento em atraso: fica de fora da campanha.
select testes.guardar('g6', testes.pessoa_r('Mário Devedor', '+5511930000016', 'paciente_antigo'));
reset role;
update public.pessoas set ultimo_atendimento_informado = testes.hoje() - 800 where id = testes.v('g6');
with v as (
  insert into public.vendas (clinica_id, pessoa_id, tipo, valor_total_centavos, condicao_pagamento, quantidade_parcelas, fechada_em)
  values (testes.v('r'), testes.v('g6'), 'saldo_anterior', 50000, 'a_vista', 1, testes.hoje() - 60) returning id
) select public.gerar_parcelas(id, testes.hoje() - 10) from v;
select testes.entrar('dona@regras.local'); set role authenticated;
select testes.ok(not exists (select 1 from public.prever_campanha(testes.v('r'), 'inativos', 12) where nome = 'Mário Devedor'),
  'quem está com pagamento em atraso não entra em campanha');
select testes.ok((select count(*) from public.prever_campanha(testes.v('r'), 'nao_fecharam', 1)) = 0,
  'segmento "não fecharam": ninguém encerrado há mais de 1 mês ainda');

reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.erro($$select * from public.prever_campanha(testes.v('r'), 'inativos', 12)$$, 'Sem acesso',
  'outra clínica não vê a prévia desta');
select testes.ok((select count(*) from public.v_campanhas where clinica_id = testes.v('r')) = 0
             and (select count(*) from public.regras_followup where clinica_id = testes.v('r')) = 0,
  'outra clínica não vê campanhas nem regras desta');
reset role;

\echo '✓ Regras de follow-up e campanhas verificadas.'
