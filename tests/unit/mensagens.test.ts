import { describe, expect, it } from "vitest";
import { CATEGORIAS, esquemaModelo, preencherExemplo, trechos, variaveisDesconhecidas } from "@/modules/mensagens/mensagens";

describe("biblioteca de mensagens", () => {
  it("as 13 situações pedidas pela clínica", () => {
    expect(CATEGORIAS.map((c) => c.rotulo)).toEqual([
      "Primeiro contato",
      "Passou pela primeira consulta (pensando)",
      "Paciente não fechou",
      "Paciente sem resposta",
      "Paciente desmarcou",
      "Confirmação",
      "Remarcação",
      "Reativação",
      "Acompanhamento pós-atendimento",
      "Cobrança amigável",
      "Pagamento pendente",
      "Pagamento previsto",
      "Paciente antigo",
    ]);
  });

  it("prévia com exemplos e destaque das variáveis", () => {
    const texto = "Olá, {{nome}}! Sobre {{procedimento}}, {primeiro_nome}.";
    expect(preencherExemplo(texto)).toBe("Olá, Maria! Sobre facetas de porcelana, Maria.");
    expect(trechos("Oi, {{nome}}!")).toEqual([
      { texto: "Oi, ", variavel: false },
      { texto: "{{nome}}", variavel: true },
      { texto: "!", variavel: false },
    ]);
  });

  it("avisa sobre variáveis que o CRM não conhece", () => {
    expect(variaveisDesconhecidas("Olá, {{nome}} e {{apelido}}")).toEqual(["apelido"]);
    const r = esquemaModelo.safeParse({
      id: "", categoria: "confirmacao", procedimentoId: "", titulo: "Teste", texto: "Olá, {{nme}}! Tudo certo?", padrao: false, ativo: true,
    });
    expect(r.success).toBe(false);
    expect(r.error?.issues[0].message).toContain("{{nme}}");
  });
});
