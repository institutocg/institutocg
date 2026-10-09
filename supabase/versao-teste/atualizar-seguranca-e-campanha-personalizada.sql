-- =============================================================================
-- Instituto CG — ATUALIZAÇÃO da versão de teste: segurança reforçada e
-- campanha personalizada.
--
-- Para quem já aplicou atualizar-campanhas.sql.
-- Cole no SQL Editor do projeto de TESTE e clique em "Run" (uma vez só).
-- Os dados que você já colocou continuam lá.
-- =============================================================================

begin;

-- =============================================================================
-- Migração 17: endurecimento para produção
--   A chave pública do Supabase (anon) fica no navegador. Quem não fez login não
--   deve conseguir chamar nenhuma função nem ler nenhuma tabela — nem as que já
--   checam acesso por dentro. O sistema conversa com o banco pelo servidor, sempre
--   como usuária logada ("authenticated"), então nada aqui muda para quem usa.
--   Funções internas que já eram fechadas para "authenticated" continuam fechadas.
-- =============================================================================

revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- =============================================================================
-- Migração 18: campanha personalizada
--   Além dos tipos prontos, a administradora monta a própria campanha: escolhe
--   o público (pacientes, contatos ou todos), procedimento (que fez ou se
--   interessou), tempo sem vir, idade, bairro/cidade e como conheceu. Decide se
--   a campanha abre negociação no funil ou só cria o contato do dia.
--   As regras de sempre continuam: aceita contato, sem negociação em andamento,
--   sem outra campanha nos últimos 30 dias, sem contato recente, sem atraso.
-- =============================================================================

alter table public.campanhas add column if not exists filtros jsonb;
alter table public.campanhas drop constraint if exists campanhas_segmento_check;
alter table public.campanhas add constraint campanhas_segmento_check check (segmento in (
  'inativos', 'procedimento', 'nao_fecharam',
  'tratamento_pendente', 'avaliacao_nao_agendada', 'aniversario', 'pos_tratamento', 'interesse', 'desmarcou', 'especiais',
  'personalizada'));

drop function if exists public.prever_campanha(uuid, text, int, uuid, boolean);
drop function if exists public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[]);

-- Quem entra numa campanha. Regras de sempre: aceita contato, sem negociação em
-- andamento, sem outra campanha nos últimos 30 dias, sem contato recente e sem
-- pagamento em atraso. Aniversário é exceção (parabéns não é insistência).
create or replace function public.prever_campanha(
  p_clinica            uuid,
  p_segmento           text,
  p_meses              int,
  p_procedimento       uuid default null,
  p_somente_marketing  boolean default false,
  p_filtros            jsonb default null
)
returns table (pessoa_id uuid, nome text, detalhe text, referencia date, procedimento text)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_hoje      date;
  v_corte     date;
  v_intervalo int;
  v_aniv      boolean := p_segmento = 'aniversario';
  -- Campanha personalizada: filtros escolhidos pela administradora.
  v_publico   text := coalesce(nullif(p_filtros->>'publico', ''), 'todos');
  v_relacao   text := coalesce(nullif(p_filtros->>'relacao', ''), 'qualquer');
  v_sem_vir   int  := nullif(p_filtros->>'sem_vir_meses', '')::int;
  v_idade_min int  := nullif(p_filtros->>'idade_min', '')::int;
  v_idade_max int  := nullif(p_filtros->>'idade_max', '')::int;
  v_local     text := nullif(btrim(p_filtros->>'local'), '');
  v_origem    uuid := nullif(p_filtros->>'origem_id', '')::uuid;
begin
  if auth.uid() is not null and p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  if p_segmento in ('procedimento', 'interesse') and p_procedimento is null then
    raise exception 'Escolha o procedimento.' using errcode = 'P0001';
  end if;
  if p_segmento = 'personalizada' then
    if v_publico not in ('todos', 'pacientes', 'contatos') or v_relacao not in ('qualquer', 'fez', 'interesse') then
      raise exception 'Filtro inválido.' using errcode = 'P0001';
    end if;
    if v_idade_min is not null and v_idade_max is not null and v_idade_min > v_idade_max then
      raise exception 'A idade mínima é maior que a máxima.' using errcode = 'P0001';
    end if;
  end if;
  v_hoje := public.hoje_clinica(p_clinica);
  v_corte := (v_hoje - make_interval(months => greatest(coalesce(p_meses, 6), 1)))::date;
  v_intervalo := public.cfg_int(p_clinica, 'intervalo_min_contato_dias', 3);

  return query
  with candidatos as (
    -- Pacientes sem atendimento há X meses
    (select c.id, c.nome, c.ultimo_atendimento_em as ref,
           case when c.ultimo_atendimento_em is not null
                then 'Último atendimento em ' || to_char(c.ultimo_atendimento_em, 'MM/YYYY')
                else 'Paciente antigo, sem data de atendimento' end as det, null::text as proc
      from public.v_contatos c
     where p_segmento = 'inativos' and c.clinica_id = p_clinica
       and c.relacionamento <> 'lead' and not c.em_tratamento
       and (c.ultimo_atendimento_em is null or c.ultimo_atendimento_em <= v_corte))
    union all
    -- Quem fez o procedimento há X meses (ex.: clareamento há 12 meses)
    (select distinct on (x.pid) x.pid, p.nome, x.dia, x.det, null::text
      from (
        select ta.pessoa_id as pid, ta.realizado_em as dia,
               pr.nome || coalesce(' em ' || to_char(ta.realizado_em, 'MM/YYYY'), '') as det
          from public.tratamentos_anteriores ta join public.procedimentos pr on pr.id = ta.procedimento_id
         where ta.clinica_id = p_clinica and ta.procedimento_id = p_procedimento
           and (ta.realizado_em is null or ta.realizado_em <= v_corte)
        union all
        select o.pessoa_id, o.fechada_em::date,
               pr.nome || ' (fechou em ' || to_char(o.fechada_em, 'MM/YYYY') || ')'
          from public.oportunidades o join public.procedimentos pr on pr.id = o.procedimento_id
         where o.clinica_id = p_clinica and o.status = 'ganha' and o.procedimento_id = p_procedimento
           and o.fechada_em::date <= v_corte
        union all
        select oc.pessoa_id, i.realizado_em, pr.nome || ' em ' || to_char(i.realizado_em, 'MM/YYYY')
          from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
          join public.procedimentos pr on pr.id = i.procedimento_id
         where i.clinica_id = p_clinica and i.status = 'realizado' and i.procedimento_id = p_procedimento
           and i.realizado_em <= v_corte
      ) x
      join public.pessoas p on p.id = x.pid
     where p_segmento = 'procedimento' and not p.em_tratamento
     order by x.pid, x.dia desc nulls last)
    union all
    -- Quem não fechou há X meses
    (select distinct on (o.pessoa_id) o.pessoa_id, p.nome, o.fechada_em::date,
           case when o.resultado = 'desistiu' then 'Desistiu' else 'Não fechou' end
             || coalesce(' (' || lower(m.nome) || ')', '') || coalesce(' — ' || lower(pr.nome), '')
             || ' em ' || to_char(o.fechada_em, 'MM/YYYY'), null::text
      from public.oportunidades o
      join public.pessoas p on p.id = o.pessoa_id
      left join public.motivos m on m.id = o.motivo_id
      left join public.procedimentos pr on pr.id = o.procedimento_id
     where p_segmento = 'nao_fecharam' and o.clinica_id = p_clinica and o.status = 'perdida'
       and o.fechada_em::date <= v_corte
       and (p_procedimento is null or o.procedimento_id = p_procedimento)
     order by o.pessoa_id, o.fechada_em desc)
    union all
    -- Tratamento pendente: procedimentos do plano ainda a fazer, sem consulta marcada.
    (select oc.pessoa_id, p.nome, max(coalesce(i.atualizado_em, i.criado_em))::date,
            'Pendente no plano: ' || string_agg(pr.nome, ', ' order by i.criado_em),
            string_agg(lower(pr.nome), ', ' order by i.criado_em)
       from public.orcamento_itens i
       join public.orcamentos oc on oc.id = i.orcamento_id and oc.origem = 'prontuario'
       join public.procedimentos pr on pr.id = i.procedimento_id
       join public.pessoas p on p.id = oc.pessoa_id
      where p_segmento = 'tratamento_pendente' and i.clinica_id = p_clinica
        and i.status in ('orcado', 'aceito', 'pendente')
        and not exists (select 1 from public.agendamentos a where a.pessoa_id = oc.pessoa_id
                         and a.status in ('agendado', 'confirmado') and a.inicio >= now())
      group by oc.pessoa_id, p.nome
     having max(coalesce(i.atualizado_em, i.criado_em))::date <= v_corte
         and (p_procedimento is null or bool_or(i.procedimento_id = p_procedimento)))
    union all
    -- Interesse que nunca virou avaliação (negociação encerrada sem nenhuma consulta).
    (select distinct on (o.pessoa_id) o.pessoa_id, p.nome, o.criado_em::date,
            'Interesse' || coalesce(' em ' || lower(pr.nome), '') || ' desde ' || to_char(o.criado_em, 'MM/YYYY')
              || ', sem avaliação', null::text
       from public.oportunidades o
       join public.pessoas p on p.id = o.pessoa_id
       left join public.procedimentos pr on pr.id = o.procedimento_id
      where p_segmento = 'avaliacao_nao_agendada' and o.clinica_id = p_clinica and o.status = 'perdida'
        and o.criado_em::date <= v_corte
        and (p_procedimento is null or o.procedimento_id = p_procedimento)
        and not exists (select 1 from public.agendamentos a where a.pessoa_id = o.pessoa_id)
        and not exists (select 1 from public.oportunidades g where g.pessoa_id = o.pessoa_id and g.status = 'ganha')
      order by o.pessoa_id, o.criado_em desc)
    union all
    -- Aniversário nos próximos X meses (a tarefa fica para o dia).
    (select p.id, p.nome, x.dia, 'Aniversário em ' || to_char(x.dia, 'DD/MM'), null::text
       from public.pessoas p,
            lateral (select case when (p.data_nascimento + make_interval(years => extract(year from age(v_hoje, p.data_nascimento))::int))::date >= v_hoje
                                 then (p.data_nascimento + make_interval(years => extract(year from age(v_hoje, p.data_nascimento))::int))::date
                                 else (p.data_nascimento + make_interval(years => extract(year from age(v_hoje, p.data_nascimento))::int + 1))::date
                            end as dia) x
      where v_aniv and p.clinica_id = p_clinica and p.data_nascimento is not null
        and x.dia < (v_hoje + make_interval(months => greatest(coalesce(p_meses, 1), 1)))::date
        and not exists (select 1 from public.campanha_destinatarios d join public.campanhas c on c.id = d.campanha_id
                         where d.pessoa_id = p.id and c.segmento = 'aniversario' and d.contato_em = (case when public.eh_dia_util(p_clinica, x.dia) then x.dia else public.dia_util_anterior(p_clinica, x.dia) end)))
    union all
    -- Pós-tratamento: realizou algo entre 1 e 3 meses atrás (padrão) e nunca recebeu este pedido.
    (select y.pid, p.nome, y.dia, 'Fez ' || y.proc || ' em ' || to_char(y.dia, 'DD/MM/YYYY'), lower(y.proc)
       from (
         select distinct on (z.pid) z.pid, z.dia, z.proc from (
           select oc.pessoa_id as pid, i.realizado_em as dia, pr.nome as proc
             from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
             join public.procedimentos pr on pr.id = i.procedimento_id
            where i.clinica_id = p_clinica and i.status = 'realizado'
           union all
           select o.pessoa_id, o.fechada_em::date, coalesce(pr.nome, 'tratamento')
             from public.oportunidades o left join public.procedimentos pr on pr.id = o.procedimento_id
            where o.clinica_id = p_clinica and o.status = 'ganha'
         ) z order by z.pid, z.dia desc
       ) y
       join public.pessoas p on p.id = y.pid
      where p_segmento = 'pos_tratamento' and y.dia <= v_corte and y.dia > v_corte - 60
        and not exists (select 1 from public.campanha_destinatarios d join public.campanhas c on c.id = d.campanha_id
                         where d.pessoa_id = p.id and c.segmento = 'pos_tratamento'))
    union all
    -- Interesse num procedimento (campanhas de época): demonstrou interesse nos últimos X meses e não fez.
    (select distinct on (z.pid) z.pid, p.nome, z.dia, 'Interesse em ' || lower(pr.nome) || ' (' || to_char(z.dia, 'MM/YYYY') || ')', null::text
       from (
         select o.pessoa_id as pid, o.criado_em::date as dia from public.oportunidades o
          where o.clinica_id = p_clinica and o.procedimento_id = p_procedimento and o.status <> 'ganha'
         union all
         select o.pessoa_id, oi.criado_em::date from public.oportunidade_interesses oi
           join public.oportunidades o on o.id = oi.oportunidade_id
          where oi.clinica_id = p_clinica and oi.procedimento_id = p_procedimento
         union all
         select oc.pessoa_id, i.criado_em::date from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
          where i.clinica_id = p_clinica and i.procedimento_id = p_procedimento and i.status in ('orcado', 'aceito', 'pendente')
       ) z
       join public.pessoas p on p.id = z.pid
       join public.procedimentos pr on pr.id = p_procedimento
      where p_segmento = 'interesse' and z.dia >= v_corte
        and not exists (select 1 from public.tratamentos_anteriores ta where ta.pessoa_id = z.pid and ta.procedimento_id = p_procedimento)
        and not exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                         where oc.pessoa_id = z.pid and i.procedimento_id = p_procedimento and i.status = 'realizado')
        and not exists (select 1 from public.oportunidades g where g.pessoa_id = z.pid and g.procedimento_id = p_procedimento and g.status = 'ganha')
      order by z.pid, z.dia desc)
    union all
    -- Desmarcou ou faltou há mais de X meses e nunca remarcou.
    (select distinct on (a.pessoa_id) a.pessoa_id, p.nome, a.status_em::date,
            case a.status when 'faltou' then 'Faltou' when 'cancelado_clinica' then 'Consulta cancelada pela clínica' else 'Desmarcou' end
              || ' em ' || to_char(a.inicio at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ', sem remarcar', null::text
       from public.agendamentos a join public.pessoas p on p.id = a.pessoa_id
      where p_segmento = 'desmarcou' and a.clinica_id = p_clinica
        and a.status in ('desmarcado', 'faltou', 'cancelado_clinica') and a.remarcado_para_id is null
        and a.status_em::date <= v_corte
        and not exists (select 1 from public.agendamentos b where b.pessoa_id = a.pessoa_id and b.inicio > a.inicio
                         and b.status in ('agendado', 'confirmado', 'compareceu'))
      order by a.pessoa_id, a.inicio desc)
    union all
    -- Pacientes especiais: os de maior histórico (30% com mais negociações fechadas e valor).
    (select t.pid, p.nome, t.desde,
            'Paciente desde ' || to_char(t.desde, 'YYYY') || ' · ' || t.n || ' ' || case when t.n = 1 then 'tratamento fechado' else 'tratamentos fechados' end,
            null::text
       from (
         select v.pessoa_id as pid, count(*)::int as n, sum(v.valor_final_centavos) as total, min(v.fechada_em) as desde,
                percent_rank() over (order by sum(v.valor_final_centavos)) as pr
           from public.vendas v
          where v.clinica_id = p_clinica and v.status = 'ativa' and v.tipo = 'venda'
          group by v.pessoa_id
       ) t
       join public.pessoas p on p.id = t.pid
      where p_segmento = 'especiais' and t.pr >= 0.7)
    union all
    -- Personalizada: a administradora monta o público com os filtros.
    (select c.id, c.nome, c.ultimo_atendimento_em,
            concat_ws(' · ',
              case when c.relacionamento = 'lead' then 'Contato, ainda não veio' else 'Paciente' end,
              case when c.ultimo_atendimento_em is not null then 'último atendimento ' || to_char(c.ultimo_atendimento_em, 'MM/YYYY') end,
              case when c.data_nascimento is not null then extract(year from age(v_hoje, c.data_nascimento))::int || ' anos' end,
              nullif(concat_ws(', ', nullif(c.bairro, ''), nullif(c.cidade, '')), ''),
              case when p_procedimento is not null then
                (select case when v_relacao = 'interesse' then 'interesse em ' else '' end || lower(pr.nome)
                   from public.procedimentos pr where pr.id = p_procedimento) end),
            null::text
       from public.v_contatos c
      where p_segmento = 'personalizada' and c.clinica_id = p_clinica
        and (v_publico = 'todos' or (v_publico = 'pacientes') = (c.relacionamento <> 'lead'))
        and (v_sem_vir is null or (c.relacionamento <> 'lead' and not c.em_tratamento
             and (c.ultimo_atendimento_em is null
                  or c.ultimo_atendimento_em <= (v_hoje - make_interval(months => v_sem_vir))::date)))
        and (v_idade_min is null or (c.data_nascimento is not null and extract(year from age(v_hoje, c.data_nascimento)) >= v_idade_min))
        and (v_idade_max is null or (c.data_nascimento is not null and extract(year from age(v_hoje, c.data_nascimento)) <= v_idade_max))
        and (v_local is null or position(lower(v_local) in lower(concat_ws(' ', c.bairro, c.cidade))) > 0)
        and (v_origem is null or c.origem_id = v_origem)
        and (p_procedimento is null
             or (v_relacao in ('qualquer', 'fez') and (
                   exists (select 1 from public.tratamentos_anteriores ta where ta.pessoa_id = c.id and ta.procedimento_id = p_procedimento)
                or exists (select 1 from public.oportunidades o where o.pessoa_id = c.id and o.procedimento_id = p_procedimento and o.status = 'ganha')
                or exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                            where oc.pessoa_id = c.id and i.procedimento_id = p_procedimento and i.status = 'realizado')))
             or (v_relacao in ('qualquer', 'interesse') and (
                   exists (select 1 from public.oportunidades o where o.pessoa_id = c.id and o.procedimento_id = p_procedimento and o.status <> 'ganha')
                or exists (select 1 from public.oportunidade_interesses oi join public.oportunidades o on o.id = oi.oportunidade_id
                            where o.pessoa_id = c.id and oi.procedimento_id = p_procedimento)
                or exists (select 1 from public.orcamento_itens i join public.orcamentos oc on oc.id = i.orcamento_id
                            where oc.pessoa_id = c.id and i.procedimento_id = p_procedimento and i.status in ('orcado', 'aceito', 'pendente'))))))
  )
  select k.id, k.nome, k.det, k.ref, k.proc
    from candidatos k
    join public.pessoas p on p.id = k.id
   where p.arquivado_em is null and not p.nao_contatar and p.consentimento_contato
     and (not p_somente_marketing or p.consentimento_marketing)
     and (v_aniv or p.ultimo_contato_em is null or p.ultimo_contato_em < now() - make_interval(days => v_intervalo))
     and not exists (select 1 from public.oportunidades o where o.pessoa_id = p.id and o.status in ('aberta', 'pausada'))
     and (v_aniv or not exists (select 1 from public.campanha_destinatarios d join public.campanhas c on c.id = d.campanha_id
                                 where d.pessoa_id = p.id and c.segmento <> 'aniversario'
                                   and d.criado_em > now() - interval '30 days'))
     -- Quem está com pagamento em atraso é tratado pelo financeiro, não por campanha.
     and (v_aniv or not exists (select 1 from public.parcelas pa where pa.pessoa_id = p.id
                                 and pa.status in ('pendente', 'parcial') and pa.vencimento < v_hoje))
   order by k.ref nulls first, k.nome;
end;
$$;

-- Cria a campanha e distribui os contatos (limite por dia útil). Campanhas de
-- vendas abrem a negociação em "Reativação"; as de relacionamento só criam a
-- tarefa. Aniversário: a tarefa fica para o dia (ou o dia útil anterior).
create or replace function public.criar_campanha(
  p_clinica            uuid,
  p_nome               text,
  p_segmento           text,
  p_meses              int,
  p_procedimento       uuid,
  p_somente_marketing  boolean,
  p_mensagem           text,
  p_limite_dia         int,
  p_inicia_em          date,
  p_pessoas            uuid[] default null,
  p_filtros            jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     uuid;
  v_hoje   date;
  v_dia    date;
  v_quando date;
  v_no_dia int := 0;
  v_total  int := 0;
  v_tarefa uuid;
  v_op     uuid;
  v_proc   text;
  v_prim   date;
  v_ult    date;
  -- Personalizada: só abre negociação no funil se ela escolher.
  v_rel    boolean := public.campanha_de_relacionamento(p_segmento)
                      or (p_segmento = 'personalizada' and not coalesce((p_filtros->>'negociacao')::boolean, false));
  v_nome   text;
  x        record;
begin
  if not public.eh_admin(p_clinica) then
    raise exception 'Somente a administradora cria campanhas.' using errcode = '42501';
  end if;
  v_hoje := public.hoje_clinica(p_clinica);
  if p_inicia_em is null or p_inicia_em < v_hoje then
    raise exception 'A campanha precisa começar hoje ou numa data futura.' using errcode = 'P0001';
  end if;
  select nome into v_proc from public.procedimentos where id = p_procedimento and clinica_id = p_clinica;

  insert into public.campanhas (clinica_id, nome, segmento, meses, procedimento_id, somente_marketing, mensagem,
                                limite_dia, inicia_em, filtros)
  values (p_clinica, btrim(p_nome), p_segmento, p_meses, p_procedimento, p_somente_marketing, p_mensagem,
          p_limite_dia, p_inicia_em, case when p_segmento = 'personalizada' then coalesce(p_filtros, '{}') end)
  returning id into v_id;

  v_dia := public.proximo_dia_util(p_clinica, p_inicia_em);
  for x in
    select * from public.prever_campanha(p_clinica, p_segmento, p_meses, p_procedimento, p_somente_marketing, p_filtros) c
     where p_pessoas is null or c.pessoa_id = any (p_pessoas)
  loop
    v_nome := coalesce((select nullif(apelido_tratamento, '') from public.pessoas where id = x.pessoa_id), split_part(x.nome, ' ', 1));
    if p_segmento = 'aniversario' then
      v_quando := case when public.eh_dia_util(p_clinica, x.referencia) then x.referencia
                       else public.dia_util_anterior(p_clinica, x.referencia) end;
      v_quando := greatest(v_quando, v_hoje);
    else
      if v_no_dia >= p_limite_dia then
        v_dia := public.proximo_dia_util(p_clinica, v_dia + 1);
        v_no_dia := 0;
      end if;
      v_quando := v_dia;
    end if;

    if v_rel then
      v_tarefa := public.criar_tarefa_auto(
        x.pessoa_id, null,
        case when p_segmento = 'tratamento_pendente' then 'agendar_tratamento' else 'personalizada' end::public.tipo_tarefa,
        case when p_segmento = 'tratamento_pendente' then 'agenda' else 'outra' end::public.categoria_tarefa,
        case p_segmento
          when 'aniversario' then 'Aniversário de ' || v_nome || ' — ' || to_char(x.referencia, 'DD/MM')
          when 'tratamento_pendente' then 'Convidar ' || v_nome || ' para continuar o tratamento'
          when 'pos_tratamento' then 'Pedir avaliação a ' || v_nome
          when 'personalizada' then 'Contato com ' || v_nome || ' — ' || btrim(p_nome)
          else 'Contato especial com ' || v_nome end,
        v_quando, 'normal', 'campanha', 'camp:' || v_id || ':' || x.pessoa_id, 1,
        'Campanha “' || btrim(p_nome) || '”. ' || x.detalhe, null,
        public.renderizar_texto(p_mensagem, x.pessoa_id, coalesce(x.procedimento, lower(v_proc))));
      v_op := null;
    else
      v_tarefa := public.abrir_reativacao(
        x.pessoa_id, null, p_procedimento, 'reativacao',
        'Convidar ' || v_nome || ' — ' || btrim(p_nome),
        'Campanha “' || btrim(p_nome) || '”. ' || x.detalhe,
        v_quando, 'campanha', public.renderizar_texto(p_mensagem, x.pessoa_id, coalesce(x.procedimento, lower(v_proc))), 'normal');
      if v_tarefa is not null then
        select oportunidade_id into v_op from public.tarefas where id = v_tarefa;
      end if;
    end if;

    if v_tarefa is not null then
      select vence_em into v_ult from public.tarefas where id = v_tarefa;
      insert into public.campanha_destinatarios (clinica_id, campanha_id, pessoa_id, oportunidade_id, tarefa_id, contato_em)
      values (p_clinica, v_id, x.pessoa_id, v_op, v_tarefa, v_ult);
      v_prim := least(coalesce(v_prim, v_ult), v_ult);
      v_no_dia := v_no_dia + 1;
      v_total := v_total + 1;
    end if;
  end loop;

  if v_total = 0 then
    raise exception 'Nenhuma pessoa elegível para esta campanha.' using errcode = 'P0001';
  end if;
  select max(contato_em) into v_ult from public.campanha_destinatarios where campanha_id = v_id;
  return jsonb_build_object('id', v_id, 'pessoas', v_total, 'primeiro_dia', v_prim, 'ultimo_dia', v_ult);
end;
$$;

revoke execute on function public.prever_campanha(uuid, text, int, uuid, boolean, jsonb) from public, anon;
revoke execute on function public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[], jsonb) from public, anon;
grant execute on function public.prever_campanha(uuid, text, int, uuid, boolean, jsonb) to authenticated;
grant execute on function public.criar_campanha(uuid, text, text, int, uuid, boolean, text, int, date, uuid[], jsonb) to authenticated;

commit;
