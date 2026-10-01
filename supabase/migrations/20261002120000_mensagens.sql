-- =============================================================================
-- Migração 10: biblioteca de mensagens prontas
--   • variaveis_pessoa() / variaveis_tarefa(): os dados que preenchem {{nome}},
--     {{procedimento}}, {{data}}, {{dentista}}, {{valor}}, {{vencimento}}…
--   • chave_mensagem_tarefa(): a situação da tarefa (pagamentos mudam conforme o atraso:
--     previsto → cobrança amigável → pagamento pendente).
--   • sugestoes_mensagem(tarefa): a biblioteca inteira preenchida para a tarefa, com a
--     recomendada primeiro. Nada é enviado: a usuária copia, adapta e envia.
--   • mensagens_para_pessoa(pessoa): a biblioteca preenchida para um paciente.
-- =============================================================================

-- Dados do paciente: negociação em andamento, próxima consulta e parcela em aberto.
create or replace function public.variaveis_pessoa(p_pessoa uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'procedimento', (select pr.nome from public.oportunidades o join public.procedimentos pr on pr.id = o.procedimento_id
                      where o.pessoa_id = p_pessoa order by (o.status in ('aberta', 'pausada')) desc, o.criado_em desc limit 1),
    'consulta', public.rotulo_consulta(ag.tipo),
    'data', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'DD/MM'),
    'horario', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'dentista', pf.nome,
    'valor', public.formatar_brl(pa.valor_centavos - pa.valor_pago_centavos),
    'vencimento', to_char(pa.vencimento, 'DD/MM')))
  from (select 1) x
  left join lateral (
    select a.* from public.agendamentos a where a.pessoa_id = p_pessoa
     order by (a.status in ('agendado', 'confirmado') and a.inicio >= now()) desc, a.inicio desc limit 1
  ) ag on true
  left join public.profissionais pf on pf.id = ag.profissional_id
  left join lateral (
    select p.* from public.parcelas p where p.pessoa_id = p_pessoa and p.status in ('pendente', 'parcial')
     order by p.vencimento limit 1
  ) pa on true;
$$;

-- Dados da tarefa (a consulta, a parcela e o procedimento dela), completados pelos do paciente.
create or replace function public.variaveis_tarefa(p_tarefa uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.variaveis_pessoa(t.pessoa_id) || jsonb_strip_nulls(jsonb_build_object(
    'procedimento', coalesce(pr.nome, pa_ag.nome),
    'consulta', public.rotulo_consulta(ag.tipo),
    'data', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'DD/MM'),
    'horario', to_char(ag.inicio at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'dentista', pf.nome,
    'valor', public.formatar_brl(pa.valor_centavos - pa.valor_pago_centavos),
    'vencimento', to_char(pa.vencimento, 'DD/MM')))
  from public.tarefas t
  left join public.oportunidades o on o.id = t.oportunidade_id
  left join public.procedimentos pr on pr.id = o.procedimento_id
  left join public.agendamentos ag on ag.id = t.agendamento_id
  left join public.procedimentos pa_ag on pa_ag.id = ag.procedimento_id
  left join public.profissionais pf on pf.id = ag.profissional_id
  left join public.parcelas pa on pa.id = t.parcela_id
  where t.id = p_tarefa;
$$;

-- Situação da mensagem para a tarefa. Pagamento: até o vencimento "previsto"; até 7 dias
-- de atraso "cobrança amigável"; depois "pagamento pendente".
create or replace function public.chave_mensagem_tarefa(t public.tarefas)
returns text
language sql
stable
set search_path = public
as $$
  select case
    when t.tipo = 'confirmar_pagamento' then
      case when (select p.vencimento from public.parcelas p where p.id = t.parcela_id) >= public.hoje_clinica(t.clinica_id)
             then 'confirmar_pagamento'
           when public.hoje_clinica(t.clinica_id) - (select p.vencimento from public.parcelas p where p.id = t.parcela_id) <= 7
             then 'cobranca_amigavel'
           else 'pagamento_pendente' end
    when t.regra in ('pos_tratamento', 'clinica_cancelou') then t.regra
    when t.regra = 'campanha' then 'reativacao'
    else t.tipo::text
  end;
$$;

-- A biblioteca preenchida para a tarefa; a recomendada vem primeiro, depois as da mesma
-- categoria, depois as demais.
create or replace function public.sugestoes_mensagem(p_tarefa uuid)
returns table (modelo_id uuid, titulo text, categoria text, procedimento text, texto text,
               recomendada boolean, mesma_categoria boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t       public.tarefas;
  v_chave text;
  v_cat   text;
  v_proc  text;
  v_vars  jsonb;
  v_rec   uuid;
begin
  select * into t from public.tarefas where id = p_tarefa;
  if t.id is null or (auth.uid() is not null and t.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Tarefa não encontrada.' using errcode = 'P0002';
  end if;
  v_chave := public.chave_mensagem_tarefa(t);
  v_cat := public.categoria_mensagem(v_chave);
  v_vars := public.variaveis_tarefa(t.id);
  v_proc := v_vars ->> 'procedimento';
  v_rec := (public.escolher_modelo(t.clinica_id, v_chave, v_proc)).id;

  return query
  select m.id, m.titulo, m.categoria, pr.nome,
         public.renderizar_texto(m.texto, t.pessoa_id, v_proc, v_vars),
         m.id = v_rec, m.categoria = v_cat
    from public.modelos_mensagem m
    left join public.procedimentos pr on pr.id = m.procedimento_id
   where m.clinica_id = t.clinica_id and m.ativo
   order by m.id = v_rec desc, m.categoria = v_cat desc, m.categoria, m.padrao desc, m.titulo;
end;
$$;

-- A biblioteca preenchida para um paciente (tela Mensagens → "Preencher para").
create or replace function public.mensagens_para_pessoa(p_pessoa uuid)
returns table (modelo_id uuid, texto text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
  v_vars   jsonb;
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null or (auth.uid() is not null and v_pessoa.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Cadastro não encontrado.' using errcode = 'P0002';
  end if;
  v_vars := public.variaveis_pessoa(p_pessoa);
  return query
  select m.id, public.renderizar_texto(m.texto, p_pessoa, v_vars ->> 'procedimento', v_vars)
    from public.modelos_mensagem m
   where m.clinica_id = v_pessoa.clinica_id and m.ativo;
end;
$$;

-- Tornar um modelo o padrão da categoria desmarca o padrão anterior (mesmo procedimento).
create or replace function public.um_padrao_por_categoria()
returns trigger
language plpgsql
as $$
begin
  if new.padrao and new.ativo then
    update public.modelos_mensagem
       set padrao = false
     where clinica_id = new.clinica_id and categoria = new.categoria and id <> new.id and padrao
       and procedimento_id is not distinct from new.procedimento_id;
  end if;
  return new;
end;
$$;

create trigger um_padrao_por_categoria
  before insert or update of padrao, ativo, categoria, procedimento_id on public.modelos_mensagem
  for each row execute function public.um_padrao_por_categoria();

revoke execute on function public.variaveis_pessoa(uuid) from public, anon, authenticated;
revoke execute on function public.variaveis_tarefa(uuid) from public, anon, authenticated;
revoke execute on function public.escolher_modelo(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.sugestoes_mensagem(uuid) from anon;
revoke execute on function public.mensagens_para_pessoa(uuid) from anon;
