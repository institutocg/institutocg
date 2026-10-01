-- =============================================================================
-- Migração 3/4: financeiro simples (somente contas a receber)
--   orçamentos (+ itens), vendas (negociação fechada), parcelas, pagamentos
--   e os lembretes financeiros automáticos.
--
--   Orçamento ──aprovado──► Venda ──► Parcelas ──► Pagamentos
--                          (vendido)  (a receber)   (recebido)
-- =============================================================================

create type public.condicao_pagamento as enum ('a_vista', 'parcelado');
create type public.status_orcamento as enum (
  'rascunho', 'apresentado', 'em_negociacao', 'aprovado', 'recusado', 'expirado', 'substituido'
);
create type public.tipo_venda as enum ('venda', 'saldo_anterior');
create type public.status_venda as enum ('ativa', 'cancelada');
create type public.status_parcela as enum ('pendente', 'parcial', 'paga', 'cancelada', 'renegociada');

-- ─── Orçamentos ──────────────────────────────────────────────────────────────

create table public.orcamentos (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  pessoa_id               uuid not null,
  oportunidade_id         uuid not null,
  numero                  int not null default 0,         -- definido pelo gatilho
  versao                  int not null default 1 check (versao >= 1),
  status                  public.status_orcamento not null default 'rascunho',
  valor_total_centavos    bigint not null default 0 check (valor_total_centavos >= 0),
  desconto_centavos       bigint not null default 0 check (desconto_centavos >= 0),
  valor_final_centavos    bigint generated always as (valor_total_centavos - desconto_centavos) stored,
  forma_pagamento_id      uuid,
  condicao_pagamento      public.condicao_pagamento not null default 'a_vista',
  entrada_centavos        bigint not null default 0 check (entrada_centavos >= 0),
  quantidade_parcelas     int not null default 1 check (quantidade_parcelas between 1 and 60),
  valor_parcela_centavos  bigint generated always as (
    (valor_total_centavos - desconto_centavos - entrada_centavos) / quantidade_parcelas
  ) stored,
  observacao_financeira   text check (length(observacao_financeira) <= 1000),
  apresentado_em          date,
  valido_ate              date,
  apresentado_por         uuid,                              -- profissional
  criado_por              uuid default auth.uid(),
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, numero, versao),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  foreign key (clinica_id, apresentado_por) references public.profissionais (clinica_id, id),
  check (desconto_centavos <= valor_total_centavos),
  check (entrada_centavos <= valor_total_centavos - desconto_centavos),
  check ((condicao_pagamento = 'a_vista') = (quantidade_parcelas = 1 and entrada_centavos = 0)),
  check (valido_ate is null or apresentado_em is null or valido_ate >= apresentado_em)
);

-- Um único orçamento aprovado por negociação.
create unique index orcamentos_um_aprovado on public.orcamentos (oportunidade_id) where status = 'aprovado';

-- Itens: procedimento + descrição comercial (nada de plano clínico).
create table public.orcamento_itens (
  id                        uuid primary key default gen_random_uuid(),
  clinica_id                uuid not null references public.clinicas (id),
  orcamento_id              uuid not null,
  procedimento_id           uuid not null,
  descricao_comercial       text check (length(descricao_comercial) <= 200),
  quantidade                int not null default 1 check (quantidade between 1 and 100),
  valor_unitario_centavos   bigint not null check (valor_unitario_centavos >= 0),
  desconto_centavos         bigint not null default 0 check (desconto_centavos >= 0),
  criado_em                 timestamptz not null default now(),
  foreign key (clinica_id, orcamento_id) references public.orcamentos (clinica_id, id) on delete cascade,
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id),
  check (desconto_centavos <= quantidade * valor_unitario_centavos)
);

-- ─── Vendas (negociação fechada) ─────────────────────────────────────────────

create table public.vendas (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  pessoa_id               uuid not null,
  oportunidade_id         uuid,
  orcamento_id            uuid unique,
  tipo                    public.tipo_venda not null default 'venda',
  status                  public.status_venda not null default 'ativa',
  fechada_em              date not null default (now() at time zone 'America/Sao_Paulo')::date,
  valor_total_centavos    bigint not null check (valor_total_centavos > 0),
  desconto_centavos       bigint not null default 0 check (desconto_centavos >= 0),
  valor_final_centavos    bigint generated always as (valor_total_centavos - desconto_centavos) stored,
  forma_pagamento_id      uuid,
  condicao_pagamento      public.condicao_pagamento not null default 'a_vista',
  entrada_centavos        bigint not null default 0 check (entrada_centavos >= 0),
  quantidade_parcelas     int not null default 1 check (quantidade_parcelas between 1 and 60),
  valor_parcela_centavos  bigint generated always as (
    (valor_total_centavos - desconto_centavos - entrada_centavos) / quantidade_parcelas
  ) stored,
  observacao_financeira   text check (length(observacao_financeira) <= 1000),
  cancelada_em            timestamptz,
  cancelada_motivo        text,
  criado_por              uuid default auth.uid(),
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, oportunidade_id) references public.oportunidades (clinica_id, id),
  foreign key (clinica_id, orcamento_id) references public.orcamentos (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  check (desconto_centavos < valor_total_centavos),
  check (entrada_centavos <= valor_total_centavos - desconto_centavos),
  check ((condicao_pagamento = 'a_vista') = (quantidade_parcelas = 1 and entrada_centavos = 0)),
  -- Venda nova nasce de uma negociação; "saldo anterior" é só para o recadastro.
  check (tipo = 'saldo_anterior' or oportunidade_id is not null),
  check ((status = 'cancelada') = (cancelada_em is not null and cancelada_motivo is not null))
);

-- ─── Parcelas (contas a receber) ─────────────────────────────────────────────

create table public.parcelas (
  id                      uuid primary key default gen_random_uuid(),
  clinica_id              uuid not null references public.clinicas (id),
  venda_id                uuid not null,
  pessoa_id               uuid not null,
  numero                  int not null check (numero >= 0),   -- 0 = entrada
  valor_centavos          bigint not null check (valor_centavos > 0),
  vencimento              date not null,                      -- data prevista
  forma_pagamento_id      uuid,
  status                  public.status_parcela not null default 'pendente',
  valor_pago_centavos     bigint not null default 0 check (valor_pago_centavos >= 0),
  pago_em                 date,                               -- data efetiva
  observacao_financeira   text check (length(observacao_financeira) <= 500),
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  unique (clinica_id, id),
  unique (venda_id, numero),
  foreign key (clinica_id, venda_id) references public.vendas (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  check (status <> 'paga' or (valor_pago_centavos >= valor_centavos and pago_em is not null))
);

create index parcelas_vencimento on public.parcelas (clinica_id, status, vencimento);
create index parcelas_pessoa on public.parcelas (pessoa_id);

alter table public.tarefas
  add foreign key (clinica_id, parcela_id) references public.parcelas (clinica_id, id);
create unique index tarefas_uma_por_parcela on public.tarefas (parcela_id)
  where status = 'pendente' and parcela_id is not null;

-- ─── Pagamentos (o que efetivamente entrou) ──────────────────────────────────

create table public.pagamentos (
  id                  uuid primary key default gen_random_uuid(),
  clinica_id          uuid not null references public.clinicas (id),
  parcela_id          uuid not null,
  valor_centavos      bigint not null check (valor_centavos > 0),
  pago_em             date not null default (now() at time zone 'America/Sao_Paulo')::date,
  forma_pagamento_id  uuid,
  observacao          text check (length(observacao) <= 500),
  registrado_por      uuid default auth.uid(),
  -- Pagamento lançado por engano é estornado, nunca apagado.
  estornado_em        timestamptz,
  estorno_motivo      text,
  criado_em           timestamptz not null default now(),
  foreign key (clinica_id, parcela_id) references public.parcelas (clinica_id, id),
  foreign key (clinica_id, forma_pagamento_id) references public.formas_pagamento (clinica_id, id),
  check ((estornado_em is null) = (estorno_motivo is null))
);

create index pagamentos_parcela on public.pagamentos (parcela_id);
create index pagamentos_data on public.pagamentos (clinica_id, pago_em);

-- =============================================================================
-- Gatilhos e funções
-- =============================================================================

-- Numeração sequencial de orçamentos por clínica (nova versão mantém o número).
create or replace function public.numerar_orcamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.numero = 0 then
    perform pg_advisory_xact_lock(hashtext('orcamento:' || new.clinica_id));
    select coalesce(max(numero), 0) + 1 into new.numero
      from public.orcamentos where clinica_id = new.clinica_id;
  end if;
  return new;
end;
$$;

create trigger numerar_orcamento
  before insert on public.orcamentos
  for each row execute function public.numerar_orcamento();

-- Valor total do orçamento = soma dos itens (quando há itens).
create or replace function public.recalcular_orcamento()
returns trigger
language plpgsql
as $$
declare
  v_orcamento uuid := coalesce(new.orcamento_id, old.orcamento_id);
begin
  update public.orcamentos o
     set valor_total_centavos = coalesce((
           select sum(i.quantidade * i.valor_unitario_centavos - i.desconto_centavos)
             from public.orcamento_itens i where i.orcamento_id = v_orcamento), 0)
   where o.id = v_orcamento;
  return null;
end;
$$;

create trigger recalcular_orcamento
  after insert or update or delete on public.orcamento_itens
  for each row execute function public.recalcular_orcamento();

-- Registrar uma venda fecha a negociação: move para a etapa "Fechou", grava o
-- valor fechado e marca o orçamento como aprovado.
create or replace function public.ao_registrar_venda()
returns trigger
language plpgsql
as $$
declare
  v_etapa_fechou uuid;
begin
  if new.tipo = 'venda' then
    select id into v_etapa_fechou from public.etapas_funil
     where clinica_id = new.clinica_id and resultado = 'fechou' and ativo;
    if v_etapa_fechou is null then
      raise exception 'A clínica não tem etapa ativa para "Fechou".' using errcode = 'P0001';
    end if;

    update public.oportunidades set valor_fechado_centavos = new.valor_final_centavos
     where id = new.oportunidade_id;
    if (select status from public.oportunidades where id = new.oportunidade_id) <> 'ganha' then
      perform public.mover_etapa(new.oportunidade_id, v_etapa_fechou, 'Venda registrada');
    end if;

    if new.orcamento_id is not null then
      update public.orcamentos set status = 'aprovado' where id = new.orcamento_id;
      update public.orcamentos set status = 'substituido'
       where oportunidade_id = new.oportunidade_id and id <> new.orcamento_id
         and status in ('rascunho', 'apresentado', 'em_negociacao');
    end if;

    insert into public.interacoes (clinica_id, pessoa_id, oportunidade_id, tipo, descricao)
    values (new.clinica_id, new.pessoa_id, new.oportunidade_id, 'paciente_fechou',
            'Negociação fechada: ' || public.formatar_brl(new.valor_final_centavos));
  end if;
  return new;
end;
$$;

create trigger ao_registrar_venda
  after insert on public.vendas
  for each row execute function public.ao_registrar_venda();

-- Cancelar uma venda exige a administradora e cancela as parcelas em aberto.
create or replace function public.ao_cancelar_venda()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'cancelada' and old.status <> 'cancelada' then
    if auth.uid() is not null and not public.eh_admin(new.clinica_id) then
      raise exception 'Somente a administradora pode cancelar uma venda.' using errcode = '42501';
    end if;
    update public.parcelas set status = 'cancelada'
     where venda_id = new.id and status in ('pendente', 'parcial');
  end if;
  return new;
end;
$$;

create trigger ao_cancelar_venda
  after update of status on public.vendas
  for each row execute function public.ao_cancelar_venda();

-- Gera entrada + parcelas mensais. A diferença de centavos vai para a última.
create or replace function public.gerar_parcelas(
  p_venda uuid,
  p_primeiro_vencimento date,
  p_vencimento_entrada date default null
)
returns int
language plpgsql
as $$
declare
  v public.vendas;
  v_restante bigint;
  v_valor bigint;
  i int;
begin
  select * into v from public.vendas where id = p_venda;
  if v.id is null then
    raise exception 'Venda não encontrada ou sem permissão' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.parcelas where venda_id = p_venda) then
    raise exception 'As parcelas desta venda já foram geradas.' using errcode = 'P0001';
  end if;

  if v.entrada_centavos > 0 then
    insert into public.parcelas (clinica_id, venda_id, pessoa_id, numero, valor_centavos, vencimento, forma_pagamento_id)
    values (v.clinica_id, v.id, v.pessoa_id, 0, v.entrada_centavos,
            coalesce(p_vencimento_entrada, v.fechada_em), v.forma_pagamento_id);
  end if;

  v_restante := v.valor_final_centavos - v.entrada_centavos;
  if v_restante > 0 then
    for i in 1 .. v.quantidade_parcelas loop
      v_valor := case when i = v.quantidade_parcelas
                      then v_restante - v.valor_parcela_centavos * (v.quantidade_parcelas - 1)
                      else v.valor_parcela_centavos end;
      insert into public.parcelas (clinica_id, venda_id, pessoa_id, numero, valor_centavos, vencimento, forma_pagamento_id)
      values (v.clinica_id, v.id, v.pessoa_id, i, v_valor,
              (p_primeiro_vencimento + make_interval(months => i - 1))::date, v.forma_pagamento_id);
    end loop;
  end if;

  return (select count(*) from public.parcelas where venda_id = p_venda);
end;
$$;

-- Pagamentos só podem ser estornados (com motivo), nunca editados.
create or replace function public.proteger_pagamento()
returns trigger
language plpgsql
as $$
begin
  if (to_jsonb(new) - array['estornado_em', 'estorno_motivo'])
     is distinct from (to_jsonb(old) - array['estornado_em', 'estorno_motivo']) then
    raise exception 'Pagamentos não podem ser editados; estorne e registre novamente.'
      using errcode = 'P0001';
  end if;
  if old.estornado_em is not null then
    raise exception 'Este pagamento já foi estornado.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger proteger_pagamento
  before update on public.pagamentos
  for each row execute function public.proteger_pagamento();

-- Recalcula valor pago, data efetiva e status da parcela a partir dos pagamentos.
create or replace function public.recalcular_parcela()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pago bigint;
  v_data date;
begin
  select coalesce(sum(valor_centavos), 0), max(pago_em) into v_pago, v_data
    from public.pagamentos where parcela_id = new.parcela_id and estornado_em is null;

  update public.parcelas p set
    valor_pago_centavos = v_pago,
    pago_em = case when v_pago > 0 then v_data end,
    status = case
      when p.status in ('cancelada', 'renegociada') then p.status
      when v_pago >= p.valor_centavos then 'paga'
      when v_pago > 0 then 'parcial'
      else 'pendente'
    end::public.status_parcela
  where p.id = new.parcela_id;

  if tg_op = 'INSERT' then
    insert into public.interacoes (clinica_id, pessoa_id, tipo, descricao, usuario_id)
    select pa.clinica_id, pa.pessoa_id, 'pagamento_recebido',
           'Pagamento de ' || public.formatar_brl(new.valor_centavos) || ' recebido em '
             || to_char(new.pago_em, 'DD/MM/YYYY'),
           new.registrado_por
      from public.parcelas pa where pa.id = new.parcela_id;
  end if;
  return null;
end;
$$;

create trigger recalcular_parcela
  after insert or update on public.pagamentos
  for each row execute function public.recalcular_parcela();

-- LEMBRETE FINANCEIRO AUTOMÁTICO
-- Toda parcela em aberto tem uma tarefa "confirmar pagamento" na data prevista.
-- Muda a data → a tarefa acompanha. Pagou → tarefa concluída. Cancelou → cancelada.
-- Se passar da data sem pagamento, a tarefa continua pendente e aparece no painel
-- como "Pagamento em atraso".
create or replace function public.sincronizar_tarefa_parcela()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pessoa     public.pessoas;
  v_venda      public.vendas;
  v_forma      text;
  v_saldo      bigint := new.valor_centavos - new.valor_pago_centavos;
  v_chave      text := 'pagamento:' || new.id;
  v_titulo     text;
  v_descricao  text;
  v_mensagem   text;
begin
  select * into v_pessoa from public.pessoas where id = new.pessoa_id;
  select * into v_venda from public.vendas where id = new.venda_id;
  select nome into v_forma from public.formas_pagamento where id = new.forma_pagamento_id;

  if new.status in ('pendente', 'parcial') then
    v_titulo := 'Pagamento previsto — ' || v_pessoa.nome || ' — ' || public.formatar_brl(v_saldo);
    v_descricao := case when new.numero = 0 then 'Entrada'
                        else 'Parcela ' || new.numero || ' de ' || v_venda.quantidade_parcelas end
                   || ' · vencimento ' || to_char(new.vencimento, 'DD/MM/YYYY')
                   || coalesce(' · ' || v_forma, '')
                   || case when new.valor_pago_centavos > 0
                           then ' · já pago ' || public.formatar_brl(new.valor_pago_centavos) else '' end;
    -- Mensagem da biblioteca ("Pagamento previsto"); o painel troca por cobrança amigável
    -- ou pagamento pendente conforme o atraso.
    v_mensagem := public.renderizar_mensagem(new.clinica_id, 'confirmar_pagamento', new.pessoa_id, null,
                    jsonb_build_object('valor', public.formatar_brl(v_saldo),
                                       'vencimento', to_char(new.vencimento, 'DD/MM')));

    update public.tarefas
       set titulo = v_titulo, descricao = v_descricao, vence_em = new.vencimento,
           mensagem_sugerida = v_mensagem
     where parcela_id = new.id and status = 'pendente';

    if not found then
      insert into public.tarefas (
        clinica_id, pessoa_id, oportunidade_id, parcela_id, tipo, categoria, titulo, descricao,
        vence_em, prioridade, responsavel_id, origem, regra, mensagem_sugerida, chave_dedupe
      ) values (
        new.clinica_id, new.pessoa_id, v_venda.oportunidade_id, new.id, 'confirmar_pagamento',
        'financeiro', v_titulo, v_descricao, new.vencimento, 'alta', v_pessoa.responsavel_id,
        'automatica', 'R-FIN-01', v_mensagem, v_chave
      );
    end if;

  elsif new.status = 'paga' then
    update public.tarefas
       set status = 'concluida', resultado = 'Pagamento registrado'
     where parcela_id = new.id and status = 'pendente';

  else -- cancelada / renegociada
    update public.tarefas
       set status = 'cancelada', cancelada_motivo = 'Parcela ' || new.status::text
     where parcela_id = new.id and status = 'pendente';
  end if;

  return null;
end;
$$;

create trigger sincronizar_tarefa_parcela
  after insert or update of status, vencimento, valor_centavos, valor_pago_centavos on public.parcelas
  for each row execute function public.sincronizar_tarefa_parcela();

-- ─── Gatilhos comuns e RLS ───────────────────────────────────────────────────

do $$
declare
  t text;
begin
  foreach t in array array['orcamentos', 'vendas', 'parcelas'] loop
    execute format(
      'create trigger definir_atualizado_em before update on public.%I
         for each row execute function public.definir_atualizado_em()', t);
  end loop;
  foreach t in array array['orcamentos', 'orcamento_itens', 'vendas', 'parcelas', 'pagamentos'] loop
    execute format(
      'create trigger auditoria after insert or update or delete on public.%I
         for each row execute function public.registrar_auditoria()', t);
    execute format('alter table public.%I enable row level security', t);
    -- Ver valores exige permissão financeira; registrar (ex.: pagamento) basta ser membro.
    execute format(
      'create policy financeiro_ler on public.%I for select to authenticated
         using (public.pode_ver_financeiro(clinica_id))', t);
    execute format(
      'create policy membro_inserir on public.%I for insert to authenticated
         with check (clinica_id in (select public.minhas_clinicas()))', t);
    execute format(
      'create policy membro_alterar on public.%I for update to authenticated
         using (clinica_id in (select public.minhas_clinicas()))
         with check (clinica_id in (select public.minhas_clinicas()))', t);
  end loop;
end;
$$;

-- Itens de orçamento podem ser removidos enquanto o orçamento é rascunho.
create policy item_remover on public.orcamento_itens for delete to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and exists (select 1 from public.orcamentos o where o.id = orcamento_id and o.status = 'rascunho')
  );
