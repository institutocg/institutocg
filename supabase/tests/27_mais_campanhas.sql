-- =============================================================================
-- Testes das campanhas novas: tratamento pendente, avaliação que não aconteceu,
-- aniversário, pós-tratamento, interesse (época), desmarcou e especiais.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('mc', public.inicializar_clinica('Clínica das Campanhas'));
insert into auth.users (email, raw_user_meta_data) values ('dra@camp.local', '{"nome": "Dra. Camp"}');
select public.adicionar_membro(testes.v('mc'), 'dra@camp.local', 'admin');

create function testes.p_mc(n text, fone text, nasc date default null) returns uuid language sql as
  $$ insert into public.pessoas (clinica_id, nome, whatsapp_e164, data_nascimento, consentimento_marketing)
     values (testes.v('mc'), n, fone, nasc, true) returning id $$;
create function testes.proc_mc(n text) returns uuid language sql as
  $$ select id from public.procedimentos where clinica_id = testes.v('mc') and nome = n $$;
create function testes.et_mc(m text) returns uuid language sql as
  $$ select id from public.etapas_funil where clinica_id = testes.v('mc') and (marco = m or resultado::text = m) $$;
create function testes.quem(seg text, meses int, proc uuid default null) returns text language sql as
  $$ select coalesce(string_agg(nome, ', ' order by nome), '') from public.prever_campanha(testes.v('mc'), seg, meses, proc) $$;
-- Plano do prontuário com um item (status e datas ajustáveis).
create function testes.item_mc(pessoa uuid, proc text, st public.status_item_plano, dias_atras int) returns void language plpgsql as $$
declare o uuid;
begin
  select id into o from public.orcamentos where pessoa_id = pessoa and origem = 'prontuario';
  if o is null then
    insert into public.orcamentos (clinica_id, pessoa_id, origem, status, apresentado_em)
    values (testes.v('mc'), pessoa, 'prontuario', 'rascunho', testes.hoje() - dias_atras) returning id into o;
  end if;
  insert into public.orcamento_itens (clinica_id, orcamento_id, procedimento_id, valor_unitario_centavos, status, criado_em, atualizado_em)
  values (testes.v('mc'), o, testes.proc_mc(proc), 100000, case when st = 'realizado' then 'pendente' else st end,
          now() - make_interval(days => dias_atras), now() - make_interval(days => dias_atras));
  if st = 'realizado' then
    insert into public.prontuarios (clinica_id, pessoa_id) values (testes.v('mc'), pessoa) on conflict do nothing;
    insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, data)
    select testes.v('mc'), id, pessoa, testes.hoje() - dias_atras from public.prontuarios where pessoa_id = pessoa;
    update public.orcamento_itens i set status = 'realizado', realizado_em = testes.hoje() - dias_atras,
           realizado_atendimento_id = (select max(id::text)::uuid from public.atendimentos where pessoa_id = pessoa)
     where i.orcamento_id = o and i.procedimento_id = testes.proc_mc(proc);
    update public.orcamento_itens set atualizado_em = now() - make_interval(days => dias_atras) where orcamento_id = o;
  end if;
end $$;
grant execute on all functions in schema testes to authenticated, anon;

-- Tratamento pendente
select testes.guardar('tp', testes.p_mc('Tânia Pendente', '+5511900001001'));
select testes.item_mc(testes.v('tp'), 'Facetas de porcelana', 'pendente', 40);
select testes.guardar('tp2', testes.p_mc('Téo Agendado', '+5511900001002'));
select testes.item_mc(testes.v('tp2'), 'Implantes', 'pendente', 40);
insert into public.agendamentos (clinica_id, pessoa_id, tipo, inicio)
values (testes.v('mc'), testes.v('tp2'), 'procedimento', now() + interval '7 days');
select testes.guardar('tp3', testes.p_mc('Tito Recente', '+5511900001003'));
select testes.item_mc(testes.v('tp3'), 'Implantes', 'pendente', 5);

-- Avaliação que não aconteceu (negociação encerrada sem consulta)
select testes.guardar('av', testes.p_mc('Ávila Sem Avaliação', '+5511900001004'));
with o as (
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (testes.v('mc'), testes.v('av'), testes.proc_mc('Clareamento dental'), testes.et_mc('novo_contato')) returning id
) select testes.guardar('av_op', id) from o;
select public.mover_etapa(testes.v('av_op'), testes.et_mc('desistiu'), null,
  (select id from public.motivos where clinica_id = testes.v('mc') and nome = 'Fez o tratamento em outro lugar' limit 1));
update public.oportunidades set criado_em = now() - interval '70 days' where id = testes.v('av_op');

-- Aniversário
select testes.guardar('an', testes.p_mc('Aninha Aniversário', '+5511900001005', (testes.hoje() + 10 - interval '30 years')::date));
select testes.guardar('an2', testes.p_mc('Beto Longe', '+5511900001006', (testes.hoje() + 100 - interval '30 years')::date));

-- Pós-tratamento
select testes.guardar('pt', testes.p_mc('Paula Pós', '+5511900001007'));
select testes.item_mc(testes.v('pt'), 'Clareamento dental', 'realizado', 40);
select testes.guardar('pt2', testes.p_mc('Pedro Antigo', '+5511900001008'));
select testes.item_mc(testes.v('pt2'), 'Clareamento dental', 'realizado', 200);

-- Desmarcou e não remarcou
select testes.guardar('dm', testes.p_mc('Dora Desmarcou', '+5511900001009'));
insert into public.agendamentos (clinica_id, pessoa_id, tipo, inicio, status, status_em)
values (testes.v('mc'), testes.v('dm'), 'avaliacao', now() - interval '95 days', 'desmarcado', now() - interval '95 days');
update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste' where pessoa_id = testes.v('dm') and status = 'pendente';

-- Especiais (maior histórico)
do $$
declare i int; p uuid; o uuid;
begin
  for i in 1 .. 5 loop
    p := testes.p_mc('Especial ' || i, '+55119000020' || lpad(i::text, 2, '0'));
    insert into public.oportunidades (clinica_id, pessoa_id, etapa_id)
    values (testes.v('mc'), p, testes.et_mc('avaliacao_realizada')) returning id into o;
    insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, valor_total_centavos, fechada_em)
    values (testes.v('mc'), p, o, i * 100000, testes.hoje() - 30);
    update public.tarefas set status = 'cancelada', cancelada_motivo = 'teste' where pessoa_id = p and status = 'pendente';
    update public.pessoas set ultimo_contato_em = now() - interval '30 days' where id = p;
  end loop;
end $$;

reset role; select testes.entrar('dra@camp.local'); set role authenticated;

\echo '— Quem entra em cada campanha'
select testes.ok(testes.quem('tratamento_pendente', 1) = 'Tânia Pendente',
  'tratamento pendente: plano parado há mais de 1 mês e sem consulta marcada (quem tem consulta ou é recente fica de fora)');
select testes.ok(testes.quem('avaliacao_nao_agendada', 2) = 'Ávila Sem Avaliação',
  'avaliação que não aconteceu: interesse encerrado sem nenhuma consulta');
select testes.ok(testes.quem('aniversario', 1) = 'Aninha Aniversário', 'aniversário: quem faz aniversário no próximo mês');
select testes.ok(testes.quem('pos_tratamento', 1) = 'Paula Pós', 'pós-tratamento: realizado há 1 a 3 meses (o antigo fica de fora)');
select testes.ok(testes.quem('interesse', 12, testes.proc_mc('Clareamento dental')) = 'Ávila Sem Avaliação',
  'interesse em clareamento: quem se interessou e não fez (quem já fez fica de fora)');
select testes.ok(testes.quem('desmarcou', 2) = 'Dora Desmarcou', 'desmarcou há mais de 2 meses e nunca remarcou');
select testes.ok(testes.quem('especiais', 12) = 'Especial 4, Especial 5', 'especiais: os 30% com maior histórico');
select testes.erro($$select * from public.prever_campanha(testes.v('mc'), 'interesse', 12)$$, 'Escolha o procedimento',
  'interesse exige o procedimento');

\echo '— Criar: relacionamento só cria tarefa; vendas abre negociação'
select set_config('t.r', public.criar_campanha(testes.v('mc'), 'Parabéns', 'aniversario', 1, null, false,
  'Feliz aniversário, {{nome}}! Toda a equipe do {{clinica}} deseja um dia lindo.', 10, testes.hoje())::text, false);
select testes.ok((select t.titulo like 'Aniversário de Aninha — %' and t.vence_em <= testes.hoje() + 10 and t.vence_em >= testes.hoje() + 8
                         and t.oportunidade_id is null and t.mensagem_sugerida like 'Feliz aniversário, Aninha!%'
                    from public.tarefas t where t.pessoa_id = testes.v('an') and t.status = 'pendente'),
  'aniversário: tarefa no dia (ou no dia útil anterior), com a mensagem, sem negociação no funil');
select public.criar_campanha(testes.v('mc'), 'Terminar o tratamento', 'tratamento_pendente', 1, null, false,
  'Olá, {{nome}}! Vamos combinar um horário para continuar o seu tratamento ({{procedimento}})?', 10, testes.hoje());
select testes.ok((select t.tipo = 'agendar_tratamento' and t.oportunidade_id is null
                         and t.mensagem_sugerida like '%(facetas de porcelana)?'
                    from public.tarefas t where t.pessoa_id = testes.v('tp') and t.status = 'pendente'),
  'tratamento pendente: tarefa "continuar o tratamento" com os procedimentos pendentes na mensagem');
select public.criar_campanha(testes.v('mc'), 'Remarcar', 'desmarcou', 2, null, false,
  'Olá, {{nome}}! Que tal encontrarmos um novo horário?', 10, testes.hoje());
select testes.ok(exists (select 1 from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id
                          where o.pessoa_id = testes.v('dm') and o.status = 'aberta' and e.marco = 'reativacao'),
  'desmarcou: abre a negociação em "Reativação", como as campanhas de vendas');
select testes.ok(testes.quem('aniversario', 1) = '', 'quem já recebeu o parabéns deste ano não entra de novo');
select testes.ok(testes.quem('especiais', 12) = 'Especial 4, Especial 5', 'aniversário não bloqueia outras campanhas');
reset role;

\echo '✓ Campanhas novas verificadas.'
