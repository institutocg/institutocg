import { describe, expect, it } from "vitest";
import {
  acoesPermitidas,
  descreverPerda,
  diasDaSemana,
  inicioDaSemana,
  intervalo,
  prazoRecuperacao,
  rotuloDia,
} from "@/modules/agenda/agenda";

const HOJE = "2026-09-30"; // quarta-feira

describe("semana de atendimento", () => {
  it("começa na segunda e vai até sexta", () => {
    expect(inicioDaSemana(HOJE)).toBe("2026-09-28");
    expect(inicioDaSemana("2026-10-04")).toBe("2026-09-28"); // domingo
    expect(diasDaSemana("2026-09-28")).toEqual(["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"]);
    expect(rotuloDia("2026-10-01")).toBe("quinta, 01/10");
    expect(intervalo("10:30", 90)).toBe("10:30–12:00");
  });
});

describe("ações por status", () => {
  const base = { dia: "2026-10-05", remarcado_para: null };
  it("antes do dia: confirmar, desmarcar, remarcar e cancelar (sem presença ou falta)", () => {
    expect(acoesPermitidas({ ...base, status: "agendado" }, HOJE)).toEqual(["confirmar", "desmarcar", "remarcar", "cancelar"]);
    expect(acoesPermitidas({ ...base, status: "confirmado" }, HOJE)).toEqual(["desmarcar", "remarcar", "cancelar"]);
  });
  it("no dia: compareceu e faltou aparecem primeiro", () => {
    expect(acoesPermitidas({ ...base, dia: HOJE, status: "confirmado" }, HOJE)).toEqual([
      "compareceu", "faltou", "desmarcar", "remarcar", "cancelar",
    ]);
  });
  it("desmarcada ou faltou: só remarcar (e corrigir a falta); depois de remarcada, nada", () => {
    expect(acoesPermitidas({ ...base, status: "desmarcado" }, HOJE)).toEqual(["remarcar"]);
    expect(acoesPermitidas({ ...base, status: "faltou" }, HOJE)).toEqual(["compareceu", "remarcar"]);
    expect(acoesPermitidas({ ...base, status: "desmarcado", remarcado_para: new Date() }, HOJE)).toEqual([]);
    expect(acoesPermitidas({ ...base, status: "remarcado" }, HOJE)).toEqual([]);
  });
});

describe("recuperação", () => {
  it("prazo da tarefa", () => {
    expect(prazoRecuperacao("2026-09-28", HOJE)).toEqual({ texto: "Atrasada há 2 dias", atrasada: true });
    expect(prazoRecuperacao(HOJE, HOJE)).toEqual({ texto: "Hoje", atrasada: false });
    expect(prazoRecuperacao("2026-10-01", HOJE)).toEqual({ texto: "Amanhã", atrasada: false });
    expect(prazoRecuperacao(null, HOJE).atrasada).toBe(true);
  });
  it("descreve a consulta perdida com o artigo certo", () => {
    const inicio = new Date("2026-10-01T13:00:00Z"); // 10:00 em São Paulo
    expect(descreverPerda({ status: "desmarcado", tipo: "avaliacao", inicio })).toBe("Desmarcou a avaliação de 01/10 às 10:00");
    expect(descreverPerda({ status: "faltou", tipo: "procedimento", inicio })).toBe("Faltou ao procedimento de 01/10 às 10:00");
    expect(descreverPerda({ status: "faltou", tipo: "avaliacao", inicio })).toBe("Faltou à avaliação de 01/10 às 10:00");
    expect(descreverPerda({ status: "cancelado_clinica", tipo: "retorno", inicio })).toBe("Clínica cancelou o retorno de 01/10 às 10:00");
  });
});
