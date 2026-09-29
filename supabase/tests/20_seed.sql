-- Mostra as tarefas geradas pelos dados fictícios (conferência visual).
\set ON_ERROR_STOP 1
\echo '— Tarefas abertas geradas pelos dados fictícios (seed)'
select format('  %s | %s | %s | %s', to_char(vence_em, 'DD/MM'), tipo, prioridade, titulo)
  from public.v_tarefas_abertas t
  join public.clinicas c on c.id = t.clinica_id and c.nome = 'Instituto CG'
 order by vence_em, prioridade \g (tuples_only=on format=unaligned)
