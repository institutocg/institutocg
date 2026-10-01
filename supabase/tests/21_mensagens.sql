-- =============================================================================
-- Testes da biblioteca de mensagens prontas.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('mc', public.inicializar_clinica('Instituto Mensagens'));
insert into auth.users (email, raw_user_meta_data) values ('sec@msg.local', '{"nome": "Secretária Msg"}');
select public.adicionar_membro(testes.v('mc'), 'sec@msg.local', 'comercial');
select testes.guardar('facetas_m', (select id from public.procedimentos where clinica_id = testes.v('mc') and nome = 'Facetas de porcelana'));
create function testes.sug(t uuid) returns setof record language sql as
  $$ select modelo_id, titulo, categoria, texto, recomendada from public.sugestoes_mensagem(t) $$;
create function testes.recomendada(t uuid) returns text language sql as
  $$ select titulo || ' | ' || texto from public.sugestoes_mensagem(t) where recomendada $$;
grant execute on all functions in schema testes to authenticated, anon;

\echo '— Biblioteca padrão'
select testes.ok((select count(distinct categoria) = 13 from public.modelos_mensagem where clinica_id = testes.v('mc'))
             and not exists (select categoria from public.modelos_mensagem where clinica_id = testes.v('mc')
                              group by categoria having count(*) filter (where padrao) <> 1),
  '13 categorias, cada uma com uma mensagem padrão');
select testes.ok(not exists (select 1 from public.modelos_mensagem where clinica_id = testes.v('mc') and texto not like '%{{%}}%'),
  'toda mensagem possui variáveis');
select testes.ok(not exists (select 1 from public.modelos_mensagem where clinica_id = testes.v('mc')
                              and (texto ~ '!!|URGENTE|[Úú]ltima chance|imperdível|PROMO' or texto ~ '[A-ZÀ-Ú]{6,}')),
  'tom elegante: nada de caixa alta, urgência artificial ou apelo agressivo');

reset role; select testes.entrar('sec@msg.local'); set role authenticated;

\echo '— Variáveis preenchidas pelo CRM'
with x as (
  insert into public.pessoas (clinica_id, nome, apelido_tratamento, whatsapp_e164)
  values (testes.v('mc'), 'Mariana Teixeira Lopes', 'Mari', '+5511950000001') returning id
) select testes.guardar('mari', id) from x;
reset role;
select testes.ok(public.renderizar_texto('Olá, {{nome}} ({{nome_completo}})! {{clinica}} · {primeiro_nome}', testes.v('mari'))
                 = 'Olá, Mari (Mariana Teixeira Lopes)! Instituto Mensagens · Mari',
  '{{nome}} usa como a pessoa prefere ser chamada; {{nome_completo}}, {{clinica}} e a forma curta também funcionam');
select testes.entrar('sec@msg.local'); set role authenticated;

\echo '— Sugestão automática de acordo com a tarefa'
with x as (
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (testes.v('mc'), testes.v('mari'), testes.v('facetas_m'), (public.etapa_por_marco(testes.v('mc'), 'novo_contato')).id)
  returning id
) select testes.guardar('op_mari', id) from x;
select testes.guardar('t_mari', (select id from public.tarefas where pessoa_id = testes.v('mari') and status = 'pendente'));
select testes.ok(testes.recomendada(testes.v('t_mari')) = 'Boas-vindas | Olá, Mari! Tudo bem? Aqui é do Instituto Mensagens. '
                   || 'Recebemos o seu contato e fico muito feliz com o seu interesse em facetas de porcelana. '
                   || 'Posso te contar como funciona a avaliação e encontrar um horário que seja confortável para você?'
             and (select mensagem_sugerida like 'Olá, Mari! Tudo bem? Aqui é do Instituto Mensagens.%' from public.tarefas where id = testes.v('t_mari'))
             and (select count(*) from public.sugestoes_mensagem(testes.v('t_mari'))) =
                 (select count(*) from public.modelos_mensagem where clinica_id = testes.v('mc') and ativo),
  'primeiro contato: mensagem recomendada já preenchida (nome e procedimento) e o resto da biblioteca disponível');

-- Mensagem específica de um procedimento tem preferência.
insert into public.modelos_mensagem (clinica_id, categoria, procedimento_id, padrao, titulo, texto)
values (testes.v('mc'), 'primeiro_contato', testes.v('facetas_m'), true, 'Facetas — primeiro contato',
        'Olá, {{nome}}! As facetas de porcelana são feitas sob medida para o seu sorriso. Vamos conversar?');
select testes.ok(testes.recomendada(testes.v('t_mari')) like 'Facetas — primeiro contato | Olá, Mari! As facetas%'
             and (select padrao from public.modelos_mensagem where clinica_id = testes.v('mc') and titulo = 'Boas-vindas'),
  'mensagem associada ao procedimento é a sugerida para quem negocia esse procedimento (a padrão geral continua)');

\echo '— Pagamentos: previsto, cobrança amigável e pendente'
reset role;
with v as (
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, valor_total_centavos, condicao_pagamento, quantidade_parcelas)
  values (testes.v('mc'), testes.v('mari'), testes.v('op_mari'), 300000, 'parcelado', 3) returning id
) select testes.guardar('v_mari', id) from v;
select public.gerar_parcelas(testes.v('v_mari'), testes.hoje() + 5);
select testes.guardar('t_pag1', (select t.id from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                                  where p.venda_id = testes.v('v_mari') and p.numero = 1));
select testes.ok(testes.recomendada(testes.v('t_pag1')) like 'Lembrete antes do vencimento | %R$ 1.000,00 previsto para '
                   || to_char(testes.hoje() + 5, 'DD/MM') || '%',
  'antes do vencimento: "pagamento previsto", com valor e vencimento');
update public.parcelas set vencimento = testes.hoje() - 3 where venda_id = testes.v('v_mari') and numero = 1;
select testes.ok(testes.recomendada(testes.v('t_pag1')) like 'Lembrete gentil | %',
  'até 7 dias de atraso: "cobrança amigável"');
update public.parcelas set vencimento = testes.hoje() - 12 where venda_id = testes.v('v_mari') and numero = 1;
select testes.ok(testes.recomendada(testes.v('t_pag1')) like 'Pagamento em aberto | %',
  'mais de 7 dias: "pagamento pendente"');

\echo '— Criar e editar'
select testes.entrar('sec@msg.local'); set role authenticated;
insert into public.modelos_mensagem (clinica_id, categoria, padrao, titulo, texto)
values (testes.v('mc'), 'confirmacao', true, 'Confirmação curta', 'Olá, {{nome}}! Confirmamos {{consulta}} no dia {{data}}?');
select testes.ok((select count(*) filter (where padrao) = 1 and bool_or(padrao and titulo = 'Confirmação curta')
                  from public.modelos_mensagem where clinica_id = testes.v('mc') and categoria = 'confirmacao'),
  'a secretária cria mensagens; tornar padrão desmarca a padrão anterior');
update public.modelos_mensagem set texto = 'Olá, {{nome}}! Tudo certo para {{consulta}} no dia {{data}}?'
 where clinica_id = testes.v('mc') and titulo = 'Confirmação curta';
reset role;
select testes.ok(exists (select 1 from public.auditoria where tabela = 'modelos_mensagem' and acao = 'update'),
  'edições ficam na auditoria');
select testes.entrar('sec@msg.local'); set role authenticated;

select testes.ok((select count(*) from public.mensagens_para_pessoa(testes.v('mari')) where texto like '%Mari%') > 10,
  'biblioteca preenchida para um paciente escolhido');

\echo '— Segurança'
reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.ok((select count(*) from public.modelos_mensagem where clinica_id = testes.v('mc')) = 0,
  'outra clínica não vê as mensagens desta');
select testes.erro(format($$select * from public.sugestoes_mensagem(%L)$$, testes.v('t_mari')), 'não encontrada',
  'outra clínica não vê sugestões desta');
select testes.erro(format($$select * from public.mensagens_para_pessoa(%L)$$, testes.v('mari')), 'não encontrado',
  'outra clínica não preenche mensagens com pacientes desta');
reset role;

\echo '✓ Mensagens verificadas.'
