import { describe, expect, it } from "vitest";
import { formatarMoeda, formatarMoedaCompacta, paraCentavos } from "@/lib/moeda";
import { formatarTelefone, linkWhatsApp, normalizarTelefone } from "@/lib/telefone";
import {
  dentroDoHorario,
  diaUtilAnterior,
  ehDiaUtil,
  feriadosNacionais,
  formatarDataLonga,
  hoje,
  pontosFacultativos,
  proximoDiaUtil,
  saudacao,
} from "@/lib/datas";
import { CONFIGURACOES_PADRAO, lerConfiguracoes } from "@/modules/configuracoes/padroes";

const cfg = CONFIGURACOES_PADRAO;

describe("moeda", () => {
  it("formata centavos em reais", () => {
    expect(formatarMoeda(123456)).toBe("R$ 1.234,56");
    expect(formatarMoeda(0)).toBe("R$ 0,00");
    expect(formatarMoedaCompacta(1_250_000)).toBe("R$ 12.500");
  });

  it.each([
    ["1.234,56", 123456],
    ["1234,56", 123456],
    ["R$ 1.234", 123400],
    ["1234.56", 123456],
    ["1234", 123400],
    ["12.500", 1250000],
    ["0,5", 50],
  ])("converte %s em %i centavos", (texto, esperado) => {
    expect(paraCentavos(texto)).toBe(esperado);
  });

  it.each(["", "abc", "1,2,3", "-10", "1.2.3,4.5"])("rejeita %s", (texto) => {
    expect(paraCentavos(texto)).toBeNull();
  });
});

describe("telefone", () => {
  it.each([
    ["(11) 99999-8888", "+5511999998888"],
    ["11999998888", "+5511999998888"],
    ["+55 11 99999-8888", "+5511999998888"],
    ["011 99999-8888", "+5511999998888"],
    ["(21) 3333-4444", "+552133334444"],
  ])("normaliza %s", (entrada, esperado) => {
    expect(normalizarTelefone(entrada)).toBe(esperado);
  });

  it.each(["123", "(10) 99999-8888", "(11) 89999-8888", "(11) 9999-8888", "+1 415 555 0100"])(
    "rejeita %s",
    (entrada) => {
      expect(normalizarTelefone(entrada)).toBeNull();
    },
  );

  it("formata para exibição e monta link do WhatsApp", () => {
    expect(formatarTelefone("+5511999998888")).toBe("(11) 99999-8888");
    expect(formatarTelefone("+552133334444")).toBe("(21) 3333-4444");
    expect(linkWhatsApp("+5511999998888", "Olá, Maria!")).toBe(
      "https://wa.me/5511999998888?text=Ol%C3%A1%2C%20Maria!",
    );
  });
});

describe("datas", () => {
  it("usa o fuso de São Paulo para definir 'hoje'", () => {
    // 01:30 UTC de 30/09 ainda é 29/09 em São Paulo (UTC−3).
    expect(hoje(new Date("2026-09-30T01:30:00Z"))).toBe("2026-09-29");
    expect(hoje(new Date("2026-09-30T03:30:00Z"))).toBe("2026-09-30");
  });

  it("calcula feriados móveis", () => {
    // Páscoa de 2026: 5 de abril.
    expect(feriadosNacionais(2026).get("2026-04-03")).toBe("Sexta-feira Santa");
    expect(pontosFacultativos(2026).has("2026-02-16")).toBe(true); // Carnaval
    expect(pontosFacultativos(2026).has("2026-06-04")).toBe(true); // Corpus Christi
    expect(feriadosNacionais(2026).has("2026-11-20")).toBe(true);
  });

  it("respeita os dias de funcionamento (seg–sex) e feriados", () => {
    expect(ehDiaUtil("2026-09-29", cfg)).toBe(true); // terça
    expect(ehDiaUtil("2026-10-03", cfg)).toBe(false); // sábado
    expect(ehDiaUtil("2026-10-12", cfg)).toBe(false); // feriado
    expect(ehDiaUtil("2026-02-16", cfg)).toBe(true); // Carnaval: facultativo, clínica abre
    expect(ehDiaUtil("2026-02-16", { ...cfg, fecha_pontos_facultativos: true })).toBe(false);
    expect(ehDiaUtil("2026-10-01", { ...cfg, dias_fechados_extra: ["2026-10-01"] })).toBe(false);
  });

  it("encontra a véspera útil para confirmações", () => {
    expect(diaUtilAnterior("2026-10-05", cfg)).toBe("2026-10-02"); // segunda → sexta
    expect(diaUtilAnterior("2026-10-13", cfg)).toBe("2026-10-09"); // terça após feriado → sexta
    expect(proximoDiaUtil("2026-10-03", cfg)).toBe("2026-10-05");
  });

  it("verifica o horário de funcionamento (08h–19h)", () => {
    expect(dentroDoHorario(new Date("2026-09-29T11:00:00Z"), cfg)).toBe(true); // 08:00 SP
    expect(dentroDoHorario(new Date("2026-09-29T10:59:00Z"), cfg)).toBe(false); // 07:59 SP
    expect(dentroDoHorario(new Date("2026-09-29T22:00:00Z"), cfg)).toBe(false); // 19:00 SP
    expect(dentroDoHorario(new Date("2026-10-03T15:00:00Z"), cfg)).toBe(false); // sábado
  });

  it("saúda e formata datas em português", () => {
    expect(saudacao(new Date("2026-09-29T12:00:00Z"))).toBe("Bom dia"); // 09h SP
    expect(saudacao(new Date("2026-09-29T18:00:00Z"))).toBe("Boa tarde"); // 15h SP
    expect(saudacao(new Date("2026-09-29T23:00:00Z"))).toBe("Boa noite"); // 20h SP
    expect(formatarDataLonga("2026-09-29")).toBe("terça-feira, 29 de setembro");
  });
});

describe("configurações", () => {
  it("completa valores ausentes com os padrões", () => {
    const lidas = lerConfiguracoes({ limite_reativacao_dia: 5 });
    expect(lidas.limite_reativacao_dia).toBe(5);
    expect(lidas.horario).toEqual({ dias: [1, 2, 3, 4, 5], inicio: "08:00", fim: "19:00" });
    expect(lidas.reativacao_automatica).toBe(false);
  });

  it("ignora JSON inválido", () => {
    expect(lerConfiguracoes("lixo")).toEqual(CONFIGURACOES_PADRAO);
  });
});
