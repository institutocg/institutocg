-- =============================================================================
-- Testes do prontuário: um por paciente, várias consultas, odontograma por
-- consulta, plano de tratamento com status e cobrança no Financeiro.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('pc', public.inicializar_clinica('Clínica do Prontuário'));
insert into auth.users (email, raw_user_meta_data) values
  ('dra@pront.local', '{"nome": "Dra. Pront"}'),
  ('sec@pront.local', '{"nome": "Secretária Pront"}');
select public.adicionar_membro(testes.v('pc'), 'dra@pront.local', 'admin');
select public.adicionar_membro(testes.v('pc'), 'sec@pront.local', 'comercial');

create function testes.proc_p(n text) returns uuid language sql as
  $$ select id from public.procedimentos where clinica_id = testes.v('pc') and nome = n $$;
create function testes.forma_p(n text) returns uuid language sql as
  $$ select id from public.formas_pagamento where clinica_id = testes.v('pc') and nome = n $$;
create function testes.item_p(n text) returns public.v_plano_tratamento language sql as
  $$ select * from public.v_plano_tratamento where clinica_id = testes.v('pc') and procedimento = n $$;
grant execute on all functions in schema testes to authenticated, anon;

-- Maria: paciente cadastrada, com uma consulta hoje (como sistema: o horário já passou).
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('pc'), 'Maria Silva', '+5511920000001') returning id
) select testes.guardar('maria', id) from x;
insert into public.agendamentos (clinica_id, pessoa_id, profissional_id, tipo, procedimento_id, inicio, status)
values (testes.v('pc'), testes.v('maria'), (select id from public.profissionais where clinica_id = testes.v('pc') limit 1),
        'avaliacao', testes.proc_p('Clareamento dental'), (testes.hoje() + time '09:00') at time zone 'America/Sao_Paulo', 'confirmado')
returning id \gset ag_
select testes.guardar('ag1', :'ag_id'::uuid);
insert into public.agendamentos (clinica_id, pessoa_id, tipo, inicio)
values (testes.v('pc'), testes.v('maria'), 'procedimento',
        (public.proximo_dia_util(testes.v('pc'), testes.hoje() + 10) + time '10:00') at time zone 'America/Sao_Paulo')
returning id \gset fut_
select testes.guardar('ag_futuro', :'fut_id'::uuid);

\echo '— Um prontuário por paciente'
select testes.ok((select count(*) from public.prontuarios where pessoa_id = testes.v('maria')) = 1
             and not exists (select 1 from public.pessoas p where not exists (select 1 from public.prontuarios r where r.pessoa_id = p.id)),
  'todo paciente tem prontuário (criado automaticamente, pelo id)');

\echo '— Acesso'
reset role; select testes.entrar('sec@pront.local'); set role authenticated;
select testes.erro(format($$select public.abrir_atendimento(%L)$$, testes.v('ag1')), 'Sem acesso ao prontuário',
  'secretária (comercial) não abre o prontuário');
select testes.ok((select count(*) from public.prontuarios where clinica_id = testes.v('pc')) = 0,
  'secretária não lê prontuários');

reset role; select testes.entrar('dra@pront.local'); set role authenticated;

\echo '— Agenda → consulta 01'
select testes.guardar('c1', public.abrir_atendimento(testes.v('ag1')));
select testes.ok((select numero = 1 and data = testes.hoje() and horario = time '09:00' and tipo = 'avaliacao'
                         and procedimento_id = testes.proc_p('Clareamento dental') and profissional_id is not null
                         and motivo_obs = 'Clareamento dental' and status = 'em_andamento'
                  from public.atendimentos where id = testes.v('c1')),
  'abrir pelo agendamento cria a consulta com paciente, data, horário, dentista e procedimento/motivo');
select testes.ok(public.abrir_atendimento(testes.v('ag1')) = testes.v('c1'), 'abrir de novo reabre a mesma consulta');
select testes.erro(format($$select public.abrir_atendimento(%L)$$, testes.v('ag_futuro')), 'abre no dia',
  'consulta futura: a ficha só abre no dia');

\echo '— Ficha e odontograma'
select public.salvar_atendimento(testes.v('c1'), jsonb_build_object(
  'motivo', jsonb_build_array('Avaliação', 'Estética'), 'anamnese', jsonb_build_array('Hipertensão'),
  'diagnostico', jsonb_build_array('Cárie'), 'evolucao', 'Avaliação completa.', 'orientacoes', jsonb_build_array('Higiene'),
  'retorno_em', (testes.hoje() + 15)::text,
  'odontograma', '{"16": {"c": "carie", "f": ["O"], "s": "a_tratar"}, "21": {"c": "restauracao", "f": ["V"], "s": "existente"}}'::jsonb));
select testes.ok((select anamnese = array['Hipertensão'] and diagnostico = array['Cárie'] and retorno_em = testes.hoje() + 15
                         and odontograma -> '16' ->> 'c' = 'carie' from public.atendimentos where id = testes.v('c1')),
  'a ficha guarda seleções, textos, retorno e odontograma');

\echo '— Plano de tratamento'
select testes.guardar('i_clar', public.adicionar_item_plano(testes.v('maria'), testes.proc_p('Clareamento dental'), 120000, null, testes.v('c1')));
select testes.guardar('i_fac', public.adicionar_item_plano(testes.v('maria'), testes.proc_p('Facetas de porcelana'), 500000, '11, 21', testes.v('c1'), 'aceito'));
select testes.guardar('i_limp', public.adicionar_item_plano(testes.v('maria'), testes.proc_p('Manutenção e limpeza'), 35000, null, testes.v('c1'), 'pendente'));
select testes.ok((select count(*) from public.v_plano_tratamento where pessoa_id = testes.v('maria')) = 3
             and (select valor_final_centavos = 655000 and origem = 'prontuario' and oportunidade_id is null
                  from public.orcamentos where pessoa_id = testes.v('maria'))
             and not exists (select 1 from public.oportunidades where pessoa_id = testes.v('maria'))
             and not exists (select 1 from public.tarefas where pessoa_id = testes.v('maria') and status = 'pendente' and agendamento_id is null),
  'vários procedimentos num plano (orçamento do prontuário), sem mexer no funil nem criar follow-up comercial');
select public.mudar_status_item(testes.v('i_clar'), 'aceito');
select testes.ok((testes.item_p('Clareamento dental')).status = 'aceito', 'status do procedimento: orçado → aceito');

\echo '— Realizar + financeiro (consulta 01)'
select public.realizar_item(testes.v('i_clar'), testes.v('c1'), 'parcial', null, testes.forma_p('PIX'), 50000, testes.hoje() + 20);
select testes.ok((select status = 'realizado' and realizado_atendimento_numero = 1 and financeiro = 'parcial'
                         and saldo_centavos = 70000 and pago_centavos = 50000
                  from testes.item_p('Clareamento dental'))
             and (select situacao = 'parcial' and procedimento = 'Clareamento dental'
                  from public.v_financeiro_negociacoes where pessoa_id = testes.v('maria')),
  'clareamento realizado na consulta 01 com pagamento parcial: aparece no prontuário e no Financeiro');
select testes.ok(exists (select 1 from public.tarefas t join public.parcelas pa on pa.id = t.parcela_id
                          where pa.venda_id = (testes.item_p('Clareamento dental')).venda_id and t.status = 'pendente'
                            and t.vence_em = testes.hoje() + 20),
  'o saldo tem lembrete na data prevista');
select testes.erro(format($$select public.realizar_item(%L, %L, 'sem_cobranca')$$, testes.v('i_clar'), testes.v('c1')),
  'já foi realizado', 'não realiza duas vezes');

\echo '— Pagamento pelo Financeiro aparece no prontuário'
select public.registrar_pagamento((select id from public.parcelas where venda_id = (testes.item_p('Clareamento dental')).venda_id
                                     and status <> 'paga' order by numero limit 1));
select testes.ok((testes.item_p('Clareamento dental')).financeiro = 'pago',
  'quitou no Financeiro → prontuário mostra "pago"');

select public.salvar_atendimento(testes.v('c1'), (select to_jsonb(a) - 'id' from public.atendimentos a where id = testes.v('c1')), true);
select testes.erro(format($$select public.salvar_atendimento(%L, '{}'::jsonb)$$, testes.v('c1')), 'finalizada',
  'consulta finalizada não pode ser alterada');
reset role;
select testes.erro(format($$delete from public.atendimentos where id = %L$$, testes.v('c1')), 'não são apagadas',
  'consultas não são apagadas (nem pelo sistema)');
select testes.entrar('dra@pront.local'); set role authenticated;

\echo '— Consulta 02: histórico preservado'
select testes.guardar('c2', public.novo_atendimento(testes.v('maria')));
select testes.ok((select numero = 2 and odontograma -> '16' ->> 'c' = 'carie' from public.atendimentos where id = testes.v('c2')),
  'consulta 02 começa com o odontograma da consulta 01');
select public.salvar_atendimento(testes.v('c2'), jsonb_build_object(
  'odontograma', '{"16": {"c": "restauracao", "f": ["O"], "s": "existente"}, "21": {"c": "restauracao", "f": ["V"], "s": "existente"}}'::jsonb));
select public.realizar_item(testes.v('i_fac'), testes.v('c2'), 'a_pagar', null, testes.forma_p('Transferência'), null, testes.hoje() + 30, 2);
select testes.ok((select odontograma -> '16' ->> 'c' = 'carie' from public.atendimentos where id = testes.v('c1'))
             and (select odontograma -> '16' ->> 'c' = 'restauracao' from public.atendimentos where id = testes.v('c2')),
  'a consulta 02 não apaga o odontograma da consulta 01 (evolução)');
select testes.ok((select string_agg(numero || ':' || coalesce(procedimentos_realizados, '-'), ' ' order by numero)
                    from public.v_atendimentos where pessoa_id = testes.v('maria'))
                 = '1:Clareamento dental 2:Facetas de porcelana'
             and (testes.item_p('Manutenção e limpeza')).status = 'pendente'
             and (testes.item_p('Facetas de porcelana')).financeiro = 'pendente',
  'o histórico mostra o que foi realizado em cada consulta; limpeza segue pendente');

\echo '— Já registrado / sem cobrança'
select testes.guardar('i_extra', public.adicionar_item_plano(testes.v('maria'), testes.proc_p('Clareamento dental'), 20000, null, testes.v('c2'), 'pendente'));
select public.realizar_item(testes.v('i_extra'), testes.v('c2'), 'ja_registrado', null, null, null, null, 1,
                            (testes.item_p('Facetas de porcelana')).venda_id);
select testes.ok((select count(*) from public.vendas where pessoa_id = testes.v('maria')) = 2,
  'ligar a um pagamento já registrado não cria cobrança duplicada');
select testes.erro(format($$select public.mudar_status_item(%L, 'pendente')$$, testes.v('i_clar')), 'já foi realizado',
  'procedimento realizado não volta a pendente');

\echo '— Secretária sem prontuário continua no financeiro'
reset role; select testes.entrar('sec@pront.local'); set role authenticated;
select testes.ok((select count(*) from public.v_financeiro_negociacoes where pessoa_id = testes.v('maria')) = 2
             and (select count(*) from public.atendimentos) = 0,
  'secretária vê os pagamentos no Financeiro, mas não a ficha clínica');
reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.ok((select count(*) from public.atendimentos where clinica_id = testes.v('pc')) = 0
             and (select count(*) from public.v_plano_tratamento where clinica_id = testes.v('pc')) = 0,
  'outra clínica não vê nada do prontuário');
reset role;

\echo '✓ Prontuário verificado.'
