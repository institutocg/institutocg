-- =============================================================================
-- Migração 6: resgate de pacientes antigos sob demanda
--   criar_resgate(pessoa) cria, na hora, a tarefa de contato para um paciente
--   antigo: "manutenção" quando algum tratamento anterior tem ciclo de retorno
--   (ex.: limpeza a cada 6 meses), senão "reativação". Funciona mesmo com a
--   reativação automática desligada (recadastramento).
-- =============================================================================

create or replace function public.criar_resgate(p_pessoa uuid)
returns uuid
language plpgsql
as $$
declare
  v_pessoa public.pessoas;
  v_hoje   date;
  v_trat   record;
  v_id     uuid;
begin
  -- Leitura com RLS: só encontra pessoas da própria clínica.
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null then
    raise exception 'Cadastro não encontrado.' using errcode = 'P0002';
  end if;
  if v_pessoa.nao_contatar or not v_pessoa.consentimento_contato or v_pessoa.arquivado_em is not null then
    raise exception 'Esta pessoa não deseja receber contatos.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.oportunidades where pessoa_id = p_pessoa and status in ('aberta', 'pausada')) then
    raise exception 'Já existe uma negociação em andamento; use a próxima ação dela.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.tarefas where chave_dedupe = 'pessoa:' || p_pessoa and status = 'pendente') then
    raise exception 'Já existe uma tarefa de resgate pendente para esta pessoa.' using errcode = 'P0001';
  end if;

  v_hoje := public.hoje_clinica(v_pessoa.clinica_id);

  -- Tratamento anterior com ciclo de retorno (o mais recente).
  select pr.nome, ta.realizado_em into v_trat
    from public.tratamentos_anteriores ta
    join public.procedimentos pr on pr.id = ta.procedimento_id and pr.ciclo_retorno_meses is not null
   where ta.pessoa_id = p_pessoa
   order by ta.realizado_em desc nulls last
   limit 1;

  if v_trat.nome is not null then
    v_id := public.criar_tarefa_auto(
      p_pessoa, null, 'manutencao', 'reativacao',
      'Lembrar ' || split_part(v_pessoa.nome, ' ', 1) || ' da manutenção', v_hoje, 'normal', 'R-RES-10',
      'pessoa:' || p_pessoa,
      p_descricao => lower(v_trat.nome) || coalesce(' em ' || to_char(v_trat.realizado_em, 'MM/YYYY'), ''),
      p_mensagem => public.renderizar_mensagem(v_pessoa.clinica_id, 'manutencao', p_pessoa, v_trat.nome));
  else
    v_id := public.criar_tarefa_auto(
      p_pessoa, null, 'reativacao', 'reativacao',
      'Reativar contato com ' || split_part(v_pessoa.nome, ' ', 1), v_hoje, 'normal', 'R-RES-11',
      'pessoa:' || p_pessoa,
      p_descricao => 'Paciente antigo' || coalesce(', último atendimento em ' || to_char(v_pessoa.ultimo_atendimento_informado, 'MM/YYYY'), ''));
  end if;
  return v_id;
end;
$$;

revoke execute on function public.criar_resgate(uuid) from anon;

-- Busca sem acento ("joao" encontra "João").
create or replace function public.sem_acento(p_texto text)
returns text
language sql immutable parallel safe
as $$
  select lower(translate(p_texto,
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn'));
$$;

create index pessoas_nome_sem_acento on public.pessoas (clinica_id, public.sem_acento(nome));
