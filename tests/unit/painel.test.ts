import { describe, expect, it } from "vitest";
import {
  acaoRecomendada,
  classificar,
  fraseResumo,
  montarCartao,
  montarPainel,
  motivoDoContato,
  rotuloData,
  type TarefaAberta,
  type TipoTarefa,
} from "@/modules/painel/painel";

const HOJE = "2026-09-29"; // terça-feira

let seq = 0;
function tarefa(dados: Partial<TarefaAberta> = {}): TarefaAberta {
  seq += 1;
  return {
    id: `t${seq}`,
    pessoa_id: `p${seq}`,
    oportunidade_id: "o1",
    agendamento_id: null,
    parcela_id: null,
    tipo: "follow_up",
    titulo: "Acompanhar",
    descricao: null,
    vence_em: HOJE,
    horario: null,
    prioridade: "normal",
    passo: 1,
    regra: null,
    mensagem_sugerida: "Olá!",
    pessoa_nome: "Maria Silva",
    whatsapp_e164: "+5511999990001",
    telefone_e164: null,
    origem_nome: null,
    primeiro_contato_em: null,
    procedimento: "Facetas de porcelana",
    etapa_marco: "em_contato",
    orcamento_apresentado_em: null,
    orcamento_valor_centavos: null,
    agendamento_inicio: null,
    agendamento_tipo: null,
    parcela_numero: null,
    parcela_vencimento: null,
    parcela_saldo_centavos: null,
    parcela_total: null,
    ...dados,
  };
}

describe("classificação por prioridade", () => {
  it.each<[TipoTarefa, Partial<TarefaAberta>, string]>([
    ["primeiro_contato", {}, "urgente"],
    ["recuperar_desmarcacao", {}, "urgente"],
    ["recuperar_falta", {}, "urgente"],
    ["follow_up", { regra: "pediu_retorno" }, "urgente"], // pediu retorno para hoje
    ["confirmar_pagamento", { vence_em: "2026-09-25" }, "urgente"], // pagamento atrasado
    ["confirmar_pagamento", {}, "importante"], // pagamento do dia
    ["follow_up_orcamento", {}, "importante"],
    ["acompanhar_decisao", {}, "importante"], // está pensando
    ["follow_up", { regra: "em_contato" }, "importante"], // demonstrou interesse
    ["follow_up", {}, "importante"],
    ["retorno_por_motivo", {}, "importante"],
    ["reabrir_sem_resposta", {}, "importante"],
    ["apresentar_orcamento", {}, "importante"],
    ["agendar_tratamento", {}, "importante"],
    ["definir_proxima_acao", {}, "importante"],
    ["confirmar_agendamento", {}, "rotina"],
    ["reativacao", {}, "rotina"],
    ["manutencao", {}, "rotina"],
    ["personalizada", {}, "rotina"],
    ["personalizada", { prioridade: "alta" }, "importante"],
    ["reativacao", { prioridade: "urgente" }, "urgente"], // marcada como urgente à mão
  ])("%s %o → %s", (tipo, extra, esperado) => {
    expect(classificar(tarefa({ tipo, ...extra }), HOJE)).toBe(esperado);
  });
});

describe("textos do cartão", () => {
  it("orçamento enviado há N dias (exemplo da Maria)", () => {
    const t = tarefa({
      tipo: "follow_up_orcamento",
      orcamento_apresentado_em: "2026-09-24",
      orcamento_valor_centavos: 1_400_000,
    });
    expect(motivoDoContato(t, HOJE)).toBe("Orçamento de R$ 14.000,00 enviado há 5 dias");
    expect(acaoRecomendada(t, HOJE)).toBe("Fazer follow-up hoje: perguntar se ficou alguma dúvida sobre o orçamento.");
    expect(acaoRecomendada({ ...t, passo: 3 }, HOJE)).toContain("conversa com a doutora");
  });

  it("desmarcou (exemplo do João)", () => {
    const t = tarefa({
      tipo: "recuperar_desmarcacao",
      pessoa_nome: "João Silva",
      agendamento_inicio: "2026-09-30T13:00:00Z", // 10:00 em São Paulo
    });
    expect(motivoDoContato(t, HOJE)).toBe("Desmarcou a consulta de amanhã às 10:00");
    expect(acaoRecomendada(t, HOJE)).toBe("Entrar em contato para entender se deseja remarcar.");
    const c = montarCartao(t, HOJE);
    expect(c.botoes).toEqual(["abrir_paciente", "ver_mensagem", "registrar_contato"]);
  });

  it("pagamento previsto hoje (exemplo de pagamento)", () => {
    const t = tarefa({
      tipo: "confirmar_pagamento",
      parcela_id: "pa1",
      parcela_numero: 2,
      parcela_total: 10,
      parcela_vencimento: HOJE,
      parcela_saldo_centavos: 250_000,
      procedimento: "Facetas",
    });
    const c = montarCartao(t, HOJE);
    expect(c.titulo).toBe("Pagamento previsto");
    expect(c.subtitulo).toBe("Maria Silva — R$ 2.500,00");
    expect(c.procedimento).toBe("Facetas");
    expect(c.motivo).toBe("Parcela 2 de 10 · vencimento 29/09");
    expect(c.botoes.slice(0, 2)).toEqual(["ver_negociacao", "marcar_pago"]);
    expect(c.botoes).not.toContain("concluir");
    expect(c.registro).toBe("pagamento");
  });

  it("pagamento em atraso: singular e plural; entrada", () => {
    const base = { tipo: "confirmar_pagamento" as const, parcela_saldo_centavos: 80_000 };
    const um = montarCartao(tarefa({ ...base, vence_em: "2026-09-28", parcela_vencimento: "2026-09-28" }), HOJE);
    expect(um.titulo).toBe("Pagamento atrasado");
    expect(um.motivo).toMatch(/^Vencido há 1 dia · /);
    const c = montarCartao(tarefa({ ...base, vence_em: "2026-09-24", parcela_vencimento: "2026-09-24" }), HOJE);
    expect(c.titulo).toBe("Pagamento atrasado");
    expect(c.motivo).toMatch(/^Vencido há 5 dias · /);
    expect(c.acaoRecomendada).toBe("Lembrar Maria do pagamento, com gentileza.");
    expect(motivoDoContato(tarefa({ ...base, parcela_numero: 0, parcela_vencimento: HOJE }), HOJE))
      .toBe("Entrada · vencimento 29/09");
  });

  it("pagamento combinado para outra data usa a data da parcela no título", () => {
    const c = montarCartao(
      tarefa({ tipo: "confirmar_pagamento", vence_em: "2026-10-01", parcela_vencimento: "2026-09-25", parcela_saldo_centavos: 100 }),
      HOJE,
    );
    expect(c.titulo).toBe("Pagamento atrasado");
    expect(c.motivo).toMatch(/^Vencido há 4 dias/);
  });

  it("primeiro contato mostra origem e quando chegou; tentativas seguintes", () => {
    const t = tarefa({ tipo: "primeiro_contato", origem_nome: "Instagram", primeiro_contato_em: HOJE });
    expect(motivoDoContato(t, HOJE)).toBe("Novo contato — via Instagram, chegou hoje");
    expect(acaoRecomendada(t, HOJE)).toContain("ainda hoje");
    expect(acaoRecomendada({ ...t, passo: 3 }, HOJE)).toBe("Fazer a 3ª tentativa de contato.");
    expect(motivoDoContato(tarefa({ tipo: "primeiro_contato" }), HOJE)).toBe("Novo contato");
  });

  it("confirmação de agendamento", () => {
    const t = tarefa({ tipo: "confirmar_agendamento", agendamento_tipo: "avaliacao", agendamento_inicio: "2026-09-30T17:30:00Z" });
    expect(motivoDoContato(t, HOJE)).toBe("Avaliação amanhã às 14:30");
    expect(montarCartao(t, HOJE).registro).toBe("agendamento");
    expect(acaoRecomendada({ ...t, passo: 2 }, HOJE)).toBe("Tentar confirmar a presença novamente.");
  });

  it("desmarcou e sem resposta: registro de recuperação, com o nome da regra", () => {
    const t = tarefa({ tipo: "recuperar_desmarcacao", regra: "desmarcou", regra_nome: "Paciente desmarcou" });
    const c = montarCartao(t, HOJE);
    expect(c.registro).toBe("recuperacao");
    expect(c.regraNome).toBe("Paciente desmarcou");
    expect(c.botoes).not.toContain("concluir");
    expect(montarCartao(tarefa({ tipo: "reabrir_sem_resposta" }), HOJE).registro).toBe("recuperacao");
  });

  it("reativação, campanha e retorno após o tratamento", () => {
    expect(montarCartao(tarefa({ tipo: "reativacao" }), HOJE).registro).toBe("reativacao");
    expect(acaoRecomendada(tarefa({ tipo: "reativacao", regra: "campanha" }), HOJE)).toBe(
      "Enviar a mensagem da campanha, com um convite pessoal.",
    );
    expect(acaoRecomendada(tarefa({ tipo: "manutencao", regra: "pos_tratamento" }), HOJE)).toBe(
      "Convidar para a revisão após o tratamento.",
    );
  });

  it("cobre todos os tipos com um motivo e uma ação", () => {
    const tipos: TipoTarefa[] = [
      "primeiro_contato", "follow_up", "follow_up_orcamento", "confirmar_agendamento",
      "recuperar_desmarcacao", "recuperar_falta", "reabrir_sem_resposta", "retorno_por_motivo",
      "reativacao", "manutencao", "confirmar_pagamento", "apresentar_orcamento",
      "agendar_tratamento", "definir_proxima_acao", "personalizada", "acompanhar_decisao",
    ];
    for (const tipo of tipos) {
      const t = tarefa({ tipo, descricao: tipo === "reativacao" ? "Último atendimento em 02/2025" : null });
      expect(motivoDoContato(t, HOJE).length, tipo).toBeGreaterThan(3);
      expect(acaoRecomendada(t, HOJE).length, tipo).toBeGreaterThan(3);
    }
  });

  it("retorno combinado: hoje × data futura", () => {
    const t = tarefa({ tipo: "follow_up", regra: "pediu_retorno" });
    expect(acaoRecomendada(t, HOJE)).toBe("Retornar hoje, como combinado.");
    expect(acaoRecomendada({ ...t, vence_em: "2026-10-05" }, HOJE)).toBe("Retornar na data combinada.");
  });

  it("saiu da consulta sem fechar: acompanhamento leve, que muda a cada contato", () => {
    const t = tarefa({ tipo: "acompanhar_decisao", descricao: "Ficou de pensar", orcamento_valor_centavos: 900_000 });
    expect(motivoDoContato(t, HOJE)).toBe("Passou pela consulta e está decidindo (orçamento de R$ 9.000,00) — ficou de pensar");
    expect(motivoDoContato({ ...t, orcamento_apresentado_em: "2026-09-22" }, HOJE)).toBe(
      "Recebeu o orçamento de R$ 9.000,00 na consulta há 7 dias — ficou de pensar",
    );
    expect(acaoRecomendada(t, HOJE)).toContain("sem pressionar");
    expect(acaoRecomendada({ ...t, passo: 2 }, HOJE)).toContain("conversa com a doutora");
    expect(acaoRecomendada({ ...t, passo: 3 }, HOJE)).toContain("porta aberta");
  });

  it("'compareceu?' pede o registro de comparecimento", () => {
    const t = tarefa({ tipo: "definir_proxima_acao", titulo: "Ana compareceu?", pessoa_nome: "Ana Lima" });
    expect(acaoRecomendada(t, HOJE)).toBe("Registrar se Ana compareceu à consulta.");
  });

  it("mesmo sem mensagem guardada na tarefa, 'Ver mensagem' aparece (a biblioteca sugere uma)", () => {
    expect(montarCartao(tarefa({ mensagem_sugerida: null }), HOJE).botoes).toContain("ver_mensagem");
  });

  it("rótulos de data", () => {
    expect(rotuloData(HOJE, HOJE)).toBe("Hoje");
    expect(rotuloData(HOJE, HOJE, "15:00:00")).toBe("Hoje às 15:00");
    expect(rotuloData("2026-09-30", HOJE)).toBe("Amanhã");
    expect(rotuloData("2026-09-28", HOJE)).toBe("Ontem");
    expect(rotuloData("2026-09-26", HOJE)).toBe("Atrasada há 3 dias");
    expect(rotuloData("2026-10-02", HOJE)).toBe("sex. 02/10");
  });
});

describe("montagem do painel", () => {
  const tarefas = [
    tarefa({ tipo: "reativacao", pessoa_nome: "Sofia" }),
    tarefa({ tipo: "primeiro_contato", pessoa_nome: "Beatriz" }),
    tarefa({ tipo: "follow_up_orcamento", pessoa_nome: "Maria" }),
    tarefa({ tipo: "confirmar_pagamento", vence_em: "2026-09-24", parcela_vencimento: "2026-09-24", pessoa_nome: "Paulo" }),
    tarefa({ tipo: "follow_up", vence_em: "2026-09-27", pessoa_nome: "João" }),
    tarefa({ tipo: "follow_up", vence_em: "2026-10-01", pessoa_nome: "Luiza" }),
    tarefa({ tipo: "follow_up", vence_em: "2026-10-01", pessoa_nome: "Bruna", prioridade: "alta" }),
    tarefa({ tipo: "follow_up", vence_em: "2026-10-03", pessoa_nome: "Fernanda" }),
    tarefa({ tipo: "confirmar_pagamento", vence_em: "2026-10-29", pessoa_nome: "Ana" }), // fora da janela de 7 dias
  ];
  const p = montarPainel(tarefas, HOJE);

  it("separa atrasadas, hoje (por prioridade) e próximos dias", () => {
    expect(p.atrasadas.map((c) => c.subtitulo ?? c.titulo)).toEqual(["Paulo", "João"]);
    expect(p.atrasadas[0].grupo).toBe("urgente"); // pagamento atrasado vem primeiro
    expect(p.doDia.urgente.map((c) => c.titulo)).toEqual(["Beatriz"]);
    expect(p.doDia.importante.map((c) => c.titulo)).toEqual(["Maria"]);
    expect(p.doDia.rotina.map((c) => c.titulo)).toEqual(["Sofia"]);
    expect(p.proximos.map((d) => [d.dia, d.cartoes.map((c) => c.titulo)])).toEqual([
      ["2026-10-01", ["Bruna", "Luiza"]],
      ["2026-10-03", ["Fernanda"]],
    ]);
  });

  it("resume o dia em uma frase", () => {
    expect(p.resumo).toEqual({ totalHoje: 5, atrasadas: 2, urgentes: 1, importantes: 1, rotina: 1, proximos: 3 });
    expect(fraseResumo(p)).toBe("Hoje você tem 5 ações: 2 atrasadas, 1 urgente, 1 importante e 1 de rotina.");
  });

  it("estados vazios", () => {
    expect(fraseResumo(montarPainel([], HOJE))).toBe("Tudo em dia por aqui. Nenhuma ação pendente.");
    const soFuturo = montarPainel([tarefa({ vence_em: "2026-10-01" })], HOJE);
    expect(fraseResumo(soFuturo)).toBe("Tudo em dia por aqui. Há 1 ação programada para os próximos dias.");
    const umaSo = montarPainel([tarefa({ tipo: "reativacao" })], HOJE);
    expect(fraseResumo(umaSo)).toBe("Hoje você tem 1 ação: 1 de rotina.");
  });
});
