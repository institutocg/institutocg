-- =============================================================================
-- Instituto CG — ATUALIZAÇÃO da versão de teste: PRONTUÁRIO
--
-- Para quem já instalou a versão de teste antes do prontuário.
-- Antes, aplique atualizar-agenda-financeiro.sql (se ainda não aplicou).
-- Cole no SQL Editor do projeto de TESTE e clique em "Run" (uma vez só).
-- Depois, no sistema: Configurações → Versão de teste → "Recomeçar com dados de exemplo".
-- =============================================================================

begin;

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

  -- Consulta de hoje, com o valor do procedimento: para testar "Compareceu" + pagamento.
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, cidade, uf, origem_id)
  values (c, 'Renata Alves', '+5511900000016', 'São Paulo', 'SP',
          (select id from public.origens where clinica_id = c and nome = 'Indicação de paciente'))
  returning id into p;
  insert into public.agendamentos (clinica_id, pessoa_id, profissional_id, tipo, procedimento_id, inicio, duracao_min,
                                   status, confirmado_em, valor_centavos)
  values (c, p, (select id from public.profissionais where clinica_id = c and nome = 'Dra. Lívia Moraes'), 'procedimento',
          (select id from public.procedimentos where clinica_id = c and nome = 'Clareamento dental'),
          (hoje + time '08:30') at time zone 'America/Sao_Paulo', 60, 'confirmado', now(), 180000);
  update public.agendamentos set valor_centavos = 350000
   where clinica_id = c and pessoa_id = (select id from public.pessoas where clinica_id = c and nome = 'Ana Costa');

  -- Prontuário da Maria: consulta 01 (avaliação, finalizada) com odontograma e plano de tratamento.
  insert into public.atendimentos (clinica_id, prontuario_id, pessoa_id, profissional_id, data, horario, tipo, procedimento_id,
                                   motivo, anamnese, anamnese_obs, diagnostico, evolucao, orientacoes, retorno_em, odontograma,
                                   status, finalizado_em)
  select c, pr.id, pr.pessoa_id, prof, hoje - 14, time '10:00', 'avaliacao',
         (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'),
         array['Avaliação', 'Estética'], array['Hipertensão'], 'Losartana 50 mg.', array['Manchas / escurecimento', 'Desgaste dental'],
         'Avaliação estética completa. Limpeza realizada. Planejado clareamento e facetas.',
         array['Higiene oral reforçada', 'Evitar alimentos com corante'], hoje + 7,
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
     'aceito', null, null),
    (c, orc, (select id from public.procedimentos where clinica_id = c and nome = 'Facetas de porcelana'), 1400000, '13 a 23', v,
     'orcado', null, null);

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
