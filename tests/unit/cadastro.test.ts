import { describe, expect, it } from "vitest";
import { errosPorCampo, lerFormulario, rotuloUltimoAtendimento, subtrairMeses, ultimoAtendimento } from "@/modules/contatos/cadastro";

const ORIGEM = "0b7f9c1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f";
const PROC = "1b7f9c1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f";

function form(campos: Record<string, string | string[]>) {
  const f = new FormData();
  for (const [k, v] of Object.entries(campos)) {
    for (const x of Array.isArray(v) ? v : [v]) f.append(k, x);
  }
  return f;
}

describe("formulário de cadastro", () => {
  it("novo contato válido: normaliza nome, WhatsApp, e-mail, UF e CEP", () => {
    const r = lerFormulario(form({
      tipo: "novo_contato", nome: "  maria   da  Silva ", whatsapp: "(11) 99999-8888", email: "Maria@Exemplo.com",
      origemId: ORIGEM, procedimentoId: PROC, uf: "sp", cep: "01310-100", cidade: "São Paulo", nascimento: "",
    }));
    expect(r.success).toBe(true);
    if (!r.success) return;
    expect(r.data.nome).toBe("maria da Silva");
    expect(r.data.whatsapp).toBe("+5511999998888");
    expect(r.data.email).toBe("maria@exemplo.com");
    expect(r.data.uf).toBe("SP");
    expect(r.data.cep).toBe("01310100");
    expect(r.data.nascimento).toBeUndefined();
    expect(r.data.aceitaMarketing).toBe(false);
  });

  it("mostra os erros no campo certo", () => {
    const r = lerFormulario(form({ tipo: "novo_contato", nome: "Ma", whatsapp: "123", email: "x" }));
    expect(r.success).toBe(false);
    if (r.success) return;
    const e = errosPorCampo(r.error);
    expect(e.nome).toBe("Informe o nome completo.");
    expect(e.email).toBe("E-mail inválido.");
  });

  it("exige WhatsApp ou e-mail, e origem para novo contato", () => {
    const r = lerFormulario(form({ tipo: "novo_contato", nome: "Maria Silva" }));
    expect(r.success).toBe(false);
    if (r.success) return;
    const e = errosPorCampo(r.error);
    expect(e.whatsapp).toBe("Informe o WhatsApp ou o e-mail.");
    expect(e.origemId).toBe("Informe como conheceu a clínica.");
  });

  it("mostra todos os erros de uma vez (nome, contato e origem)", () => {
    const r = lerFormulario(form({ tipo: "novo_contato", nome: "" }));
    expect(r.success).toBe(false);
    if (r.success) return;
    const e = errosPorCampo(r.error);
    expect(Object.keys(e).sort()).toEqual(["nome", "origemId", "whatsapp"]);
  });

  it("WhatsApp inválido tem mensagem própria", () => {
    const r = lerFormulario(form({ tipo: "novo_contato", nome: "Maria Silva", whatsapp: "(10) 1234", origemId: ORIGEM }));
    expect(r.success).toBe(false);
    if (!r.success) expect(errosPorCampo(r.error).whatsapp).toBe("WhatsApp inválido. Use DDD + número.");
  });

  it("paciente antigo: não exige origem; lê tratamentos, faixa e 'em tratamento'", () => {
    const r = lerFormulario(form({
      tipo: "paciente_antigo", nome: "João Pereira", whatsapp: "11988887777",
      ultimoAtendimentoFaixa: "1_a_2_anos", tratamentos: [PROC, ORIGEM], emTratamento: "on",
    }));
    expect(r.success).toBe(true);
    if (!r.success) return;
    expect(r.data.tratamentos).toEqual([PROC, ORIGEM]);
    expect(r.data.ultimoAtendimentoFaixa).toBe("1_a_2_anos");
    expect(r.data.emTratamento).toBe(true);
  });

  it("rejeita nascimento no futuro", () => {
    const r = lerFormulario(form({ tipo: "paciente_antigo", nome: "João Pereira", email: "j@x.com", nascimento: "2999-01-01" }));
    expect(r.success).toBe(false);
  });
});

describe("último atendimento", () => {
  const HOJE = "2026-09-29";
  it("mês lembrado", () => {
    expect(ultimoAtendimento("2025-03", undefined, HOJE)).toEqual({ data: "2025-03-01", faixa: null });
  });
  it("faixas viram data aproximada (para a reativação) e guardam a faixa", () => {
    expect(ultimoAtendimento(undefined, "1_a_2_anos", HOJE)).toEqual({ data: "2025-03-29", faixa: "1_a_2_anos" });
    expect(ultimoAtendimento(undefined, "menos_6_meses", HOJE).data).toBe("2026-06-29");
    expect(ultimoAtendimento(undefined, "nao_lembra", HOJE)).toEqual({ data: null, faixa: "nao_lembra" });
    expect(ultimoAtendimento(undefined, undefined, HOJE)).toEqual({ data: null, faixa: null });
  });
  it("subtrai meses respeitando o fim do mês", () => {
    expect(subtrairMeses("2026-03-31", 1)).toBe("2026-02-28");
    expect(subtrairMeses("2026-01-15", 30)).toBe("2023-07-15");
  });
  it("rótulos", () => {
    expect(rotuloUltimoAtendimento("2025-03-01", null)).toBe("mar/2025");
    expect(rotuloUltimoAtendimento("2025-03-31", "1_a_2_anos")).toBe("Há 1 a 2 anos");
    expect(rotuloUltimoAtendimento(null, "nao_lembra")).toBe("Não lembra");
    expect(rotuloUltimoAtendimento(null, null)).toBeNull();
  });
});
