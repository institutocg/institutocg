import { ArrowLeft, CalendarClock } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { z } from "zod";
import { Bloco, FichaConsulta, type FichaInicial } from "@/components/prontuario/ficha";
import { PagamentoPlano, PlanoTratamento } from "@/components/prontuario/plano";
import { comoUsuaria } from "@/lib/db";
import { diferencasOdontograma, normalizarOdontograma, tituloConsulta } from "@/modules/prontuario/prontuario";
import { carregarCatalogo, carregarPaciente, carregarPagamentoPlano, carregarPlano } from "@/modules/prontuario/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import { SemAcessoProntuario } from "../../../sem-acesso";

export const metadata = { title: "Consulta · Prontuário · Instituto CG" };

interface Linha {
  id: string;
  numero: number;
  data: string;
  horario: string | null;
  tipo: string | null;
  procedimento: string | null;
  profissional: string | null;
  profissional_id: string | null;
  agendamento_id: string | null;
  status: "em_andamento" | "finalizado";
  motivo: string[];
  motivo_obs: string | null;
  queixa: string | null;
  anamnese: string[];
  anamnese_obs: string | null;
  diagnostico: string[];
  diagnostico_obs: string | null;
  evolucao: string | null;
  orientacoes: string[];
  orientacoes_obs: string | null;
  retorno_em: string | null;
  retorno_obs: string | null;
  odontograma: unknown;
  anterior_odontograma: unknown;
  anterior_numero: number | null;
}

export default async function Consulta({ params }: { params: Promise<{ pessoaId: string; atendimentoId: string }> }) {
  const sessao = await exigirSessao();
  if (!sessao.podeVerProntuario) return <SemAcessoProntuario />;
  const { pessoaId, atendimentoId } = await params;
  if (!z.uuid().safeParse(pessoaId).success || !z.uuid().safeParse(atendimentoId).success) notFound();

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    const paciente = await carregarPaciente(db, pessoaId);
    const { rows } = await db.query<Linha>(
      `select a.id, a.numero, a.data, to_char(a.horario, 'HH24:MI') as horario, a.tipo, pr.nome as procedimento,
              pf.nome as profissional, a.profissional_id, a.agendamento_id, a.status, a.motivo, a.motivo_obs, a.queixa, a.anamnese,
              a.anamnese_obs, a.diagnostico, a.diagnostico_obs, a.evolucao, a.orientacoes, a.orientacoes_obs, a.retorno_em,
              a.retorno_obs, a.odontograma, ant.odontograma as anterior_odontograma, ant.numero as anterior_numero
         from public.atendimentos a
         left join public.procedimentos pr on pr.id = a.procedimento_id
         left join public.profissionais pf on pf.id = a.profissional_id
         left join lateral (
           select x.odontograma, x.numero from public.atendimentos x
            where x.prontuario_id = a.prontuario_id and x.numero < a.numero order by x.numero desc limit 1
         ) ant on true
        where a.id = $1 and a.pessoa_id = $2`,
      [atendimentoId, pessoaId],
    );
    if (!paciente || !rows[0]) return null;
    const hoje = (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId])).rows[0].hoje;
    const plano = await carregarPlano(db, pessoaId);
    const catalogo = await carregarCatalogo(db, sessao.clinicaId);
    const pagamento = await carregarPagamentoPlano(db, pessoaId, sessao.podeVerFinanceiro);
    return { paciente, a: rows[0], hoje, plano, catalogo, pagamento };
  });
  if (!d) notFound();

  const { a, paciente: p } = d;
  const finalizada = a.status === "finalizado";
  const odonto = normalizarOdontograma(a.odontograma);
  const anterior = a.anterior_numero ? normalizarOdontograma(a.anterior_odontograma) : null;
  const mudancas = anterior ? diferencasOdontograma(anterior, odonto) : [];
  const inicial: FichaInicial = {
    profissional_id: a.profissional_id ?? "",
    motivo_obs: a.motivo_obs ?? "",
    queixa: a.queixa ?? "",
    anamnese_obs: [a.anamnese.join(", "), a.anamnese_obs].filter(Boolean).join("\n"),
    odontograma: odonto,
  };

  return (
    <div className="mx-auto max-w-4xl px-4 py-8 sm:px-8 lg:py-10">
      <Link href={`/prontuario/${p.id}`} className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Prontuário de {p.nome}
      </Link>
      <header className="mt-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <p className="text-[11px] font-semibold tracking-[0.12em] text-sutil uppercase">{p.nome}</p>
          <h1 className="mt-1 font-titulo text-3xl leading-tight sm:text-4xl">{tituloConsulta(a)}</h1>
          <p className="mt-1 text-sm text-suave">
            {[a.horario && `às ${a.horario}`, a.profissional, a.agendamento_id ? "aberta pela agenda" : null, finalizada ? "finalizada" : "em andamento"]
              .filter(Boolean)
              .join(" · ")}
          </p>
        </div>
        {!finalizada && (
          <Link href={`/agenda?novo=${p.id}`} className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado">
            <CalendarClock className="size-4 text-dourado" /> Agendar retorno
          </Link>
        )}
      </header>

      <div className="mt-6">
        <FichaConsulta
          atendimentoId={a.id}
          inicial={inicial}
          finalizada={finalizada}
          profissionais={d.catalogo.profissionais}
          odontogramaAnterior={
            anterior
              ? mudancas.length
                ? `Desde a consulta ${String(a.anterior_numero).padStart(2, "0")}: ${mudancas.join("; ")}.`
                : `Começou igual ao da consulta ${String(a.anterior_numero).padStart(2, "0")}.`
              : null
          }
          plano={
            <>
              <Bloco titulo="Procedimentos / plano de tratamento" id="procedimentos-consulta">
                <p className="-mt-1 mb-3 text-xs text-sutil">Marque “Feito hoje” no que foi realizado nesta consulta. O resto fica pendente para as próximas.</p>
                <PlanoTratamento pessoaId={p.id} itens={d.plano} sugestoes={d.catalogo.procedimentos} atendimentoId={a.id} travado={finalizada} />
              </Bloco>
              {sessao.podeVerFinanceiro && (
                <Bloco titulo="Pagamento" id="pagamento-consulta">
                  <PagamentoPlano planoId={d.pagamento.planoId} situacao={d.pagamento.situacao} formas={d.catalogo.formas} parcelas={d.pagamento.parcelas} hoje={d.hoje} />
                </Bloco>
              )}
            </>
          }
        />
      </div>
    </div>
  );
}
