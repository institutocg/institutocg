import { describe, expect, it } from "vitest";
import { resumoComercial, type DadosResumo } from "@/modules/contatos/resumo";

const HOJE = "2026-09-29";
const base: DadosResumo = {
  tipo_cadastro: "novo_contato",
  relacionamento: "lead",
  primeiro_contato_em: "2026-09-22",
  origem: "Instagram",
  ultimo_atendimento_informado: null,
  ultimo_atendimento_faixa: null,
  etapa_atual: "Orçamento apresentado",
  status_atual: "em_negociacao",
  procedimento_interesse: "Facetas de porcelana",
  dias_na_etapa: 7,
  valor_estimado_centavos: 1_400_000,
  proxima_acao: "Retornar Maria sobre facetas",
  proxima_acao_em: HOJE,
  nao_contatar: false,
};

describe("resumo comercial", () => {
  it("lead em negociação", () => {
    expect(resumoComercial(base, HOJE)).toEqual([
      "Novo contato desde 22/09/2026 (Instagram).",
      "Interesse em facetas de porcelana — etapa “Orçamento apresentado” há 7 dias, valor estimado R$ 14.000.",
      "Próxima ação: Retornar Maria sobre facetas — hoje.",
    ]);
  });

  it("lead recém-cadastrado, sem interesse definido", () => {
    const r = resumoComercial({ ...base, origem: null, procedimento_interesse: null, dias_na_etapa: 0, valor_estimado_centavos: null, etapa_atual: "Novo contato" }, HOJE);
    expect(r[0]).toBe("Novo contato desde 22/09/2026.");
    expect(r[1]).toBe("Interesse ainda não definido — etapa “Novo contato” desde hoje.");
  });

  it("paciente antigo inativo, sem negociação", () => {
    const r = resumoComercial(
      {
        ...base,
        tipo_cadastro: "paciente_antigo",
        relacionamento: "paciente_inativo",
        ultimo_atendimento_informado: "2025-03-29",
        ultimo_atendimento_faixa: "1_a_2_anos",
        etapa_atual: null,
        proxima_acao: null,
        proxima_acao_em: null,
      },
      HOJE,
      "Manutenção e limpeza",
    );
    expect(r).toEqual([
      "Paciente antigo, sem atendimento recente — último atendimento há 1 a 2 anos; já fez manutenção e limpeza.",
      "Sem negociação em andamento.",
      "Nenhuma ação pendente.",
    ]);
  });

  it("paciente ativo com mês lembrado e quem não quer contato", () => {
    const r = resumoComercial(
      { ...base, relacionamento: "paciente_ativo", ultimo_atendimento_informado: "2026-05-01", nao_contatar: true, proxima_acao: null, proxima_acao_em: null },
      HOJE,
    );
    expect(r).toEqual(["Paciente ativo — último atendimento em mai/2026.", "Pediu para não receber contatos."]);
  });
});
