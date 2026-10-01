-- =============================================================================
-- Testes dos indicadores comerciais e de marketing.
-- =============================================================================

\set ON_ERROR_STOP 1
\o /dev/null

select testes.guardar('ic', public.inicializar_clinica('Clínica dos Indicadores'));
insert into auth.users (email, raw_user_meta_data) values ('sec@ind.local', '{"nome": "Secretária Ind"}');
select public.adicionar_membro(testes.v('ic'), 'sec@ind.local', 'comercial');

create function testes.org(n text) returns uuid language sql as
  $$ select id from public.origens where clinica_id = testes.v('ic') and nome = n $$;
create function testes.proc_i(n text) returns uuid language sql as
  $$ select id from public.procedimentos where clinica_id = testes.v('ic') and nome = n $$;
create function testes.et_i(m text) returns uuid language sql as
  $$ select id from public.etapas_funil where clinica_id = testes.v('ic') and (marco = m or resultado::text = m) $$;
create function testes.mot_i(n text) returns uuid language sql as
  $$ select id from public.motivos where clinica_id = testes.v('ic') and nome = n limit 1 $$;
-- Lead: pessoa + negociação (origem, procedimento, etapa inicial).
create function testes.lead(nome text, fone text, origem text, proc text, marco text default 'novo_contato') returns uuid
language plpgsql as $$
declare p uuid; o uuid;
begin
  insert into public.pessoas (clinica_id, nome, whatsapp_e164, origem_id) values (testes.v('ic'), nome, fone, testes.org(origem))
  returning id into p;
  insert into public.oportunidades (clinica_id, pessoa_id, procedimento_id, origem_id, etapa_id)
  values (testes.v('ic'), p, testes.proc_i(proc), testes.org(origem), testes.et_i(marco)) returning id into o;
  return o;
end $$;
create function testes.ind(de date, ate date, proc uuid default null) returns jsonb language sql as
  $$ select public.indicadores(testes.v('ic'), de, ate, proc) $$;
grant execute on all functions in schema testes to authenticated, anon;

-- Cenário (como sistema): 5 leads no período, 1 fora do período, 1 reativação e 1 paciente inativo.
select testes.guardar('l1', testes.lead('Lia Fechou', '+5511970000001', 'Instagram', 'Facetas de porcelana'));
select testes.guardar('l2', testes.lead('Leo Negocia', '+5511970000002', 'Google', 'Implantes'));
select testes.guardar('l3', testes.lead('Lua Sumiu', '+5511970000003', 'WhatsApp', 'Facetas de porcelana'));
select testes.guardar('l4', testes.lead('Lis Caro', '+5511970000004', 'Instagram', 'Clareamento dental'));
select testes.guardar('l5', testes.lead('Ian Outro', '+5511970000005', 'Indicação de paciente', 'Implantes'));
select testes.guardar('l6', testes.lead('Old Antigo', '+5511970000006', 'Google', 'Implantes'));
update public.oportunidades set criado_em = now() - interval '200 days' where id = testes.v('l6');

-- L1: agendou, compareceu, recebeu orçamento e fechou.
insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, tipo, inicio, status)
select testes.v('ic'), pessoa_id, id, 'avaliacao', now() - interval '1 day', 'compareceu' from public.oportunidades where id = testes.v('l1');
insert into public.orcamentos (clinica_id, pessoa_id, oportunidade_id, status, valor_total_centavos, apresentado_em)
select testes.v('ic'), pessoa_id, id, 'apresentado', 500000, testes.hoje() from public.oportunidades where id = testes.v('l1');
select public.mover_etapa(testes.v('l1'), testes.et_i('fechou'));
-- L2: agendou (ainda não foi) — segue em negociação.
insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, tipo, inicio)
select testes.v('ic'), pessoa_id, id, 'avaliacao', now() + interval '3 days' from public.oportunidades where id = testes.v('l2');
-- L3: parou de responder.
select public.mover_etapa(testes.v('l3'), testes.et_i('sem_resposta'));
-- L4: não fechou por preço; L5: desistiu porque fez em outro lugar.
select public.mover_etapa(testes.v('l4'), testes.et_i('nao_fechou'), null, testes.mot_i('Valor alto'));
select public.mover_etapa(testes.v('l5'), testes.et_i('desistiu'), null, testes.mot_i('Fez o tratamento em outro lugar'));
-- Reativação: paciente antigo que respondeu e agendou.
with x as (
  insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, origem_id, ultimo_atendimento_informado)
  values (testes.v('ic'), 'paciente_antigo', 'Rui Volta', '+5511970000007', testes.org('Paciente antigo'), testes.hoje() - 500)
  returning id
) select testes.guardar('rui', id) from x;
select testes.guardar('t_rui', public.abrir_reativacao(testes.v('rui'), null, null, 'reativacao', 'Reativar Rui', null, testes.hoje(), 'campanha'));
select public.mover_etapa((select oportunidade_id from public.tarefas where id = testes.v('t_rui')), testes.et_i('em_contato'));
insert into public.agendamentos (clinica_id, pessoa_id, oportunidade_id, tipo, inicio)
select testes.v('ic'), testes.v('rui'), oportunidade_id, 'avaliacao', now() + interval '5 days' from public.tarefas where id = testes.v('t_rui');
-- Paciente inativo, ainda sem contato: elegível.
insert into public.pessoas (clinica_id, tipo_cadastro, nome, whatsapp_e164, ultimo_atendimento_informado)
values (testes.v('ic'), 'paciente_antigo', 'Ana Inativa', '+5511970000008', testes.hoje() - 800);

reset role; select testes.entrar('sec@ind.local'); set role authenticated;
select set_config('t.i', testes.ind(testes.hoje() - 30, testes.hoje())::text, false);

\echo '— Leads'
select testes.ok((select (i -> 'leads') = '{"novos": 5, "convertidos": 1, "em_negociacao": 1, "sem_resposta": 1, "perdidos": 2}'::jsonb
                  from (select current_setting('t.i')::jsonb i) x),
  'novos leads no período, convertidos, em negociação, sem resposta e perdidos (reativação e lead antigo ficam de fora)');
select testes.ok((select jsonb_array_length(i -> 'por_canal') = 6
                     and (select string_agg(c ->> 'canal', ',') from jsonb_array_elements(i -> 'por_canal') c)
                         = 'instagram,indicacao,google,whatsapp,paciente_antigo,outro'
                     and (i -> 'por_canal') @> '[{"canal": "instagram", "leads": 2, "convertidos": 1}, {"canal": "indicacao", "leads": 1}, {"canal": "google", "leads": 1}, {"canal": "whatsapp", "leads": 1}, {"canal": "paciente_antigo", "leads": 0}, {"canal": "outro", "leads": 0}]'::jsonb
                  from (select current_setting('t.i')::jsonb i) x),
  'origem: Instagram, indicação, Google, WhatsApp, paciente antigo e outro (sempre os seis)');
select testes.ok((select (i -> 'por_origem') @> '[{"origem": "Instagram", "leads": 2, "convertidos": 1}, {"origem": "Google", "leads": 1}]'::jsonb
                     and (i -> 'por_procedimento') @> '[{"procedimento": "Facetas de porcelana", "leads": 2, "convertidos": 1}, {"procedimento": "Implantes", "leads": 2}]'::jsonb
                  from (select current_setting('t.i')::jsonb i) x),
  'leads por origem e por procedimento (com quantos converteram)');

\echo '— Conversão'
select testes.ok((select (i -> 'conversao') = '{"leads": 5, "agendaram": 2, "consulta": 1, "orcamento": 1, "fechamento": 1}'::jsonb
                  from (select current_setting('t.i')::jsonb i) x),
  'conversão: leads → agendaram → consulta → orçamento → fechamento');

\echo '— Funil'
select testes.ok((select (i -> 'funil') @> '[{"etapa": "Novo contato", "quantidade": 0}, {"etapa": "Avaliação agendada", "quantidade": 2}, {"etapa": "Sem resposta", "quantidade": 1}, {"etapa": "Fechou", "quantidade": 1}, {"etapa": "Não fechou", "quantidade": 1}, {"etapa": "Desistiu", "quantidade": 1}]'::jsonb
                  from (select current_setting('t.i')::jsonb i) x),
  'funil: onde está agora cada pessoa que entrou no período');
select testes.ok((testes.ind(testes.hoje() - 365, testes.hoje()) -> 'funil') @> '[{"etapa": "Novo contato", "quantidade": 1}]'::jsonb,
  'funil acompanha o período: o lead antigo aparece em "Novo contato" no período dele');

\echo '— Perdas'
select testes.ok((select (i -> 'perdas' -> 'grupos') = '{"preco": 1, "desistiu": 0, "nao_respondeu": 1, "outro_local": 1, "adiou": 0, "outro": 0}'::jsonb
                     and (i -> 'perdas' -> 'motivos') @> '[{"motivo": "Valor alto", "quantidade": 1}, {"motivo": "Fez o tratamento em outro lugar", "quantidade": 1}]'::jsonb
                     and (i -> 'perdas' ->> 'total')::int = 3
                  from (select current_setting('t.i')::jsonb i) x),
  'perdas por grupo (preço, desistiu, não respondeu, outro local, adiou, outro) e por motivo registrado');

\echo '— Reativação'
select testes.ok((select (i -> 'reativacao') = '{"elegiveis": 1, "reativados": 1, "responderam": 1, "agendaram": 1, "fecharam": 0, "aguardando": 0, "sem_retorno": 0}'::jsonb
                  from (select current_setting('t.i')::jsonb i) x),
  'reativação: elegíveis, reativados e resultado (responderam, agendaram, fecharam)');

\echo '— Filtros'
select testes.ok((testes.ind(testes.hoje() - 365, testes.hoje()) -> 'leads' ->> 'novos')::int = 6
             and (testes.ind(testes.hoje() + 1, testes.hoje() + 30) -> 'leads' ->> 'novos')::int = 0,
  'filtro por período: o lead antigo aparece só no período dele');
select testes.ok((select (i -> 'leads' ->> 'novos')::int = 2 and (i -> 'conversao' ->> 'fechamento')::int = 1
                  from (select testes.ind(testes.hoje() - 30, testes.hoje(), testes.proc_i('Facetas de porcelana')) i) x),
  'filtro por procedimento');

reset role; select testes.entrar('intruso@outra.local'); set role authenticated;
select testes.ok((testes.ind(testes.hoje() - 30, testes.hoje()) -> 'leads' ->> 'novos')::int = 0,
  'outra clínica não vê os indicadores desta');
reset role;

\echo '✓ Indicadores verificados.'
