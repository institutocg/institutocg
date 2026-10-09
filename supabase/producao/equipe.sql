-- =============================================================================
-- Instituto CG — VERSÃO OFICIAL: dar acesso à equipe
--
-- Antes: no Supabase oficial, em Authentication → Users → "Add user" →
-- "Create new user", crie um login para cada pessoa (e-mail e senha, com
-- "Auto Confirm User" marcado).
--
-- Depois: troque os dois e-mails abaixo pelos que você usou, cole no SQL Editor
-- e clique em "Run". Pode rodar de novo sem problema (só atualiza).
-- =============================================================================

do $$
declare
  -- ↓↓↓ TROQUE AQUI ↓↓↓
  email_administradora text := 'email-da-dra-cristina@exemplo.com';
  email_secretaria     text := 'email-da-secretaria@exemplo.com';   -- deixe '' se ainda não houver
  secretaria_ve_prontuario boolean := false;   -- true = a secretária também abre o prontuário
  -- ↑↑↑ TROQUE AQUI ↑↑↑
  clinica uuid := (select id from public.clinicas where nome = 'Instituto CG');
begin
  if clinica is null then
    raise exception 'Clínica "Instituto CG" não encontrada. Rode primeiro supabase/producao/instalar.sql.';
  end if;

  -- Administradora: vê e configura tudo (financeiro, prontuário, campanhas, regras).
  perform public.adicionar_membro(clinica, email_administradora, 'admin');

  -- Secretária: agenda, contatos, tarefas do dia e financeiro.
  if btrim(email_secretaria) <> '' then
    perform public.adicionar_membro(clinica, email_secretaria, 'comercial');
    update public.membros m set pode_ver_prontuario = secretaria_ve_prontuario
      from public.usuarios u
     where m.usuario_id = u.id and m.clinica_id = clinica and lower(u.email) = lower(email_secretaria);
  end if;
end $$;

select u.email, m.papel, m.pode_ver_financeiro as ve_financeiro,
       (m.papel = 'admin' or m.pode_ver_prontuario) as ve_prontuario
  from public.membros m join public.usuarios u on u.id = m.usuario_id
 order by m.papel, u.email;
