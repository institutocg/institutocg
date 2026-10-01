-- =============================================================================
-- Migração 11: visão financeira simples (contas a receber, sem contabilidade)
--   • registrar_negociacao(): paciente, procedimento, valor, entrada (data e forma),
--     parcelas, forma de pagamento e observações → parcelas e lembretes automáticos.
--     Cartão (à vista ou parcelado) é recebido na hora: entra como pago, sem lembretes.
--   • registrar_pagamento(): total ou parcial, com data e forma.
--   • mudar_vencimento(): nova data prevista (o lembrete acompanha).
--   • v_financeiro_parcelas / v_financeiro_negociacoes e resumo_financeiro(mês).
-- Status: pendente · parcialmente pago · pago · atrasado.
-- =============================================================================

-- ─── Parcelas com o contexto da negociação ───────────────────────────────────

create view public.v_financeiro_parcelas with (security_invoker = true) as
select
  pa.id, pa.clinica_id, pa.venda_id, pa.pessoa_id, pa.numero, pa.vencimento, pa.pago_em,
  pa.valor_centavos, pa.valor_pago_centavos,
  pa.valor_centavos - pa.valor_pago_centavos                       as saldo_centavos,
  pa.observacao_financeira                                         as observacao,
  pe.nome                                                          as pessoa_nome,
  coalesce(pe.whatsapp_e164, pe.telefone_e164)                     as whatsapp,
  pr.nome                                                          as procedimento,
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
  (select t.id from public.tarefas t where t.parcela_id = pa.id and t.status = 'pendente' limit 1) as tarefa_id
from public.parcelas pa
join public.vendas v on v.id = pa.venda_id
join public.pessoas pe on pe.id = pa.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = o.procedimento_id
left join public.formas_pagamento fp on fp.id = pa.forma_pagamento_id
where v.status = 'ativa' and pa.status <> 'cancelada';

-- ─── Uma linha por negociação (venda) ────────────────────────────────────────

create view public.v_financeiro_negociacoes with (security_invoker = true) as
select
  v.id, v.clinica_id, v.pessoa_id, v.tipo, v.fechada_em,
  pe.nome                                       as pessoa_nome,
  coalesce(pr.nome, case when v.tipo = 'saldo_anterior' then 'Saldo anterior' end) as procedimento,
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
  end                                           as situacao
from public.vendas v
join public.pessoas pe on pe.id = v.pessoa_id
left join public.oportunidades o on o.id = v.oportunidade_id
left join public.procedimentos pr on pr.id = o.procedimento_id
left join public.formas_pagamento fp on fp.id = v.forma_pagamento_id
left join public.v_financeiro_parcelas p on p.venda_id = v.id
where v.status = 'ativa'
group by v.id, pe.nome, pr.nome, fp.nome;

-- ─── Resumo do mês ───────────────────────────────────────────────────────────

create or replace function public.resumo_financeiro(p_clinica uuid, p_mes date)
returns jsonb
language sql
stable
set search_path = public
as $$
  with lim as (
    select date_trunc('month', p_mes)::date as ini,
           (date_trunc('month', p_mes) + interval '1 month')::date as fim
  )
  select jsonb_build_object(
    'recebido_mes', coalesce((select sum(pg.valor_centavos) from public.pagamentos pg, lim
                               where pg.clinica_id = p_clinica and pg.estornado_em is null
                                 and pg.pago_em >= lim.ini and pg.pago_em < lim.fim), 0),
    'pagamentos_mes', (select count(*) from public.pagamentos pg, lim
                        where pg.clinica_id = p_clinica and pg.estornado_em is null
                          and pg.pago_em >= lim.ini and pg.pago_em < lim.fim),
    'previsto_mes', coalesce((select sum(p.saldo_centavos) from public.v_financeiro_parcelas p, lim
                               where p.clinica_id = p_clinica and p.situacao <> 'pago'
                                 and p.vencimento >= lim.ini and p.vencimento < lim.fim), 0),
    'pendente', coalesce((select sum(p.saldo_centavos) from public.v_financeiro_parcelas p
                           where p.clinica_id = p_clinica and p.situacao in ('pendente', 'parcial')), 0),
    'atrasado', coalesce((select sum(p.saldo_centavos) from public.v_financeiro_parcelas p
                           where p.clinica_id = p_clinica and p.situacao = 'atrasado'), 0),
    'atrasados', (select count(*) from public.v_financeiro_parcelas p
                   where p.clinica_id = p_clinica and p.situacao = 'atrasado'),
    'vendido_mes', coalesce((select sum(v.valor_final_centavos) from public.vendas v, lim
                              where v.clinica_id = p_clinica and v.status = 'ativa' and v.tipo = 'venda'
                                and v.fechada_em >= lim.ini and v.fechada_em < lim.fim), 0)
  );
$$;

-- ─── Cartão: recebido no ato (sem lembretes de cobrança) ─────────────────────

create or replace function public.quitar_recebidos_na_hora(p_venda uuid)
returns int
language plpgsql
set search_path = public
as $$
declare
  x record;
  n int := 0;
begin
  for x in
    select pa.id, pa.clinica_id, pa.valor_centavos - pa.valor_pago_centavos as saldo, pa.forma_pagamento_id
      from public.parcelas pa join public.formas_pagamento fx on fx.id = pa.forma_pagamento_id
     where pa.venda_id = p_venda and fx.recebe_na_hora and pa.status in ('pendente', 'parcial')
  loop
    insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id, observacao)
    values (x.clinica_id, x.id, x.saldo, public.hoje_clinica(x.clinica_id), x.forma_pagamento_id, 'Recebido no cartão');
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- ─── Registrar negociação ────────────────────────────────────────────────────

create or replace function public.registrar_negociacao(
  p_clinica             uuid,
  p_pessoa              uuid,
  p_procedimento        uuid,
  p_valor_centavos      bigint,
  p_desconto_centavos   bigint default 0,
  p_entrada_centavos    bigint default 0,
  p_entrada_em          date default null,
  p_entrada_forma       uuid default null,
  p_parcelas            int default 1,
  p_primeiro_vencimento date default null,
  p_forma               uuid default null,
  p_observacao          text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_hoje   date;
  v_op     public.oportunidades;
  v_venda  uuid;
  v_final  bigint := p_valor_centavos - coalesce(p_desconto_centavos, 0);
  v_antes  text := coalesce(current_setting('crm.acao_manual', true), '');
  f        public.formas_pagamento;
  fe       public.formas_pagamento;
begin
  if not public.pode_ver_financeiro(p_clinica) then
    raise exception 'Sem acesso ao financeiro.' using errcode = '42501';
  end if;
  v_hoje := public.hoje_clinica(p_clinica);
  if not exists (select 1 from public.pessoas where id = p_pessoa and clinica_id = p_clinica) then
    raise exception 'Paciente não encontrado.' using errcode = 'P0002';
  end if;
  if coalesce(p_valor_centavos, 0) <= 0 then
    raise exception 'Informe o valor.' using errcode = 'P0001';
  end if;
  if coalesce(p_desconto_centavos, 0) >= p_valor_centavos then
    raise exception 'O desconto não pode ser maior que o valor.' using errcode = 'P0001';
  end if;
  if coalesce(p_entrada_centavos, 0) > v_final then
    raise exception 'A entrada não pode ser maior que o valor final.' using errcode = 'P0001';
  end if;
  if p_forma is null then
    raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
  end if;
  select * into f from public.formas_pagamento where id = p_forma and clinica_id = p_clinica and ativo;
  select * into fe from public.formas_pagamento where id = coalesce(p_entrada_forma, p_forma) and clinica_id = p_clinica and ativo;
  if f.id is null or fe.id is null then
    raise exception 'Forma de pagamento inválida.' using errcode = 'P0001';
  end if;
  if coalesce(p_parcelas, 1) > f.max_parcelas then
    raise exception '% permite no máximo % parcela(s).', f.nome, f.max_parcelas using errcode = 'P0001';
  end if;

  -- A negociação do paciente (ou uma nova, já com o procedimento).
  select * into v_op from public.oportunidades where pessoa_id = p_pessoa and status in ('aberta', 'pausada');
  if v_op.id is null then
    perform set_config('crm.acao_manual', 'on', true);
    insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id, responsavel_id)
    select p_clinica, p_pessoa, p_procedimento, pe.origem_id, (public.etapa_por_marco(p_clinica, 'avaliacao_realizada')).id,
           coalesce(pe.responsavel_id, auth.uid())
      from public.pessoas pe where pe.id = p_pessoa
    returning * into v_op;
    perform set_config('crm.acao_manual', v_antes, true);
  elsif p_procedimento is not null and v_op.procedimento_id is distinct from p_procedimento then
    update public.oportunidades set procedimento_id = p_procedimento where id = v_op.id;
  end if;

  -- A venda move a negociação para "Fechou" (gatilho) e as parcelas geram os lembretes.
  insert into public.vendas (clinica_id, pessoa_id, oportunidade_id, valor_total_centavos, desconto_centavos,
                             condicao_pagamento, entrada_centavos, quantidade_parcelas, forma_pagamento_id,
                             fechada_em, observacao_financeira)
  values (p_clinica, p_pessoa, v_op.id, p_valor_centavos, coalesce(p_desconto_centavos, 0),
          case when coalesce(p_parcelas, 1) = 1 and coalesce(p_entrada_centavos, 0) = 0 then 'a_vista' else 'parcelado' end
            ::public.condicao_pagamento,
          coalesce(p_entrada_centavos, 0), greatest(coalesce(p_parcelas, 1), 1), p_forma, v_hoje,
          nullif(btrim(p_observacao), ''))
  returning id into v_venda;

  perform public.gerar_parcelas(v_venda,
    coalesce(p_primeiro_vencimento, case when coalesce(p_entrada_centavos, 0) > 0 then v_hoje + 30 else v_hoje end),
    coalesce(p_entrada_em, v_hoje));
  update public.parcelas set forma_pagamento_id = fe.id where venda_id = v_venda and numero = 0;

  perform public.quitar_recebidos_na_hora(v_venda);

  return jsonb_build_object('venda_id', v_venda,
    'parcelas', (select count(*) from public.parcelas where venda_id = v_venda),
    'lembretes', (select count(*) from public.tarefas t join public.parcelas pa on pa.id = t.parcela_id
                   where pa.venda_id = v_venda and t.status = 'pendente'));
end;
$$;

-- ─── Registrar pagamento (total ou parcial) ──────────────────────────────────

create or replace function public.registrar_pagamento(
  p_parcela     uuid,
  p_valor       bigint default null,     -- vazio = o saldo inteiro
  p_data        date default null,
  p_forma       uuid default null,
  p_observacao  text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  p      public.parcelas;
  v_saldo bigint;
  v_valor bigint;
begin
  select * into p from public.parcelas where id = p_parcela for update;
  if p.id is null then
    raise exception 'Parcela não encontrada ou sem permissão.' using errcode = 'P0002';
  end if;
  if p.status not in ('pendente', 'parcial') then
    raise exception 'Esta parcela não está em aberto.' using errcode = 'P0001';
  end if;
  v_saldo := p.valor_centavos - p.valor_pago_centavos;
  v_valor := coalesce(p_valor, v_saldo);
  if v_valor <= 0 then
    raise exception 'Informe o valor recebido.' using errcode = 'P0001';
  end if;
  if v_valor > v_saldo then
    raise exception 'O valor é maior que o saldo da parcela (%).', public.formatar_brl(v_saldo) using errcode = 'P0001';
  end if;
  if p_data > public.hoje_clinica(p.clinica_id) then
    raise exception 'A data do pagamento não pode ser futura.' using errcode = 'P0001';
  end if;
  insert into public.pagamentos (clinica_id, parcela_id, valor_centavos, pago_em, forma_pagamento_id, observacao)
  values (p.clinica_id, p.id, v_valor, coalesce(p_data, public.hoje_clinica(p.clinica_id)),
          coalesce(p_forma, p.forma_pagamento_id), nullif(btrim(p_observacao), ''));
  select * into p from public.parcelas where id = p_parcela;
  return jsonb_build_object('status', p.status, 'saldo_centavos', p.valor_centavos - p.valor_pago_centavos);
end;
$$;

-- ─── Nova data prevista (o lembrete acompanha) ───────────────────────────────

create or replace function public.mudar_vencimento(p_parcela uuid, p_data date, p_observacao text default null)
returns void
language plpgsql
set search_path = public
as $$
declare
  p public.parcelas;
begin
  select * into p from public.parcelas where id = p_parcela for update;
  if p.id is null then
    raise exception 'Parcela não encontrada ou sem permissão.' using errcode = 'P0002';
  end if;
  if p.status not in ('pendente', 'parcial') then
    raise exception 'Esta parcela não está em aberto.' using errcode = 'P0001';
  end if;
  if p_data is null or p_data < public.hoje_clinica(p.clinica_id) then
    raise exception 'Escolha hoje ou uma data futura.' using errcode = 'P0001';
  end if;
  update public.parcelas
     set vencimento = p_data,
         observacao_financeira = coalesce(nullif(btrim(p_observacao), ''), observacao_financeira)
   where id = p_parcela;
end;
$$;

revoke execute on function public.resumo_financeiro(uuid, date) from anon;
revoke execute on function public.registrar_negociacao(uuid, uuid, uuid, bigint, bigint, bigint, date, uuid, int, date, uuid, text) from anon;
revoke execute on function public.registrar_pagamento(uuid, bigint, date, uuid, text) from anon;
revoke execute on function public.mudar_vencimento(uuid, date, text) from anon;
