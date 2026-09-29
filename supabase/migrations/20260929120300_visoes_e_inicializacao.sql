-- =============================================================================
-- Migração 4/4: visões de leitura e inicialização da clínica
--   v_contatos            → cada contato com status, etapa atual, procedimento
--                            de interesse e próxima ação (data incluída)
--   v_parcelas            → parcelas com situação (a vencer, vence hoje, atrasada…)
--   v_painel_tarefas      → o que fazer hoje (inclui atrasadas), com o texto do painel
--   v_pendencias_financeiras, v_resumo_financeiro_mensal, v_funil
--   inicializar_clinica() → cria a clínica com catálogos e parâmetros padrão
--
-- Todas as visões usam security_invoker: respeitam o RLS de quem consulta.
-- =============================================================================

-- ─── Contatos ────────────────────────────────────────────────────────────────

create view public.v_contatos with (security_invoker = true) as
with base as (
  select
    p.*,
    (now() at time zone c.fuso)::date as hoje,
    coalesce((c.configuracoes ->> 'meses_paciente_inativo')::int, 12) as meses_inativo,
    greatest(
      p.ultimo_atendimento_informado,
      (select max((a.inicio at time zone c.fuso)::date)
         from public.agendamentos a
        where a.pessoa_id = p.id and a.status = 'compareceu')
    ) as ultimo_atendimento_em,
    (select max(o.fechada_em)::date from public.oportunidades o
      where o.pessoa_id = p.id and o.status = 'ganha') as ultima_venda_em
  from public.pessoas p
  join public.clinicas c on c.id = p.clinica_id
)
select
  b.id,
  b.clinica_id,
  b.tipo_cadastro,
  b.nome,
  b.apelido_tratamento,
  b.data_nascimento,
  b.telefone_e164,
  b.whatsapp_e164,
  b.email,
  b.cep, b.logradouro, b.numero, b.complemento, b.bairro, b.cidade, b.uf,
  b.origem_id,
  orig.nome                                 as origem,
  b.responsavel_id,
  resp.nome                                 as responsavel,
  b.temperatura,
  b.observacoes_comerciais,
  b.primeiro_contato_em,
  b.ultimo_contato_em,
  b.ultimo_atendimento_em,
  b.consentimento_contato,
  b.consentimento_marketing,
  b.nao_contatar,
  b.arquivado_em,
  -- Relacionamento com a clínica
  case
    when b.tipo_cadastro = 'novo_contato' and b.ultima_venda_em is null then 'lead'
    when b.em_tratamento
      or greatest(b.ultimo_atendimento_em, b.ultima_venda_em)
         >= b.hoje - make_interval(months => b.meses_inativo) then 'paciente_ativo'
    else 'paciente_inativo'
  end                                       as relacionamento,
  -- Status atual
  case
    when b.arquivado_em is not null then 'arquivado'
    when b.nao_contatar then 'nao_contatar'
    when op.status = 'aberta' then 'em_negociacao'
    when op.status = 'pausada' then 'sem_resposta'
    when b.em_tratamento then 'em_tratamento'
    else 'sem_negociacao'
  end                                       as status_atual,
  -- Funil (uma única negociação em andamento por pessoa)
  op.id                                     as oportunidade_id,
  op.procedimento_id                        as procedimento_interesse_id,
  proc.nome                                 as procedimento_interesse,
  op.etapa_id,
  et.nome                                   as etapa_atual,
  op.etapa_desde,
  (b.hoje - (op.etapa_desde at time zone 'America/Sao_Paulo')::date) as dias_na_etapa,
  op.valor_estimado_centavos,
  -- Próxima ação = tarefa pendente mais próxima
  prox.id                                   as proxima_tarefa_id,
  prox.titulo                               as proxima_acao,
  prox.vence_em                             as proxima_acao_em,
  prox.horario                              as proxima_acao_horario
from base b
left join public.origens orig on orig.id = b.origem_id
left join public.usuarios resp on resp.id = b.responsavel_id
left join public.oportunidades op on op.pessoa_id = b.id and op.status in ('aberta', 'pausada')
left join public.procedimentos proc on proc.id = op.procedimento_id
left join public.etapas_funil et on et.id = op.etapa_id
left join lateral (
  select t.id, t.titulo, t.vence_em, t.horario
    from public.tarefas t
   where t.pessoa_id = b.id and t.status = 'pendente'
   order by t.vence_em, t.horario nulls last,
            array_position(array['urgente', 'alta', 'normal', 'baixa']::public.prioridade_tarefa[], t.prioridade)
   limit 1
) prox on true;

-- ─── Parcelas com situação calculada ─────────────────────────────────────────

create view public.v_parcelas with (security_invoker = true) as
select
  pa.*,
  pe.nome                                           as pessoa_nome,
  fp.nome                                           as forma_pagamento,
  v.quantidade_parcelas,
  pa.valor_centavos - pa.valor_pago_centavos        as saldo_centavos,
  (now() at time zone c.fuso)::date - pa.vencimento as dias_atraso,
  case
    when pa.status in ('paga', 'cancelada', 'renegociada') then pa.status::text
    when pa.vencimento < (now() at time zone c.fuso)::date then 'atrasada'
    when pa.vencimento = (now() at time zone c.fuso)::date then 'vence_hoje'
    else 'a_vencer'
  end                                               as situacao
from public.parcelas pa
join public.pessoas pe on pe.id = pa.pessoa_id
join public.vendas v on v.id = pa.venda_id
join public.clinicas c on c.id = pa.clinica_id
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id;

create view public.v_pendencias_financeiras with (security_invoker = true) as
select * from public.v_parcelas where situacao in ('vence_hoje', 'atrasada');

-- ─── Painel "O que eu tenho que fazer hoje?" ─────────────────────────────────

create view public.v_painel_tarefas with (security_invoker = true) as
with t as (
  select
    t.*,
    (now() at time zone c.fuso)::date as hoje,
    pe.nome as pessoa_nome,
    pe.whatsapp_e164,
    pe.telefone_e164,
    pa.valor_centavos - pa.valor_pago_centavos as saldo_parcela_centavos
  from public.tarefas t
  join public.clinicas c on c.id = t.clinica_id
  join public.pessoas pe on pe.id = t.pessoa_id
  left join public.parcelas pa on pa.id = t.parcela_id
  where t.status = 'pendente'
    and t.vence_em <= (now() at time zone c.fuso)::date
)
select
  t.id, t.clinica_id, t.pessoa_id, t.oportunidade_id, t.agendamento_id, t.parcela_id,
  t.tipo, t.categoria, t.titulo, t.descricao, t.vence_em, t.horario, t.prioridade,
  t.responsavel_id, t.origem, t.mensagem_sugerida, t.modelo_mensagem_id,
  t.pessoa_nome, t.whatsapp_e164, t.telefone_e164,
  t.hoje - t.vence_em as dias_atraso,
  case
    when t.tipo = 'confirmar_pagamento' and t.vence_em = t.hoje then 'Pagamento previsto hoje'
    when t.tipo = 'confirmar_pagamento' then
      'Pagamento em atraso há ' || (t.hoje - t.vence_em)
      || case when t.hoje - t.vence_em = 1 then ' dia' else ' dias' end
    when t.vence_em = t.hoje then 'Para hoje'
    else 'Atrasada há ' || (t.hoje - t.vence_em)
      || case when t.hoje - t.vence_em = 1 then ' dia' else ' dias' end
  end as situacao_prazo,
  -- Texto pronto para o painel
  case
    when t.tipo = 'confirmar_pagamento' and t.saldo_parcela_centavos is not null then
      case when t.vence_em = t.hoje then 'Pagamento previsto hoje'
           else 'Pagamento em atraso' end
      || ' — ' || t.pessoa_nome || ' — ' || public.formatar_brl(t.saldo_parcela_centavos)
    else t.titulo
  end as texto_painel,
  -- Ordem sugerida: urgência, atraso e horário
  array_position(array['urgente', 'alta', 'normal', 'baixa']::public.prioridade_tarefa[], t.prioridade) as ordem_prioridade
from t;

-- ─── Resumos ─────────────────────────────────────────────────────────────────

-- Vendido (competência) × recebido (caixa) por mês.
create view public.v_resumo_financeiro_mensal with (security_invoker = true) as
with vendido as (
  select clinica_id, date_trunc('month', fechada_em)::date as mes, sum(valor_final_centavos) as vendido_centavos
    from public.vendas where status = 'ativa' and tipo = 'venda'
   group by 1, 2
), recebido as (
  select clinica_id, date_trunc('month', pago_em)::date as mes, sum(valor_centavos) as recebido_centavos
    from public.pagamentos where estornado_em is null
   group by 1, 2
), previsto as (
  select clinica_id, date_trunc('month', vencimento)::date as mes,
         sum(valor_centavos - valor_pago_centavos) as a_receber_centavos
    from public.parcelas where status in ('pendente', 'parcial')
   group by 1, 2
)
select
  coalesce(v.clinica_id, r.clinica_id, p.clinica_id) as clinica_id,
  coalesce(v.mes, r.mes, p.mes)                      as mes,
  coalesce(v.vendido_centavos, 0)                    as vendido_centavos,
  coalesce(r.recebido_centavos, 0)                   as recebido_centavos,
  coalesce(p.a_receber_centavos, 0)                  as a_receber_centavos
from vendido v
full join recebido r on r.clinica_id = v.clinica_id and r.mes = v.mes
full join previsto p on p.clinica_id = coalesce(v.clinica_id, r.clinica_id)
                    and p.mes = coalesce(v.mes, r.mes);

-- Quantidade e valor por etapa (negociações em andamento).
create view public.v_funil with (security_invoker = true) as
select
  e.clinica_id, e.id as etapa_id, e.nome as etapa, e.ordem, e.tipo, e.cor,
  count(o.id)                                   as quantidade,
  coalesce(sum(o.valor_estimado_centavos), 0)   as valor_estimado_centavos
from public.etapas_funil e
left join public.oportunidades o on o.etapa_id = e.id and o.status in ('aberta', 'pausada')
where e.ativo
group by e.clinica_id, e.id, e.nome, e.ordem, e.tipo, e.cor;

-- ─── Inicialização da clínica (executar uma vez, pelo servidor) ──────────────

create or replace function public.inicializar_clinica(p_nome text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c uuid;
begin
  insert into public.clinicas (nome, configuracoes)
  values (p_nome, jsonb_build_object(
    'horario', jsonb_build_object('dias', jsonb_build_array(1, 2, 3, 4, 5), 'inicio', '08:00', 'fim', '19:00'),
    'dias_fechados_extra', '[]'::jsonb,
    'fecha_pontos_facultativos', false,
    'sla_primeiro_contato_min', 15,
    'meses_paciente_inativo', 12,
    'dias_reativacao_desistiu', 180,
    'intervalo_min_contato_dias', 3,
    'intervalo_min_campanha_dias', 30,
    'reativacao_automatica', false,
    'limite_reativacao_dia', 10,
    'validade_orcamento_dias', 30
  ))
  returning id into c;

  insert into public.profissionais (clinica_id, nome, cor) values (c, 'Dentista responsável', '#B08D57');

  insert into public.procedimentos (clinica_id, nome, categoria, ciclo_retorno_meses, ordem) values
    (c, 'Facetas de porcelana',      'Estética',      null, 1),
    (c, 'Facetas/lentes em resina',  'Estética',      null, 2),
    (c, 'Estética odontológica',     'Estética',      null, 3),
    (c, 'Clareamento dental',        'Estética',      12,   4),
    (c, 'Periodontia',               'Periodontia',   6,    5),
    (c, 'Implantes',                 'Reabilitação',  null, 6),
    (c, 'Manutenção e limpeza',      'Prevenção',     6,    7),
    (c, 'Outros serviços',           'Outros',        null, 99);

  insert into public.origens (clinica_id, nome, tipo, ordem) values
    (c, 'Instagram',                   'organico',  1),
    (c, 'Anúncio Instagram/Facebook',  'pago',      2),
    (c, 'Google',                      'organico',  3),
    (c, 'Anúncio Google',              'pago',      4),
    (c, 'Site',                        'organico',  5),
    (c, 'Indicação de paciente',       'indicacao', 6),
    (c, 'Indicação de profissional',   'indicacao', 7),
    (c, 'WhatsApp',                    'organico',  8),
    (c, 'Passou em frente à clínica',  'organico',  9),
    (c, 'Paciente antigo',             'interno',   10),
    (c, 'Outro',                       'organico',  99);

  insert into public.etapas_funil (clinica_id, nome, ordem, tipo, resultado, sla_dias, cor) values
    (c, 'Novo contato',          1,  'aberta', null,           0,    '#C9A96E'),
    (c, 'Em contato',            2,  'aberta', null,           3,    '#B99A62'),
    (c, 'Avaliação agendada',    3,  'aberta', null,           null, '#A88B57'),
    (c, 'Avaliação realizada',   4,  'aberta', null,           2,    '#977C4C'),
    (c, 'Orçamento apresentado', 5,  'aberta', null,           7,    '#866D41'),
    (c, 'Em negociação',         6,  'aberta', null,           15,   '#755E36'),
    (c, 'Fechou',                7,  'ganho',  'fechou',       null, '#5E7D5A'),
    (c, 'Não fechou',            8,  'perda',  'nao_fechou',   null, '#9A8F84'),
    (c, 'Desistiu',              9,  'perda',  'desistiu',     null, '#8A8178'),
    (c, 'Sem resposta',          10, 'perda',  'sem_resposta', null, '#B3AAA0');

  insert into public.motivos (clinica_id, nome, aplica_a, retorno_sugerido_dias, ordem) values
    (c, 'Valor alto',                        'nao_fechou', 30,   1),
    (c, 'Forma de pagamento',                'nao_fechou', 15,   2),
    (c, 'Precisa pensar',                    'nao_fechou', 7,    3),
    (c, 'Conversar com a família',           'nao_fechou', 7,    4),
    (c, 'Medo ou insegurança',               'nao_fechou', 10,   5),
    (c, 'Pesquisando outras clínicas',       'nao_fechou', 10,   6),
    (c, 'Não é o momento',                   'nao_fechou', 90,   7),
    (c, 'Momento financeiro',                'nao_fechou', 120,  8),
    (c, 'Escolheu outra clínica',            'nao_fechou', 365,  9),
    (c, 'Outro',                             'nao_fechou', null, 99),
    (c, 'Sem interesse no momento',          'desistiu',   180,  1),
    (c, 'Fez o tratamento em outro lugar',   'desistiu',   365,  2),
    (c, 'Mudou de cidade',                   'desistiu',   null, 3),
    (c, 'Outro',                             'desistiu',   null, 99),
    (c, 'Imprevisto pessoal',                'desmarcou',  null, 1),
    (c, 'Trabalho',                          'desmarcou',  null, 2),
    (c, 'Saúde',                             'desmarcou',  null, 3),
    (c, 'Financeiro',                        'desmarcou',  null, 4),
    (c, 'Não informou',                      'desmarcou',  null, 5),
    (c, 'Outro',                             'desmarcou',  null, 99);

  insert into public.formas_pagamento (clinica_id, nome, permite_parcelamento, max_parcelas, ordem) values
    (c, 'PIX',                    true,  24, 1),
    (c, 'Cartão de crédito',      true,  12, 2),
    (c, 'Cartão de débito',       false, 1,  3),
    (c, 'Dinheiro',               true,  24, 4),
    (c, 'Transferência bancária', true,  24, 5),
    (c, 'Boleto',                 true,  24, 6);

  insert into public.modelos_mensagem (clinica_id, situacao, titulo, texto) values
    (c, 'primeiro_contato', 'Primeiro contato',
     'Olá, {primeiro_nome}! Aqui é do Instituto CG. Recebemos o seu interesse em {procedimento} e será um prazer conversar com você. Qual o melhor horário para falarmos?'),
    (c, 'confirmar_agendamento', 'Confirmação de avaliação',
     'Olá, {primeiro_nome}! Passando para confirmar a sua avaliação no Instituto CG em {data}, às {horario}. Podemos confirmar?'),
    (c, 'follow_up_orcamento', 'Acompanhamento do orçamento',
     'Olá, {primeiro_nome}! Tudo bem? Fico à disposição caso tenha ficado alguma dúvida sobre o planejamento de {procedimento}. Se preferir, podemos conversar com calma.'),
    (c, 'recuperar_desmarcacao', 'Paciente desmarcou',
     'Olá, {primeiro_nome}! Sentimos sua falta. Quando for melhor para você, reservamos um novo horário. Tenho disponibilidade em {data}. Fica bom?'),
    (c, 'reativacao', 'Reativação de paciente',
     'Olá, {primeiro_nome}! Há algum tempo não nos vemos no Instituto CG. Que tal agendarmos uma visita para cuidarmos do seu sorriso?'),
    (c, 'confirmar_pagamento', 'Lembrete de pagamento',
     'Olá, {primeiro_nome}! Tudo bem? Passando para lembrar, com carinho, do pagamento de {valor} previsto para {data}. Qualquer dúvida, estou à disposição.');

  return c;
end;
$$;

-- Vincula um login existente a uma clínica com um papel (executar pelo servidor).
create or replace function public.adicionar_membro(
  p_clinica uuid,
  p_email text,
  p_papel public.papel_membro,
  p_pode_ver_financeiro boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario uuid;
  v_membro uuid;
begin
  select id into v_usuario from public.usuarios where lower(email) = lower(p_email);
  if v_usuario is null then
    raise exception 'Nenhum login encontrado para %', p_email using errcode = 'P0002';
  end if;
  insert into public.membros (clinica_id, usuario_id, papel, pode_ver_financeiro)
  values (p_clinica, v_usuario, p_papel, p_pode_ver_financeiro)
  on conflict (clinica_id, usuario_id)
    do update set papel = excluded.papel, pode_ver_financeiro = excluded.pode_ver_financeiro, ativo = true
  returning id into v_membro;
  return v_membro;
end;
$$;

-- Estas funções administrativas não podem ser chamadas pelo navegador.
revoke execute on function public.inicializar_clinica(text) from public, anon, authenticated;
revoke execute on function public.adicionar_membro(uuid, text, public.papel_membro, boolean) from public, anon, authenticated;
