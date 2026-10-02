-- =============================================================================
-- Prontuário simplificado: procedimento livre, "feito hoje", total do plano e
-- pagamento do PLANO (pagamento ≠ realização).
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('ps', public.inicializar_clinica('Clínica Simples'));
insert into auth.users (email, raw_user_meta_data) values ('dra@simples.local', '{"nome": "Dra. Simples"}');
select public.adicionar_membro(testes.v('ps'), 'dra@simples.local', 'admin');
create function testes.forma_s(n text) returns uuid language sql as
  $$ select id from public.formas_pagamento where clinica_id = testes.v('ps') and nome = n $$;
create function testes.sit_s() returns jsonb language sql as
  $$ select public.situacao_plano(public.plano_atual(testes.v('ana_s'))) $$;
grant execute on all functions in schema testes to authenticated, anon;

with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('ps'), 'Ana Souza', '+5511910000001') returning id
) select testes.guardar('ana_s', id) from x;

reset role; select testes.entrar('dra@simples.local'); set role authenticated;

\echo '— Procedimento livre'
select testes.ok(public.procedimento_por_nome(testes.v('ps'), 'Facetas em resina') is not null
             and public.procedimento_por_nome(testes.v('ps'), '  facetas  EM resina ') = public.procedimento_por_nome(testes.v('ps'), 'Facetas em resina')
             and public.procedimento_por_nome(testes.v('ps'), 'clareamento DENTAL')
                 = (select id from public.procedimentos where clinica_id = testes.v('ps') and nome = 'Clareamento dental')
             and public.procedimento_por_nome(testes.v('ps'), '') is null,
  'qualquer procedimento pode ser digitado: acha o existente (sem acento/maiúsculas) ou cria um novo');

\echo '— Consulta 01: orçamento com vários procedimentos'
select testes.guardar('c1_s', public.novo_atendimento(testes.v('ana_s')));
select public.salvar_atendimento(testes.v('c1_s'), '{"motivo_obs": "Quer clarear e trocar as facetas", "queixa": "Dentes amarelados", "anamnese_obs": "Hipertensa, usa losartana. Alergia a dipirona."}');
select testes.ok((select motivo_obs = 'Quer clarear e trocar as facetas' and queixa = 'Dentes amarelados'
                         and anamnese_obs like 'Hipertensa%' from public.atendimentos where id = testes.v('c1_s')),
  'motivo, queixa principal e anamnese em texto livre');
select testes.guardar('i_cl', public.adicionar_procedimento_plano(testes.v('ana_s'), 'Clareamento', 120000, testes.v('c1_s'), true));
select testes.guardar('i_fa', public.adicionar_procedimento_plano(testes.v('ana_s'), 'Facetas em resina', 500000, testes.v('c1_s'), false));
select testes.guardar('i_li', public.adicionar_procedimento_plano(testes.v('ana_s'), 'Limpeza', 35000, testes.v('c1_s'), false));
select testes.ok((testes.sit_s() ->> 'total')::bigint = 655000
             and (select string_agg(procedimento || ':' || status, ' ' order by procedimento) from public.v_plano_tratamento
                   where pessoa_id = testes.v('ana_s')) = 'Clareamento:realizado Facetas em resina:pendente Limpeza:pendente',
  'total automático R$ 6.550; clareamento feito hoje, facetas e limpeza pendentes');

\echo '— Pagou tudo hoje, faz depois'
select public.registrar_pagamento_plano(public.plano_atual(testes.v('ana_s')), 'integral', testes.forma_s('PIX'));
select testes.ok((testes.sit_s() ->> 'pago')::bigint = 655000 and (testes.sit_s() ->> 'pendente')::bigint = 0
             and (select situacao = 'pago' and procedimento = 'Plano de tratamento' from public.v_financeiro_negociacoes
                   where pessoa_id = testes.v('ana_s'))
             and (select count(*) from public.v_plano_tratamento where pessoa_id = testes.v('ana_s') and status = 'pendente') = 2,
  'pagamento ≠ realização: R$ 6.550 pagos hoje, procedimentos seguem pendentes');
select testes.erro(format($$select public.registrar_pagamento_plano(%L, 'integral', %L)$$,
                          public.plano_atual(testes.v('ana_s')), testes.forma_s('PIX')), 'todo no Financeiro',
  'não registra o mesmo valor duas vezes');
select public.salvar_atendimento(testes.v('c1_s'), '{}', true);

\echo '— Consulta 02: pendentes aparecem para marcar'
select testes.guardar('c2_s', public.novo_atendimento(testes.v('ana_s')));
select public.marcar_feito(testes.v('i_li'), testes.v('c2_s'), true);
select testes.ok((select realizado_atendimento_numero = 2 from public.v_plano_tratamento where id = testes.v('i_li'))
             and (select status = 'pendente' from public.v_plano_tratamento where id = testes.v('i_fa')),
  'limpeza feita na consulta 02; facetas continuam pendentes');
select testes.erro(format($$select public.marcar_feito(%L, %L, false)$$, testes.v('i_cl'), testes.v('c2_s')),
  'outra consulta', 'não desfaz o que foi feito em outra consulta');
select public.marcar_feito(testes.v('i_li'), testes.v('c2_s'), false);
select public.marcar_feito(testes.v('i_li'), testes.v('c2_s'), true);
select testes.ok((select status = 'realizado' from public.v_plano_tratamento where id = testes.v('i_li')),
  'na consulta em andamento, dá para desmarcar e marcar de novo');

\echo '— Novo procedimento → pagamento parcial com data prevista'
select public.adicionar_procedimento_plano(testes.v('ana_s'), 'Restauração dente 26', 35000, testes.v('c2_s'), false);
select testes.ok((testes.sit_s() ->> 'total')::bigint = 690000 and (testes.sit_s() ->> 'a_registrar')::bigint = 35000
             and (testes.sit_s() ->> 'pendente')::bigint = 35000,
  'procedimento novo: total sobe e o que falta aparece como pendente');
select testes.erro(format($$select public.registrar_pagamento_plano(%L, 'parcial', %L, 10000)$$,
                          public.plano_atual(testes.v('ana_s')), testes.forma_s('PIX')), 'data prevista',
  'parcial: pede a data prevista do restante');
select public.registrar_pagamento_plano(public.plano_atual(testes.v('ana_s')), 'parcial', testes.forma_s('Dinheiro'),
                                        10000, testes.hoje(), testes.hoje() + 15, 1);
select testes.ok((testes.sit_s() ->> 'pago')::bigint = 665000 and (testes.sit_s() ->> 'pendente')::bigint = 25000
             and (testes.sit_s() ->> 'proximo_vencimento')::date = testes.hoje() + 15
             and exists (select 1 from public.tarefas t join public.parcelas pa on pa.id = t.parcela_id
                          where pa.pessoa_id = testes.v('ana_s') and t.status = 'pendente' and t.vence_em = testes.hoje() + 15),
  'parcialmente pago: total, pago e pendente; o restante tem lembrete na data prevista (pendências do dia)');

\echo '— Remover do plano'
select testes.guardar('i_x', public.adicionar_procedimento_plano(testes.v('ana_s'), 'Clareamento caseiro', 50000, testes.v('c2_s'), false));
select public.remover_item_plano(testes.v('i_x'));
select testes.ok((testes.sit_s() ->> 'total')::bigint = 690000, 'procedimento removido sai do total');
select testes.erro(format($$select public.remover_item_plano(%L)$$, testes.v('i_cl')), 'não sai do plano',
  'procedimento já feito não sai do plano');
reset role;

\echo '✓ Prontuário simplificado verificado.'
