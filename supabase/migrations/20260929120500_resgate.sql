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
security definer
set search_path = public
as $$
declare
  v_pessoa public.pessoas;
  v_hoje   date;
  v_trat   record;
  v_id     uuid;
begin
  select * into v_pessoa from public.pessoas where id = p_pessoa;
  if v_pessoa.id is null or (auth.uid() is not null and v_pessoa.clinica_id not in (select public.minhas_clinicas())) then
    raise exception 'Cadastro não encontrado.' using errcode = 'P0002';
  end if;
  if v_pessoa.nao_contatar or not v_pessoa.consentimento_contato or v_pessoa.arquivado_em is not null then
    raise exception 'Esta pessoa não deseja receber contatos.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.oportunidades where pessoa_id = p_pessoa and status in ('aberta', 'pausada')) then
    raise exception 'Já existe uma negociação em andamento; use a próxima ação dela.' using errcode = 'P0001';
  end if;

  v_hoje := public.hoje_clinica(v_pessoa.clinica_id);

  -- Tratamento anterior com ciclo de retorno (o mais recente).
  select pr.id, pr.nome, ta.realizado_em into v_trat
    from public.tratamentos_anteriores ta
    join public.procedimentos pr on pr.id = ta.procedimento_id and pr.ciclo_retorno_meses is not null
   where ta.pessoa_id = p_pessoa
   order by ta.realizado_em desc nulls last
   limit 1;

  -- O resgate abre uma negociação na coluna "Reativação" do funil.
  if v_trat.nome is not null then
    v_id := public.abrir_reativacao(
      p_pessoa, null, v_trat.id, 'manutencao',
      'Lembrar ' || split_part(v_pessoa.nome, ' ', 1) || ' da manutenção',
      lower(v_trat.nome) || coalesce(' em ' || to_char(v_trat.realizado_em, 'MM/YYYY'), ''),
      v_hoje, 'R-RES-10', public.renderizar_mensagem(v_pessoa.clinica_id, 'manutencao', p_pessoa, v_trat.nome));
  else
    v_id := public.abrir_reativacao(
      p_pessoa, null, null, 'reativacao',
      'Reativar contato com ' || split_part(v_pessoa.nome, ' ', 1),
      'Paciente antigo' || coalesce(', último atendimento em ' || to_char(v_pessoa.ultimo_atendimento_informado, 'MM/YYYY'), ''),
      v_hoje, 'R-RES-11');
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
