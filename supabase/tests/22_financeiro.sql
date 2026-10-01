-- =============================================================================
-- Testes da visão financeira simples (contas a receber).
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('fc', public.inicializar_clinica('Clínica Financeira'));
insert into auth.users (email, raw_user_meta_data) values ('sec@fin.local', '{"nome": "Secretária Fin"}');
select public.adicionar_membro(testes.v('fc'), 'sec@fin.local', 'comercial');
create function testes.forma(nome text) returns uuid language sql as
  $$ select id from public.formas_pagamento where clinica_id = testes.v('fc') and formas_pagamento.nome = forma.nome $$;
create function testes.parc(venda uuid, n int) returns public.v_financeiro_parcelas language sql as
  $$ select * from public.v_financeiro_parcelas where venda_id = venda and numero = n $$;
create function testes.neg(venda uuid) returns public.v_financeiro_negociacoes language sql as
  $$ select * from public.v_financeiro_negociacoes where id = venda $$;
grant execute on all functions in schema testes to authenticated, anon;

\echo '— Formas de pagamento'
select testes.ok((select string_agg(nome, ' | ' order by ordem) from public.formas_pagamento where clinica_id = testes.v('fc'))
                   = 'PIX | Cartão à vista | Cartão parcelado | Dinheiro | Transferência'
             and (select bool_and(recebe_na_hora) from public.formas_pagamento where clinica_id = testes.v('fc') and nome like 'Cartão%'),
  'formas iniciais: PIX, cartão à vista, cartão parcelado, dinheiro e transferência');

reset role; select testes.entrar('sec@fin.local'); set role authenticated;

\echo '— Negociação com entrada em data futura (exemplo da Maria)'
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('fc'), 'Maria Silva', '+5511960000001') returning id
) select testes.guardar('maria', id) from x;
select set_config('t.r', public.registrar_negociacao(testes.v('fc'), testes.v('maria'),
  (select id from public.procedimentos where clinica_id = testes.v('fc') and nome = 'Facetas de porcelana'),
  500000, 0, 200000, testes.hoje() + 9, testes.forma('PIX'), 3, testes.hoje() + 40, testes.forma('Transferência'),
  'Entrada no PIX; restante por transferência')::text, false);
select testes.guardar('v_maria', (current_setting('t.r')::jsonb ->> 'venda_id')::uuid);
select testes.ok((select pessoa_nome = 'Maria Silva' and procedimento = 'Facetas de porcelana' and valor_final_centavos = 500000
                     and entrada_centavos = 200000 and quantidade_parcelas = 3 and valor_parcela_centavos = 100000
                     and forma_pagamento = 'Transferência' and observacao = 'Entrada no PIX; restante por transferência'
                     and situacao = 'pendente' and saldo_centavos = 500000
                  from testes.neg(testes.v('v_maria'))),
  'negociação: paciente, procedimento, valor, forma, parcelas, valor da parcela, status e observações');
select testes.ok((select vencimento = testes.hoje() + 9 and valor_centavos = 200000 and forma_pagamento = 'PIX' and situacao = 'pendente'
                  from testes.parc(testes.v('v_maria'), 0))
             and (select vencimento = testes.hoje() + 40 from testes.parc(testes.v('v_maria'), 1))
             and (current_setting('t.r')::jsonb ->> 'lembretes')::int = 4,
  'entrada com data e forma próprias; cada pagamento futuro tem lembrete');
select testes.ok((select t.titulo = 'Pagamento previsto — Maria Silva — R$ 2.000,00' and t.vence_em = testes.hoje() + 9
                  from public.tarefas t where t.parcela_id = (testes.parc(testes.v('v_maria'), 0)).id and t.status = 'pendente'),
  'no dia da entrada, o painel mostra "Pagamento previsto — Maria Silva — R$ 2.000,00"');
select testes.ok((select o.status = 'ganha' and e.resultado = 'fechou' from public.oportunidades o
                    join public.etapas_funil e on e.id = o.etapa_id where o.pessoa_id = testes.v('maria')),
  'a negociação vai para "Fechou" no funil');

\echo '— Pagamento parcial, total e atraso'
select public.registrar_pagamento((testes.parc(testes.v('v_maria'), 0)).id, 50000, testes.hoje(), testes.forma('PIX'), 'Adiantou uma parte');
select testes.ok((select situacao = 'parcial' and saldo_centavos = 150000 from testes.parc(testes.v('v_maria'), 0))
             and (select situacao = 'parcial' and pago_centavos = 50000 from testes.neg(testes.v('v_maria')))
             and (select titulo like '%R$ 1.500,00' from public.tarefas
                   where parcela_id = (testes.parc(testes.v('v_maria'), 0)).id and status = 'pendente'),
  'pagamento parcial: "parcialmente pago" e o lembrete passa a mostrar o saldo');
select testes.erro(format($$select public.registrar_pagamento(%L, 999999)$$, (testes.parc(testes.v('v_maria'), 0)).id),
  'maior que o saldo', 'não recebe mais do que o saldo');
select testes.erro(format($$select public.registrar_pagamento(%L, null, %L)$$, (testes.parc(testes.v('v_maria'), 0)).id, testes.hoje() + 1),
  'não pode ser futura', 'data do pagamento não pode ser futura');
select public.registrar_pagamento((testes.parc(testes.v('v_maria'), 0)).id);
select testes.ok((select situacao = 'pago' and pago_em = testes.hoje() from testes.parc(testes.v('v_maria'), 0))
             and not exists (select 1 from public.tarefas where parcela_id = (testes.parc(testes.v('v_maria'), 0)).id and status = 'pendente'),
  'quitou: "pago", com a data de pagamento, e o lembrete sai do painel');

reset role;
update public.parcelas set vencimento = testes.hoje() - 3 where venda_id = testes.v('v_maria') and numero = 1;
select testes.entrar('sec@fin.local'); set role authenticated;
select testes.ok((select situacao = 'atrasado' and dias_atraso = 3 from testes.parc(testes.v('v_maria'), 1))
             and (select situacao = 'atrasado' and atrasado_centavos = 100000 from testes.neg(testes.v('v_maria')))
             and exists (select 1 from public.v_tarefas_abertas where parcela_id = (testes.parc(testes.v('v_maria'), 1)).id
                          and dias_atraso = 3),
  'passou da data: "atrasado" há 3 dias, no painel e na negociação');
select public.mudar_vencimento((testes.parc(testes.v('v_maria'), 1)).id, testes.hoje() + 5, 'Pediu para pagar dia 5');
select testes.ok((select situacao = 'pendente' and observacao = 'Pediu para pagar dia 5' from testes.parc(testes.v('v_maria'), 1))
             and (select vence_em = testes.hoje() + 5 from public.tarefas
                   where parcela_id = (testes.parc(testes.v('v_maria'), 1)).id and status = 'pendente'),
  'nova data combinada: o lembrete acompanha');
select testes.erro(format($$select public.mudar_vencimento(%L, %L)$$, (testes.parc(testes.v('v_maria'), 1)).id, testes.hoje() - 1),
  'hoje ou uma data futura', 'nova data não pode estar no passado');

\echo '— Cartão: recebido na hora'
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('fc'), 'Bruno Alves', '+5511960000002') returning id
) select testes.guardar('bruno', id) from x;
select set_config('t.r', public.registrar_negociacao(testes.v('fc'), testes.v('bruno'), null, 360000, 0, 0, null, null, 6, null,
  testes.forma('Cartão parcelado'))::text, false);
select testes.ok((select situacao = 'pago' and pago_centavos = 360000 and quantidade_parcelas = 6
                  from testes.neg((current_setting('t.r')::jsonb ->> 'venda_id')::uuid))
             and (current_setting('t.r')::jsonb ->> 'lembretes')::int = 0,
  'cartão parcelado em 6x: recebido na hora, sem lembretes de cobrança (paciente sem negociação ganha uma, já fechada)');
select testes.erro(format($$select public.registrar_negociacao(%L, %L, null, 100000, 0, 0, null, null, 2, null, %L)$$,
                          testes.v('fc'), testes.v('bruno'), testes.forma('Cartão à vista')),
  'no máximo 1 parcela', 'cartão à vista não aceita parcelas');
select testes.erro(format($$select public.registrar_negociacao(%L, %L, null, 100000, 0, 200000, null, null, 1, null, %L)$$,
                          testes.v('fc'), testes.v('bruno'), testes.forma('PIX')),
  'entrada não pode ser maior', 'entrada maior que o valor é recusada');

\echo '— Resumo'
select testes.ok((select (r ->> 'recebido_mes')::bigint = 200000 + 360000
                     and (r ->> 'atrasado')::bigint = 0
                     and (r ->> 'pendente')::bigint = 300000
                     and (r ->> 'vendido_mes')::bigint = 860000
                     and (r ->> 'pagamentos_mes')::int = 1 + 1 + 6
                  from public.resumo_financeiro(testes.v('fc'), testes.hoje()) r),
  'resumo: total recebido no mês, pendente, atrasado, vendido e pagamentos do mês');

\echo '— Segurança'
reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.erro(format($$select public.registrar_negociacao(%L, %L, null, 100000, 0, 0, null, null, 1, null, %L)$$,
                          testes.v('fc'), testes.v('bruno'), testes.forma('PIX')),
  'Sem acesso ao financeiro', 'outra clínica não registra negociações nesta');
select testes.ok((select count(*) from public.v_financeiro_negociacoes where clinica_id = testes.v('fc')) = 0,
  'outra clínica não vê o financeiro desta');
reset role;

\echo '✓ Financeiro verificado.'
