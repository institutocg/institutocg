import { describe, expect, it } from "vitest";
import {
  ARCADAS,
  descreverDente,
  diferencasOdontograma,
  esquemaFicha,
  idade,
  normalizarOdontograma,
  STATUS_ITEM,
  totaisPlano,
  tituloConsulta,
} from "@/modules/prontuario/prontuario";

describe("odontograma", () => {
  it("32 dentes permanentes, em notação FDI", () => {
    expect(ARCADAS.superior).toHaveLength(16);
    expect(ARCADAS.inferior).toHaveLength(16);
    expect(ARCADAS.superior.slice(7, 9)).toEqual([11, 21]);
  });
  it("normaliza: descarta dentes inválidos e faces de condições do dente inteiro", () => {
    expect(
      normalizarOdontograma({
        "16": { c: "carie", f: ["O", "O", "M"], s: "a_tratar" },
        "36": { c: "canal", f: ["O"] },
        "99": { c: "carie" },
        "11": { c: "inexistente" },
      }),
    ).toEqual({ "16": { c: "carie", f: ["O", "M"], s: "a_tratar" }, "36": { c: "canal", f: [], s: "a_tratar" } });
    expect(normalizarOdontograma(null)).toEqual({});
  });
  it("descreve e compara consultas (evolução)", () => {
    expect(descreverDente("16", { c: "carie", f: ["O"], s: "a_tratar" })).toBe("16 — Cárie (O) · a tratar");
    const antes = normalizarOdontograma({ "16": { c: "carie", f: ["O"] }, "21": { c: "faceta" } });
    const depois = normalizarOdontograma({ "16": { c: "restauracao", f: ["O"], s: "existente" }, "21": { c: "faceta" }, "36": { c: "canal", s: "existente" } });
    expect(diferencasOdontograma(antes, depois)).toEqual([
      "16: Cárie → Restauração (O) · existente / realizado",
      "36 — Canal (endodontia) · existente / realizado (novo)",
    ]);
  });
});

describe("plano de tratamento", () => {
  it("os seis status", () => {
    expect(Object.values(STATUS_ITEM).map((s) => s.rotulo)).toEqual(["Orçado", "Aceito", "Pendente", "Realizado", "Não realizado", "Cancelado"]);
  });
  it("totais: realizado, a fazer e total (sem cancelados)", () => {
    expect(
      totaisPlano([
        { status: "realizado", valor_centavos: 120000 },
        { status: "pendente", valor_centavos: 500000 },
        { status: "orcado", valor_centavos: 35000 },
        { status: "cancelado", valor_centavos: 99900 },
      ]),
    ).toEqual({ realizado: 120000, aFazer: 535000, total: 655000 });
  });
});

describe("consultas", () => {
  it("título: Consulta 03 — Facetas — 30/10/2026", () => {
    expect(tituloConsulta({ numero: 3, data: "2026-10-30", procedimento: "Facetas", motivo: [], tipo: "procedimento" })).toBe(
      "Consulta 03 — Facetas — 30/10/2026",
    );
    expect(tituloConsulta({ numero: 1, data: "2026-10-01", procedimento: null, motivo: ["Avaliação"], tipo: null })).toBe(
      "Consulta 01 — Avaliação — 01/10/2026",
    );
  });
  it("ficha: só texto livre + odontograma, com limites de tamanho", () => {
    expect(esquemaFicha.safeParse({ motivo_obs: "Dor no 26", queixa: "Dói ao mastigar", anamnese_obs: "Hipertensa" }).success).toBe(true);
    expect(esquemaFicha.safeParse({ anamnese_obs: "x".repeat(2001) }).success).toBe(false);
    expect(esquemaFicha.parse({}).motivo_obs).toBe("");
  });
  it("título usa o motivo escrito quando não há procedimento agendado", () => {
    expect(tituloConsulta({ numero: 2, data: "2026-10-02", procedimento: null, motivo: [], tipo: null, motivo_obs: "Dor no dente 26" })).toBe(
      "Consulta 02 — Dor no dente 26 — 02/10/2026",
    );
  });
  it("idade", () => {
    expect(idade("1985-06-15", "2026-10-01")).toBe(41);
    expect(idade("1985-10-02", "2026-10-01")).toBe(40);
    expect(idade(null, "2026-10-01")).toBeNull();
  });
});
