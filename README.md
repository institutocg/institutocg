# Instituto CG — CRM comercial

CRM interno de relacionamento e organização comercial da clínica (não é prontuário).

- Especificação: [`docs/ARQUITETURA_CRM.md`](docs/ARQUITETURA_CRM.md)
- Banco de dados e motor de ações: [`supabase/README.md`](supabase/README.md)
- Telas: [`docs/telas/`](docs/telas)

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
