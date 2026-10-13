-- =============================================================================
-- Migração 20: receituário
--   • Receitas dentro do prontuário de cada paciente (simples ou de controle
--     especial, em 1 ou 2 vias), assinadas por uma dentista (nome e CRO).
--   • Receita emitida não muda nem é apagada (pode ser reimpressa ou repetida).
--   • Modelos de receita da clínica (ex.: "Pós-extração") para não digitar tudo.
--   • Dados do cabeçalho/rodapé em clinicas.configuracoes->'receituario'
--     (endereço, telefone, cidade, rodapé) e o CRO em profissionais.cro.
--   • Acesso: o mesmo do prontuário (dado de saúde). Tudo auditado.
-- =============================================================================

alter table public.profissionais add column if not exists cro text check (length(cro) <= 30);
alter table public.profissionais add column if not exists especialidade text check (length(especialidade) <= 80);

create table public.receitas (
  id               uuid primary key default gen_random_uuid(),
  clinica_id       uuid not null references public.clinicas (id),
  pessoa_id        uuid not null,
  prontuario_id    uuid not null,
  atendimento_id   uuid references public.atendimentos (id),
  profissional_id  uuid,
  tipo             text not null default 'simples' check (tipo in ('simples', 'controle_especial')),
  vias             int not null default 1 check (vias in (1, 2)),
  data             date not null,
  -- [{ "medicamento": "Amoxicilina 500 mg", "quantidade": "21 cápsulas", "uso": "oral", "posologia": "..." }]
  itens            jsonb not null check (jsonb_typeof(itens) = 'array' and jsonb_array_length(itens) between 1 and 20),
  orientacoes      text check (length(orientacoes) <= 2000),
  criado_por       uuid default auth.uid(),
  criado_em        timestamptz not null default now(),
  unique (clinica_id, id),
  foreign key (clinica_id, pessoa_id) references public.pessoas (clinica_id, id),
  foreign key (clinica_id, prontuario_id) references public.prontuarios (clinica_id, id),
  foreign key (clinica_id, profissional_id) references public.profissionais (clinica_id, id),
  check (tipo = 'simples' or vias = 2)
);
create index receitas_pessoa on public.receitas (pessoa_id, data desc, criado_em desc);

create table public.receita_modelos (
  id             uuid primary key default gen_random_uuid(),
  clinica_id     uuid not null references public.clinicas (id),
  nome           text not null check (length(btrim(nome)) between 2 and 60),
  tipo           text not null default 'simples' check (tipo in ('simples', 'controle_especial')),
  itens          jsonb not null check (jsonb_typeof(itens) = 'array' and jsonb_array_length(itens) between 1 and 20),
  orientacoes    text check (length(orientacoes) <= 2000),
  criado_por     uuid default auth.uid(),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (clinica_id, nome)
);

-- Itens válidos: medicamento obrigatório; textos curtos.
create or replace function public.itens_receita_validos(p_itens jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  x   jsonb;
  out jsonb := '[]';
begin
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then
    raise exception 'Inclua ao menos um medicamento.' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_array_elements(p_itens) loop
    if coalesce(btrim(x->>'medicamento'), '') = '' then
      continue;
    end if;
    if length(x->>'medicamento') > 120 or length(coalesce(x->>'quantidade', '')) > 60
       or length(coalesce(x->>'posologia', '')) > 500 then
      raise exception 'Texto muito longo em um dos medicamentos.' using errcode = 'P0001';
    end if;
    out := out || jsonb_build_array(jsonb_build_object(
      'medicamento', btrim(x->>'medicamento'),
      'quantidade', coalesce(btrim(x->>'quantidade'), ''),
      'uso', case when x->>'uso' in ('oral', 'topico', 'sublingual', 'externo') then x->>'uso' else 'oral' end,
      'posologia', coalesce(btrim(x->>'posologia'), '')));
  end loop;
  if jsonb_array_length(out) = 0 then
    raise exception 'Inclua ao menos um medicamento.' using errcode = 'P0001';
  end if;
  if jsonb_array_length(out) > 20 then
    raise exception 'No máximo 20 medicamentos por receita.' using errcode = 'P0001';
  end if;
  return out;
end;
$$;

-- Emite a receita (quem tem acesso ao prontuário). Opcionalmente guarda como modelo.
create or replace function public.criar_receita(
  p_pessoa        uuid,
  p_profissional  uuid,
  p_tipo          text,
  p_vias          int,
  p_data          date,
  p_itens         jsonb,
  p_orientacoes   text default null,
  p_atendimento   uuid default null,
  p_salvar_modelo text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  pr      public.prontuarios;
  v_itens jsonb := public.itens_receita_validos(p_itens);
  v_id    uuid;
  v_orient text := nullif(btrim(coalesce(p_orientacoes, '')), '');
begin
  select * into pr from public.prontuarios where pessoa_id = p_pessoa;
  if pr.id is null or not public.pode_ver_prontuario(pr.clinica_id) then
    raise exception 'Seu acesso não inclui o prontuário.' using errcode = '42501';
  end if;
  if p_profissional is null or not exists (select 1 from public.profissionais
                                            where id = p_profissional and clinica_id = pr.clinica_id) then
    raise exception 'Escolha a dentista que assina a receita.' using errcode = 'P0001';
  end if;
  if p_tipo not in ('simples', 'controle_especial') then
    raise exception 'Tipo de receita inválido.' using errcode = 'P0001';
  end if;
  if p_data is null or p_data > public.hoje_clinica(pr.clinica_id) + 30 or p_data < public.hoje_clinica(pr.clinica_id) - 365 then
    raise exception 'Confira a data da receita.' using errcode = 'P0001';
  end if;
  if p_atendimento is not null and not exists (select 1 from public.atendimentos where id = p_atendimento and pessoa_id = p_pessoa) then
    raise exception 'Consulta inválida.' using errcode = 'P0001';
  end if;

  insert into public.receitas (clinica_id, pessoa_id, prontuario_id, atendimento_id, profissional_id, tipo, vias, data,
                               itens, orientacoes)
  values (pr.clinica_id, p_pessoa, pr.id, p_atendimento, p_profissional, p_tipo,
          case when p_tipo = 'controle_especial' then 2 else greatest(1, least(coalesce(p_vias, 1), 2)) end,
          p_data, v_itens, v_orient)
  returning id into v_id;

  if nullif(btrim(coalesce(p_salvar_modelo, '')), '') is not null then
    insert into public.receita_modelos (clinica_id, nome, tipo, itens, orientacoes)
    values (pr.clinica_id, btrim(p_salvar_modelo), p_tipo, v_itens, v_orient)
    on conflict (clinica_id, nome) do update
      set tipo = excluded.tipo, itens = excluded.itens, orientacoes = excluded.orientacoes, atualizado_em = now();
  end if;
  return v_id;
end;
$$;

-- Receita emitida não muda nem é apagada.
create or replace function public.proteger_receita()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Receitas emitidas não são alteradas nem apagadas. Emita uma nova, se precisar.' using errcode = 'P0001';
end;
$$;

create trigger proteger_receita before update or delete on public.receitas
  for each row execute function public.proteger_receita();
create trigger definir_atualizado_em before update on public.receita_modelos
  for each row execute function public.definir_atualizado_em();

alter table public.receitas enable row level security;
alter table public.receita_modelos enable row level security;

create policy receita_ler on public.receitas for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy receita_inserir on public.receitas for insert to authenticated
  with check (public.pode_ver_prontuario(clinica_id));
create policy modelo_ler on public.receita_modelos for select to authenticated
  using (public.pode_ver_prontuario(clinica_id));
create policy modelo_inserir on public.receita_modelos for insert to authenticated
  with check (public.pode_ver_prontuario(clinica_id));
create policy modelo_alterar on public.receita_modelos for update to authenticated
  using (public.pode_ver_prontuario(clinica_id)) with check (public.pode_ver_prontuario(clinica_id));
create policy modelo_apagar on public.receita_modelos for delete to authenticated
  using (public.pode_ver_prontuario(clinica_id));

grant select, insert on public.receitas to authenticated;
grant select, insert, update, delete on public.receita_modelos to authenticated;

create trigger auditoria after insert or update or delete on public.receitas
  for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.receita_modelos
  for each row execute function public.registrar_auditoria();

-- Leitura para a lista e a impressão.
create view public.v_receitas with (security_invoker = true) as
select
  r.id, r.clinica_id, r.pessoa_id, r.atendimento_id, a.numero as atendimento_numero,
  r.profissional_id, pf.nome as profissional, pf.cro as profissional_cro, pf.especialidade as profissional_especialidade,
  r.tipo, r.vias, r.data, r.itens, r.orientacoes, r.criado_em
from public.receitas r
left join public.atendimentos a on a.id = r.atendimento_id
left join public.profissionais pf on pf.id = r.profissional_id;

-- Dados do receituário (cabeçalho e rodapé). Somente a administradora.
create or replace function public.salvar_dados_receituario(p_clinica uuid, p_dados jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.eh_admin(p_clinica) then
    raise exception 'Somente a administradora altera os dados do receituário.' using errcode = '42501';
  end if;
  update public.clinicas
     set configuracoes = configuracoes || jsonb_build_object('receituario', jsonb_build_object(
           'endereco', left(nullif(btrim(p_dados->>'endereco'), ''), 200),
           'telefone', left(nullif(btrim(p_dados->>'telefone'), ''), 60),
           'cidade',   left(nullif(btrim(p_dados->>'cidade'), ''), 80),
           'rodape',   left(nullif(btrim(p_dados->>'rodape'), ''), 200)))
   where id = p_clinica;
end;
$$;

revoke execute on function public.criar_receita(uuid, uuid, text, int, date, jsonb, text, uuid, text) from public, anon;
revoke execute on function public.salvar_dados_receituario(uuid, jsonb) from public, anon;
revoke execute on function public.itens_receita_validos(jsonb) from public, anon;
grant execute on function public.criar_receita(uuid, uuid, text, int, date, jsonb, text, uuid, text) to authenticated;
grant execute on function public.salvar_dados_receituario(uuid, jsonb) to authenticated;
grant execute on function public.itens_receita_validos(jsonb) to authenticated;

-- Ninguém sem login chama funções nem lê tabelas (como na migração de segurança).
revoke execute on all functions in schema public from public, anon;
revoke all on public.receitas, public.receita_modelos, public.v_receitas from anon;
