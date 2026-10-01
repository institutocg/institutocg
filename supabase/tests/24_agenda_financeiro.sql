-- =============================================================================
-- Testes da agenda integrada ao financeiro: valor ao agendar e pagamento ao
-- marcar "Compareceu" (sem preencher o financeiro à parte).
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('af', public.inicializar_clinica('Clínica Agenda e Financeiro'));
insert into auth.users (email, raw_user_meta_data) values ('sec@af.local', '{"nome": "Secretária AF"}');
select public.adicionar_membro(testes.v('af'), 'sec@af.local', 'comercial');
insert into auth.users (email, raw_user_meta_data) values ('semfin@af.local', '{"nome": "Sem Financeiro"}');
select public.adicionar_membro(testes.v('af'), 'semfin@af.local', 'comercial', false);

create function testes.proc_af(n text) returns uuid language sql as
  $$ select id from public.procedimentos where clinica_id = testes.v('af') and nome = n $$;
create function testes.forma_af(n text) returns uuid language sql as
  $$ select id from public.formas_pagamento where clinica_id = testes.v('af') and nome = n $$;
create function testes.neg_af(a uuid) returns public.v_financeiro_negociacoes language sql as
  $$ select * from public.v_financeiro_negociacoes where agendamento_id = a $$;
-- Paciente com uma consulta de hoje (como sistema: o horário já passou).
create function testes.consulta_hoje(nome text, fone text, tipo public.tipo_agendamento, proc text, valor bigint)
returns uuid language plpgsql as $$
declare p uuid; a uuid;
begin
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('af'), nome, fone) returning id into p;
  insert into public.agendamentos (clinica_id, pessoa_id, tipo, procedimento_id, inicio, valor_centavos,
                                   profissional_id)
  values (testes.v('af'), p, tipo, testes.proc_af(proc), (testes.hoje() + time '08:00') at time zone 'America/Sao_Paulo',
          valor, (select id from public.profissionais where clinica_id = testes.v('af') limit 1))
  returning id into a;
  return a;
end $$;
grant execute on all functions in schema testes to authenticated, anon;

select testes.guardar('a_pix', testes.consulta_hoje('Pia Pago', '+5511930000001', 'procedimento', 'Clareamento dental', 120000));
select testes.guardar('a_depois', testes.consulta_hoje('Dora Depois', '+5511930000002', 'procedimento', 'Facetas de porcelana', 600000));
select testes.guardar('a_aval', testes.consulta_hoje('Ava Avaliação', '+5511930000003', 'avaliacao', 'Implantes', 30000));
select testes.guardar('a_gratis', testes.consulta_hoje('Gil Cortesia', '+5511930000004', 'avaliacao', null, null));
select testes.guardar('a_cartao', testes.consulta_hoje('Caio Cartão', '+5511930000005', 'procedimento', 'Implantes', 900000));

reset role; select testes.entrar('sec@af.local'); set role authenticated;

\echo '— Valor ao agendar'
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('af'), 'Vera Valor', '+5511930000009') returning id
) select testes.guardar('vera', id) from x;
select set_config('t.r', public.agendar(testes.v('af'), testes.v('vera'), 'procedimento', testes.proc_af('Clareamento dental'),
  (public.proximo_dia_util(testes.v('af'), testes.hoje() + 3) + time '10:00') at time zone 'America/Sao_Paulo', 60,
  (select id from public.profissionais where clinica_id = testes.v('af') limit 1),
  false, null, false, null, null, 'novo_contato', 150000)::text, false);
select testes.guardar('a_vera', (current_setting('t.r')::jsonb ->> 'id')::uuid);
select testes.ok((select valor_centavos = 150000 from public.v_agenda where id = testes.v('a_vera')),
  'ao agendar, o valor do procedimento fica na consulta');
select set_config('t.r', public.remarcar_consulta(testes.v('a_vera'),
  (public.proximo_dia_util(testes.v('af'), testes.hoje() + 5) + time '10:00') at time zone 'America/Sao_Paulo')::text, false);
select testes.ok((select valor_centavos = 150000 from public.agendamentos where id = (current_setting('t.r')::jsonb ->> 'id')::uuid),
  'remarcar leva o valor junto');

\echo '— Compareceu: pago agora'
select set_config('t.r', public.registrar_atendimento(testes.v('a_pix'), 'pago', null, testes.forma_af('PIX'))::text, false);
select testes.ok((select status = 'compareceu' from public.agendamentos where id = testes.v('a_pix'))
             and (select situacao = 'pago' and valor_final_centavos = 120000 and forma_pagamento = 'PIX'
                         and procedimento = 'Clareamento dental' from testes.neg_af(testes.v('a_pix')))
             and (select cobranca = 'pago' from public.v_agenda where id = testes.v('a_pix'))
             and not exists (select 1 from public.tarefas t join public.parcelas pa on pa.id = t.parcela_id
                              where pa.venda_id = (testes.neg_af(testes.v('a_pix'))).id and t.status = 'pendente'),
  'compareceu + pago no PIX: presença registrada, pagamento no financeiro como pago, sem lembrete');
select testes.ok((select o.status = 'ganha' from public.oportunidades o where o.pessoa_id = (select pessoa_id from public.agendamentos where id = testes.v('a_pix'))),
  'procedimento pago: a negociação vai para "Fechou"');
select testes.erro(format($$select public.registrar_atendimento(%L, 'pago', null, %L)$$, testes.v('a_pix'), testes.forma_af('PIX')),
  'já foi registrado', 'não registra a mesma cobrança duas vezes');

\echo '— Compareceu: vai pagar depois'
select testes.erro(format($$select public.registrar_atendimento(%L, 'a_pagar', null, %L)$$, testes.v('a_depois'), testes.forma_af('PIX')),
  'data prevista', 'vai pagar depois: pede a data prevista');
select set_config('t.r', public.registrar_atendimento(testes.v('a_depois'), 'a_pagar', null, testes.forma_af('Transferência'),
  testes.hoje() + 10, 3)::text, false);
select testes.ok((select situacao = 'pendente' and saldo_centavos = 600000 and quantidade_parcelas = 3
                         and proximo_vencimento = testes.hoje() + 10 from testes.neg_af(testes.v('a_depois')))
             and (select count(*) from public.tarefas t join public.parcelas pa on pa.id = t.parcela_id
                   where pa.venda_id = (testes.neg_af(testes.v('a_depois'))).id and t.status = 'pendente') = 3,
  'vai pagar depois em 3x: pendente no financeiro, com um lembrete por parcela');
reset role;
update public.parcelas set vencimento = testes.hoje() - 2
 where venda_id = (select id from public.vendas where agendamento_id = testes.v('a_depois')) and numero = 1;
select testes.entrar('sec@af.local'); set role authenticated;
select testes.ok((select situacao = 'atrasado' from testes.neg_af(testes.v('a_depois')))
             and (select cobranca = 'atrasado' from public.v_agenda where id = testes.v('a_depois'))
             and exists (select 1 from public.v_tarefas_abertas t join public.parcelas pa on pa.id = t.parcela_id
                          where pa.venda_id = (testes.neg_af(testes.v('a_depois'))).id and t.dias_atraso = 2),
  'passou da data prevista: atrasado no financeiro, na agenda e no painel');

\echo '— Avaliação, cortesia e cartão'
select public.registrar_atendimento(testes.v('a_aval'), 'pago', 25000, testes.forma_af('Dinheiro'));
select testes.ok((select situacao = 'pago' and valor_final_centavos = 25000 from testes.neg_af(testes.v('a_aval')))
             and (select o.status = 'aberta' from public.oportunidades o
                   where o.pessoa_id = (select pessoa_id from public.agendamentos where id = testes.v('a_aval'))),
  'avaliação paga (valor ajustado na hora): entra no financeiro sem fechar a negociação');
select testes.erro(format($$select public.registrar_atendimento(%L, 'pago', null, %L)$$, testes.v('a_gratis'), testes.forma_af('PIX')),
  'Informe o valor', 'sem valor na consulta: pede o valor');
select set_config('t.r', public.registrar_atendimento(testes.v('a_gratis'), 'sem_cobranca')::text, false);
select testes.ok((select status = 'compareceu' from public.agendamentos where id = testes.v('a_gratis'))
             and testes.neg_af(testes.v('a_gratis')) is null,
  'sem cobrança: só registra a presença');
select public.registrar_atendimento(testes.v('a_cartao'), 'a_pagar', null, testes.forma_af('Cartão parcelado'), null, 10);
select testes.ok((select situacao = 'pago' and quantidade_parcelas = 10 from testes.neg_af(testes.v('a_cartao'))),
  'cartão parcelado em 10x: recebido na hora, sem lembretes');

\echo '— Quem não vê o financeiro'
reset role;
select testes.guardar('a_semfin', testes.consulta_hoje('Sem Fin', '+5511930000006', 'procedimento', null, 50000));
select testes.entrar('semfin@af.local'); set role authenticated;
select testes.erro(format($$select public.registrar_atendimento(%L, 'pago', null, %L)$$, testes.v('a_semfin'), testes.forma_af('PIX')),
  'não inclui o financeiro', 'sem acesso ao financeiro: não registra pagamento');
select public.registrar_atendimento(testes.v('a_semfin'), 'sem_cobranca');
select testes.ok((select status = 'compareceu' from public.agendamentos where id = testes.v('a_semfin')),
  'sem acesso ao financeiro: registra só a presença');
reset role;

\echo '✓ Agenda integrada ao financeiro verificada.'
