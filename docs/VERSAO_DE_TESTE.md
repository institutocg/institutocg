# Versão de teste — passo a passo

Uma cópia **completa e funcionando** do CRM, na internet, com **pacientes fictícios**, para testar tudo antes de usar com dados reais. Ela fica totalmente separada da futura versão oficial (outro banco, outro endereço).

O que muda em relação à versão oficial:

- Uma faixa amarela **"Versão de teste"** aparece em todas as telas e na tela de entrada.
- Já vem com ~20 situações de exemplo (novo contato, orçamento, desmarcação, faltas, pagamentos atrasados, pacientes antigos…), com datas a partir do dia da instalação.
- Em **Configurações → Versão de teste**, a administradora pode **Recomeçar com dados de exemplo**: apaga tudo o que foi feito nos testes e recria os exemplos com datas a partir de hoje. Os logins continuam os mesmos.
- Os telefones dos pacientes de exemplo são inventados: **não envie mensagens pelo WhatsApp para eles** (o CRM nunca envia nada sozinho; o WhatsApp só abre se você clicar).

Tempo estimado: 20 minutos. Custo: zero (planos gratuitos do Supabase e da Vercel).

---

## 1. Banco de dados (Supabase)

1. Entre em [supabase.com](https://supabase.com) → **New project**.
   - Nome: `instituto-cg-teste`
   - Região: **South America (São Paulo)**
   - Senha do banco: clique em *Generate a password* e **guarde** (vai ser usada no passo 3).
2. Com o projeto pronto, abra **SQL Editor** → **New query**.
3. Abra o arquivo [`supabase/versao-teste/instalar.sql`](../supabase/versao-teste/instalar.sql) no GitHub, clique em **Copy raw file**, cole no SQL Editor e clique em **Run**.
   - No fim aparece uma tabelinha com **e-mail e senha** da dona e da secretária. **Anote.**
   - Esqueceu a senha? No SQL Editor: `select * from teste.criar_logins_de_teste();` gera senhas novas.
4. **Authentication → Sign In / Providers** → desligue **Allow new users to sign up** (ninguém de fora cria conta).
5. Copie três informações (botão **Connect**, no topo do projeto):
   - **Project URL** (ex.: `https://abcd1234.supabase.co`)
   - **Publishable key** (ou *anon key*)
   - Em *Connection string*, a do **Transaction pooler** (porta **6543**), trocando `[YOUR-PASSWORD]` pela senha do banco do passo 1.

## 2. Site (Vercel)

1. Entre em [vercel.com](https://vercel.com) com a conta do GitHub → **Add New → Project** → importe `institutocg/institutocg`.
2. Em **Environment Variables**, adicione:

   | Nome | Valor |
   |---|---|
   | `DATABASE_URL` | a connection string do Transaction pooler |
   | `NEXT_PUBLIC_SUPABASE_URL` | o Project URL |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | a publishable key |

   Não adicione `AUTH_MODO` (é só para o computador de desenvolvimento).
3. Clique em **Deploy**.
4. Enquanto o código ainda não estiver na branch principal (`main`), vá em **Settings → Git → Production Branch** e coloque `claude/eloquent-tesla-page70`; depois **Deployments → Redeploy**.
5. Abra o endereço que a Vercel mostrar (ex.: `instituto-cg-teste.vercel.app`) e entre com o e-mail e a senha do passo 1.3. A faixa **Versão de teste** deve aparecer.

O servidor já está configurado para rodar em São Paulo (`vercel.json`), perto do banco — as telas ficam rápidas.

### Se o login não funcionar

1. No Supabase, **Authentication → Users → Add user → Create new user**: e-mail `dona@teste.institutocg.com.br`, uma senha, marque **Auto Confirm User**. Repita para `secretaria@teste.institutocg.com.br` se precisar.
2. No SQL Editor:
   ```sql
   select public.adicionar_membro((select id from public.clinicas where nome = 'Instituto CG'), 'dona@teste.institutocg.com.br', 'admin');
   select public.adicionar_membro((select id from public.clinicas where nome = 'Instituto CG'), 'secretaria@teste.institutocg.com.br', 'comercial');
   ```
3. Se ainda assim der erro, copie a mensagem que aparecer e me envie.

---

## 3. Roteiro de testes

Sugestão de ordem. Entre como **dona** (administradora) e, em outra janela anônima, como **secretária**, para ver as diferenças de acesso.

**Hoje (painel)**
- [ ] As ações do dia aparecem por prioridade (urgente, importante, rotina), com o motivo.
- [ ] *Ver mensagem*: o texto vem preenchido com o nome; dá para editar e copiar.
- [ ] *Registrar contato*: respondeu, não respondeu, agendou (pede data, horário e dentista).
- [ ] Lembretes de pagamento ("Pagamento previsto" / "Pagamento atrasado") com *Marcar como pago*.

**Contatos**
- [ ] *+ Novo paciente*: novo contato e paciente antigo; aviso de cadastro duplicado.
- [ ] Ficha: histórico, etapa, próxima ação, *Registrar negociação*.

**Funil**
- [ ] Arrastar entre etapas; "Não fechou" pede motivo; "Fechou" registra valores.
- [ ] Avaliação agendada pede data, horário e dentista.

**Agenda**
- [ ] Agendar com dentista; confirmar; *desmarcou* e *faltou* geram ação de recuperação (nenhuma desmarcação some).
- [ ] *Remarcou*: atualiza a agenda e troca a tarefa.

**Mensagens prontas**
- [ ] Copiar, editar e criar mensagem; variáveis como `{{nome}}` preenchidas.

**Financeiro**
- [ ] Registrar negociação (entrada + parcelas, cartão), pagamento parcial, mudar data, filtro por procedimento.

**Indicadores**
- [ ] Leads, conversão, funil, origem, procedimentos, perdas e reativação; troque o período e o procedimento.

**Campanhas e Configurações**
- [ ] Campanha de reativação (prévia e lista) — só a dona cria.
- [ ] Regras de follow-up, dentistas e limites de contato — a secretária só consulta.

**Recomeçar**
- [ ] Configurações → Versão de teste → *Recomeçar com dados de exemplo*: tudo volta ao início.

Anote o que estranhar (tela, o que fez, o que esperava) e me envie — ajusto antes da versão oficial.

---

## Versão oficial (depois dos testes)

A versão oficial usa **outro projeto Supabase** e segue o roteiro de [`supabase/README.md`](../supabase/README.md#implantação-no-supabase-quando-formos-para-produção): só as migrações, **sem** `instalar.sql` e sem dados fictícios. Lá a faixa de teste e o botão *Recomeçar* não existem.
