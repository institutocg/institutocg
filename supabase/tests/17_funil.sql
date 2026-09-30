-- =============================================================================
-- Testes do funil comercial: sugestões por etapa e movimentação manual.
-- Usa as ferramentas de 10_integridade.sql e 15_motor_de_acoes.sql.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('f', public.inicializar_clinica('Clínica do Funil'));
insert into auth.users (email, raw_user_meta_data) values ('sec@funil.local', '{"nome": "Secretária Funil"}');
select public.adicionar_membro(testes.v('f'), 'sec@funil.local', 'comercial');

create function testes.etf(nome text) returns uuid language sql as
  $$ select id from public.etapas_funil where clinica_id = testes.v('f') and nome = etf.nome $$;
create function testes.pessoa_f(nome text, fone text) returns uuid language sql as $$
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('f'), nome, fone) returning id
$$;
create function testes.op_f(p uuid, etapa text) returns uuid language sql as $$
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (testes.v('f'), p, (select id from public.procedimentos where clinica_id = testes.v('f') and nome = 'Facetas de porcelana'),
          testes.etf(etapa))
  returning id
$$;
create function testes.pend_op(op uuid) returns public.tarefas language sql as
  $$ select * from public.tarefas where oportunidade_id = op and status = 'pendente' order by vence_em limit 1 $$;
create function testes.util_f(dias int) returns date language sql as
  $$ select public.proximo_dia_util(testes.v('f'), testes.hoje() + dias) $$;
grant execute on all functions in schema testes to authenticated, anon;

\echo '— Etapas padrão'
select testes.ok((select string_agg(nome, ' | ' order by ordem) from public.etapas_funil where clinica_id = testes.v('f'))
  = 'Novo contato | Em contato | Avaliação agendada | Compareceu | Orçamento apresentado | Negociação / pensando | Desmarcou | Sem resposta | Reativação | Fechou | Não fechou | Desistiu',
  'funil com as etapas combinadas (editáveis: nome, cor e prazo)');

reset role; select testes.entrar('sec@funil.local'); set role authenticated;

select testes.guardar('lu', testes.pessoa_f('Luana Prado', '+5511920000001'));
select testes.guardar('op_lu', testes.op_f(testes.v('lu'), 'Em contato'));

\echo '— Sugestões por etapa'
select testes.ok((select s ->> 'tipo' = 'follow_up_orcamento' and (s ->> 'vence_em')::date = testes.util_f(3)
                  and s ->> 'titulo' = 'Retornar Luana sobre facetas de porcelana' and s ->> 'mensagem' like 'Olá, Luana!%'
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Orçamento apresentado')) s),
  'orçamento apresentado → follow-up leve em 3 dias, com mensagem');
select testes.ok((select s ->> 'tipo' = 'acompanhar_decisao' and (s ->> 'vence_em')::date = testes.util_f(4)
                  and s ->> 'explicacao' like '%3 contatos espaçados (4, 10, 20 dias)%'
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Negociação / pensando')) s),
  'pensando → sequência de acompanhamento espaçada (4, 10, 20 dias)');
select testes.ok((select s ->> 'tipo' = 'reabrir_sem_resposta' and (s ->> 'vence_em')::date = testes.util_f(7)
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Sem resposta')) s),
  'sem resposta → nova tentativa em 7 dias');
select testes.ok((select s ->> 'tipo' = 'recuperar_desmarcacao' and s ->> 'prioridade' = 'urgente'
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Desmarcou')) s),
  'desmarcou → recuperação ainda hoje');
select testes.ok((select s ->> 'requer' = 'agendamento'
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Avaliação agendada')) s),
  'avaliação agendada → pede data e horário');
select testes.ok((select s ->> 'requer' = 'motivo' and s ->> 'vence_em' is null
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Não fechou')) s)
             and (select (s ->> 'vence_em')::date = testes.util_f(30) and s ->> 'descricao' = 'Não fechou: valor alto'
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Não fechou'),
                        (select id from public.motivos where clinica_id = testes.v('f') and nome = 'Valor alto')) s),
  'não fechou → o motivo define quando retomar (valor alto = 30 dias)');
select testes.ok((select s ->> 'requer' = 'financeiro' and s ->> 'tipo' = 'agendar_tratamento'
                  from public.sugerir_acao(testes.v('op_lu'), testes.etf('Fechou')) s),
  'fechou → direciona para o registro financeiro');

\echo '— Mover com a ação editada pela usuária'
select public.mover_etapa_manual(testes.v('op_lu'), testes.etf('Orçamento apresentado'), 'Apresentado na avaliação', null,
  jsonb_build_object('criar', true, 'titulo', 'Mandar áudio para a Luana', 'vence_em', testes.hoje() + 5,
                     'mensagem', 'Oi, Luana! Gravei um áudio explicando as etapas.', 'valor_centavos', 1800000));
select testes.ok((select t.titulo = 'Mandar áudio para a Luana' and t.vence_em = testes.util_f(5)
                  and t.mensagem_sugerida = 'Oi, Luana! Gravei um áudio explicando as etapas.' and t.regra = 'R-FUN-01'
                  from testes.pend_op(testes.v('op_lu')) t)
             and (select count(*) from public.tarefas where oportunidade_id = testes.v('op_lu') and status = 'pendente') = 1
             and (select valor_estimado_centavos = 1800000 from public.oportunidades where id = testes.v('op_lu')),
  'título, data e mensagem editados valem; a ação antiga é substituída; valor potencial registrado');
select testes.ok((select observacao = 'Apresentado na avaliação' from public.historico_etapas
                  where oportunidade_id = testes.v('op_lu') order by mudou_em desc, id desc limit 1),
  'observação da mudança vai para o histórico');

select public.mover_etapa_manual(testes.v('op_lu'), testes.etf('Negociação / pensando'), null, null, '{"criar": false}');
select testes.ok((select count(*) from public.tarefas where oportunidade_id = testes.v('op_lu') and status = 'pendente') = 0,
  'a usuária pode recusar a ação automática');
select testes.erro(format($$select public.mover_etapa_manual(%L, %L)$$, testes.v('op_lu'), testes.etf('Negociação / pensando')),
  'já está nesta etapa', 'não move para a mesma etapa');

select testes.guardar('qu', testes.pessoa_f('Quésia Rocha', '+5511920000008'));
select testes.guardar('op_qu', testes.op_f(testes.v('qu'), 'Em contato'));
select public.mover_etapa_manual(testes.v('op_qu'), testes.etf('Avaliação agendada'), null, null, '{"criar": true}');
select testes.ok((select tipo = 'follow_up' and titulo = 'Combinar a data da avaliação com Quésia' from testes.pend_op(testes.v('op_qu'))),
  'avaliação agendada sem data ainda: a próxima ação é combinar a data');

\echo '— Desmarcou'
select testes.guardar('ma', testes.pessoa_f('Marcela Dias', '+5511920000002'));
select testes.guardar('op_ma', testes.op_f(testes.v('ma'), 'Em contato'));
select public.mover_etapa_manual(testes.v('op_ma'), testes.etf('Avaliação agendada'), null, null,
  jsonb_build_object('agendar_em', to_char(testes.util_f(6), 'YYYY-MM-DD') || 'T10:00'));
select testes.ok((select a.status = 'agendado' and to_char(a.inicio at time zone 'America/Sao_Paulo', 'HH24:MI') = '10:00'
                  from public.agendamentos a where a.oportunidade_id = testes.v('op_ma'))
             and (select tipo = 'confirmar_agendamento' from testes.pend_op(testes.v('op_ma'))),
  'avaliação agendada: cria o agendamento e a confirmação na véspera');
select public.mover_etapa_manual(testes.v('op_ma'), testes.etf('Desmarcou'), 'Viagem a trabalho', null,
  jsonb_build_object('criar', true));
select testes.ok((select status = 'desmarcado' from public.agendamentos where oportunidade_id = testes.v('op_ma'))
             and (select count(*) from public.tarefas where oportunidade_id = testes.v('op_ma') and status = 'pendente') = 1
             and (select tipo = 'recuperar_desmarcacao' and vence_em = testes.util_f(0) from testes.pend_op(testes.v('op_ma'))),
  'desmarcou pelo funil: agendamento desmarcado e uma única tarefa de recuperação');
select public.mover_etapa_manual(testes.v('op_ma'), testes.etf('Avaliação agendada'), null, null,
  jsonb_build_object('agendar_em', to_char(testes.util_f(8), 'YYYY-MM-DD') || 'T15:30'));
select testes.ok((select e.nome = 'Avaliação agendada' from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                  where o.id = testes.v('op_ma')),
  'de "Desmarcou" volta para "Avaliação agendada" ao reagendar');

-- Desmarcação feita na agenda também move o cartão.
update public.agendamentos set status = 'desmarcado' where oportunidade_id = testes.v('op_ma') and status = 'agendado';
select testes.ok((select e.nome = 'Desmarcou' from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                  where o.id = testes.v('op_ma'))
             and (select tipo = 'recuperar_desmarcacao' from testes.pend_op(testes.v('op_ma'))),
  'desmarcação registrada na agenda leva o cartão para "Desmarcou" com recuperação');

\echo '— Não fechou, reativação e retomada'
select testes.guardar('ni', testes.pessoa_f('Nina Castro', '+5511920000003'));
select testes.guardar('op_ni', testes.op_f(testes.v('ni'), 'Orçamento apresentado'));
select testes.erro(format($$select public.mover_etapa_manual(%L, %L)$$, testes.v('op_ni'), testes.etf('Não fechou')),
  'Informe o motivo', '"Não fechou" exige motivo');
select public.mover_etapa_manual(testes.v('op_ni'), testes.etf('Não fechou'), null,
  (select id from public.motivos where clinica_id = testes.v('f') and nome = 'Valor alto'),
  jsonb_build_object('criar', true, 'vence_em', testes.hoje() + 45));
select testes.ok((select status = 'perdida' and reabre_em = testes.hoje() + 45 from public.oportunidades where id = testes.v('op_ni'))
             and (select tipo = 'retorno_por_motivo' and vence_em = testes.util_f(45) and categoria = 'recuperacao'
                  from testes.pend_op(testes.v('op_ni'))),
  'não fechou: possibilidade de retomada na data escolhida (45 dias), sem contatos até lá');
select testes.erro(format($$select public.mover_etapa_manual(%L, %L)$$, testes.v('op_ni'), testes.etf('Fechou')),
  'já foi encerrada', 'negociação encerrada não vai direto para outro resultado');

-- Chegou a data do retorno: a rotina leva a pessoa para "Reativação".
reset role;
update public.tarefas set vence_em = testes.hoje() where oportunidade_id = testes.v('op_ni') and status = 'pendente';
select public.preparar_dia(testes.v('f'), true);
select testes.ok((select count(*) from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                  where o.pessoa_id = testes.v('ni') and o.status = 'aberta' and e.nome = 'Reativação'
                    and o.oportunidade_origem_id = testes.v('op_ni')) = 1
             and (select status = 'perdida' from public.oportunidades where id = testes.v('op_ni'))
             and (select t.tipo = 'retorno_por_motivo' and o.oportunidade_origem_id = testes.v('op_ni')
                  from public.tarefas t join public.oportunidades o on o.id = t.oportunidade_id
                  where t.pessoa_id = testes.v('ni') and t.status = 'pendente'),
  'na data combinada, a pessoa aparece em "Reativação" (o "não fechou" original fica no histórico)');
select testes.entrar('sec@funil.local'); set role authenticated;

select testes.guardar('ot', testes.pessoa_f('Otávio Reis', '+5511920000004'));
select testes.guardar('op_ot', testes.op_f(testes.v('ot'), 'Em contato'));
select public.mover_etapa_manual(testes.v('op_ot'), testes.etf('Não fechou'), null,
  (select id from public.motivos where clinica_id = testes.v('f') and nome = 'Escolheu outra clínica'), '{"criar": false}');
select testes.ok(not exists (select 1 from public.tarefas where oportunidade_id = testes.v('op_ot') and status = 'pendente'),
  'não fechou sem retomada: nenhuma tarefa');
select public.mover_etapa_manual(testes.v('op_ot'), testes.etf('Reativação'), 'Voltou a falar conosco', null,
  jsonb_build_object('criar', true));
select testes.ok((select count(*) from public.oportunidades where pessoa_id = testes.v('ot')) = 2
             and (select tipo = 'reativacao' from public.tarefas where pessoa_id = testes.v('ot') and status = 'pendente'),
  'mover um "não fechou" para Reativação abre uma nova negociação com tarefa de reaproximação');

\echo '— Sem resposta'
select testes.guardar('pe', testes.pessoa_f('Pedro Lins', '+5511920000005'));
select testes.guardar('op_pe', testes.op_f(testes.v('pe'), 'Orçamento apresentado'));
select public.mover_etapa_manual(testes.v('op_pe'), testes.etf('Sem resposta'), null, null, '{"criar": true}');
select testes.ok((select status = 'pausada' from public.oportunidades where id = testes.v('op_pe'))
             and (select tipo = 'reabrir_sem_resposta' and vence_em = testes.util_f(7) from testes.pend_op(testes.v('op_pe'))),
  'sem resposta: negociação pausada com nova tentativa em 7 dias');
select public.registrar_acao((testes.pend_op(testes.v('op_pe'))).id, 'nao_respondeu');
select public.registrar_acao((testes.pend_op(testes.v('op_pe'))).id, 'nao_respondeu');
select public.registrar_acao((testes.pend_op(testes.v('op_pe'))).id, 'nao_respondeu');
select testes.ok((select tipo = 'definir_proxima_acao' from testes.pend_op(testes.v('op_pe'))),
  'depois de 3 tentativas espaçadas, a decisão volta para a usuária (sem insistência)');

\echo '— Fechou → financeiro'
select testes.guardar('ra', testes.pessoa_f('Raquel Moura', '+5511920000006'));
select testes.guardar('op_ra', testes.op_f(testes.v('ra'), 'Negociação / pensando'));
select public.mover_etapa_manual(testes.v('op_ra'), testes.etf('Fechou'), null, null,
  jsonb_build_object('criar', true, 'venda', jsonb_build_object(
    'valor_total_centavos', 1500000, 'desconto_centavos', 100000, 'entrada_centavos', 200000, 'parcelas', 4,
    'forma_pagamento_id', (select id from public.formas_pagamento where clinica_id = testes.v('f') and nome = 'PIX'),
    'primeiro_vencimento', testes.hoje() + 30)));
select testes.ok((select status = 'ganha' and valor_fechado_centavos = 1400000 from public.oportunidades where id = testes.v('op_ra'))
             and (select count(*) = 5 and sum(valor_centavos) = 1400000 from public.parcelas p join public.vendas v on v.id = p.venda_id
                  where v.oportunidade_id = testes.v('op_ra'))
             and (select count(*) from public.tarefas where pessoa_id = testes.v('ra') and tipo = 'confirmar_pagamento'
                    and status = 'pendente') = 5
             and (select tipo = 'agendar_tratamento' from public.tarefas where pessoa_id = testes.v('ra') and status = 'pendente'
                    and categoria <> 'financeiro'),
  'fechou com valores: venda, entrada + 4 parcelas, lembretes de pagamento e "agendar início"');

\echo '— Espaçamento e segurança'
reset role;
-- Paciente contatado ontem: a reativação respeita o intervalo mínimo (3 dias).
select testes.guardar('so', testes.pessoa_f('Solange Vaz', '+5511920000007'));
update public.pessoas set tipo_cadastro = 'paciente_antigo', ultimo_contato_em = now() - interval '1 day'
 where id = testes.v('so');
select testes.entrar('sec@funil.local'); set role authenticated;
select public.criar_resgate(testes.v('so'));
select testes.ok((select vence_em >= testes.hoje() + 2 from public.tarefas where pessoa_id = testes.v('so') and status = 'pendente'),
  'reativação nunca fica colada no último contato (intervalo mínimo de 3 dias)');

select testes.erro(format($$select public.criar_tarefa_auto(%L, null, 'personalizada', 'outra', 'x', current_date, 'normal', 'R', null)$$,
                          testes.v('so')),
  'permission denied', 'funções internas do motor não podem ser chamadas diretamente');

reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.erro(format($$select public.mover_etapa_manual(%L, %L)$$, testes.v('op_ot'), testes.etf('Em contato')),
  'não encontrada', 'outra clínica não move cartões desta');
select testes.ok(public.sugerir_acao(testes.v('op_ot'), testes.etf('Em contato')) is null,
  'outra clínica não vê sugestões desta');
select testes.erro(format($$select public.criar_resgate(%L)$$, testes.v('so')),
  'não encontrado', 'outra clínica não cria resgate para pacientes desta');
reset role;

\echo '✓ Funil verificado.'

\echo '— Vencimento padrão da 1ª parcela'
select testes.entrar('sec@funil.local'); set role authenticated;
select testes.guardar('ti', testes.pessoa_f('Tina Braga', '+5511920000009'));
select testes.guardar('op_ti', testes.op_f(testes.v('ti'), 'Negociação / pensando'));
select public.mover_etapa_manual(testes.v('op_ti'), testes.etf('Fechou'), null, null,
  jsonb_build_object('criar', false, 'venda', jsonb_build_object('valor_total_centavos', 600000, 'entrada_centavos', 100000, 'parcelas', 2)));
select testes.ok((select min(vencimento) filter (where numero = 1) = testes.hoje() + 30
                     and min(vencimento) filter (where numero = 0) = testes.hoje()
                  from public.parcelas p join public.vendas v on v.id = p.venda_id where v.oportunidade_id = testes.v('op_ti')),
  'com entrada e sem data: entrada hoje e 1ª parcela em 30 dias');
reset role;
