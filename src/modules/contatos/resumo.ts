import type { DataCivil } from "@/lib/datas";
import { formatarMoedaCompacta } from "@/lib/moeda";
import { rotuloData } from "@/modules/painel/painel";
import { rotuloUltimoAtendimento } from "./cadastro";

export interface DadosResumo {
  tipo_cadastro: "novo_contato" | "paciente_antigo";
  relacionamento: "lead" | "paciente_ativo" | "paciente_inativo";
  primeiro_contato_em: DataCivil;
  origem: string | null;
  ultimo_atendimento_informado: DataCivil | null;
  ultimo_atendimento_faixa: string | null;
  etapa_atual: string | null;
  status_atual: string;
  procedimento_interesse: string | null;
  dias_na_etapa: number | null;
  valor_estimado_centavos: number | null;
  proxima_acao: string | null;
  proxima_acao_em: DataCivil | null;
  nao_contatar: boolean;
}

function dataBr(d: DataCivil) {
  return d.split("-").reverse().join("/");
}

/** Situação comercial em três frases curtas, para entender o paciente em segundos. */
export function resumoComercial(c: DadosResumo, hoje: DataCivil, ultimoTratamento?: string | null): string[] {
  const frases: string[] = [];

  if (c.relacionamento === "lead") {
    frases.push(`Novo contato desde ${dataBr(c.primeiro_contato_em)}${c.origem ? ` (${c.origem})` : ""}.`);
  } else {
    const ultimo = rotuloUltimoAtendimento(c.ultimo_atendimento_informado, c.ultimo_atendimento_faixa);
    const quando = ultimo && ultimo !== "Não lembra" ? (ultimo.startsWith("Há") ? ultimo.toLowerCase() : `em ${ultimo}`) : null;
    const base = c.relacionamento === "paciente_ativo" ? "Paciente ativo" : "Paciente antigo, sem atendimento recente";
    const detalhe = [quando && `último atendimento ${quando}`, ultimoTratamento && `já fez ${ultimoTratamento.toLowerCase()}`]
      .filter(Boolean)
      .join("; ");
    frases.push(`${base}${detalhe ? ` — ${detalhe}` : ""}.`);
  }

  if (c.nao_contatar) {
    frases.push("Pediu para não receber contatos.");
  } else if (c.etapa_atual) {
    const dias = c.dias_na_etapa ?? 0;
    const tempo = dias === 0 ? "desde hoje" : `há ${dias} ${dias === 1 ? "dia" : "dias"}`;
    const valor = c.valor_estimado_centavos ? `, valor estimado ${formatarMoedaCompacta(c.valor_estimado_centavos)}` : "";
    const interesse = c.procedimento_interesse ? `Interesse em ${c.procedimento_interesse.toLowerCase()}` : "Interesse ainda não definido";
    frases.push(`${interesse} — etapa “${c.etapa_atual}” ${tempo}${valor}.`);
  } else {
    frases.push("Sem negociação em andamento.");
  }

  if (c.proxima_acao && c.proxima_acao_em) {
    frases.push(`Próxima ação: ${c.proxima_acao} — ${rotuloData(c.proxima_acao_em, hoje).toLowerCase()}.`);
  } else if (!c.nao_contatar) {
    frases.push("Nenhuma ação pendente.");
  }
  return frases;
}
