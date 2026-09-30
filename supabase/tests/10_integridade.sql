-- =============================================================================
-- Testes de integridade do banco
--   Executados por scripts/testar-banco.sh num PostgreSQL temporário.
--   Cada verificação imprime "ok - ..."; qualquer falha interrompe o teste.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null
set client_min_messages = notice;

-- ─── Ferramentas de teste ────────────────────────────────────────────────────

create schema testes;
grant usage on schema testes to authenticated, anon;

create function testes.ok(condicao boolean, descricao text) returns void
language plpgsql as $$
begin
  if condicao is not true then
    raise exception 'FALHOU: %', descricao;
  end if;
  raise notice 'ok - %', descricao;
end;
$$;

-- Executa um comando e exige que ele falhe com a mensagem/código esperado.
create function testes.erro(comando text, esperado text, descricao text) returns void
language plpgsql as $$
begin
  begin
    execute comando;
  exception when others then
    if sqlstate = esperado or sqlerrm ilike '%' || esperado || '%' then
      raise notice 'ok - % (bloqueado: %)', descricao, sqlerrm;
      return;
    end if;
    raise exception 'FALHOU: % (erro inesperado % — %)', descricao, sqlstate, sqlerrm;
  end;
  raise exception 'FALHOU: % (o comando deveria ter sido bloqueado)', descricao;
end;
$$;

create function testes.v(nome text) returns uuid
language sql as $$ select current_setting('t.' || nome)::uuid $$;

create function testes.guardar(nome text, valor uuid) returns uuid
language sql as $$ select set_config('t.' || nome, valor::text, false)::uuid $$;

create function testes.hoje() returns date
language sql as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- Busca o id de um item de catálogo em qualquer clínica (ignora RLS de propósito).
create function testes.cat(tabela text, clinica uuid, nome text) returns uuid
language plpgsql security definer as $$
declare r uuid;
begin
  execute format('select id from public.%I where clinica_id = $1 and nome = $2 limit 1', tabela)
    into r using clinica, nome;
  if r is null then raise exception 'catálogo %/% não encontrado', tabela, nome; end if;
  return r;
end;
$$;

-- Troca o usuário "logado" (simula o JWT do Supabase).
create function testes.entrar(email text) returns void
language plpgsql security definer as $$
declare u uuid;
begin
  select id into u from auth.users where auth.users.email = entrar.email;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false);
end;
$$;

grant execute on all functions in schema testes to authenticated, anon;

-- ─── Preparação: duas clínicas e quatro logins ───────────────────────────────

select testes.guardar('c1', public.inicializar_clinica('Instituto CG (teste)'));
select testes.guardar('c2', public.inicializar_clinica('Outra Clínica'));

insert into auth.users (email, raw_user_meta_data) values
  ('mae@teste.local',        '{"nome": "Dra. Helena"}'),
  ('secretaria@teste.local', '{"nome": "Júlia"}'),
  ('estagiaria@teste.local', '{"nome": "Estagiária"}'),
  ('intruso@outra.local',    '{"nome": "Intruso"}');

select public.adicionar_membro(testes.v('c1'), 'mae@teste.local', 'admin');
select public.adicionar_membro(testes.v('c1'), 'secretaria@teste.local', 'comercial', true);
select public.adicionar_membro(testes.v('c1'), 'estagiaria@teste.local', 'comercial', false);
select public.adicionar_membro(testes.v('c2'), 'intruso@outra.local', 'admin');

select testes.guardar('mae', (select id from auth.users where email = 'mae@teste.local'));
select testes.guardar('secretaria', (select id from auth.users where email = 'secretaria@teste.local'));

select testes.ok((select count(*) from public.usuarios) = 4,
  'perfil de usuário é criado automaticamente a cada login novo');
select testes.ok((select count(*) from public.procedimentos where clinica_id = testes.v('c1')) = 8
             and (select count(*) from public.etapas_funil where clinica_id = testes.v('c1')) = 12
             and (select count(*) from public.formas_pagamento where clinica_id = testes.v('c1')) = 6,
  'clínica nasce com procedimentos, etapas do funil e formas de pagamento padrão');

-- =============================================================================
\echo '— Procedimentos e catálogos'
-- =============================================================================

reset role; select testes.entrar('secretaria@teste.local'); set role authenticated;

select testes.ok((select count(*) from public.procedimentos) = 8,
  'secretária vê apenas os procedimentos da própria clínica');
select testes.erro(
  $$insert into public.procedimentos (clinica_id, nome) values (testes.v('c1'), 'Ortodontia')$$,
  'row-level security', 'secretária não cadastra procedimento (somente administradora)');

reset role; select testes.entrar('mae@teste.local'); set role authenticated;

insert into public.procedimentos (clinica_id, nome, categoria) values (testes.v('c1'), 'Alinhadores', 'Ortodontia');
update public.procedimentos set nome = 'Alinhadores invisíveis' where nome = 'Alinhadores';
select testes.ok(exists (select 1 from public.procedimentos where nome = 'Alinhadores invisíveis'),
  'administradora cadastra e edita procedimentos');
delete from public.procedimentos where nome = 'Alinhadores invisíveis';
select testes.ok(exists (select 1 from public.procedimentos where nome = 'Alinhadores invisíveis'),
  'procedimentos não são apagados (desativa-se com ativo = false)');
select testes.erro(
  $$insert into public.procedimentos (clinica_id, nome) values (testes.v('c1'), 'Periodontia')$$,
  'duplicate key', 'não permite dois procedimentos com o mesmo nome');

-- =============================================================================
\echo '— Leads/pacientes'
-- =============================================================================

reset role; select testes.entrar('secretaria@teste.local'); set role authenticated;

with novo as (
  insert into public.pessoas (
    clinica_id, tipo_cadastro, nome, data_nascimento, telefone_e164, whatsapp_e164, email,
    cep, logradouro, numero, bairro, cidade, uf, origem_id, responsavel_id,
    observacoes_comerciais, primeiro_contato_em
  ) values (
    testes.v('c1'), 'novo_contato', 'Maria Silva', '1988-04-12', '+5511999990001', '+5511999990001',
    'maria@exemplo.com', '01310100', 'Av. Paulista', '1000', 'Bela Vista', 'São Paulo', 'SP',
    testes.cat('origens', testes.v('c1'), 'Instagram'), testes.v('secretaria'),
    'Prefere contato à tarde.', testes.hoje() - 10
  ) returning id
) select testes.guardar('maria', id) from novo;
select testes.ok(true, 'cadastro completo de lead (nome, nascimento, telefones, e-mail, endereço, origem, responsável)');

select testes.erro(
  $$insert into public.pessoas (clinica_id, nome, telefone_e164) values (testes.v('c1'), 'Outra Maria', '+5511999990001')$$,
  'duplicate key', 'não permite dois cadastros com o mesmo telefone');
select testes.erro(
  $$insert into public.pessoas (clinica_id, nome) values (testes.v('c1'), 'Sem Contato')$$,
  'check constraint', 'exige ao menos uma forma de contato');
select testes.erro(
  $$insert into public.pessoas (clinica_id, nome, telefone_e164) values (testes.v('c1'), 'Fone Ruim', '11 9999')$$,
  'check constraint', 'rejeita telefone fora do formato internacional');
select testes.erro(
  $$insert into public.pessoas (clinica_id, nome, email) values (testes.v('c2'), 'Invasora', 'x@y.com')$$,
  'row-level security', 'não cadastra pessoa em outra clínica');
select testes.erro(
  format($$insert into public.pessoas (clinica_id, nome, email, origem_id) values (testes.v('c1'), 'Mistura', 'm@y.com', %L)$$,
         testes.cat('origens', testes.v('c2'), 'Instagram')),
  'foreign key', 'não usa catálogo (origem) de outra clínica');

with novo as (
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id,
                              paciente_desde, ultimo_atendimento_informado)
  values (testes.v('c1'), 'paciente_antigo', 'João Pereira', '+5511999990002',
          testes.cat('origens', testes.v('c1'), 'Paciente antigo'), '2019-01-01', testes.hoje() - 500)
  returning id
) select testes.guardar('joao', id) from novo;
insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
values (testes.v('c1'), testes.v('joao'), testes.cat('procedimentos', testes.v('c1'), 'Clareamento dental'), '2024-03-01');

select testes.ok((select relacionamento from public.v_contatos where id = testes.v('maria')) = 'lead'
             and (select relacionamento from public.v_contatos where id = testes.v('joao')) = 'paciente_inativo',
  'relacionamento calculado: lead × paciente antigo inativo (último atendimento há 500 dias)');

-- =============================================================================
\echo '— Funil: uma etapa atual por lead + histórico'
-- =============================================================================

with novo as (
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos, responsavel_id)
  values (testes.v('c1'), testes.v('maria'), testes.cat('procedimentos', testes.v('c1'), 'Facetas de porcelana'),
          testes.cat('etapas_funil', testes.v('c1'), 'Novo contato'), 1800000, testes.v('secretaria'))
  returning id
) select testes.guardar('op_maria', id) from novo;

select testes.erro(
  format($$insert into public.oportunidades (clinica_id, pessoa_id, etapa_id) values (testes.v('c1'), testes.v('maria'), %L)$$,
         testes.cat('etapas_funil', testes.v('c1'), 'Novo contato')),
  'oportunidades_uma_em_andamento', 'cada lead tem apenas UMA etapa atual (uma negociação em andamento)');
select testes.erro(
  format($$update public.oportunidades set etapa_id = %L where id = testes.v('op_maria')$$,
         testes.cat('etapas_funil', testes.v('c2'), 'Em contato')),
  'foreign key', 'não move para etapa de outra clínica');

select public.mover_etapa(testes.v('op_maria'), testes.cat('etapas_funil', testes.v('c1'), 'Em contato'),
                          'Respondeu no Instagram, quer saber valores');
select public.mover_etapa(testes.v('op_maria'), testes.cat('etapas_funil', testes.v('c1'), 'Avaliação agendada'));

select testes.ok((select count(*) from public.historico_etapas where oportunidade_id = testes.v('op_maria')) = 3,
  'histórico registra a entrada no funil e cada mudança de etapa');
select testes.ok((
  select h.etapa_anterior_id = testes.cat('etapas_funil', testes.v('c1'), 'Novo contato')
     and h.etapa_nova_id = testes.cat('etapas_funil', testes.v('c1'), 'Em contato')
     and h.usuario_id = testes.v('secretaria')
     and h.observacao = 'Respondeu no Instagram, quer saber valores'
     and h.mudou_em is not null
  from public.historico_etapas h
  where h.oportunidade_id = testes.v('op_maria') and h.observacao is not null),
  'histórico guarda etapa anterior, nova etapa, data, usuário e observação');
delete from public.historico_etapas;
select testes.ok((select count(*) from public.historico_etapas where oportunidade_id = testes.v('op_maria')) = 3,
  'tentativa de apagar o histórico não remove nada');

-- =============================================================================
\echo '— Tarefas e próxima ação'
-- =============================================================================

insert into public.tarefas (clinica_id, pessoa_id, oportunidade_id, tipo, categoria, titulo, descricao,
                            vence_em, horario, prioridade, responsavel_id, mensagem_sugerida)
values (testes.v('c1'), testes.v('maria'), testes.v('op_maria'), 'follow_up', 'vendas',
        'Retornar Maria sobre facetas', 'Enviar valores e condições', testes.hoje(), '15:00', 'alta',
        testes.v('secretaria'), 'Olá, Maria! Tudo bem? Separei as informações sobre as facetas...');

select testes.ok((
  select c.etapa_atual = 'Avaliação agendada' and c.procedimento_interesse = 'Facetas de porcelana'
     and c.status_atual = 'em_negociacao' and c.proxima_acao = 'Retornar Maria sobre facetas'
     and c.proxima_acao_em = testes.hoje() and c.proxima_acao_horario = '15:00'
     and c.responsavel = 'Júlia' and c.origem = 'Instagram'
  from public.v_contatos c where c.id = testes.v('maria')),
  'contato mostra status, etapa atual, procedimento de interesse, próxima ação e data');
select testes.ok((select count(*) from public.v_painel_tarefas where pessoa_id = testes.v('maria')) = 2,
  'tarefa do dia aparece no painel (a manual + o primeiro contato criado automaticamente)');

select testes.erro(
  $$insert into public.tarefas (clinica_id, pessoa_id, titulo, vence_em, origem) values (testes.v('c1'), testes.v('maria'), 'Sem regra', current_date, 'automatica')$$,
  'check constraint', 'tarefa automática precisa informar a regra de origem');
insert into public.tarefas (clinica_id, pessoa_id, titulo, vence_em, origem, regra, chave_dedupe)
values (testes.v('c1'), testes.v('joao'), 'Reativar João', testes.hoje(), 'automatica', 'R-REA-01', 'reativacao:joao');
select testes.erro(
  $$insert into public.tarefas (clinica_id, pessoa_id, titulo, vence_em, origem, regra, chave_dedupe) values (testes.v('c1'), testes.v('joao'), 'Reativar João', current_date, 'automatica', 'R-REA-01', 'reativacao:joao')$$,
  'tarefas_sem_duplicidade', 'lembrete automático não é duplicado');
update public.tarefas set status = 'concluida', resultado = 'Respondeu' where chave_dedupe = 'reativacao:joao';
select testes.ok((select concluida_em is not null and concluida_por = testes.v('secretaria')
                  from public.tarefas where chave_dedupe = 'reativacao:joao'),
  'conclusão registra data e quem concluiu');

-- =============================================================================
\echo '— Follow-ups (histórico de relacionamento)'
-- =============================================================================

insert into public.interacoes (clinica_id, pessoa_id, oportunidade_id, tipo, canal, direcao, descricao)
values (testes.v('c1'), testes.v('maria'), testes.v('op_maria'), 'whatsapp', 'whatsapp', 'saida', 'Enviei valores das facetas');
insert into public.interacoes (clinica_id, pessoa_id, oportunidade_id, tipo, retorno_em, descricao)
values (testes.v('c1'), testes.v('maria'), testes.v('op_maria'), 'retorno_solicitado', testes.hoje() + 3, 'Pediu retorno na sexta');

select testes.ok((select ultimo_contato_em is not null from public.pessoas where id = testes.v('maria')),
  'follow-up atualiza a data do último contato');
select testes.erro(
  $$update public.interacoes set descricao = 'alterado' where tipo = 'whatsapp'$$,
  'não podem ser editados', 'follow-up não pode ser editado');
update public.interacoes set anulada_em = now(), anulada_motivo = 'Registrado no paciente errado' where tipo = 'whatsapp';
delete from public.interacoes;
select testes.ok((select count(*) from public.interacoes where pessoa_id = testes.v('maria')) = 2,
  'follow-up pode ser anulado com motivo, mas nunca apagado');
select testes.erro(
  $$insert into public.interacoes (clinica_id, pessoa_id, tipo) values (testes.v('c1'), testes.v('maria'), 'retorno_solicitado')$$,
  'check constraint', '"retorno solicitado" exige a data do retorno');

-- Agenda: desmarcação vira follow-up automaticamente.
with novo as (
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
  values (testes.v('c1'), testes.v('maria'), testes.v('op_maria'),
          testes.cat('profissionais', testes.v('c1'), 'Dentista responsável'), 'avaliacao', now() + interval '2 days')
  returning id
) select testes.guardar('ag_maria', id) from novo;
update public.agendamentos set status = 'desmarcado',
  motivo_id = testes.cat('motivos', testes.v('c1'), 'Trabalho') where id = testes.v('ag_maria');
select testes.ok(exists (select 1 from public.interacoes where agendamento_id = testes.v('ag_maria') and tipo = 'paciente_desmarcou'),
  'desmarcação na agenda gera follow-up "paciente desmarcou"');

-- =============================================================================
\echo '— Resultado da negociação'
-- =============================================================================

select testes.erro(
  format($$select public.mover_etapa(testes.v('op_maria'), %L)$$, testes.cat('etapas_funil', testes.v('c1'), 'Não fechou')),
  'check constraint', '"Não fechou" exige motivo');
select public.mover_etapa(testes.v('op_maria'), testes.cat('etapas_funil', testes.v('c1'), 'Não fechou'),
  'Achou o valor alto', (select id from public.motivos where nome = 'Valor alto'));
select testes.ok((select status = 'perdida' and resultado = 'nao_fechou' and fechada_em is not null
                  from public.oportunidades where id = testes.v('op_maria')),
  'status e resultado acompanham a etapa (Não fechou → perdida)');
select testes.ok((select status = 'cancelada' from public.tarefas where titulo = 'Retornar Maria sobre facetas'),
  'lembretes de venda pendentes são cancelados quando a negociação é encerrada');

-- Nova negociação depois de encerrada a anterior (histórico preservado).
with novo as (
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, oportunidade_origem_id)
  values (testes.v('c1'), testes.v('maria'), testes.cat('procedimentos', testes.v('c1'), 'Facetas/lentes em resina'),
          testes.cat('etapas_funil', testes.v('c1'), 'Orçamento apresentado'), testes.v('op_maria'))
  returning id
) select testes.guardar('op_maria2', id) from novo;
select testes.ok((select count(*) from public.oportunidades where pessoa_id = testes.v('maria')) = 2,
  'nova negociação pode ser aberta após encerrar a anterior; a antiga continua no histórico');

-- =============================================================================
\echo '— Financeiro e lembretes financeiros'
-- =============================================================================

with novo as (
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, desconto_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas,
                                 forma_pagamento_id, apresentado_em, valido_ate)
  values (testes.v('c1'), testes.v('maria'), testes.v('op_maria2'), 'apresentado', 0,
          'a_vista', 0, 1, testes.cat('formas_pagamento', testes.v('c1'), 'PIX'), testes.hoje(), testes.hoje() + 30)
  returning id
) select testes.guardar('orc', id) from novo;
insert into public.orcamento_itens (clinica_id, orcamento_id, procedimento_id, descricao_comercial, quantidade, valor_unitario_centavos)
values (testes.v('c1'), testes.v('orc'), testes.cat('procedimentos', testes.v('c1'), 'Facetas/lentes em resina'),
        'Lentes em resina — arcada superior', 10, 90000);
select testes.ok((select valor_total_centavos = 900000 and numero >= 1 from public.orcamentos where id = testes.v('orc')),
  'valor total do orçamento = soma dos itens; número sequencial automático');
select testes.erro(
  $$update public.orcamentos set desconto_centavos = 99999999 where id = testes.v('orc')$$,
  'check constraint', 'desconto não pode ser maior que o valor total');

-- Fechou: R$ 9.000 − R$ 500 de desconto; entrada R$ 1.000 + 3 parcelas.
with novo as (
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, orcamento_id, valor_total_centavos,
                             desconto_centavos, condicao_pagamento, entrada_centavos, quantidade_parcelas,
                             forma_pagamento_id, observacao_financeira)
  values (testes.v('c1'), testes.v('maria'), testes.v('op_maria2'), testes.v('orc'), 900000, 50000,
          'parcelado', 100000, 3, testes.cat('formas_pagamento', testes.v('c1'), 'PIX'), 'Entrada no ato')
  returning id
) select testes.guardar('venda', id) from novo;
select testes.ok((select valor_final_centavos = 850000 and valor_parcela_centavos = 250000
                  from public.vendas where id = testes.v('venda')),
  'venda calcula valor final e valor da parcela');
select testes.ok((select o.status = 'ganha' and o.valor_fechado_centavos = 850000
                  and (select nome from public.etapas_funil where id = o.etapa_id) = 'Fechou'
                  from public.oportunidades o where o.id = testes.v('op_maria2'))
             and (select status = 'aprovado' from public.orcamentos where id = testes.v('orc'))
             and exists (select 1 from public.interacoes where pessoa_id = testes.v('maria') and tipo = 'paciente_fechou'),
  'registrar a venda move para "Fechou", aprova o orçamento e registra o follow-up');

select public.gerar_parcelas(testes.v('venda'), testes.hoje() + 30, testes.hoje());
select testes.ok((select count(*) = 4 and sum(valor_centavos) = 850000 from public.parcelas where venda_id = testes.v('venda')),
  'parcelas geradas (entrada + 3) somam exatamente o valor final');
select testes.ok((select count(*) from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                  where p.venda_id = testes.v('venda') and t.status = 'pendente' and t.categoria = 'financeiro'
                    and t.vence_em = p.vencimento and t.origem = 'automatica') = 4,
  'cada pagamento futuro gera automaticamente uma tarefa financeira na data prevista');
select testes.ok(exists (
  select 1 from public.v_painel_tarefas
  where texto_painel = 'Pagamento previsto hoje — Maria Silva — R$ 1.000,00'),
  'painel mostra "Pagamento previsto hoje — Maria Silva — R$ 1.000,00"');

-- Parcela 1 passa a vencer 3 dias atrás (simula atraso).
update public.parcelas set vencimento = testes.hoje() - 3 where venda_id = testes.v('venda') and numero = 1;
select testes.ok(exists (
  select 1 from public.v_painel_tarefas
  where texto_painel = 'Pagamento em atraso — Maria Silva — R$ 2.500,00'
    and situacao_prazo = 'Pagamento em atraso há 3 dias'),
  'pagamento atrasado aparece como pendência no painel');
select testes.ok((select count(*) from public.v_pendencias_financeiras where venda_id = testes.v('venda')) = 2,
  'pendências financeiras: a que vence hoje e a atrasada');

-- Pagamento parcial e depois quitação.
insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, forma_pagamento_id)
select testes.v('c1'), id, 100000, forma_pagamento_id from public.parcelas where venda_id = testes.v('venda') and numero = 1;
select testes.ok((select p.status = 'parcial' and p.valor_pago_centavos = 100000
                  from public.parcelas p where venda_id = testes.v('venda') and numero = 1)
             and exists (select 1 from public.v_painel_tarefas where texto_painel = 'Pagamento em atraso — Maria Silva — R$ 1.500,00'),
  'pagamento parcial: parcela "parcial" e lembrete atualizado com o saldo');

insert into public.pagamentos (clinica_id, parcela_id, valor_centavos)
select testes.v('c1'), id, 150000 from public.parcelas where venda_id = testes.v('venda') and numero = 1;
select testes.ok((select p.status = 'paga' and p.pago_em = testes.hoje()
                  from public.parcelas p where venda_id = testes.v('venda') and numero = 1)
             and (select t.status = 'concluida' from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                  where p.venda_id = testes.v('venda') and p.numero = 1),
  'quitação: parcela paga com data efetiva, tarefa financeira concluída automaticamente');
select testes.ok((select count(*) from public.interacoes where pessoa_id = testes.v('maria') and tipo = 'pagamento_recebido') = 2,
  'cada pagamento fica no histórico da paciente');

select testes.erro(
  $$update public.pagamentos set valor_centavos = 1 where valor_centavos = 150000$$,
  'não podem ser editados', 'pagamento não pode ser editado');
update public.pagamentos set estornado_em = now(), estorno_motivo = 'Lançado em duplicidade' where valor_centavos = 150000;
select testes.ok((select p.status = 'parcial' from public.parcelas p where venda_id = testes.v('venda') and numero = 1)
             and exists (select 1 from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                         where p.venda_id = testes.v('venda') and p.numero = 1 and t.status = 'pendente'),
  'estorno reabre a parcela e o lembrete volta para o painel');
delete from public.pagamentos;
select testes.ok((select count(*) from public.pagamentos) = 2, 'pagamentos nunca são apagados');

-- Saldo anterior (recadastro de paciente antigo com parcelas em aberto).
with novo as (
  insert into public.vendas (clinica_id, pessoa_id, tipo, valor_total_centavos, condicao_pagamento, quantidade_parcelas)
  values (testes.v('c1'), testes.v('joao'), 'saldo_anterior', 300000, 'parcelado', 2) returning id
) select testes.guardar('saldo', id) from novo;
select public.gerar_parcelas(testes.v('saldo'), testes.hoje() + 5);
select testes.ok((select count(*) from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                  where p.venda_id = testes.v('saldo')) = 2,
  'saldo anterior de paciente antigo também gera lembretes financeiros');
select testes.erro(
  $$insert into public.vendas (clinica_id, pessoa_id, valor_total_centavos) values (testes.v('c1'), testes.v('joao'), 1000)$$,
  'check constraint', 'venda nova precisa estar ligada a uma negociação');

select testes.erro(
  $$update public.vendas set status = 'cancelada', cancelada_em = now(), cancelada_motivo = 'x' where id = testes.v('venda')$$,
  'Somente a administradora', 'secretária não cancela venda');

-- ─── Permissão financeira ────────────────────────────────────────────────────

reset role; select testes.entrar('estagiaria@teste.local'); set role authenticated;
select testes.ok((select count(*) from public.parcelas) = 0 and (select count(*) from public.vendas) = 0,
  'usuária sem permissão financeira não vê valores');
select testes.ok((select count(*) from public.pessoas) = 2,
  '...mas vê os contatos normalmente');

-- ─── Administradora ──────────────────────────────────────────────────────────

reset role; select testes.entrar('mae@teste.local'); set role authenticated;

update public.vendas set status = 'cancelada', cancelada_em = now(), cancelada_motivo = 'Paciente desistiu do tratamento'
 where id = testes.v('saldo');
select testes.ok((select bool_and(status = 'cancelada') from public.parcelas where venda_id = testes.v('saldo'))
             and (select bool_and(t.status = 'cancelada') from public.tarefas t join public.parcelas p on p.id = t.parcela_id
                  where p.venda_id = testes.v('saldo')),
  'cancelar venda (administradora) cancela parcelas em aberto e seus lembretes');

update public.pessoas set observacoes_comerciais = 'Prefere contato pela manhã' where id = testes.v('maria');
select testes.ok((
  select a.antes ->> 'observacoes_comerciais' = 'Prefere contato à tarde.'
     and a.depois ->> 'observacoes_comerciais' = 'Prefere contato pela manhã'
     and a.usuario_id = testes.v('mae')
     and not (a.depois ? 'nome')
  from public.auditoria a
  where a.tabela = 'pessoas' and a.registro_id = testes.v('maria') and a.acao = 'update'
  order by a.id desc limit 1),
  'auditoria guarda antes/depois apenas dos campos alterados e quem alterou');
select testes.ok((select count(*) from public.auditoria where tabela = 'parcelas') > 0,
  'alterações financeiras ficam na auditoria');

delete from public.pessoas where id = testes.v('maria');
select testes.ok(exists (select 1 from public.pessoas where id = testes.v('maria')),
  'contatos não são apagados pelo sistema (arquivar em vez de excluir)');

reset role; select testes.entrar('secretaria@teste.local'); set role authenticated;
select testes.ok((select count(*) from public.auditoria) = 0, 'secretária não acessa a auditoria');
select testes.erro($$select public.anonimizar_pessoa(testes.v('joao'), 'pedido')$$,
  'Somente a administradora', 'secretária não anonimiza cadastros');

-- ─── Isolamento entre clínicas ───────────────────────────────────────────────

reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.ok(
  (select count(*) from public.pessoas) = 0 and (select count(*) from public.tarefas) = 0
  and (select count(*) from public.interacoes) = 0 and (select count(*) from public.parcelas) = 0
  and (select count(*) from public.v_contatos) = 0 and (select count(*) from public.v_painel_tarefas) = 0,
  'outra clínica não enxerga nenhum dado do Instituto CG');
update public.pessoas set nome = 'Hackeado' where id = testes.v('maria');
reset role;
select testes.ok((select nome from public.pessoas where id = testes.v('maria')) = 'Maria Silva',
  'outra clínica não consegue alterar dados do Instituto CG');

-- Sem login: nada.
set role anon;
select testes.ok((select count(*) from public.pessoas) = 0 and (select count(*) from public.procedimentos) = 0,
  'sem login não há acesso a nenhum dado');
reset role;

-- ─── LGPD ────────────────────────────────────────────────────────────────────

select testes.entrar('mae@teste.local'); set role authenticated;
select public.anonimizar_pessoa(testes.v('joao'), 'Pedido do titular por e-mail');
reset role;
select testes.ok((select nome = 'Pessoa anonimizada' and whatsapp_e164 is null and nao_contatar
                  from public.pessoas where id = testes.v('joao'))
             and not exists (select 1 from public.auditoria
                             where registro_id = testes.v('joao') and (antes::text like '%Pereira%' or depois::text like '%Pereira%')),
  'anonimização LGPD remove dados pessoais, inclusive das cópias na auditoria');

-- ─── Integridade referencial (varredura geral como superusuário) ─────────────

select testes.erro($$delete from public.pessoas where id = testes.v('maria')$$,
  'foreign key', 'nem o superusuário apaga pessoa que tem histórico ligado');
select testes.erro($$delete from public.etapas_funil where nome = 'Em contato' and clinica_id = testes.v('c1')$$,
  'foreign key', 'etapa usada no histórico não pode ser apagada');
select testes.erro($$delete from public.parcelas where venda_id = testes.v('venda')$$,
  'foreign key', 'parcela com pagamentos/lembretes não pode ser apagada');

select testes.ok(not exists (
  select 1 from public.tarefas t join public.pessoas p on p.id = t.pessoa_id where p.clinica_id <> t.clinica_id
  union all
  select 1 from public.oportunidades o join public.etapas_funil e on e.id = o.etapa_id where e.clinica_id <> o.clinica_id
  union all
  select 1 from public.parcelas pa join public.vendas v on v.id = pa.venda_id
   where v.clinica_id <> pa.clinica_id or v.pessoa_id <> pa.pessoa_id
  union all
  select 1 from public.historico_etapas h join public.oportunidades o on o.id = h.oportunidade_id
   where o.pessoa_id <> h.pessoa_id
),
  'varredura: nenhum registro ligado a pessoa, etapa ou venda de outra clínica/pessoa');

select testes.ok(not exists (
  select 1 from public.oportunidades
  where status in ('aberta', 'pausada') group by pessoa_id having count(*) > 1),
  'varredura: nenhuma pessoa com mais de uma etapa atual');

select testes.ok(not exists (
  select 1 from public.parcelas p
  where p.status in ('pendente', 'parcial')
    and not exists (select 1 from public.tarefas t where t.parcela_id = p.id and t.status = 'pendente')),
  'varredura: toda parcela em aberto tem lembrete financeiro pendente');

\echo '✓ Todos os testes de integridade passaram.'
