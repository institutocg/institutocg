# Instituto CG — CRM comercial

CRM interno de relacionamento e organização comercial da clínica (não é prontuário).

- Especificação: [`docs/ARQUITETURA_CRM.md`](docs/ARQUITETURA_CRM.md)
- Banco de dados: [`supabase/README.md`](supabase/README.md)

## Desenvolvimento

```bash
npm install
npm run dev        # aplicação (Next.js)
npm test           # testes das regras em TypeScript
npm run test:db    # testes de integridade do banco (PostgreSQL local)
npm run lint && npm run typecheck
```
