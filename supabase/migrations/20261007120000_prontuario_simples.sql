-- =============================================================================
-- Migração 15: prontuário simplificado + procedimento livre + pagamento do plano
--   • Consulta: motivo, queixa principal e anamnese em texto livre + odontograma.
--   • Procedimento é sempre digitável: procedimento_por_nome() acha (sem acento,
--     sem maiúsculas) ou cria no catálogo. A lista vira sugestão, nunca trava.
--   • Plano de tratamento: cada procedimento com "feito hoje" (marcar_feito);
--     pendentes aparecem nas próximas consultas.
--   • Pagamento ≠ realização: o pagamento é do PLANO (vendas.plano_id), não do
--     procedimento. registrar_pagamento_plano(): integral, parcial ou não pago,
--     com forma, data, valor, restante, data prevista e parcelas — nas mesmas
--     vendas/parcelas do Financeiro (lembretes "previsto"/"atrasado" no painel).
-- Nada é apagado: colunas e funções anteriores continuam existindo.
-- =============================================================================

-- ─── Procedimento livre ──────────────────────────────────────────────────────

create or replace function public.procedimento_por_nome(p_clinica uuid, p_nome text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_id   uuid;
begin
  if p_clinica not in (select public.minhas_clinicas()) then
    raise exception 'Sem acesso a esta clínica.' using errcode = '42501';
  end if;
  if v_nome = '' then
    return null;
  end if;
  if length(v_nome) < 2 or length(v_nome) > 120 then
    raise exception 'Procedimento: de 2 a 120 caracteres.' using errcode = 'P0001';
  end if;
  select id into v_id from public.procedimentos
   where clinica_id = p_clinica and public.sem_acento(nome) = public.sem_acento(v_nome)
   order by ativo desc, ordem limit 1;
  if v_id is not null then
    update public.procedimentos set ativo = true where id = v_id and not ativo;
    return v_id;
  end if;
  insert into public.procedimentos (clinica_id, nome, ordem)
  values (p_clinica, v_nome, 900)
  on conflict (clinica_id, nome) do update set ativo = true
  returning id into v_id;
  return v_id;
end;
$$;

-- ─── Consulta simplificada ───────────────────────────────────────────────────

alter table public.atendimentos add column if not exists queixa text check (length(queixa) <= 1000);

create or replace function public.criar_atendimento(
  p_pessoa uuid, p_data date, p_horario time default null, p_profissional uuid default null,
  p_tipo public.tipo_agendamento default null, p_procedimento uuid default null, p_agendamento uuid default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  pr     public.prontuarios;
  v_id   uuid;
  v_mot  text;
begin
  select * into pr from public.prontuarios where pessoa_id = p_pessoa;
  if pr.id is null or not public.pode_ver_prontuario(pr.clinica_id) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  -- Motivo (texto livre), já preenchido com o que foi agendado.
  v_mot := coalesce((select nome from public.procedimentos where id = p_procedimento),
                    case p_tipo when 'avaliacao' then 'Avaliação' when 'retorno' then 'Retorno'
                                when 'manutencao' then 'Manutenção' when 'apresentacao_orcamento' then 'Retorno para decisão' end);
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, agendamento_id, profissional_id, data, horario,
                                   tipo, procedimento_id, motivo_obs, odontograma)
  values (pr.clinica_id, pr.id, p_pessoa, p_agendamento, p_profissional, coalesce(p_data, public.hoje_clinica(pr.clinica_id)),
          p_horario, p_tipo, p_procedimento, v_mot,
          coalesce((select a.odontograma from public.atendimentos a where a.prontuario_id = pr.id
                     order by a.data desc, a.numero desc limit 1), '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- Lista de consultas: com os textos livres.
create or replace view public.v_atendimentos with (security_invoker = true) as
select
  a.id, a.clinica_id, a.prontuario_id, a.pessoa_id, a.numero, a.agendamento_id, a.data,
  to_char(a.horario, 'HH24:MI')                                 as horario,
  a.tipo, a.procedimento_id, pr.nome                            as procedimento,
  a.profissional_id, pf.nome                                    as profissional, pf.cor as profissional_cor,
  a.status, a.finalizado_em, a.motivo, a.anamnese, a.diagnostico, a.retorno_em,
  (select count(*) from public.orcamento_itens i where i.realizado_atendimento_id = a.id)::int as realizados,
  (select string_agg(p2.nome, ', ' order by i.realizado_em, p2.nome)
     from public.orcamento_itens i join public.procedimentos p2 on p2.id = i.procedimento_id
    where i.realizado_atendimento_id = a.id)                    as procedimentos_realizados,
  a.motivo_obs, a.queixa, a.anamnese_obs
from public.atendimentos a
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.profissionais pf on pf.id = a.profissional_id;

-- Salva só os campos enviados (o que não vier fica como estava).
create or replace function public.salvar_atendimento(p_atendimento uuid, p jsonb, p_finalizar boolean default false)
returns void
language plpgsql
set search_path = public
as $$
declare
  a public.atendimentos;
  lista text[];
begin
  select * into a from public.atendimentos where id = p_atendimento for update;
  if a.id is null or not public.pode_ver_prontuario(a.clinica_id) then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  update public.atendimentos set
    profissional_id = case when p ? 'profissional_id' then coalesce(nullif(p ->> 'profissional_id', '')::uuid, profissional_id) else profissional_id end,
    motivo          = case when p ? 'motivo' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'motivo') x), '{}') else motivo end,
    motivo_obs      = case when p ? 'motivo_obs' then nullif(btrim(p ->> 'motivo_obs'), '') else motivo_obs end,
    queixa          = case when p ? 'queixa' then nullif(btrim(p ->> 'queixa'), '') else queixa end,
    anamnese        = case when p ? 'anamnese' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'anamnese') x), '{}') else anamnese end,
    anamnese_obs    = case when p ? 'anamnese_obs' then nullif(btrim(p ->> 'anamnese_obs'), '') else anamnese_obs end,
    diagnostico     = case when p ? 'diagnostico' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'diagnostico') x), '{}') else diagnostico end,
    diagnostico_obs = case when p ? 'diagnostico_obs' then nullif(btrim(p ->> 'diagnostico_obs'), '') else diagnostico_obs end,
    evolucao        = case when p ? 'evolucao' then nullif(btrim(p ->> 'evolucao'), '') else evolucao end,
    orientacoes     = case when p ? 'orientacoes' then coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'orientacoes') x), '{}') else orientacoes end,
    orientacoes_obs = case when p ? 'orientacoes_obs' then nullif(btrim(p ->> 'orientacoes_obs'), '') else orientacoes_obs end,
    retorno_em      = case when p ? 'retorno_em' then nullif(p ->> 'retorno_em', '')::date else retorno_em end,
    retorno_obs     = case when p ? 'retorno_obs' then nullif(btrim(p ->> 'retorno_obs'), '') else retorno_obs end,
    odontograma     = case when p ? 'odontograma' then p -> 'odontograma' else odontograma end,
    status          = case when p_finalizar then 'finalizado'::public.status_atendimento else status end,
    finalizado_em   = case when p_finalizar then now() else finalizado_em end,
    finalizado_por  = case when p_finalizar then auth.uid() else finalizado_por end
  where id = p_atendimento;
end;
$$;

-- ─── Plano: procedimento digitado + "feito hoje" ─────────────────────────────

create or replace function public.adicionar_procedimento_plano(
  p_pessoa uuid, p_nome text, p_valor bigint, p_atendimento uuid default null, p_feito boolean default false
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  v_proc    uuid;
  v_item    uuid;
begin
  if v_clinica is null or not public.pode_ver_prontuario(v_clinica) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  v_proc := public.procedimento_por_nome(v_clinica, p_nome);
  if v_proc is null then
    raise exception 'Escreva o procedimento.' using errcode = 'P0001';
  end if;
  v_item := public.adicionar_item_plano(p_pessoa, v_proc, coalesce(p_valor, 0), null, p_atendimento, 'pendente');
  if p_feito then
    if p_atendimento is null then
      raise exception 'Para marcar como feito, abra a consulta.' using errcode = 'P0001';
    end if;
    perform public.marcar_feito(v_item, p_atendimento, true);
  end if;
  return v_item;
end;
$$;

-- Feito nesta consulta (ou desfaz, enquanto a consulta não foi finalizada).
-- Não mexe em pagamento: pagamento é do plano, não do procedimento.
create or replace function public.marcar_feito(p_item uuid, p_atendimento uuid, p_feito boolean)
returns void
language plpgsql
set search_path = public
as $$
declare
  i public.orcamento_itens;
  a public.atendimentos;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  select * into a from public.atendimentos where id = p_atendimento;
  if i.id is null or a.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento ou consulta não encontrados.' using errcode = 'P0002';
  end if;
  if (select pessoa_id from public.orcamentos where id = i.orcamento_id) <> a.pessoa_id then
    raise exception 'O procedimento não é deste paciente.' using errcode = 'P0001';
  end if;
  if a.status = 'finalizado' then
    raise exception 'Esta consulta foi finalizada e não pode ser alterada.' using errcode = 'P0001';
  end if;
  if p_feito then
    if i.status = 'realizado' and i.realizado_atendimento_id <> a.id then
      raise exception 'Este procedimento já foi feito em outra consulta.' using errcode = 'P0001';
    end if;
    update public.orcamento_itens set status = 'realizado', realizado_atendimento_id = a.id, realizado_em = a.data
     where id = p_item;
  else
    if i.status = 'realizado' and i.realizado_atendimento_id <> a.id then
      raise exception 'Este procedimento foi feito em outra consulta.' using errcode = 'P0001';
    end if;
    update public.orcamento_itens set status = 'pendente', realizado_atendimento_id = null, realizado_em = null
     where id = p_item and status = 'realizado';
  end if;
end;
$$;

create or replace function public.remover_item_plano(p_item uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  i public.orcamento_itens;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  if i.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento não encontrado.' using errcode = 'P0002';
  end if;
  if i.status = 'realizado' then
    raise exception 'Procedimento já feito não sai do plano (fica no histórico).' using errcode = 'P0001';
  end if;
  update public.orcamento_itens set status = 'cancelado' where id = p_item;
end;
$$;

-- ─── Pagamento do plano (não do procedimento) ────────────────────────────────

alter table public.vendas add column if not exists plano_id uuid;
alter table public.vendas
  add constraint vendas_plano_fk foreign key (clinica_id, plano_id) references public.orcamentos (clinica_id, id);

create or replace view public.v_financeiro_parcelas with (security_invoker = true) as
select
  pa.id, pa.clinica_id, pa.venda_id, pa.pessoa_id, pa.numero, pa.vencimento, pa.pago_em,
  pa.valor_centavos, pa.valor_pago_centavos,
  pa.valor_centavos - pa.valor_pago_centavos                       as saldo_centavos,
  pa.observacao_financeira                                         as observacao,
  pe.nome                                                          as pessoa_nome,
  coalesce(pe.whatsapp_e164, pe.telefone_e164)                     as whatsapp,
  coalesce(pr.nome, case when v.plano_id is not null then 'Plano de tratamento' end) as procedimento,
  fp.nome                                                          as forma_pagamento,
  v.quantidade_parcelas,
  public.hoje_clinica(pa.clinica_id) - pa.vencimento               as dias_atraso,
  case
    when pa.status = 'paga' then 'pago'
    when pa.status in ('pendente', 'parcial') and pa.vencimento < public.hoje_clinica(pa.clinica_id) then 'atrasado'
    when pa.status = 'parcial' then 'parcial'
    when pa.status = 'pendente' then 'pendente'
    else pa.status::text
  end                                                              as situacao,
  (select t.id from public.tarefas t where t.parcela_id = pa.id and t.status = 'pendente' limit 1) as tarefa_id,
  coalesce(v.procedimento_id, o.procedimento_id) as procedimento_id,
  v.plano_id
from public.parcelas pa
join public.vendas v on v.id = pa.venda_id
join public.pessoas pe on pe.id = pa.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = coalesce(v.procedimento_id, o.procedimento_id)
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id
where v.status = 'ativa' and pa.status <> 'cancelada';

create or replace view public.v_financeiro_negociacoes with (security_invoker = true) as
select
  v.id, v.clinica_id, v.pessoa_id, v.tipo, v.fechada_em,
  pe.nome                                       as pessoa_nome,
  coalesce(pr.nome, case when v.tipo = 'saldo_anterior' then 'Saldo anterior' when v.plano_id is not null then 'Plano de tratamento' end) as procedimento,
  v.valor_total_centavos, v.desconto_centavos, v.valor_final_centavos,
  v.entrada_centavos, v.quantidade_parcelas, v.valor_parcela_centavos,
  fp.nome                                       as forma_pagamento,
  v.observacao_financeira                       as observacao,
  coalesce(sum(p.valor_pago_centavos), 0)::bigint                                     as pago_centavos,
  coalesce(sum(p.saldo_centavos) filter (where p.situacao <> 'pago'), 0)::bigint      as saldo_centavos,
  coalesce(sum(p.saldo_centavos) filter (where p.situacao = 'atrasado'), 0)::bigint   as atrasado_centavos,
  min(p.vencimento) filter (where p.situacao <> 'pago')                               as proximo_vencimento,
  max(p.pago_em)                                                                      as ultimo_pagamento_em,
  case
    when count(p.id) filter (where p.situacao <> 'pago') = 0 then 'pago'
    when count(p.id) filter (where p.situacao = 'atrasado') > 0 then 'atrasado'
    when coalesce(sum(p.valor_pago_centavos), 0) > 0 then 'parcial'
    else 'pendente'
  end                                           as situacao,
  coalesce(v.procedimento_id, o.procedimento_id) as procedimento_id,
  v.agendamento_id,
  v.plano_id
from public.vendas v
join public.pessoas pe on pe.id = v.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = coalesce(v.procedimento_id, o.procedimento_id)
left join public.formas_pagamento fp on fp.id = v.forma_pagamento_id
left join public.v_financeiro_parcelas p on p.venda_id = v.id
where v.status = 'ativa'
group by v.id, pe.nome, pr.nome, fp.nome, o.procedimento_id;

create or replace function public.plano_atual(p_pessoa uuid)
returns uuid
language sql
stable
set search_path = public
as $$
  select id from public.orcamentos
   where pessoa_id = p_pessoa and origem = 'prontuario' and status not in ('recusado', 'expirado', 'substituido')
   order by criado_em desc limit 1;
$$;

-- Total, pago e pendente do plano (o pagamento pode vir antes, junto ou depois dos procedimentos).
create or replace function public.situacao_plano(p_plano uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  with v as (
    select n.* from public.v_financeiro_negociacoes n
     where n.plano_id = p_plano
        or n.id in (select i.venda_id from public.orcamento_itens i where i.orcamento_id = p_plano and i.venda_id is not null)
  ),
  t as (select coalesce(sum(quantidade * valor_unitario_centavos - desconto_centavos), 0)::bigint as total
          from public.orcamento_itens where orcamento_id = p_plano and status not in ('cancelado', 'nao_realizado'))
  select jsonb_build_object(
    'total', t.total,
    'registrado', coalesce((select sum(valor_final_centavos) from v), 0),
    'pago', coalesce((select sum(pago_centavos) from v), 0),
    'pendente', greatest(t.total - coalesce((select sum(pago_centavos) from v), 0), 0),
    'a_registrar', greatest(t.total - coalesce((select sum(valor_final_centavos) from v), 0), 0),
    'atrasado', coalesce((select sum(atrasado_centavos) from v), 0),
    'proximo_vencimento', (select min(proximo_vencimento) from v))
  from t;
$$;

-- p_como: 'integral' (pagou tudo o que falta registrar) | 'parcial' (p_valor_pago agora; o resto
-- na data prevista, em p_parcelas) | 'nao_pago' (tudo na data prevista, em p_parcelas).
create or replace function public.registrar_pagamento_plano(
  p_plano          uuid,
  p_como           text,
  p_forma          uuid,
  p_valor_pago     bigint default null,
  p_data_pagamento date default null,
  p_vencimento     date default null,
  p_parcelas       int default 1,
  p_observacao     text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  o       public.orcamentos;
  f       public.formas_pagamento;
  v_hoje  date;
  v_data  date;
  v_base  bigint;
  v_neg   jsonb;
  v_venda uuid;
  v_itens text;
  x       record;
begin
  select * into o from public.orcamentos where id = p_plano and origem = 'prontuario';
  if o.id is null then
    raise exception 'Plano de tratamento não encontrado.' using errcode = 'P0002';
  end if;
  if not public.pode_ver_financeiro(o.clinica_id) then
    raise exception 'Seu acesso não inclui o financeiro.' using errcode = '42501';
  end if;
  if p_como not in ('integral', 'parcial', 'nao_pago') then
    raise exception 'Escolha como foi o pagamento.' using errcode = 'P0001';
  end if;
  v_hoje := public.hoje_clinica(o.clinica_id);
  v_data := coalesce(p_data_pagamento, v_hoje);
  if v_data > v_hoje then
    raise exception 'A data do pagamento não pode ser futura.' using errcode = 'P0001';
  end if;
  v_base := (public.situacao_plano(p_plano) ->> 'a_registrar')::bigint;
  if v_base <= 0 then
    raise exception 'O valor do plano já está todo no Financeiro. Para receber o que falta, use "Marcar como pago" nos pagamentos em aberto.'
      using errcode = 'P0001';
  end if;
  select * into f from public.formas_pagamento where id = p_forma and clinica_id = o.clinica_id and ativo;
  if f.id is null then
    raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
  end if;
  if p_como = 'parcial' and not f.recebe_na_hora and (coalesce(p_valor_pago, 0) <= 0 or p_valor_pago >= v_base) then
    raise exception 'Informe o valor pago (menor que o total a registrar, %).', public.formatar_brl(v_base) using errcode = 'P0001';
  end if;
  if p_como in ('parcial', 'nao_pago') and not f.recebe_na_hora then
    if p_vencimento is null then
      raise exception 'Informe a data prevista para o pagamento do restante.' using errcode = 'P0001';
    end if;
    if p_vencimento < v_hoje then
      raise exception 'A data prevista não pode estar no passado.' using errcode = 'P0001';
    end if;
  end if;
  if p_como = 'integral' and not f.recebe_na_hora and coalesce(p_parcelas, 1) > 1 then
    raise exception 'Pago integralmente em % é uma parcela só. Para parcelar, escolha "Não pago" ou "Parcialmente pago".', f.nome
      using errcode = 'P0001';
  end if;

  select string_agg(p.nome, ', ' order by i.criado_em) into v_itens
    from public.orcamento_itens i join public.procedimentos p on p.id = i.procedimento_id
   where i.orcamento_id = p_plano and i.status not in ('cancelado', 'nao_realizado');

  v_neg := public.registrar_negociacao(
    o.clinica_id, o.pessoa_id, null, v_base, 0,
    case when p_como = 'parcial' and not f.recebe_na_hora then p_valor_pago else 0 end,
    v_data, f.id,
    greatest(coalesce(p_parcelas, 1), 1),
    case when p_como = 'integral' or f.recebe_na_hora then v_hoje else p_vencimento end,
    f.id,
    coalesce(nullif(btrim(p_observacao), ''), left('Plano de tratamento: ' || coalesce(v_itens, ''), 1000)));
  v_venda := (v_neg ->> 'venda_id')::uuid;
  update public.vendas set plano_id = p_plano where id = v_venda;

  -- O que foi pago agora: tudo (integral) ou só a parte paga (a "entrada").
  for x in select id from public.parcelas
            where venda_id = v_venda and status in ('pendente', 'parcial')
              and (p_como = 'integral' or (p_como = 'parcial' and numero = 0))
  loop
    perform public.registrar_pagamento(x.id, null, v_data, f.id, null);
  end loop;

  return public.situacao_plano(p_plano) || jsonb_build_object('venda_id', v_venda);
end;
$$;

revoke execute on function public.procedimento_por_nome(uuid, text) from public, anon;
grant execute on function public.procedimento_por_nome(uuid, text) to authenticated;
revoke execute on function public.adicionar_procedimento_plano(uuid, text, bigint, uuid, boolean) from anon;
revoke execute on function public.marcar_feito(uuid, uuid, boolean) from anon;
revoke execute on function public.remover_item_plano(uuid) from anon;
revoke execute on function public.registrar_pagamento_plano(uuid, text, uuid, bigint, date, date, int, text) from anon;
