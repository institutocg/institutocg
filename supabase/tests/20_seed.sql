-- Confere se os dados fictícios alimentam o painel "O que eu tenho que fazer hoje?".
\set ON_ERROR_STOP 1
\echo '— Painel com os dados fictícios (seed)'
select format('  %s | %s', situacao_prazo, texto_painel)
  from public.v_painel_tarefas p
  join public.clinicas c on c.id = p.clinica_id and c.nome = 'Instituto CG'
 order by ordem_prioridade, vence_em \g (tuples_only=on format=unaligned)
