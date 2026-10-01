import { ArrowLeft, CalendarClock } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { z } from "zod";
import { Bloco, FichaConsulta, type FichaInicial } from "@/components/prontuario/ficha";
import { PlanoTratamento } from "@/components/prontuario/plano";
import { comoUsuaria } from "@/lib/db";
import { diferencasOdontograma, normalizarOdontograma, tituloConsulta } from "@/modules/prontuario/prontuario";
import { carregarCatalogo, carregarPaciente, carregarPlano } from "@/modules/prontuario/servidor";
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
              pf.nome as profissional, a.profissional_id, a.agendamento_id, a.status, a.motivo, a.motivo_obs, a.anamnese,
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
    return { paciente, a: rows[0], hoje, plano, catalogo };
  });
  if (!d) notFound();

  const { a, paciente: p } = d;
  const finalizada = a.status === "finalizado";
  const odonto = normalizarOdontograma(a.odontograma);
  const anterior = a.anterior_numero ? normalizarOdontograma(a.anterior_odontograma) : null;
  const mudancas = anterior ? diferencasOdontograma(anterior, odonto) : [];
  const inicial: FichaInicial = {
    profissional_id: a.profissional_id ?? "",
    motivo: a.motivo,
    motivo_obs: a.motivo_obs ?? "",
    anamnese: a.anamnese,
    anamnese_obs: a.anamnese_obs ?? "",
    diagnostico: a.diagnostico,
    diagnostico_obs: a.diagnostico_obs ?? "",
    evolucao: a.evolucao ?? "",
    orientacoes: a.orientacoes,
    orientacoes_obs: a.orientacoes_obs ?? "",
    retorno_em: a.retorno_em ?? "",
    retorno_obs: a.retorno_obs ?? "",
    odontograma: odonto,
  };
  const daConsulta = d.plano.filter((i) => i.realizado_atendimento_id === a.id);
  const aFazer = d.plano.filter((i) => i.status === "orcado" || i.status === "aceito" || i.status === "pendente");

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
          hoje={d.hoje}
          profissionais={d.catalogo.profissionais}
          odontogramaAnterior={
            anterior
              ? mudancas.length
                ? `Desde a consulta ${String(a.anterior_numero).padStart(2, "0")}: ${mudancas.join("; ")}.`
                : `Começou igual ao da consulta ${String(a.anterior_numero).padStart(2, "0")}.`
              : null
          }
          plano={
            <Bloco titulo="Procedimentos" id="procedimentos-consulta">
              <h3 className="text-xs font-semibold tracking-wide text-sutil uppercase">Realizados nesta consulta</h3>
              {daConsulta.length === 0 ? (
                <p className="mt-1 mb-4 text-sm text-sutil">Nenhum ainda. Marque abaixo o que foi feito hoje.</p>
              ) : (
                <div className="mt-2 mb-4">
                  <PlanoTratamento
                    pessoaId={p.id}
                    itens={daConsulta}
                    procedimentos={d.catalogo.procedimentos}
                    formas={d.catalogo.formas}
                    podeVerFinanceiro={sessao.podeVerFinanceiro}
                    editavel={false}
                  />
                </div>
              )}
              {!finalizada && (
                <>
                  <h3 className="text-xs font-semibold tracking-wide text-sutil uppercase">Plano de tratamento (planejados e pendentes)</h3>
                  <div className="mt-2">
                    <PlanoTratamento
                      pessoaId={p.id}
                      itens={aFazer}
                      procedimentos={d.catalogo.procedimentos}
                      formas={d.catalogo.formas}
                      atendimentoId={a.id}
                      podeVerFinanceiro={sessao.podeVerFinanceiro}
                      editavel
                    />
                  </div>
                </>
              )}
            </Bloco>
          }
        />
      </div>
    </div>
  );
}
