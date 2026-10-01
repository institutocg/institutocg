import { describe, expect, it } from "vitest";
import {
  CANAIS,
  etapasConversao,
  GRUPOS_PERDA,
  intervaloDoAtalho,
  pct,
  resolverPeriodo,
  rotuloPeriodo,
} from "@/modules/indicadores/indicadores";

const HOJE = "2026-10-01";

describe("indicadores: período", () => {
  it("atalhos", () => {
    expect(intervaloDoAtalho("mes", HOJE)).toEqual({ de: "2026-10-01", ate: HOJE });
    expect(intervaloDoAtalho("mes_passado", HOJE)).toEqual({ de: "2026-09-01", ate: "2026-09-30" });
    expect(intervaloDoAtalho("mes_passado", "2026-01-15")).toEqual({ de: "2025-12-01", ate: "2025-12-31" });
    expect(intervaloDoAtalho("30d", HOJE)).toEqual({ de: "2026-09-02", ate: HOJE });
    expect(intervaloDoAtalho("90d", HOJE)).toEqual({ de: "2026-07-04", ate: HOJE });
    expect(intervaloDoAtalho("ano", HOJE)).toEqual({ de: "2026-01-01", ate: HOJE });
  });
  it("sem filtro: este mês", () => {
    expect(resolverPeriodo({}, HOJE)).toEqual({ de: "2026-10-01", ate: HOJE, atalho: "mes" });
    expect(resolverPeriodo({ periodo: "xyz" }, HOJE).atalho).toBe("mes");
  });
  it("datas livres: inverte se preciso e reconhece um atalho igual", () => {
    expect(resolverPeriodo({ de: "2026-09-30", ate: "2026-08-01" }, HOJE)).toEqual({ de: "2026-08-01", ate: "2026-09-30", atalho: null });
    expect(resolverPeriodo({ de: "2026-09-01", ate: "2026-09-30" }, HOJE).atalho).toBe("mes_passado");
    expect(resolverPeriodo({ de: "2026-09-10" }, HOJE)).toEqual({ de: "2026-09-10", ate: HOJE, atalho: null });
    expect(resolverPeriodo({ de: "lixo", ate: "2026-09-10" }, HOJE)).toEqual({ de: "2026-09-10", ate: "2026-09-10", atalho: null });
  });
  it("rótulo do período", () => {
    expect(rotuloPeriodo({ de: "2026-09-01", ate: "2026-09-30" })).toBe("01 a 30 de set de 2026");
    expect(rotuloPeriodo({ de: "2026-07-04", ate: HOJE })).toBe("04 de jul a 01 de out de 2026");
    expect(rotuloPeriodo({ de: "2025-12-01", ate: "2026-01-31" })).toBe("01 de dez de 2025 a 31 de jan de 2026");
  });
});

describe("indicadores: números", () => {
  it("percentual sem divisão por zero", () => {
    expect(pct(1, 3)).toBe(33);
    expect(pct(0, 0)).toBe(0);
  });
  it("conversão em etapas", () => {
    const e = etapasConversao({ leads: 10, agendaram: 8, consulta: 6, orcamento: 3, fechamento: 1 });
    expect(e.map((x) => x.sobreLeads)).toEqual([100, 80, 60, 30, 10]);
    expect(e.map((x) => x.sobreAnterior)).toEqual([null, 80, 75, 50, 33]);
  });
  it("origens e motivos de perda pedidos pela clínica", () => {
    expect(Object.values(CANAIS)).toEqual(["Instagram", "Indicação", "Google", "WhatsApp", "Paciente antigo", "Outro"]);
    expect(GRUPOS_PERDA.map((g) => g.rotulo)).toEqual(["Preço", "Desistiu", "Não respondeu", "Escolheu outro local", "Adiou", "Outro"]);
  });
});
