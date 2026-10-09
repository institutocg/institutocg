# Publicação oficial — Instituto CG

Passo a passo para colocar o CRM em **uso real**, com pacientes de verdade.
Leva uns 30 minutos. A versão de teste continua existindo, separada, para
experimentar mudanças antes de elas chegarem à clínica.

| | Versão de teste | Versão oficial |
|---|---|---|
| Banco (Supabase) | projeto de teste | **projeto novo**, só para a clínica |
| Site (Vercel) | projeto de teste | **projeto novo** |
| Dados | fictícios, pode apagar à vontade | reais, nunca são apagados |
| Faixa “Versão de teste” | aparece | não aparece |

> **Nunca** rode `supabase/versao-teste/instalar.sql` no projeto oficial: ele cria pacientes fictícios.

---

## 1. Banco de dados oficial (Supabase)

1. Em [supabase.com](https://supabase.com) → **New project**.
   - Nome: `instituto-cg-oficial`
   - Região: **South America (São Paulo)**
   - Senha do banco: crie uma senha forte e **guarde** (vai no passo 2).
2. Plano: recomendo o **Pro** (US$ 25/mês). Ele faz **cópia de segurança diária**
   dos dados. No plano gratuito não há backup e o projeto “dorme” depois de uma
   semana sem uso.
3. Abra **SQL Editor** → **New query**, cole o arquivo inteiro
   [`supabase/producao/instalar.sql`](../supabase/producao/instalar.sql) e clique em **Run**.
   No fim aparece “Instalado”.
4. **Authentication → Sign In / Providers → Email**: deixe o e-mail ligado e
   **desligue “Allow new users to sign up”** (ninguém se cadastra sozinho; só
   você cria logins).
5. Anote, em **Project Settings**:
   - **API** → *Project URL* e a chave *publishable*;
   - **Database → Connection string → Transaction pooler** (porta 6543), trocando
     `[YOUR-PASSWORD]` pela senha do item 1.

## 2. Site oficial (Vercel)

1. Em [vercel.com](https://vercel.com) → **Add New… → Project** → importe o
   repositório `institutocg` de novo (vai virar um **segundo projeto**).
   Nome: `instituto-cg`.
2. Antes de clicar em *Deploy*, abra **Environment Variables** e cadastre:

   | Nome | Valor |
   |---|---|
   | `DATABASE_URL` | a connection string do pooler (passo 1.5) |
   | `NEXT_PUBLIC_SUPABASE_URL` | Project URL |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | chave publishable |

   Não cadastre `AUTH_MODO`.
3. **Settings → Git → Production Branch**: `producao`. Assim, o site oficial só
   muda quando uma versão aprovada no teste é passada para essa branch.
4. Clique em **Deploy**. Ao terminar, anote o endereço (ex.:
   `https://instituto-cg.vercel.app`).
5. Plano: o **Hobby** (grátis) da Vercel é só para uso não comercial. Para a
   clínica, use o **Pro** (US$ 20/mês).

## 3. Logins da equipe

1. No Supabase oficial → **Authentication → URL Configuration**:
   - **Site URL**: o endereço do passo 2.4;
   - **Redirect URLs**: adicione `https://SEU-ENDERECO/auth/confirmar`
     (é para onde volta o link de “Esqueci minha senha”).
2. **Authentication → Users → Add user → Create new user**: um para a
   Dra. Cristina e um para a secretária, com e-mail e senha, marcando
   **Auto Confirm User**.
3. **SQL Editor**: cole [`supabase/producao/equipe.sql`](../supabase/producao/equipe.sql),
   troque os dois e-mails no topo e clique em **Run**. A tabela no fim mostra
   quem tem acesso a quê.
   - Dra. Cristina: administradora (tudo, inclusive prontuário e campanhas).
   - Secretária: agenda, contatos, tarefas e financeiro. Para ela também ver o
     prontuário, troque `secretaria_ve_prontuario` para `true`.
4. Cada pessoa entra no site e, se quiser, troca a senha em
   **Configurações → Alterar minha senha**. Esqueceu? Na tela de login,
   **Esqueci minha senha** manda um link por e-mail.

## 4. Primeiro uso

Em **Configurações**:
- **Dentistas**: troque “Dentista responsável” pelos nomes reais (e as cores).
- Confira as **regras de follow-up** e os limites de contatos por dia.

Depois, cadastre os pacientes em **Contatos** (ou peça a importação de uma
planilha).

## 5. Endereço próprio (opcional)

Para usar algo como `crm.institutocg.com.br`: Vercel → projeto oficial →
**Settings → Domains → Add**, e siga as instruções de DNS no registro do domínio.
Depois, atualize a **Site URL** e as **Redirect URLs** do passo 3.1.

---

## Depois de publicado: mudanças e atualizações

O sistema continua podendo ser alterado sem perder nenhum dado:

1. A mudança é feita e publicada primeiro na **versão de teste**.
2. Você testa lá.
3. Aprovado, a mudança vai para a branch `producao` e o site oficial atualiza
   sozinho em poucos minutos.
4. Se a mudança mexer no banco, vem junto um arquivo
   `supabase/producao/atualizar-*.sql` para colar uma vez no SQL Editor do
   projeto oficial (ele só acrescenta; não apaga pacientes nem histórico).

## Segurança e LGPD

- Os dados ficam no Brasil (São Paulo) e só quem tem login acessa. Cada pessoa
  vê apenas o que o seu papel permite; o prontuário é restrito.
- Quem não fez login não consegue ler nem chamar nada no banco.
- O site não aparece no Google e não pode ser aberto dentro de outros sites.
- Nenhuma mensagem é enviada sozinha pelo WhatsApp.
- Não compartilhe senhas; cada pessoa tem o seu login. Se alguém sair da
  equipe, apague o login em **Authentication → Users**.
- O registro de quem aceitou receber comunicações fica no cadastro de cada
  paciente; campanhas podem ser limitadas a essas pessoas.
