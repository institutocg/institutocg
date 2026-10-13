-- =============================================================================
-- Testes do receituário: emitir, modelos, acesso e histórico preservado.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('rx', public.inicializar_clinica('Clínica do Receituário'));
insert into auth.users (email, raw_user_meta_data) values
  ('dra@rx.local', '{"nome": "Dra. Rx"}'), ('sec@rx.local', '{"nome": "Sec Rx"}'), ('sec2@rx.local', '{"nome": "Sec2 Rx"}');
select public.adicionar_membro(testes.v('rx'), 'dra@rx.local', 'admin');
select public.adicionar_membro(testes.v('rx'), 'sec@rx.local', 'comercial');
select public.adicionar_membro(testes.v('rx'), 'sec2@rx.local', 'comercial');
update public.membros set pode_ver_prontuario = true
 where usuario_id = (select id from public.usuarios where email = 'sec2@rx.local');
with x as (
  insert into public.pessoas (clinica_id, nome, whatsapp_e164) values (testes.v('rx'), 'Paula Receita', '+5511900004001') returning id
) select testes.guardar('rx_pac', id) from x;
select testes.guardar('rx_prof', (select id from public.profissionais where clinica_id = testes.v('rx') limit 1));
update public.profissionais set cro = 'CRO-SP 12345', especialidade = 'Cirurgiã-dentista' where id = testes.v('rx_prof');
grant execute on all functions in schema testes to authenticated, anon;

reset role; select testes.entrar('dra@rx.local'); set role authenticated;

\echo '— Emitir'
select testes.guardar('rx1', public.criar_receita(testes.v('rx_pac'), testes.v('rx_prof'), 'simples', 2, testes.hoje(),
  '[{"medicamento": " Amoxicilina 500 mg ", "quantidade": "21 cápsulas", "uso": "oral", "posologia": "Tomar 1 cápsula de 8 em 8 horas por 7 dias."},
    {"medicamento": "", "quantidade": "", "posologia": ""},
    {"medicamento": "Clorexidina 0,12%", "quantidade": "1 frasco", "uso": "xyz", "posologia": "Bochechar 15 ml de 12 em 12 horas."}]',
  'Evitar alimentos quentes nas primeiras 24 horas.', null, 'Pós-extração'));
select testes.ok((select jsonb_array_length(itens) = 2 and itens->0->>'medicamento' = 'Amoxicilina 500 mg'
                         and itens->1->>'uso' = 'oral' and vias = 2 and profissional_cro = 'CRO-SP 12345'
                    from public.v_receitas where id = testes.v('rx1')),
  'receita emitida: linhas vazias ignoradas, textos limpos, 2 vias, com o CRO da dentista');
select testes.ok((select tipo = 'simples' and jsonb_array_length(itens) = 2 from public.receita_modelos
                   where clinica_id = testes.v('rx') and nome = 'Pós-extração'),
  'guardada também como modelo');
select testes.guardar('rx2', public.criar_receita(testes.v('rx_pac'), testes.v('rx_prof'),
  'controle_especial', 1, testes.hoje(), '[{"medicamento": "Tramadol 50 mg", "quantidade": "10 comprimidos"}]'));
select testes.ok((select vias = 2 from public.receitas where id = testes.v('rx2')),
  'controle especial sempre em 2 vias');
select testes.erro($$select public.criar_receita(testes.v('rx_pac'), testes.v('rx_prof'), 'simples', 1, testes.hoje(), '[{"medicamento": " "}]')$$,
  'ao menos um medicamento', 'sem medicamento não emite');
select testes.erro($$select public.criar_receita(testes.v('rx_pac'), null, 'simples', 1, testes.hoje(), '[{"medicamento": "Dipirona"}]')$$,
  'dentista que assina', 'precisa da dentista que assina');
select testes.erro($$select public.criar_receita(testes.v('rx_pac'), testes.v('rx_prof'), 'simples', 1, testes.hoje() + 90, '[{"medicamento": "Dipirona"}]')$$,
  'Confira a data', 'data muito no futuro é recusada');

\echo '— Histórico preservado'
do $$ begin
  begin update public.receitas set orientacoes = 'x' where id = testes.v('rx1'); exception when others then null; end;
  begin delete from public.receitas where id = testes.v('rx1'); exception when others then null; end;
end $$;
select testes.ok((select orientacoes like 'Evitar%' from public.receitas where id = testes.v('rx1')),
  'pelo sistema, a receita emitida não muda nem some');
reset role;
select testes.erro($$update public.receitas set orientacoes = 'x' where id = testes.v('rx1')$$, 'não são alteradas',
  'nem direto no banco: não muda');
select testes.erro($$delete from public.receitas where id = testes.v('rx1')$$, 'não são alteradas', 'nem é apagada');
select testes.entrar('dra@rx.local'); set role authenticated;
select testes.ok(exists (select 1 from public.auditoria where tabela = 'receitas' and registro_id = testes.v('rx1')),
  'emissão registrada na auditoria');

\echo '— Dados do receituário'
select public.salvar_dados_receituario(testes.v('rx'), '{"endereco": "Rua das Flores, 100", "telefone": "(11) 3333-4444", "cidade": "São Paulo - SP", "rodape": ""}');
select testes.ok((select configuracoes->'receituario'->>'cidade' = 'São Paulo - SP' and configuracoes->'receituario'->'rodape' = 'null'
                    from public.clinicas where id = testes.v('rx')),
  'administradora salva endereço, telefone e cidade');
reset role;

\echo '— Acesso'
select testes.entrar('sec@rx.local'); set role authenticated;
select testes.ok(not exists (select 1 from public.receitas) and not exists (select 1 from public.receita_modelos),
  'secretária sem acesso ao prontuário não vê receitas nem modelos');
select testes.erro($$select public.criar_receita(testes.v('rx_pac'), testes.v('rx_prof'), 'simples', 1, testes.hoje(), '[{"medicamento": "Dipirona"}]')$$,
  'não inclui o prontuário', 'nem emite');
select testes.erro($$select public.salvar_dados_receituario(testes.v('rx'), '{}')$$, 'Somente a administradora',
  'nem altera os dados do receituário');
reset role;
select testes.entrar('sec2@rx.local'); set role authenticated;
select testes.ok((select count(*) = 2 from public.receitas) and public.criar_receita(testes.v('rx_pac'), testes.v('rx_prof'), 'simples', 1,
                  testes.hoje(), '[{"medicamento": "Dipirona 500 mg"}]') is not null,
  'quem tem acesso ao prontuário vê e emite (a dentista assina)');
reset role;

\echo '✓ Receituário verificado.'
