# Instituto CG — CRM comercial

CRM interno de relacionamento e organização comercial da clínica, com prontuário odontológico integrado (acesso restrito a quem atende).

- Especificação: [`docs/ARQUITETURA_CRM.md`](docs/ARQUITETURA_CRM.md)
- Banco de dados e motor de ações: [`supabase/README.md`](supabase/README.md)
- Telas: [`docs/telas/`](docs/telas)

## Versão de teste (na internet, com dados fictícios)

Passo a passo em [`docs/VERSAO_DE_TESTE.md`](docs/VERSAO_DE_TESTE.md): um projeto Supabase só para testes + Vercel. O banco inteiro (estrutura, dados fictícios e logins) é instalado colando [`supabase/versao-teste/instalar.sql`](supabase/versao-teste/instalar.sql) no SQL Editor. Depois de mudar migrações ou `seed.sql`, regere com `./scripts/gerar-versao-teste.sh` (o `npm run test:db` confere).

## Rodar no computador (sem Supabase)

```bash
npm install
./scripts/banco-local.sh iniciar          # PostgreSQL local com dados fictícios
cp .env.example .env.local                # e descomente as linhas de desenvolvimento
npm run dev                               # http://localhost:3000
```

Entre com `secretaria@institutocg.local` ou `dona@institutocg.local` (só o e-mail, no modo de desenvolvimento).

## Testes

```bash
npm test           # regras em TypeScript (painel, cadastro, resumo)
npm run test:db    # integridade do banco e motor de ações (PostgreSQL temporário)
npm run test:e2e   # telas, no navegador, contra o banco local recriado
npm run lint && npm run typecheck
```
