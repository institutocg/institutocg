-- =============================================================================
-- Migração 12: indicadores comerciais e de marketing
--   indicadores(clínica, de, até, procedimento) → leads, origem, procedimentos,
--   funil, conversão, perdas e reativação, sempre por período.
--   Gestão da clínica: sem rankings de pessoas da equipe.
--
-- Definições
--   • Lead: negociação aberta no período que não é reativação.
--   • Reativação: negociação que começou na etapa "Reativação" ou que retomou uma
--     negociação anterior (paciente antigo, campanha, retorno após tratamento…).
--   • Chegou à consulta: compareceu a uma consulta, passou por "Consulta realizada" ou fechou.
--   • Chegou ao orçamento: orçamento registrado ou fechou (o orçamento é apresentado na consulta).
-- =============================================================================

create or replace function public.indicadores(p_clinica uuid, p_de date, p_ate date, p_procedimento uuid default null)
returns jsonb
language sql
stable
set search_path = public
as $$
  with
  -- Negociações abertas no período, com a etapa em que começaram.
  ops as (
    select o.*,
           (select e.marco from public.historico_etapas h join public.etapas_funil e on e.id = h.etapa_nova_id
             where h.oportunidade_id = o.id order by h.mudou_em, h.id limit 1)              as marco_inicial,
           coalesce(o.origem_id, pe.origem_id)                                              as origem_lead
      from public.oportunidades o
      join public.pessoas pe on pe.id = o.pessoa_id
     where o.clinica_id = p_clinica
       and (o.criado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
  ),
  marcados as (
    select ops.*,
           (ops.marco_inicial = 'reativacao' or ops.oportunidade_origem_id is not null)    as eh_reativacao,
           exists (select 1 from public.agendamentos a where a.oportunidade_id = ops.id)    as agendou,
           (ops.status = 'ganha'
            or exists (select 1 from public.agendamentos a where a.oportunidade_id = ops.id and a.status = 'compareceu')
            or exists (select 1 from public.historico_etapas h join public.etapas_funil e on e.id = h.etapa_nova_id
                        where h.oportunidade_id = ops.id and e.marco = 'avaliacao_realizada'))  as consultou,
           (ops.status = 'ganha'
            or exists (select 1 from public.orcamentos oc where oc.oportunidade_id = ops.id and oc.status <> 'rascunho')) as orcou
      from ops
  ),
  leads as (select * from marcados where not eh_reativacao),
  reativ as (select * from marcados where eh_reativacao),
  -- Encerradas como perda no período (pela data de encerramento).
  perdas as (
    select o.*, m.nome as motivo,
           coalesce(m.grupo_perda, case when o.resultado = 'desistiu' then 'desistiu' else 'outro' end) as grupo
      from public.oportunidades o left join public.motivos m on m.id = o.motivo_id
     where o.clinica_id = p_clinica and o.status = 'perdida'
       and (o.fechada_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
  ),
  sem_resposta as (
    select o.* from public.oportunidades o
     where o.clinica_id = p_clinica and o.status = 'pausada'
       and (o.etapa_desde at time zone 'America/Sao_Paulo')::date between p_de and p_ate
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
  )
  select jsonb_build_object(
    'leads', jsonb_build_object(
      'novos', (select count(*) from leads),
      'convertidos', (select count(*) from leads where status = 'ganha'),
      'em_negociacao', (select count(*) from leads where status = 'aberta'),
      'sem_resposta', (select count(*) from leads where status = 'pausada'),
      'perdidos', (select count(*) from leads where status = 'perdida')),
    'por_procedimento', coalesce((
      select jsonb_agg(x order by x.leads desc, x.procedimento) from (
        select l.procedimento_id, coalesce(pr.nome, 'Não definido') as procedimento, count(*) as leads,
               count(*) filter (where l.status = 'ganha') as convertidos
          from leads l left join public.procedimentos pr on pr.id = l.procedimento_id
         group by 1, 2) x), '[]'::jsonb),
    -- Canais: sempre os seis, mesmo zerados (Instagram, indicação, Google, WhatsApp, paciente antigo, outro).
    'por_canal', (
      select jsonb_agg(x order by x.ordem) from (
        select c.canal, c.ordem, count(l.id) as leads, count(l.id) filter (where l.status = 'ganha') as convertidos
          from (values ('instagram', 1), ('indicacao', 2), ('google', 3), ('whatsapp', 4), ('paciente_antigo', 5), ('outro', 6))
               as c (canal, ordem)
          left join (leads l left join public.origens og on og.id = l.origem_lead)
                 on coalesce(og.canal, 'outro') = c.canal
         group by c.canal, c.ordem) x),
    'por_origem', coalesce((
      select jsonb_agg(x order by x.leads desc, x.origem) from (
        select coalesce(og.nome, 'Não informada') as origem, coalesce(og.canal, 'outro') as canal, count(*) as leads,
               count(*) filter (where l.status = 'ganha') as convertidos
          from leads l left join public.origens og on og.id = l.origem_lead
         group by 1, 2) x), '[]'::jsonb),
    'conversao', jsonb_build_object(
      'leads', (select count(*) from leads),
      'agendaram', (select count(*) from leads where agendou or consultou),
      'consulta', (select count(*) from leads where consultou),
      'orcamento', (select count(*) from leads where orcou),
      'fechamento', (select count(*) from leads where status = 'ganha')),
    -- Funil: onde está agora cada pessoa que entrou no funil no período (leads e reativações).
    'funil', coalesce((
      select jsonb_agg(jsonb_build_object('etapa', e.nome, 'cor', e.cor, 'tipo', e.tipo,
               'quantidade', (select count(*) from marcados m where m.etapa_id = e.id)) order by e.ordem)
        from public.etapas_funil e where e.clinica_id = p_clinica and e.ativo), '[]'::jsonb),
    'perdas', jsonb_build_object(
      'total', (select count(*) from perdas) + (select count(*) from sem_resposta),
      -- Grupos: preço, desistiu, não respondeu, escolheu outro local, adiou, outro.
      'grupos', jsonb_build_object(
        'preco', (select count(*) from perdas where grupo = 'preco'),
        'desistiu', (select count(*) from perdas where grupo = 'desistiu'),
        'nao_respondeu', (select count(*) from perdas where grupo = 'nao_respondeu') + (select count(*) from sem_resposta),
        'outro_local', (select count(*) from perdas where grupo = 'outro_local'),
        'adiou', (select count(*) from perdas where grupo = 'adiou'),
        'outro', (select count(*) from perdas where grupo = 'outro')),
      'motivos', coalesce((
        select jsonb_agg(x order by x.quantidade desc, x.motivo) from (
          select coalesce(motivo, 'Sem motivo registrado') as motivo, count(*) as quantidade from perdas group by 1
          union all
          select 'Parou de responder (em "Sem resposta")', count(*) from sem_resposta having count(*) > 0
        ) x), '[]'::jsonb)),
    'reativacao', jsonb_build_object(
      'elegiveis', (select count(*) from public.v_contatos c
                     where c.clinica_id = p_clinica and c.relacionamento = 'paciente_inativo'
                       and c.arquivado_em is null and not c.nao_contatar and c.consentimento_contato
                       and c.oportunidade_id is null),
      'reativados', (select count(*) from reativ),
      'responderam', (select count(*) from reativ r
                       where r.status = 'ganha' or r.agendou
                          or (r.status = 'aberta' and (select e.marco from public.etapas_funil e where e.id = r.etapa_id) is distinct from 'reativacao')
                          or exists (select 1 from public.interacoes i where i.oportunidade_id = r.id
                                      and i.tipo in ('paciente_respondeu', 'retorno_solicitado'))),
      'agendaram', (select count(*) from reativ where agendou),
      'fecharam', (select count(*) from reativ where status = 'ganha'),
      'aguardando', (select count(*) from reativ r where r.status = 'aberta'
                       and (select e.marco from public.etapas_funil e where e.id = r.etapa_id) = 'reativacao'),
      'sem_retorno', (select count(*) from reativ where status in ('perdida', 'pausada')))
  );
$$;

revoke execute on function public.indicadores(uuid, date, date, uuid) from anon;
