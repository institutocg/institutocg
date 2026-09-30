import { describe, expect, it } from "vitest";
import { terminoPrevisto, diasDeCampanha, taxa } from "@/modules/campanhas/campanhas";
import { campos, descreverRegra, esquemaRegra, exemplo, lerIntervalos } from "@/modules/regras/regras";

const base = {
  situacao: "desmarcou" as const,
  ativa: true,
  prazo_dias: 1,
  intervalos: [3, 4],
  ao_esgotar: "sem_resposta" as const,
  espera_reativacao_dias: null,
  periodo_meses: null,
};

describe("descreverRegra", () => {
  it("explica em palavras o que acontece e quando", () => {
    expect(descreverRegra(base)).toBe(
      "Ação no dia seguinte; sem resposta, mais 2 tentativas (após 3 e 4 dias). Depois disso, vai para “Sem resposta”.",
    );
  });
  it("reativação depois de esgotar, com a espera", () => {
    expect(descreverRegra({ ...base, situacao: "sem_resposta", prazo_dias: 7, intervalos: [14], ao_esgotar: "reativacao", espera_reativacao_dias: 60 }))
      .toBe("Ação em 7 dias; sem resposta, mais 1 tentativa (após 14 dias). Depois disso, vai para “Reativação”, com novo contato em 60 dias.");
  });
  it("regras de período e confirmação", () => {
    expect(descreverRegra({ ...base, situacao: "paciente_inativo", periodo_meses: 6, intervalos: [], ao_esgotar: "decidir" }))
      .toBe("Contato com quem está há 6 meses sem atendimento. Depois disso, você decide o próximo passo.");
    expect(descreverRegra({ ...base, situacao: "confirmacao", intervalos: [] })).toBe("Confirmação 1 dia(s) útil(eis) antes da consulta.");
    expect(descreverRegra({ ...base, situacao: "nao_fechou", prazo_dias: null, intervalos: [] })).toBe("Ação na data sugerida pelo motivo.");
  });
  it("regra desligada", () => {
    expect(descreverRegra({ ...base, ativa: false })).toMatch(/^Desligada/);
  });
});

describe("campos e validação", () => {
  it("uma regra não manda a pessoa para a própria etapa", () => {
    expect(campos("sem_resposta").opcoesAoEsgotar).not.toContain("sem_resposta");
    expect(campos("reativacao").opcoesAoEsgotar).not.toContain("reativacao");
    expect(campos("confirmacao").tentativas).toBe(false);
    expect(campos("pos_tratamento").periodo).toBe(true);
  });
  it("lê os intervalos digitados", () => {
    expect(lerIntervalos("3, 7")).toEqual([3, 7]);
    expect(lerIntervalos("")).toEqual([]);
    expect(lerIntervalos("3, x")).toBeNull();
    expect(lerIntervalos("0")).toBeNull();
  });
  const valida = {
    id: "5b1f7a2e-3c4d-4e5f-8a9b-0c1d2e3f4a5b", situacao: "desmarcou", ativa: true, titulo_modelo: "Ligar para {primeiro_nome}",
    prazo_dias: "1", intervalos: "3, 4", prioridade: "urgente", ao_esgotar: "sem_resposta", espera_reativacao_dias: "",
    periodo_meses: "", mensagem: "Olá",
  } as const;
  it("aceita uma regra válida e recusa insistência excessiva", () => {
    expect(esquemaRegra.safeParse(valida).success).toBe(true);
    const r = esquemaRegra.safeParse({ ...valida, intervalos: "1,1,1,1,1,1" });
    expect(r.success).toBe(false);
    expect(r.error?.issues[0].message).toMatch(/No máximo 5/);
  });
  it("exige prazo, período e espera quando fazem sentido", () => {
    expect(esquemaRegra.safeParse({ ...valida, prazo_dias: "" }).success).toBe(false);
    expect(esquemaRegra.safeParse({ ...valida, situacao: "nao_fechou", prazo_dias: "" }).success).toBe(true);
    expect(esquemaRegra.safeParse({ ...valida, situacao: "pos_tratamento", periodo_meses: "" }).success).toBe(false);
    expect(esquemaRegra.safeParse({ ...valida, ao_esgotar: "reativacao" }).success).toBe(false);
  });
  it("mostra o texto com um exemplo", () => {
    expect(exemplo("Olá, {primeiro_nome}! Sobre {procedimento}…", "implantes")).toBe("Olá, Maria! Sobre implantes…");
  });
});

describe("campanhas", () => {
  it("distribui em dias úteis conforme o limite", () => {
    expect(diasDeCampanha(25, 10)).toBe(3);
    // 02/10/2026 é sexta: 3 dias úteis → sex, seg, ter
    expect(terminoPrevisto("2026-10-02", 25, 10)).toBe("2026-10-06");
    // Começando num sábado, o primeiro dia é segunda
    expect(terminoPrevisto("2026-10-03", 5, 10)).toBe("2026-10-05");
    expect(terminoPrevisto("2026-10-02", 0, 10)).toBeNull();
  });
  it("taxa de resposta", () => {
    expect(taxa(2, 5)).toBe("40%");
    expect(taxa(0, 0)).toBe("—");
  });
});

describe("casos na tela de Configurações", () => {
  it("seis casos, paciente antigo e os passos automáticos recolhidos", async () => {
    const { GRUPOS, AUTOMATICAS } = await import("@/modules/regras/regras");
    expect(GRUPOS[0].situacoes).toEqual(["novo_contato", "pos_consulta", "sem_resposta", "desmarcou", "nao_fechou", "fechou"]);
    expect(GRUPOS[1].situacoes).toEqual(["paciente_inativo", "pos_tratamento", "manutencao"]);
    expect(AUTOMATICAS).toEqual(["em_contato", "confirmacao", "reativacao"]);
  });
});
