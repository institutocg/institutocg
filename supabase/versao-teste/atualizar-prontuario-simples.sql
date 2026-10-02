-- =============================================================================
-- Instituto CG — ATUALIZAÇÃO da versão de teste: prontuário simplificado,
-- procedimento livre e pagamento do plano de tratamento.
--
-- Para quem já tem o prontuário instalado (atualizar-prontuario.sql).
-- Cole no SQL Editor do projeto de TESTE e clique em "Run" (uma vez só).
-- Depois, no sistema: Configurações → Versão de teste → "Recomeçar com dados de exemplo".
-- =============================================================================

begin;

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


-- Dados de exemplo atualizados (usados pelo botão "Recomeçar com dados de exemplo").
create schema if not exists teste;
revoke all on schema teste from public;
grant usage on schema teste to authenticated;

-- Cria a clínica "Instituto CG" com as situações de exemplo e devolve o id.
create or replace function teste.carregar_dados_ficticios()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c        uuid := public.inicializar_clinica('Instituto CG');
  hoje     date := public.hoje_clinica(c);
  prof     uuid;
  pix      uuid;
  credito  uuid;
  p        uuid;
  o        uuid;
  v        uuid;
  orc      uuid;

begin
  select id into prof from public.profissionais where clinica_id = c limit 1;
  select id into pix from public.formas_pagamento where clinica_id = c and nome = 'PIX';
  select id into credito from public.formas_pagamento where clinica_id = c and nome = 'Cartão parcelado';

  -- 1. Beatriz: novo contato que chegou hoje pelo Instagram → primeiro contato (urgente)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id, temperatura)
  values (c, 'Beatriz Almeida', '+5511900000006', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), 'quente')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
          (public.etapa_por_marco(c, 'novo_contato')).id);

  -- 2. Maria: recebeu o orçamento de facetas na consulta há 7 dias → contato hoje (importante)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, email, origem_id, temperatura, primeiro_contato_em)
  values (c, 'Maria Silva', '+5511900000001', 'maria.silva@exemplo.com',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'), 'morna', hoje - 20)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 1400000)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id,
                                 apresentado_em, valido_ate, apresentado_por)
  values (c, p, o, 'apresentado', 1400000, 'parcelado', 200000, 10, credito, hoje - 7, hoje + 23, prof);
  -- Consulta há 7 dias: o contato da regra "Saiu da consulta sem fechar" é hoje.
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 3. João: lead com quem a conversa começou; a tarefa ficou atrasada 2 dias
  insert into public.pessoas (clinica_id, nome, telefone_e164, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'João Lima', '+5511900000002', '+5511900000002',
          (select id from public.origens where clinica_id = c and nome = 'Google'), hoje - 4)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Implantes'),
          (public.etapa_por_marco(c, 'em_contato')).id);
  update public.tarefas set vence_em = hoje - 2 where pessoa_id = p and status = 'pendente';

  -- 4. Carla: avaliação amanhã, mas desmarcou ontem → hoje "Entrar em contato para remarcar" (urgente)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Carla Mendes', '+5511900000003',
          (select id from public.origens where clinica_id = c and nome = 'Site'), hoje - 15)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (public.etapa_por_marco(c, 'em_contato')).id)
  returning id into o;
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
  values (c, p, o, prof, 'avaliacao', (hoje + 1 + time '10:00') at time zone 'America/Sao_Paulo');
  update public.agendamentos set status = 'desmarcado',
         motivo_id = (select id from public.motivos where clinica_id = c and nome = 'Trabalho')
   where pessoa_id = p;
  -- Regra "Paciente desmarcou": contato no dia seguinte à desmarcação (feita ontem).
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 5. Rafael: avaliação no próximo dia útil → confirmação hoje (rotina)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Rafael Gomes', '+5511900000007',
          (select id from public.origens where clinica_id = c and nome = 'Anúncio Instagram/Facebook'), hoje - 3)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Estética odontológica'),
          (public.etapa_por_marco(c, 'em_contato')).id)
  returning id into o;
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, inicio)
  values (c, p, o, prof, 'avaliacao', (public.proximo_dia_util(c, hoje + 1) + time '14:30') at time zone 'America/Sao_Paulo');
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 6. Luiza: passou pela consulta e ficou de pensar → contato em 2 dias (próximos dias)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Luiza Prado', '+5511900000008',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 30)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 2200000)
  returning id into o;
  perform public.definir_proxima_acao(o, 'acompanhar_decisao', 'Retomar com Luiza depois da consulta',
                                      hoje + 2, 'alta', 'pos_consulta', 1, 'Ficou de pensar');

  -- 7. Marcos: contato pós-consulta que deveria ter sido feito há 3 dias (atrasada)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Marcos Tavares', '+5511900000009',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de profissional'), hoje - 25)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Periodontia'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, apresentado_em)
  values (c, p, o, 'apresentado', 480000, hoje - 5);
  update public.tarefas set vence_em = hoje - 3 where pessoa_id = p and status = 'pendente';

  -- 8. Paulo: paciente antigo com saldo anterior; parcela atrasada há 5 dias; e reativação
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id,
                              paciente_desde, ultimo_atendimento_informado, consentimento_marketing)
  values (c, 'paciente_antigo', 'Paulo Ribeiro', '+5511900000004',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'),
          '2018-05-01', hoje - 420, true)
  returning id into p;
  insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Manutenção e limpeza'), hoje - 420);
  insert into public.vendas (clinica_id, pessoa_id, tipo, valor_total_centavos, condicao_pagamento,
                             quantidade_parcelas, forma_pagamento_id, fechada_em, observacao_financeira)
  values (c, p, 'saldo_anterior', 160000, 'parcelado', 2, pix, hoje - 400, 'Saldo informado no recadastro')
  returning id into v;
  perform public.gerar_parcelas(v, hoje - 5);
  update public.tarefas set vence_em = hoje - 5
   where parcela_id = (select id from public.parcelas where venda_id = v and numero = 1);

  -- 9. Sofia: paciente antiga inativa → reativação hoje (rotina)
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado)
  values (c, 'paciente_antigo', 'Sofia Martins', '+5511900000010',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'), hoje - 600)
  returning id into p;
  perform public.abrir_reativacao(p, null, null, 'reativacao', 'Reativar contato com Sofia',
                                  'Último atendimento em ' || to_char(hoje - 600, 'MM/YYYY'), hoje, 'paciente_inativo');
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente';

  -- 10. Ana: fechou lentes; entrada paga; parcela 1 vence hoje (importante)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Ana Costa', '+5511900000005',
          (select id from public.origens where clinica_id = c and nome = 'Instagram'), hoje - 60)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id)
  returning id into o;
  insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, desconto_centavos,
                                 condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id, apresentado_em)
  values (c, p, o, 'em_negociacao', 1250000, 50000, 'parcelado', 120000, 4, pix, hoje - 40)
  returning id into orc;
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, orcamento_id, valor_total_centavos, desconto_centavos,
                             condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id, fechada_em)
  values (c, p, o, orc, 1250000, 50000, 'parcelado', 120000, 4, pix, hoje - 35)
  returning id into v;
  perform public.gerar_parcelas(v, hoje, hoje - 35);
  insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id)
  select c, id, valor_centavos, hoje - 35, pix from public.parcelas where venda_id = v and numero = 0;
  -- O tratamento dela já começou: a tarefa "agendar início" foi feita há tempos.
  update public.tarefas set status = 'concluida', resultado = 'Tratamento agendado'
   where pessoa_id = p and tipo = 'agendar_tratamento';
  update public.tarefas set vence_em = hoje where pessoa_id = p and status = 'pendente' and parcela_id is not null
     and vence_em < hoje + 1;

  -- 11. Fernanda: pediu retorno daqui a 4 dias (próximos dias)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em)
  values (c, 'Fernanda Lopes', '+5511900000011',
          (select id from public.origens where clinica_id = c and nome = 'WhatsApp'), hoje - 6)
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (public.etapa_por_marco(c, 'em_contato')).id)
  returning id into o;
  perform public.definir_proxima_acao(o, 'follow_up', 'Retornar para Fernanda (pediu retorno)',
                                      hoje + 4, 'alta', 'pediu_retorno');

  -- 12. Tiago: recebeu orçamento e parou de responder → "Sem resposta" (nova tentativa leve)
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em, ultimo_contato_em)
  values (c, 'Tiago Moreira', '+5511900000012',
          (select id from public.origens where clinica_id = c and nome = 'Google'), hoje - 40, now() - interval '12 days')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Implantes'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 900000)
  returning id into o;
  perform public.mover_etapa(o, public.etapa_por_resultado(c, 'sem_resposta'), 'Parou de responder após o orçamento');
  update public.tarefas set vence_em = hoje + 12 where oportunidade_id = o and status = 'pendente';

  -- 13. Vera: não fechou por valor alto; retomada combinada para daqui a 25 dias
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id, primeiro_contato_em, ultimo_contato_em)
  values (c, 'Vera Albuquerque', '+5511900000013',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'), hoje - 21, now() - interval '5 days')
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, etapa_id, valor_estimado_centavos)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
          (public.etapa_por_marco(c, 'avaliacao_realizada')).id, 2400000)
  returning id into o;
  update public.oportunidades set reabre_em = hoje + 25 where id = o;
  perform public.mover_etapa(o, public.etapa_por_resultado(c, 'nao_fechou'), 'Achou o investimento alto neste momento',
                             (select id from public.motivos where clinica_id = c and nome = 'Valor alto'));

  -- Dentistas (fictícias): a dona da clínica e mais duas.
  update public.profissionais set nome = 'Dra. Cristina' where id = prof;
  insert into public.profissionais (clinica_id, nome, cor) values
    (c, 'Dra. Paula Reis', '#5F8A6A'),
    (c, 'Dra. Lívia Moraes', '#7A6FA8');

  -- Agenda da semana: consultas já confirmadas (sem tarefas novas no painel).
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em)
  select c, pe.id, null, prof, 'procedimento',
         (select id from public.procedimentos where clinica_id = c and nome = 'Facetas/lentes em resina'),
         (public.proximo_dia_util(c, hoje) + time '11:00') at time zone 'America/Sao_Paulo', 90, 'confirmado', now()
    from public.pessoas pe where pe.clinica_id = c and pe.nome = 'Ana Costa';
  insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, profissional_id, tipo, procedimento_id,
                                   inicio, duracao_min, status, confirmado_em)
  select c, pe.id, o.id, (select id from public.profissionais where clinica_id = c and nome = 'Dra. Paula Reis'),
         'apresentacao_orcamento', o.procedimento_id,
         (public.proximo_dia_util(c, public.proximo_dia_util(c, hoje) + 1) + time '16:00') at time zone 'America/Sao_Paulo',
         30, 'confirmado', now()
    from public.pessoas pe join public.oportunidades o on o.pessoa_id = pe.id and o.status = 'aberta'
   where pe.clinica_id = c and pe.nome = 'Luiza Prado';

  -- Consulta de hoje: para testar "Compareceu" → "Abrir prontuário".
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id)
  values (c, 'Renata Alves', '+5511900000016', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'))
  returning id into p;
  insert into public.agendamentos (clinica_id, pessoa_id, profissional_id, tipo, procedimento_id, inicio, duracao_min,
                                   status, confirmado_em)
  values (c, p, (select id from public.profissionais where clinica_id = c and nome = 'Dra. Lívia Moraes'), 'procedimento',
          (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (hoje + time '08:30') at time zone 'America/Sao_Paulo', 60, 'confirmado', now());

  -- Prontuário da Maria: consulta 01 (avaliação, finalizada) com odontograma e plano de tratamento.
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, profissional_id, data, horario, tipo, procedimento_id,
                                   motivo_obs, queixa, anamnese_obs, odontograma, status, finalizado_em)
  select c, pr.id, pr.pessoa_id, prof, hoje - 14, time '10:00', 'avaliacao',
         (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
         'Avaliação estética', 'Acha os dentes amarelados e desgastados na frente.',
         'Hipertensa, usa losartana 50 mg. Sem alergias conhecidas. Range os dentes à noite.',
         '{"11": {"c": "faceta", "f": [], "s": "a_tratar"}, "21": {"c": "faceta", "f": [], "s": "a_tratar"},
           "16": {"c": "restauracao", "f": ["O"], "s": "existente"}, "26": {"c": "carie", "f": ["O", "M"], "s": "a_tratar"},
           "36": {"c": "canal", "f": [], "s": "existente"}}'::jsonb,
         'finalizado', now() - interval '14 days'
    from public.prontuarios pr join public.pessoas pe on pe.id = pr.pessoa_id
   where pe.clinica_id = c and pe.nome = 'Maria Silva'
  returning id, pessoa_id into v, p;
  insert into public.orcamentos (clinica_id, pessoa_id, origem, status, apresentado_em, apresentado_por)
  values (c, p, 'prontuario', 'apresentado', hoje - 14, prof)
  returning id into orc;
  insert into public.orcamento_itens (clinica_id, orcamento_id, procedimento_id, valor_unitario_centavos, dente, atendimento_id,
                                      status, realizado_atendimento_id, realizado_em)
  values
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Manutenção e limpeza'), 35000, null, v,
     'realizado', v, hoje - 14),
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'), 120000, null, v,
     'pendente', null, null),
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'), 1400000, '13 a 23', v,
     'pendente', null, null);

  -- 14 e 15. Pacientes antigos sem atendimento há meses (público de campanhas de reativação)
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado,
                              consentimento_marketing)
  values (c, 'paciente_antigo', 'Gabriela Rocha', '+5511900000014',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'), hoje - 430, true)
  returning id into p;
  insert into public.tratamentos_anteriores (clinica_id, pessoa_id, procedimento_id, realizado_em)
  values (c, p, (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'), hoje - 430);
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado)
  values (c, 'paciente_antigo', 'Heitor Campos', '+5511900000015',
          (select id from public.origens where clinica_id = c and nome = 'Paciente antigo'), hoje - 280);

  -- A rotina de hoje já "rodou" para estes dados.
  insert into public.execucoes_rotina (clinica_id, dia) values (c, hoje);
  return c;
end;
$$;
revoke execute on function teste.carregar_dados_ficticios() from public, anon, authenticated;

-- Login de teste. No Supabase de verdade, cria o login já confirmado e com senha
-- (nenhum e-mail é enviado); se já existir, troca a senha.
create or replace function teste.criar_login(p_email text, p_nome text, p_senha text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_col text;
begin
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    -- Banco local (sem Supabase Auth): o login é só o e-mail.
    if v_id is null then
      insert into auth.users (email, raw_user_meta_data) values (p_email, jsonb_build_object('nome', p_nome));
    end if;
    return;
  end if;

  if v_id is not null then
    execute 'update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt(''bf'')),
                                   email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
              where id = $1' using v_id, p_senha;
    return;
  end if;

  v_id := gen_random_uuid();
  execute 'insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                   raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
           values (''00000000-0000-0000-0000-000000000000'', $1, ''authenticated'', ''authenticated'', $2,
                   extensions.crypt($3, extensions.gen_salt(''bf'')), now(),
                   ''{"provider": "email", "providers": ["email"]}'', jsonb_build_object(''nome'', $4), now(), now())'
    using v_id, p_email, p_senha, p_nome;
  -- O Supabase Auth não aceita estes campos nulos.
  for v_col in select column_name from information_schema.columns
                where table_schema = 'auth' and table_name = 'users'
                  and column_name in ('confirmation_token', 'recovery_token', 'email_change_token_new',
                                      'email_change_token_current', 'email_change', 'phone_change',
                                      'phone_change_token', 'reauthentication_token') loop
    execute format('update auth.users set %I = coalesce(%I, '''') where id = $1', v_col, v_col) using v_id;
  end loop;
  execute 'insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
           values (gen_random_uuid(), $1, $1::text,
                   jsonb_build_object(''sub'', $1::text, ''email'', $2, ''email_verified'', true), ''email'', now(), now(), now())'
    using v_id, p_email;
end;
$$;
revoke execute on function teste.criar_login(text, text, text) from public, anon, authenticated;

-- Logins da versão de teste (dona e secretária), com senhas novas a cada chamada.
-- Para trocar as senhas: select * from teste.criar_logins_de_teste();
create or replace function teste.criar_logins_de_teste()
returns table (perfil text, email text, senha text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinica uuid := (select id from public.clinicas where nome = 'Instituto CG' order by criado_em desc limit 1);
  v_senha text;
begin
  if v_clinica is null then v_clinica := teste.carregar_dados_ficticios(); end if;
  for perfil, email, v_senha in
    select x.perfil, x.email, 'cg-' || substr(md5(random()::text), 1, 4) || '-' || substr(md5(random()::text), 1, 4)
      from (values ('Dona da clínica (administradora)', 'dona@teste.institutocg.com.br', 1),
                   ('Secretária', 'secretaria@teste.institutocg.com.br', 2)) as x (perfil, email, ordem)
     order by x.ordem
  loop
    perform teste.criar_login(email, case when email like 'dona@%' then 'Dra. Cristina (teste)' else 'Secretária (teste)' end, v_senha);
    perform public.adicionar_membro(v_clinica, email, case when email like 'dona@%' then 'admin' else 'comercial' end::public.papel_membro, true);
    senha := v_senha;
    return next;
  end loop;
end;
$$;
revoke execute on function teste.criar_logins_de_teste() from public, anon, authenticated;

-- "Recomeçar com dados de exemplo" (só a administradora, só na versão de teste):
-- apaga tudo o que foi feito nos testes e recria as situações de exemplo, com
-- datas a partir de hoje. Os logins continuam os mesmos.
create or replace function teste.recomecar()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clinica uuid := (select m.clinica_id from public.membros m where m.usuario_id = auth.uid() and m.ativo
                      order by m.criado_em limit 1);
  v_membros jsonb;
  v_tabelas text;
  v_nova uuid;
  v_m jsonb;
begin
  if v_clinica is null or not public.eh_admin(v_clinica) then
    raise exception 'Só a administradora pode recomeçar a versão de teste.' using errcode = '42501';
  end if;
  select jsonb_agg(jsonb_build_object('email', u.email, 'papel', m.papel, 'fin', m.pode_ver_financeiro))
    into v_membros
    from public.membros m join public.usuarios u on u.id = m.usuario_id
   where m.clinica_id = v_clinica and m.ativo;

  select string_agg(format('public.%I', tablename), ', ') into v_tabelas
    from pg_tables where schemaname = 'public' and tablename <> 'usuarios';
  execute 'truncate table ' || v_tabelas || ' restart identity cascade';

  -- Os dados de exemplo são criados "pelo sistema", não em nome de quem clicou.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_nova := teste.carregar_dados_ficticios();
  for v_m in select * from jsonb_array_elements(v_membros) loop
    perform public.adicionar_membro(v_nova, v_m ->> 'email', (v_m ->> 'papel')::public.papel_membro, (v_m ->> 'fin')::boolean);
  end loop;
  return v_nova;
end;
$$;
revoke execute on function teste.recomecar() from public, anon;
grant execute on function teste.recomecar() to authenticated;


commit;
