import { describe, expect, it } from "vitest";
import {
  montarQuadro,
  resumoQuadro,
  rotuloTempoNaEtapa,
  rotuloUltimaInteracao,
  type EtapaFunil,
  type NegociacaoFunil,
} from "@/modules/funil/funil";

const HOJE = "2026-09-29";
const etapa = (id: string, ordem: number, extra: Partial<EtapaFunil> = {}): EtapaFunil => ({
  id, nome: id, ordem, tipo: "aberta", resultado: null, marco: id, cor: "#000", sla_dias: null, ...extra,
});
const ETAPAS: EtapaFunil[] = [
  etapa("novo_contato", 1, { sla_dias: 0 }),
  etapa("orcamento_apresentado", 5, { sla_dias: 7 }),
  etapa("sem_resposta", 8, { tipo: "perda", resultado: "sem_resposta", marco: null }),
  etapa("fechou", 10, { tipo: "ganho", resultado: "fechou", marco: null }),
  etapa("nao_fechou", 11, { tipo: "perda", resultado: "nao_fechou", marco: null }),
  etapa("desistiu", 12, { tipo: "perda", resultado: "desistiu", marco: null }),
];

let n = 0;
const neg = (etapa_id: string, extra: Partial<NegociacaoFunil> = {}): NegociacaoFunil => ({
  id: `o${++n}`, pessoa_id: `p${n}`, nome: `Pessoa ${n}`, procedimento: "Facetas", etapa_id, status: "aberta",
  resultado: null, dias_na_etapa: 1, primeiro_contato_em: "2026-09-01", ultimo_contato_em: null,
  proxima_acao: "Retornar", proxima_acao_em: HOJE, valor_potencial_centavos: null, motivo: null, ...extra,
});

describe("quadro do funil", () => {
  const quadro = montarQuadro(
    [...ETAPAS].reverse(),
    [
      neg("orcamento_apresentado", { nome: "Parada", dias_na_etapa: 9, valor_potencial_centavos: 1_000_000 }),
      neg("orcamento_apresentado", { nome: "Atrasada", proxima_acao_em: "2026-09-25", valor_potencial_centavos: 500_000 }),
      neg("novo_contato", { nome: "Sem ação", proxima_acao: null, proxima_acao_em: null }),
      neg("desistiu", { nome: "Desistiu", status: "perdida", resultado: "desistiu" }),
      neg("nao_fechou", { nome: "Não fechou", status: "perdida", resultado: "nao_fechou", valor_potencial_centavos: 900_000 }),
      neg("sem_resposta", { nome: "Sumiu", status: "pausada", dias_na_etapa: 30 }),
    ],
    HOJE,
  );

  it("colunas em ordem; 'Desistiu' fica dentro de 'Não fechou'", () => {
    expect(quadro.map((c) => c.etapa.id)).toEqual(["novo_contato", "orcamento_apresentado", "sem_resposta", "fechou", "nao_fechou"]);
    const nf = quadro.find((c) => c.etapa.id === "nao_fechou")!;
    expect(nf.cartoes.map((c) => c.nome).sort()).toEqual(["Desistiu", "Não fechou"]);
    expect(nf.cartoes.find((c) => c.nome === "Desistiu")!.desistiu).toBe(true);
    expect(nf.encerrada).toBe(true);
    expect(quadro.find((c) => c.etapa.id === "sem_resposta")!.encerrada).toBe(false);
  });

  it("marca quem precisa de atenção e ordena por urgência", () => {
    const orc = quadro.find((c) => c.etapa.id === "orcamento_apresentado")!;
    expect(orc.cartoes.map((c) => c.nome)).toEqual(["Atrasada", "Parada"]);
    expect(orc.cartoes[0].acaoAtrasada).toBe(true);
    expect(orc.cartoes[1].parada).toBe(true); // 9 dias > prazo de 7
    expect(orc.totalCentavos).toBe(1_500_000);
    expect(quadro[0].cartoes[0].semProximaAcao).toBe(true);
    expect(quadro.find((c) => c.etapa.id === "sem_resposta")!.cartoes[0].parada).toBe(false); // sem prazo
  });

  it("resumo considera só negociações em andamento", () => {
    expect(resumoQuadro(quadro)).toEqual({ emAndamento: 4, potencialCentavos: 1_500_000, precisamAtencao: 2 });
  });
});

describe("rótulos", () => {
  it("última interação", () => {
    expect(rotuloUltimaInteracao(null, HOJE)).toBe("nenhuma ainda");
    expect(rotuloUltimaInteracao("2026-09-29T15:00:00Z", HOJE)).toBe("hoje");
    expect(rotuloUltimaInteracao("2026-09-28T15:00:00Z", HOJE)).toBe("ontem");
    expect(rotuloUltimaInteracao("2026-09-24T15:00:00Z", HOJE)).toBe("há 5 dias");
    // 01:00 UTC do dia 29 ainda é dia 28 em São Paulo
    expect(rotuloUltimaInteracao("2026-09-29T01:00:00Z", HOJE)).toBe("ontem");
  });
  it("tempo na etapa", () => {
    expect(rotuloTempoNaEtapa(0)).toBe("entrou hoje");
    expect(rotuloTempoNaEtapa(1)).toBe("há 1 dia na etapa");
    expect(rotuloTempoNaEtapa(12)).toBe("há 12 dias na etapa");
  });
});
