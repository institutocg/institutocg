-- =============================================================================
-- Migração 14: prontuário
--   • Um prontuário por paciente (prontuarios.pessoa_id), criado automaticamente.
--   • Consultas do prontuário (atendimentos): uma por atendimento, sem apagar as
--     anteriores. Cada uma guarda a ficha (seleções + campos curtos) e o
--     ODONTOGRAMA daquele momento (cópia do anterior ao abrir a próxima).
--   • Plano de tratamento = orçamento (origem 'prontuario') com itens que têm
--     status (orçado, aceito, pendente, realizado, não realizado, cancelado).
--     Realizar um item registra a cobrança no Financeiro existente (vendas,
--     parcelas, pagamentos) — o mesmo pagamento aparece nos dois lugares.
--   • Agenda: o atendimento nasce do agendamento (data, horário, dentista,
--     procedimento/motivo).
--   • Acesso: dados de saúde (LGPD, dado sensível) — administradora, dentistas
--     e quem tiver membros.pode_ver_prontuario. Tudo auditado; nada é apagado.
-- =============================================================================

-- ─── Acesso ──────────────────────────────────────────────────────────────────

alter table public.membros add column if not exists pode_ver_prontuario boolean not null default false;

create or replace function public.pode_ver_prontuario(p_clinica uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.membros m
    join public.usuarios u on u.id = m.usuario_id
    where m.usuario_id = auth.uid() and m.clinica_id = p_clinica and m.ativo and u.ativo
      and (m.papel in ('admin', 'dentista') or m.pode_ver_prontuario)
  );
$$;

-- ─── Prontuário: um por paciente ─────────────────────────────────────────────

create table public.prontuarios (
  id          uuid primary key default gen_random_uuid(),
  clinica_id  uuid not null references public.clinicas (id),
  pessoa_id   uuid not null unique,
  criado_em   timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id)
);

create or replace function public.criar_prontuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.prontuarios (clinica_id, pessoa_id) values (new.clinica_id, new.id)
  on conflict (pessoa_id) do nothing;
  return null;
end;
$$;

create trigger criar_prontuario
  after insert on public.pessoas
  for each row execute function public.criar_prontuario();

-- Pacientes já cadastrados ganham o prontuário agora.
insert into public.prontuarios (clinica_id, pessoa_id)
select clinica_id, id from public.pessoas
on conflict (pessoa_id) do nothing;

-- ─── Consultas do prontuário (atendimentos) ──────────────────────────────────

create type public.status_atendimento as enum ('em_andamento', 'finalizado');

create table public.atendimentos (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  prontuario_id    uuid not null,
  pessoa_id        uuid not null,
  numero           int not null default 0,                 -- Consulta 01, 02… (gatilho)
  agendamento_id   uuid unique,                            -- a consulta da agenda que originou
  profissional_id  uuid,
  data             date not null,
  horario          time,
  tipo             public.tipo_agendamento,
  procedimento_id  uuid,                                   -- procedimento/motivo do agendamento
  motivo           text[] not null default '{}',
  motivo_obs       text check (length(motivo_obs) <= 500),
  anamnese         text[] not null default '{}',
  anamnese_obs     text check (length(anamnese_obs) <= 2000),
  diagnostico      text[] not null default '{}',
  diagnostico_obs  text check (length(diagnostico_obs) <= 2000),
  evolucao         text check (length(evolucao) <= 4000),  -- evolução / conduta
  orientacoes      text[] not null default '{}',
  orientacoes_obs  text check (length(orientacoes_obs) <= 1000),
  retorno_em       date,
  retorno_obs      text check (length(retorno_obs) <= 300),
  -- Estado do odontograma NESTA consulta: {"16": {"c": "carie", "f": ["O"], "s": "a_tratar", "o": "…"}}
  odontograma      jsonb not null default '{}'::jsonb check (jsonb_typeof(odontograma) = 'object'),
  status           public.status_atendimento not null default 'em_andamento',
  finalizado_em    timestamptz,
  finalizado_por   uuid,
  criado_por       uuid default auth.uid(),
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  unique (clinica_id, id),
  unique (prontuario_id, numero),
  foreign key (clinica_id, prontuario_id) references public.prontuarios (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, agendamento_id) references public.agendamentos (clinica_id, id),
  foreign key (clinica_id, profissional_id) references public.profissionais (clinica_id, id),
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id)
);

create index atendimentos_pessoa on public.atendimentos (pessoa_id, data desc, numero desc);

create or replace function public.numerar_atendimento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.numero = 0 then
    perform pg_advisory_xact_lock(hashtext('atendimento:' || new.prontuario_id));
    select coalesce(max(numero), 0) + 1 into new.numero from public.atendimentos where prontuario_id = new.prontuario_id;
  end if;
  return new;
end;
$$;

create trigger numerar_atendimento
  before insert on public.atendimentos
  for each row execute function public.numerar_atendimento();

-- Consulta finalizada não muda (o histórico é preservado).
create or replace function public.proteger_atendimento()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Consultas do prontuário não são apagadas.' using errcode = 'P0001';
  end if;
  if old.status = 'finalizado' then
    raise exception 'Esta consulta foi finalizada e não pode ser alterada.' using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger proteger_atendimento
  before update or delete on public.atendimentos
  for each row execute function public.proteger_atendimento();

create trigger definir_atualizado_em before update on public.atendimentos
  for each row execute function public.definir_atualizado_em();

-- ─── Plano de tratamento = orçamento do prontuário ───────────────────────────

create type public.status_item_plano as enum ('orcado', 'aceito', 'pendente', 'realizado', 'nao_realizado', 'cancelado');

-- O plano é um orçamento comum, marcado como vindo do prontuário. Não precisa de
-- negociação (paciente antigo, manutenção…) e não mexe no funil.
alter table public.orcamentos
  add column if not exists origem text not null default 'comercial' check (origem in ('comercial', 'prontuario'));
alter table public.orcamentos alter column oportunidade_id drop not null;

alter table public.orcamento_itens
  add column if not exists status public.status_item_plano not null default 'orcado',
  add column if not exists dente text check (length(dente) <= 60),
  add column if not exists atendimento_id uuid,             -- consulta em que foi planejado
  add column if not exists realizado_atendimento_id uuid,   -- consulta em que foi realizado
  add column if not exists realizado_em date,
  add column if not exists venda_id uuid,                   -- cobrança no Financeiro
  add column if not exists atualizado_em timestamptz not null default now();
alter table public.orcamento_itens
  add constraint orcamento_itens_atendimento_fk foreign key (clinica_id, atendimento_id) references public.atendimentos (clinica_id, id),
  add constraint orcamento_itens_realizado_fk foreign key (clinica_id, realizado_atendimento_id) references public.atendimentos (clinica_id, id),
  add constraint orcamento_itens_venda_fk foreign key (clinica_id, venda_id) references public.vendas (clinica_id, id),
  add constraint orcamento_itens_realizado_ck check ((status = 'realizado') = (realizado_atendimento_id is not null));

create trigger definir_atualizado_em before update on public.orcamento_itens
  for each row execute function public.definir_atualizado_em();

create or replace function public.motor_orcamento_apresentado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- O plano de tratamento do prontuário não é um orçamento comercial: não mexe no funil nem cria follow-up.
  if new.origem = 'prontuario' or new.oportunidade_id is null then
    return null;
  end if;
  if new.status <> 'apresentado' or (tg_op = 'UPDATE' and old.status = 'apresentado') then
    return null;
  end if;
  -- O orçamento é apresentado na consulta: a negociação fica em "Consulta realizada".
  perform public.avancar_para_marco(new.oportunidade_id, 'avaliacao_realizada', 'Orçamento apresentado na consulta');
  if not public.tem_proxima_acao(new.oportunidade_id) then
    perform public.criar_por_regra('pos_consulta', new.pessoa_id, new.oportunidade_id, 'op:' || new.oportunidade_id,
      p_base => coalesce(new.apresentado_em, public.hoje_clinica(new.clinica_id)), p_descricao => 'Recebeu o orçamento na consulta');
  end if;
  return null;
end;
$$;

-- Total do orçamento: sem os itens cancelados ou não realizados.
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
             from public.orcamento_itens i
            where i.orcamento_id = v_orcamento and i.status not in ('cancelado', 'nao_realizado')), 0)
   where o.id = v_orcamento;
  return null;
end;
$$;

-- ─── Acesso (RLS) e auditoria ────────────────────────────────────────────────

alter table public.prontuarios enable row level security;
alter table public.atendimentos enable row level security;

create policy prontuario_ler on public.prontuarios for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy prontuario_ler on public.atendimentos for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy prontuario_inserir on public.atendimentos for insert to authenticated
  with check (public.pode_ver_prontuario(clinica_id));
create policy prontuario_alterar on public.atendimentos for update to authenticated
  using (public.pode_ver_prontuario(clinica_id)) with check (public.pode_ver_prontuario(clinica_id));
-- Quem atende vê o plano de tratamento mesmo sem acesso ao financeiro.
create policy prontuario_ler on public.orcamentos for select to authenticated
  using (origem = 'prontuario' and public.pode_ver_prontuario(clinica_id));
create policy prontuario_ler on public.orcamento_itens for select to authenticated
  using (public.pode_ver_prontuario(clinica_id)
         and exists (select 1 from public.orcamentos o where o.id = orcamento_id and o.origem = 'prontuario'));

create trigger auditoria after insert or update or delete on public.atendimentos
  for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.prontuarios
  for each row execute function public.registrar_auditoria();

-- ─── Visões ──────────────────────────────────────────────────────────────────

create view public.v_atendimentos with (security_invoker = true) as
select
  a.id, a.clinica_id, a.prontuario_id, a.pessoa_id, a.numero, a.agendamento_id, a.data,
  to_char(a.horario, 'HH24:MI')                                 as horario,
  a.tipo, a.procedimento_id, pr.nome                            as procedimento,
  a.profissional_id, pf.nome                                    as profissional, pf.cor as profissional_cor,
  a.status, a.finalizado_em, a.motivo, a.anamnese, a.diagnostico, a.retorno_em,
  (select count(*) from public.orcamento_itens i where i.realizado_atendimento_id = a.id)::int as realizados,
  (select string_agg(p2.nome, ', ' order by i.realizado_em, p2.nome)
     from public.orcamento_itens i join public.procedimentos p2 on p2.id = i.procedimento_id
    where i.realizado_atendimento_id = a.id)                    as procedimentos_realizados
from public.atendimentos a
left join public.procedimentos pr on pr.id = a.procedimento_id
left join public.profissionais pf on pf.id = a.profissional_id;

create view public.v_plano_tratamento with (security_invoker = true) as
select
  i.id, i.clinica_id, o.pessoa_id, i.orcamento_id, o.numero as orcamento_numero,
  i.procedimento_id, pr.nome as procedimento, i.dente, i.status,
  (i.quantidade * i.valor_unitario_centavos - i.desconto_centavos)  as valor_centavos,
  i.atendimento_id, ap.numero as atendimento_numero,
  i.realizado_atendimento_id, ar.numero as realizado_atendimento_numero, i.realizado_em,
  i.venda_id, n.situacao as financeiro, n.saldo_centavos, n.pago_centavos, n.proximo_vencimento,
  i.criado_em
from public.orcamento_itens i
join public.orcamentos o on o.id = i.orcamento_id
join public.procedimentos pr on pr.id = i.procedimento_id
left join public.atendimentos ap on ap.id = i.atendimento_id
left join public.atendimentos ar on ar.id = i.realizado_atendimento_id
left join public.v_financeiro_negociacoes n on n.id = i.venda_id
where o.origem = 'prontuario';

-- ─── Abrir consultas ─────────────────────────────────────────────────────────

-- Cria a consulta no prontuário; o odontograma começa como o da consulta anterior.
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
  v_mot  text[];
begin
  select * into pr from public.prontuarios where pessoa_id = p_pessoa;
  if pr.id is null or not public.pode_ver_prontuario(pr.clinica_id) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  v_mot := case p_tipo when 'avaliacao' then array['Avaliação'] when 'retorno' then array['Retorno']
                       when 'manutencao' then array['Manutenção / limpeza'] when 'procedimento' then array['Continuidade do tratamento']
                       else '{}' end;
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, agendamento_id, profissional_id, data, horario,
                                   tipo, procedimento_id, motivo, odontograma)
  values (pr.clinica_id, pr.id, p_pessoa, p_agendamento, p_profissional, coalesce(p_data, public.hoje_clinica(pr.clinica_id)),
          p_horario, p_tipo, p_procedimento, v_mot,
          coalesce((select a.odontograma from public.atendimentos a where a.prontuario_id = pr.id
                     order by a.data desc, a.numero desc limit 1), '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- Agenda → prontuário: abre (ou cria) a consulta daquele agendamento.
create or replace function public.abrir_atendimento(p_agendamento uuid)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  a     public.agendamentos;
  v_id  uuid;
begin
  select * into a from public.agendamentos where id = p_agendamento;
  if a.id is null then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  if not public.pode_ver_prontuario(a.clinica_id) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  select id into v_id from public.atendimentos where agendamento_id = a.id;
  if v_id is not null then
    return v_id;
  end if;
  if a.status in ('desmarcado', 'remarcado', 'cancelado_clinica', 'faltou') then
    raise exception 'Esta consulta não aconteceu (está como %).', replace(a.status::text, '_', ' ') using errcode = 'P0001';
  end if;
  if (a.inicio at time zone 'America/Sao_Paulo')::date > public.hoje_clinica(a.clinica_id) then
    raise exception 'A consulta é em %. A ficha do atendimento abre no dia.',
      to_char(a.inicio at time zone 'America/Sao_Paulo', 'DD/MM') using errcode = 'P0001';
  end if;
  return public.criar_atendimento(a.pessoa_id, (a.inicio at time zone 'America/Sao_Paulo')::date,
    (a.inicio at time zone 'America/Sao_Paulo')::time, a.profissional_id, a.tipo, a.procedimento_id, a.id);
end;
$$;

-- Consulta sem agendamento (encaixe, urgência…).
create or replace function public.novo_atendimento(p_pessoa uuid, p_profissional uuid default null)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  v_hoje    date;
  v_ag      uuid;
begin
  if v_clinica is null or not public.pode_ver_prontuario(v_clinica) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  v_hoje := public.hoje_clinica(v_clinica);
  -- Tem consulta hoje na agenda ainda sem ficha? Usa ela.
  select ag.id into v_ag from public.agendamentos ag
   where ag.pessoa_id = p_pessoa and (ag.inicio at time zone 'America/Sao_Paulo')::date = v_hoje
     and ag.status in ('agendado', 'confirmado', 'compareceu')
     and not exists (select 1 from public.atendimentos x where x.agendamento_id = ag.id)
   order by ag.inicio limit 1;
  if v_ag is not null then
    return public.abrir_atendimento(v_ag);
  end if;
  -- Dentista: a escolhida, ou quem está logada (se for dentista da agenda); senão, escolhe-se na ficha.
  return public.criar_atendimento(p_pessoa, v_hoje, (now() at time zone 'America/Sao_Paulo')::time(0),
    coalesce(p_profissional, (select id from public.profissionais where clinica_id = v_clinica and usuario_id = auth.uid() and ativo limit 1)));
end;
$$;

-- ─── Ficha da consulta ───────────────────────────────────────────────────────

create or replace function public.salvar_atendimento(p_atendimento uuid, p jsonb, p_finalizar boolean default false)
returns void
language plpgsql
set search_path = public
as $$
declare
  a public.atendimentos;
  arr text := '{}';
begin
  select * into a from public.atendimentos where id = p_atendimento for update;
  if a.id is null or not public.pode_ver_prontuario(a.clinica_id) then
    raise exception 'Consulta não encontrada.' using errcode = 'P0002';
  end if;
  update public.atendimentos set
    profissional_id = coalesce(nullif(p ->> 'profissional_id', '')::uuid, profissional_id),
    motivo          = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'motivo') x), arr::text[]),
    motivo_obs      = nullif(btrim(p ->> 'motivo_obs'), ''),
    anamnese        = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'anamnese') x), arr::text[]),
    anamnese_obs    = nullif(btrim(p ->> 'anamnese_obs'), ''),
    diagnostico     = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'diagnostico') x), arr::text[]),
    diagnostico_obs = nullif(btrim(p ->> 'diagnostico_obs'), ''),
    evolucao        = nullif(btrim(p ->> 'evolucao'), ''),
    orientacoes     = coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'orientacoes') x), arr::text[]),
    orientacoes_obs = nullif(btrim(p ->> 'orientacoes_obs'), ''),
    retorno_em      = nullif(p ->> 'retorno_em', '')::date,
    retorno_obs     = nullif(btrim(p ->> 'retorno_obs'), ''),
    odontograma     = coalesce(p -> 'odontograma', odontograma),
    status          = case when p_finalizar then 'finalizado'::public.status_atendimento else status end,
    finalizado_em   = case when p_finalizar then now() else finalizado_em end,
    finalizado_por  = case when p_finalizar then auth.uid() else finalizado_por end
  where id = p_atendimento;
end;
$$;

-- ─── Plano de tratamento ─────────────────────────────────────────────────────

-- Adiciona um procedimento ao plano do paciente (cria o plano se ainda não houver).
create or replace function public.adicionar_item_plano(
  p_pessoa uuid, p_procedimento uuid, p_valor bigint, p_dente text default null,
  p_atendimento uuid default null, p_status public.status_item_plano default 'orcado'
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_clinica uuid := (select clinica_id from public.pessoas where id = p_pessoa);
  v_orc     uuid;
  v_item    uuid;
begin
  if v_clinica is null or not public.pode_ver_prontuario(v_clinica) then
    raise exception 'Sem acesso ao prontuário.' using errcode = '42501';
  end if;
  if p_status = 'realizado' then
    raise exception 'Para marcar como realizado, use "Realizar" dentro da consulta.' using errcode = 'P0001';
  end if;
  if coalesce(p_valor, -1) < 0 then
    raise exception 'Informe o valor do procedimento.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.procedimentos where id = p_procedimento and clinica_id = v_clinica) then
    raise exception 'Escolha o procedimento.' using errcode = 'P0001';
  end if;
  select id into v_orc from public.orcamentos
   where pessoa_id = p_pessoa and origem = 'prontuario' and status not in ('recusado', 'expirado', 'substituido')
   order by criado_em desc limit 1;
  if v_orc is null then
    insert into public.orcamentos (clinica_id, pessoa_id, origem, status, apresentado_em, apresentado_por)
    values (v_clinica, p_pessoa, 'prontuario', 'apresentado', public.hoje_clinica(v_clinica),
            (select profissional_id from public.atendimentos where id = p_atendimento))
    returning id into v_orc;
  end if;
  insert into public.orcamento_itens (clinica_id, orcamento_id, procedimento_id, valor_unitario_centavos, dente,
                                      atendimento_id, status)
  values (v_clinica, v_orc, p_procedimento, p_valor, nullif(btrim(p_dente), ''), p_atendimento, p_status)
  returning id into v_item;
  return v_item;
end;
$$;

create or replace function public.mudar_status_item(p_item uuid, p_status public.status_item_plano)
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
  if p_status = 'realizado' then
    raise exception 'Para marcar como realizado, use "Realizar" dentro da consulta.' using errcode = 'P0001';
  end if;
  if i.status = 'realizado' then
    raise exception 'Este procedimento já foi realizado (consulta registrada).' using errcode = 'P0001';
  end if;
  update public.orcamento_itens set status = p_status where id = p_item;
end;
$$;

-- Realizado nesta consulta + como ficou o pagamento (no Financeiro existente).
-- p_cobranca: 'pago' | 'parcial' (p_pago_agora + o resto na data prevista) | 'a_pagar'
--             | 'ja_registrado' (p_venda: negociação que já está no Financeiro) | 'sem_cobranca'
create or replace function public.realizar_item(
  p_item        uuid,
  p_atendimento uuid,
  p_cobranca    text,
  p_valor       bigint default null,
  p_forma       uuid default null,
  p_pago_agora  bigint default null,
  p_vencimento  date default null,
  p_parcelas    int default 1,
  p_venda       uuid default null,
  p_observacao  text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  i        public.orcamento_itens;
  a        public.atendimentos;
  f        public.formas_pagamento;
  v_pessoa uuid;
  v_hoje   date;
  v_valor  bigint;
  v_neg    jsonb;
  v_venda  uuid;
  x        record;
begin
  select * into i from public.orcamento_itens where id = p_item for update;
  select * into a from public.atendimentos where id = p_atendimento;
  if i.id is null or a.id is null or not public.pode_ver_prontuario(i.clinica_id) then
    raise exception 'Procedimento ou consulta não encontrados.' using errcode = 'P0002';
  end if;
  select pessoa_id into v_pessoa from public.orcamentos where id = i.orcamento_id;
  if v_pessoa <> a.pessoa_id then
    raise exception 'O procedimento não é deste paciente.' using errcode = 'P0001';
  end if;
  if a.status = 'finalizado' then
    raise exception 'Esta consulta foi finalizada e não pode ser alterada.' using errcode = 'P0001';
  end if;
  if i.status = 'realizado' then
    raise exception 'Este procedimento já foi realizado.' using errcode = 'P0001';
  end if;
  if i.status in ('cancelado', 'nao_realizado') then
    raise exception 'Este procedimento está como %. Volte para pendente antes de realizar.',
      case i.status when 'cancelado' then 'cancelado' else 'não realizado' end using errcode = 'P0001';
  end if;
  if p_cobranca not in ('pago', 'parcial', 'a_pagar', 'ja_registrado', 'sem_cobranca') then
    raise exception 'Escolha como ficou o pagamento.' using errcode = 'P0001';
  end if;
  v_hoje := public.hoje_clinica(i.clinica_id);
  v_valor := coalesce(p_valor, i.quantidade * i.valor_unitario_centavos - i.desconto_centavos);

  if p_cobranca = 'ja_registrado' then
    if not exists (select 1 from public.vendas where id = p_venda and pessoa_id = v_pessoa and status = 'ativa') then
      raise exception 'Escolha a negociação do Financeiro.' using errcode = 'P0001';
    end if;
    v_venda := p_venda;
  elsif p_cobranca <> 'sem_cobranca' then
    if not public.pode_ver_financeiro(i.clinica_id) then
      raise exception 'Seu acesso não inclui o financeiro.' using errcode = '42501';
    end if;
    if coalesce(v_valor, 0) <= 0 then
      raise exception 'Informe o valor.' using errcode = 'P0001';
    end if;
    select * into f from public.formas_pagamento where id = p_forma and clinica_id = i.clinica_id and ativo;
    if f.id is null then
      raise exception 'Escolha a forma de pagamento.' using errcode = 'P0001';
    end if;
    if p_cobranca = 'parcial' and not f.recebe_na_hora
       and (coalesce(p_pago_agora, 0) <= 0 or p_pago_agora >= v_valor) then
      raise exception 'Informe quanto foi pago agora (menos que o valor total).' using errcode = 'P0001';
    end if;
    if p_cobranca in ('parcial', 'a_pagar') and not f.recebe_na_hora then
      if p_vencimento is null then
        raise exception 'Informe a data prevista do pagamento.' using errcode = 'P0001';
      end if;
      if p_vencimento < v_hoje then
        raise exception 'A data prevista não pode estar no passado.' using errcode = 'P0001';
      end if;
    end if;
    if p_cobranca = 'pago' and not f.recebe_na_hora and coalesce(p_parcelas, 1) > 1 then
      raise exception 'Pago agora em % é uma parcela só. Para parcelar, escolha "Não pago" ou "Pagamento parcial".', f.nome
        using errcode = 'P0001';
    end if;

    v_neg := public.registrar_negociacao(
      i.clinica_id, v_pessoa, i.procedimento_id, v_valor, 0,
      case when p_cobranca = 'parcial' and not f.recebe_na_hora then p_pago_agora else 0 end,
      v_hoje, f.id,
      greatest(coalesce(p_parcelas, 1), 1),
      case when p_cobranca in ('parcial', 'a_pagar') then coalesce(p_vencimento, v_hoje) else v_hoje end,
      f.id,
      coalesce(nullif(btrim(p_observacao), ''), 'Prontuário: consulta ' || lpad(a.numero::text, 2, '0') || ' de '
                                                  || to_char(a.data, 'DD/MM/YYYY')));
    v_venda := (v_neg ->> 'venda_id')::uuid;
    update public.vendas set procedimento_id = i.procedimento_id where id = v_venda;
    -- Pago agora: quita tudo; parcial: quita a parte paga hoje (a "entrada").
    for x in select id from public.parcelas
              where venda_id = v_venda and status in ('pendente', 'parcial')
                and (p_cobranca = 'pago' or (p_cobranca = 'parcial' and numero = 0))
    loop
      perform public.registrar_pagamento(x.id, null, v_hoje, f.id, null);
    end loop;
  end if;

  update public.orcamento_itens
     set status = 'realizado', realizado_atendimento_id = a.id, realizado_em = a.data, venda_id = v_venda,
         valor_unitario_centavos = case when p_valor is not null and quantidade = 1 and desconto_centavos = 0
                                        then p_valor else valor_unitario_centavos end
   where id = p_item;

  return jsonb_build_object('venda_id', v_venda,
    'situacao', (select situacao from public.v_financeiro_negociacoes where id = v_venda));
end;
$$;

-- Negociações do paciente no Financeiro (para ligar um procedimento a um pagamento já registrado).
create or replace function public.negociacoes_do_paciente(p_pessoa uuid)
returns table (id uuid, descricao text, situacao text)
language sql
stable
set search_path = public
as $$
  select n.id,
         coalesce(n.procedimento, 'Sem procedimento') || ' — ' || public.formatar_brl(n.valor_final_centavos)
           || ' · ' || to_char(n.fechada_em, 'DD/MM/YYYY'),
         n.situacao
    from public.v_financeiro_negociacoes n
   where n.pessoa_id = p_pessoa and n.tipo = 'venda'
   order by n.fechada_em desc
   limit 20;
$$;

revoke execute on function public.criar_prontuario() from public, anon, authenticated;
revoke execute on function public.numerar_atendimento() from public, anon, authenticated;
revoke execute on function public.criar_atendimento(uuid, date, time, uuid, public.tipo_agendamento, uuid, uuid) from anon;
revoke execute on function public.abrir_atendimento(uuid) from anon;
revoke execute on function public.novo_atendimento(uuid, uuid) from anon;
revoke execute on function public.salvar_atendimento(uuid, jsonb, boolean) from anon;
revoke execute on function public.adicionar_item_plano(uuid, uuid, bigint, text, uuid, public.status_item_plano) from anon;
revoke execute on function public.mudar_status_item(uuid, public.status_item_plano) from anon;
revoke execute on function public.realizar_item(uuid, uuid, text, bigint, uuid, bigint, date, int, uuid, text) from anon;
revoke execute on function public.negociacoes_do_paciente(uuid) from anon;
