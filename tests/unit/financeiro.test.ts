import { describe, expect, it } from "vitest";
import { mesDe, rotuloMes, rotuloParcela, rotuloVencimento, simularParcelas, somarMes, SITUACAO } from "@/modules/financeiro/financeiro";

const HOJE = "2026-10-01";

describe("visão financeira simples", () => {
  it("os quatro status", () => {
    expect(Object.values(SITUACAO).map((s) => s.rotulo)).toEqual(["Pendente", "Parcialmente pago", "Pago", "Atrasado"]);
  });
  it("vencimento em palavras", () => {
    expect(rotuloVencimento("2026-09-28", HOJE)).toBe("Vencido há 3 dias");
    expect(rotuloVencimento("2026-09-30", HOJE)).toBe("Vencido há 1 dia");
    expect(rotuloVencimento(HOJE, HOJE)).toBe("Vence hoje");
    expect(rotuloVencimento("2026-10-02", HOJE)).toBe("Vence amanhã");
    expect(rotuloVencimento("2026-10-10", HOJE)).toBe("Vence em 10/10");
  });
  it("entrada e parcelas", () => {
    expect(rotuloParcela(0, 3)).toBe("Entrada");
    expect(rotuloParcela(2, 3)).toBe("Parcela 2 de 3");
    expect(simularParcelas(500_000, 200_000, 3)).toEqual({ restante: 300_000, valor: 100_000, ultima: 100_000 });
    expect(simularParcelas(100_000, 0, 3)).toEqual({ restante: 100_000, valor: 33_333, ultima: 33_334 });
  });
  it("navegação por mês", () => {
    expect(mesDe("2026-10-15")).toBe("2026-10-01");
    expect(somarMes("2026-01-01", -1)).toBe("2025-12-01");
    expect(somarMes("2026-12-01", 1)).toBe("2027-01-01");
    expect(rotuloMes("2026-10-01")).toBe("Outubro de 2026");
  });
});
