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
    coalesce((select r.periodo_meses from public.regras_followup r
               where r.clinica_id = p.clinica_id and r.situacao = 'paciente_inativo'), 6) as meses_inativo,
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
  b.ultimo_atendimento_informado,
  b.ultimo_atendimento_faixa,
  b.paciente_desde,
  b.em_tratamento,
  b.retorno_previsto_em,
  b.nao_contatar_motivo,
  b.criado_em,
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
    'intervalo_min_contato_dias', 3,
    'intervalo_min_campanha_dias', 30,
    'limite_reativacao_dia', 10,
    'validade_orcamento_dias', 30,
    -- (Prazos e tentativas de follow-up ficam na tabela regras_followup.)
    -- Quantos dias as negociações encerradas (Fechou / Não fechou) ficam visíveis no funil.
    'dias_encerradas_no_funil', 30
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

  -- Etapas editáveis (nome, cor, prazo). O "marco"/"resultado" diz ao sistema o papel de cada uma.
  insert into public.etapas_funil (clinica_id, nome, ordem, tipo, resultado, marco, sla_dias, cor) values
    (c, 'Novo contato',            1,  'aberta', null,           'novo_contato',          0,    '#C9A96E'),
    (c, 'Em contato',              2,  'aberta', null,           'em_contato',            3,    '#B99A62'),
    (c, 'Avaliação agendada',      3,  'aberta', null,           'avaliacao_agendada',    null, '#A88B57'),
    -- Passou pela consulta (onde o orçamento é apresentado) e ainda está decidindo.
    (c, 'Consulta realizada',      4,  'aberta', null,           'avaliacao_realizada',   14,   '#8A6A3A'),
    (c, 'Desmarcou',               5,  'aberta', null,           'desmarcou',             7,    '#B4533A'),
    (c, 'Sem resposta',            6,  'perda',  'sem_resposta', null,                    null, '#B3AAA0'),
    (c, 'Reativação',              7,  'aberta', null,           'reativacao',            30,   '#5F8A6A'),
    (c, 'Fechou',                  8,  'ganho',  'fechou',       null,                    null, '#5E7D5A'),
    (c, 'Não fechou',              9,  'perda',  'nao_fechou',   null,                    null, '#9A8F84'),
    (c, 'Desistiu',                10, 'perda',  'desistiu',     null,                    null, '#8A8178');

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
    (c, 'Parou de responder',                'nao_fechou', 90,   10),
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

  -- Mensagens prontas (editáveis em Mensagens). Tom: elegante, cordial, humano e sem pressão.
  -- "situacao" liga o modelo a uma tarefa específica; "padrao" é o sugerido na categoria.
  insert into public.modelos_mensagem (clinica_id, categoria, situacao, padrao, titulo, texto) values
    -- Primeiro contato
    (c, 'primeiro_contato', 'primeiro_contato', true, 'Boas-vindas',
     'Olá, {{nome}}! Tudo bem? Aqui é do {{clinica}}. Recebemos o seu contato e fico muito feliz com o seu interesse em {{procedimento}}. Posso te contar como funciona a avaliação e encontrar um horário que seja confortável para você?'),
    (c, 'primeiro_contato', 'follow_up', false, 'Convite para a avaliação',
     'Olá, {{nome}}! Que bom falar com você. O primeiro passo para {{procedimento}} é uma avaliação feita com calma, para entendermos exatamente o que você deseja. Qual período costuma ser melhor para você: manhã ou tarde?'),
    -- Passou pela primeira consulta (pensando)
    (c, 'pos_consulta', 'acompanhar_decisao', true, 'Depois da consulta',
     'Olá, {{nome}}! Tudo bem? Foi um prazer receber você na consulta. Sei que é uma decisão importante: se ficou alguma dúvida sobre {{procedimento}}, estou por aqui para ajudar — sem pressa.'),
    (c, 'pos_consulta', null, false, 'Conseguiu avaliar com calma?',
     'Olá, {{nome}}! Tudo bem? Estou passando para saber se conseguiu avaliar com calma as informações sobre {{procedimento}}. Se quiser, posso te ajudar com qualquer dúvida e verificar um novo horário para você.'),
    (c, 'pos_consulta', 'follow_up_orcamento', false, 'Sobre o plano de tratamento',
     'Olá, {{nome}}! Espero que esteja bem. Fico à disposição caso queira rever algum ponto do plano de tratamento ou conversar sobre as condições de pagamento. Podemos encontrar juntos o formato que fizer mais sentido para você.'),
    -- Paciente não fechou
    (c, 'nao_fechou', 'retorno_por_motivo', true, 'Retomar com leveza',
     'Olá, {{nome}}! Tudo bem? Lembrei de você e quis saber como está. Se ainda tiver vontade de realizar {{procedimento}}, será um prazer conversar sobre as possibilidades — sem compromisso.'),
    (c, 'nao_fechou', null, false, 'Novas possibilidades',
     'Olá, {{nome}}! Como vai? Queria te contar que temos algumas possibilidades de condições para {{procedimento}} que talvez façam sentido para você neste momento. Se quiser, te explico tudo com calma.'),
    -- Paciente sem resposta
    (c, 'sem_resposta', 'reabrir_sem_resposta', true, 'Retomar o contato',
     'Olá, {{nome}}! Tudo bem? Imagino que a rotina esteja corrida. Deixo esta mensagem só para dizer que seguimos à disposição sobre {{procedimento}}. Quando for um bom momento, é só me responder por aqui.'),
    (c, 'sem_resposta', null, false, 'Porta aberta',
     'Olá, {{nome}}! Não quero incomodar — esta é só uma mensagem para deixar a porta aberta. Quando quiser retomar a conversa sobre {{procedimento}}, será um prazer atender você.'),
    -- Paciente desmarcou
    (c, 'desmarcou', 'recuperar_desmarcacao', true, 'Desmarcou',
     'Olá, {{nome}}! Tudo bem? Vi que você precisou desmarcar {{consulta}} do dia {{data}}. Sem problema! Quando for melhor para você, encontramos um novo horário — é só me dizer os dias e horários que ficam mais fáceis.'),
    (c, 'desmarcou', 'recuperar_falta', false, 'Faltou à consulta',
     'Olá, {{nome}}! Sentimos sua falta na consulta do dia {{data}}. Está tudo bem? Se quiser, reservo um novo horário para você — é só me dizer o melhor dia.'),
    -- Confirmação
    (c, 'confirmacao', 'confirmar_agendamento', true, 'Confirmar presença',
     'Olá, {{nome}}! Tudo bem? Passando para confirmar {{consulta}} com {{dentista}} no dia {{data}}, às {{horario}}. Podemos contar com a sua presença? Se precisar ajustar o horário, é só me avisar.'),
    -- Remarcação
    (c, 'remarcacao', null, true, 'Novo horário',
     'Olá, {{nome}}! Tudo bem? Vamos encontrar um novo horário para {{consulta}}? Me diga os dias e períodos que ficam melhores para você, que eu verifico a agenda com carinho.'),
    (c, 'remarcacao', 'clinica_cancelou', false, 'A clínica precisou remarcar',
     'Olá, {{nome}}! Tudo bem? Precisamos reagendar {{consulta}} do dia {{data}} — pedimos desculpas pelo transtorno. Qual dia e horário ficam melhores para você?'),
    -- Reativação
    (c, 'reativacao', 'reativacao', true, 'Que saudade',
     'Olá, {{nome}}! Tudo bem? Faz um tempinho que não nos vemos aqui no {{clinica}} e lembrei de você. Que tal agendarmos uma avaliação para cuidarmos do seu sorriso? Será um prazer receber você novamente.'),
    -- Acompanhamento pós-atendimento
    (c, 'pos_atendimento', null, true, 'Como você está?',
     'Olá, {{nome}}! Tudo bem? Passando para saber como você está depois do atendimento. Se sentir qualquer coisa diferente ou tiver alguma dúvida, pode me chamar por aqui — estamos à disposição.'),
    (c, 'pos_atendimento', 'agendar_tratamento', false, 'Início do tratamento',
     'Olá, {{nome}}! Que alegria ter você conosco nesta nova etapa. Vamos combinar a data de início do seu tratamento? Me diga os dias e horários que ficam melhores para você.'),
    (c, 'pos_atendimento', 'pos_tratamento', false, 'Revisão após o tratamento',
     'Olá, {{nome}}! Tudo bem? Já faz um tempinho desde o seu tratamento aqui no {{clinica}}. Que tal agendarmos uma revisão para cuidarmos do resultado? Será um prazer rever você.'),
    -- Pagamentos (o painel escolhe conforme o vencimento)
    (c, 'pagamento_previsto', 'confirmar_pagamento', true, 'Lembrete antes do vencimento',
     'Olá, {{nome}}! Tudo bem? Passando só para lembrar, com antecedência, do pagamento de {{valor}} previsto para {{vencimento}}. Qualquer dúvida, estou por aqui.'),
    (c, 'cobranca_amigavel', null, true, 'Lembrete gentil',
     'Olá, {{nome}}! Tudo bem? Passando com carinho para lembrar do pagamento de {{valor}}, com vencimento em {{vencimento}}, que ainda consta em aberto por aqui. Se já tiver feito, por favor desconsidere — e, se precisar, envio os dados novamente.'),
    (c, 'pagamento_pendente', null, true, 'Pagamento em aberto',
     'Olá, {{nome}}! Tudo bem? O pagamento de {{valor}}, previsto para {{vencimento}}, segue em aberto aqui. Pode ter sido apenas um descompasso de datas — se preferir, podemos combinar juntos a melhor forma de acertar. Fico à disposição.'),
    -- Paciente antigo
    (c, 'paciente_antigo', 'manutencao', true, 'Hora da manutenção',
     'Olá, {{nome}}! Tudo bem? Está chegando a hora da sua manutenção de {{procedimento}}. Vamos reservar um horário para manter o resultado sempre bonito?'),
    (c, 'paciente_antigo', null, false, 'Quanto tempo!',
     'Olá, {{nome}}! Quanto tempo! Aqui é do {{clinica}}. Atualizamos o seu cadastro e quis saber como você está. Quando quiser, será um prazer receber você para uma revisão.');

  -- Regras de follow-up (tudo editável em Configurações).
  --   prazo_dias: 1ª ação N dias após o evento · intervalos: novas tentativas (dias após a anterior)
  --   ao_esgotar: o que fazer se continuar sem resposta
  insert into public.regras_followup (clinica_id, situacao, nome, quando, ativa, tipo_tarefa, titulo_modelo,
                                      prazo_dias, intervalos, prioridade, ao_esgotar, espera_reativacao_dias,
                                      periodo_meses, mensagem_situacao) values
    (c, 'novo_contato', 'Novo lead', 'Quando alguém é cadastrado como novo contato', true,
     'primeiro_contato', 'Fazer o primeiro contato com {primeiro_nome}', 0, '{1,2}', 'urgente', 'sem_resposta', null, null, 'primeiro_contato'),
    (c, 'em_contato', 'Demonstrou interesse', 'Quando a pessoa responde com interesse', true,
     'follow_up', 'Conduzir {primeiro_nome} para a avaliação', 1, '{3,4}', 'alta', 'sem_resposta', null, null, 'follow_up'),
    (c, 'confirmacao', 'Confirmar consulta', 'Quando uma avaliação ou consulta é agendada (prazo = dias úteis antes)', true,
     'confirmar_agendamento', 'Confirmar {consulta} de {primeiro_nome}', 1, '{}', 'normal', 'decidir', null, null, 'confirmar_agendamento'),
    (c, 'pos_consulta', 'Saiu da consulta sem fechar', 'Quando a pessoa passa pela consulta e ainda está decidindo', true,
     'acompanhar_decisao', 'Retomar com {primeiro_nome} depois da consulta', 3, '{4,7}', 'alta', 'sem_resposta', null, null, 'acompanhar_decisao'),
    (c, 'desmarcou', 'Desmarcou ou faltou', 'Quando uma consulta é desmarcada ou a pessoa não comparece', true,
     'recuperar_desmarcacao', 'Entrar em contato com {primeiro_nome} para remarcar', 1, '{3,4}', 'urgente', 'sem_resposta', null, null, 'recuperar_desmarcacao'),
    (c, 'sem_resposta', 'Parou de responder', 'Quando as tentativas terminam sem resposta', true,
     'reabrir_sem_resposta', 'Tentar novo contato com {primeiro_nome}', 7, '{14}', 'normal', 'reativacao', 60, null, 'reabrir_sem_resposta'),
    (c, 'nao_fechou', 'Não fechou', 'Quando a negociação não fecha — o prazo vem do motivo informado', true,
     'retorno_por_motivo', 'Retomar conversa com {primeiro_nome} sobre {procedimento}', null, '{}', 'baixa', 'decidir', null, null, 'retorno_por_motivo'),
    (c, 'fechou', 'Fechou', 'Quando a pessoa fecha o tratamento', true,
     'agendar_tratamento', 'Agendar o início do tratamento de {primeiro_nome}', 0, '{}', 'alta', 'decidir', null, null, 'agendar_tratamento'),
    (c, 'reativacao', 'Reativação', 'Quando a pessoa entra na etapa Reativação', true,
     'reativacao', 'Retomar contato com {primeiro_nome}', 0, '{21}', 'baixa', 'decidir', null, null, 'reativacao'),
    (c, 'paciente_inativo', 'Pacientes antigos sem atendimento', 'Pacientes sem atendimento há X meses (rotina diária, com limite por dia)', false,
     'reativacao', 'Reativar contato com {primeiro_nome}', 0, '{21}', 'baixa', 'decidir', null, 6, 'reativacao'),
    (c, 'manutencao', 'Manutenção devida', 'Tratamentos com retorno periódico (ex.: limpeza a cada 6 meses)', false,
     'manutencao', 'Lembrar {primeiro_nome} da manutenção', 0, '{21}', 'baixa', 'decidir', null, null, 'manutencao'),
    (c, 'pos_tratamento', 'Retorno após o tratamento', 'X meses depois de o tratamento ser concluído', true,
     'manutencao', 'Convidar {primeiro_nome} para a revisão', 0, '{21}', 'normal', 'decidir', null, 6, 'pos_tratamento');

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
