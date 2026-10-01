import { somarDias, type DataCivil } from "@/lib/datas";

/** Retorno de public.indicadores(clínica, de, até, procedimento). */
export type Indicadores = {
  leads: { novos: number; convertidos: number; em_negociacao: number; sem_resposta: number; perdidos: number };
  por_procedimento: { procedimento_id: string | null; procedimento: string; leads: number; convertidos: number }[];
  por_canal: { canal: Canal; leads: number; convertidos: number }[];
  por_origem: { origem: string; canal: Canal; leads: number; convertidos: number }[];
  conversao: { leads: number; agendaram: number; consulta: number; orcamento: number; fechamento: number };
  funil: { etapa: string; cor: string | null; tipo: string; quantidade: number }[];
  perdas: {
    total: number;
    grupos: Record<GrupoPerda, number>;
    motivos: { motivo: string; quantidade: number }[];
  };
  reativacao: {
    elegiveis: number;
    reativados: number;
    responderam: number;
    agendaram: number;
    fecharam: number;
    aguardando: number;
    sem_retorno: number;
  };
};

export type Canal = "instagram" | "indicacao" | "google" | "whatsapp" | "paciente_antigo" | "outro";
export const CANAIS: Record<Canal, string> = {
  instagram: "Instagram",
  indicacao: "Indicação",
  google: "Google",
  whatsapp: "WhatsApp",
  paciente_antigo: "Paciente antigo",
  outro: "Outro",
};

export type GrupoPerda = "preco" | "desistiu" | "nao_respondeu" | "outro_local" | "adiou" | "outro";
export const GRUPOS_PERDA: { id: GrupoPerda; rotulo: string }[] = [
  { id: "preco", rotulo: "Preço" },
  { id: "desistiu", rotulo: "Desistiu" },
  { id: "nao_respondeu", rotulo: "Não respondeu" },
  { id: "outro_local", rotulo: "Escolheu outro local" },
  { id: "adiou", rotulo: "Adiou" },
  { id: "outro", rotulo: "Outro" },
];

export type Atalho = "mes" | "mes_passado" | "30d" | "90d" | "ano";
export const ATALHOS: { id: Atalho; rotulo: string }[] = [
  { id: "mes", rotulo: "Este mês" },
  { id: "mes_passado", rotulo: "Mês passado" },
  { id: "30d", rotulo: "Últimos 30 dias" },
  { id: "90d", rotulo: "Últimos 90 dias" },
  { id: "ano", rotulo: "Este ano" },
];

export type Periodo = { de: DataCivil; ate: DataCivil; atalho: Atalho | null };

const ehData = (s: unknown): s is string => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(s));

export function intervaloDoAtalho(atalho: Atalho, hoje: DataCivil): { de: DataCivil; ate: DataCivil } {
  const inicioMes = `${hoje.slice(0, 7)}-01`;
  switch (atalho) {
    case "mes":
      return { de: inicioMes, ate: hoje };
    case "mes_passado": {
      const fim = somarDias(inicioMes, -1);
      return { de: `${fim.slice(0, 7)}-01`, ate: fim };
    }
    case "30d":
      return { de: somarDias(hoje, -29), ate: hoje };
    case "90d":
      return { de: somarDias(hoje, -89), ate: hoje };
    case "ano":
      return { de: `${hoje.slice(0, 4)}-01-01`, ate: hoje };
  }
}

/**
 * Período pedido na URL: um atalho (?periodo=90d) ou datas (?de=…&ate=…).
 * Sem nada (ou inválido), "Este mês". Datas invertidas são trocadas; no máximo 5 anos.
 */
export function resolverPeriodo(busca: { periodo?: string; de?: string; ate?: string }, hoje: DataCivil): Periodo {
  const atalho = ATALHOS.find((a) => a.id === busca.periodo)?.id;
  if (atalho) return { ...intervaloDoAtalho(atalho, hoje), atalho };
  if (ehData(busca.de) || ehData(busca.ate)) {
    let de = ehData(busca.de) ? busca.de : ehData(busca.ate) ? busca.ate : hoje;
    let ate = ehData(busca.ate) ? busca.ate : hoje;
    if (de > ate) [de, ate] = [ate, de];
    if (de < somarDias(ate, -5 * 366)) de = somarDias(ate, -5 * 366);
    const igual = ATALHOS.find((a) => {
      const i = intervaloDoAtalho(a.id, hoje);
      return i.de === de && i.ate === ate;
    });
    return { de, ate, atalho: igual?.id ?? null };
  }
  return { ...intervaloDoAtalho("mes", hoje), atalho: "mes" };
}

const MESES = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"];
/** "01 a 30 de set de 2026", "15 de ago a 30 de set de 2026"… */
export function rotuloPeriodo({ de, ate }: { de: DataCivil; ate: DataCivil }): string {
  const [ad, md, dd] = de.split("-");
  const [aa, ma, da] = ate.split("-");
  const mes = (m: string) => MESES[Number(m) - 1];
  if (de === ate) return `${dd} de ${mes(md)} de ${ad}`;
  if (ad === aa && md === ma) return `${dd} a ${da} de ${mes(ma)} de ${aa}`;
  if (ad === aa) return `${dd} de ${mes(md)} a ${da} de ${mes(ma)} de ${aa}`;
  return `${dd} de ${mes(md)} de ${ad} a ${da} de ${mes(ma)} de ${aa}`;
}

/** Percentual inteiro (0 quando a base é zero). */
export function pct(parte: number, total: number): number {
  return total > 0 ? Math.round((parte / total) * 100) : 0;
}

/** Etapas da conversão, cada uma com o % sobre os leads e sobre a etapa anterior. */
export function etapasConversao(c: Indicadores["conversao"]) {
  const passos = [
    { id: "leads", rotulo: "Novos leads", valor: c.leads },
    { id: "agendaram", rotulo: "Agendaram consulta", valor: c.agendaram },
    { id: "consulta", rotulo: "Chegaram à consulta", valor: c.consulta },
    { id: "orcamento", rotulo: "Receberam orçamento", valor: c.orcamento },
    { id: "fechamento", rotulo: "Fecharam", valor: c.fechamento },
  ];
  return passos.map((p, i) => ({
    ...p,
    sobreLeads: pct(p.valor, c.leads),
    sobreAnterior: i === 0 ? null : pct(p.valor, passos[i - 1].valor),
  }));
}
