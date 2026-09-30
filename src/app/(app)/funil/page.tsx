import { Search } from "lucide-react";
import { z } from "zod";
import { Quadro } from "@/components/funil/quadro";
import { comoUsuaria } from "@/lib/db";
import { formatarMoedaCompacta } from "@/lib/moeda";
import { montarQuadro, resumoQuadro } from "@/modules/funil/funil";
import { carregarFunil } from "@/modules/funil/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Funil · Instituto CG" };

const uuidOuNulo = (v: string | undefined) => (v && z.uuid().safeParse(v).success ? v : null);

export default async function Funil({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; procedimento?: string; responsavel?: string }>;
}) {
  const sessao = await exigirSessao();
  const busca = await searchParams;
  const filtros = {
    busca: busca.q ?? "",
    procedimentoId: uuidOuNulo(busca.procedimento),
    responsavelId: uuidOuNulo(busca.responsavel),
  };
  const dados = await comoUsuaria(sessao.usuarioId, (db) => carregarFunil(db, sessao.clinicaId, filtros));
  const colunas = montarQuadro(dados.etapas, dados.negociacoes, dados.hoje);
  const resumo = resumoQuadro(colunas);
  const filtrando = Boolean(filtros.busca || filtros.procedimentoId || filtros.responsavelId);

  return (
    <div className="px-4 py-8 sm:px-8 lg:py-10">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-titulo text-4xl">Funil</h1>
          <p className="mt-1 text-suave">
            {resumo.emAndamento} {resumo.emAndamento === 1 ? "negociação em andamento" : "negociações em andamento"}
            {resumo.potencialCentavos > 0 && ` · ${formatarMoedaCompacta(resumo.potencialCentavos)} em potencial`}
            {resumo.precisamAtencao > 0 && (
              <span className="text-urgente">
                {" "}
                · {resumo.precisamAtencao} {resumo.precisamAtencao === 1 ? "precisa" : "precisam"} de atenção
              </span>
            )}
          </p>
          <p className="mt-1 text-xs text-sutil">
            Arraste um cartão para outra etapa (ou use “Mover”). O sistema sugere a próxima ação — você confirma, edita ou recusa.
          </p>
        </div>

        <form role="search" className="flex flex-wrap items-center gap-2">
          <label className="relative">
            <span className="sr-only">Buscar pelo nome</span>
            <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-sutil" />
            <input
              name="q"
              defaultValue={filtros.busca}
              placeholder="Buscar pelo nome"
              className="w-44 rounded-lg border border-borda-forte bg-superficie py-2 pr-2 pl-8 text-sm outline-none focus:border-dourado"
            />
          </label>
          <select
            name="procedimento"
            aria-label="Procedimento"
            defaultValue={filtros.procedimentoId ?? ""}
            className="rounded-lg border border-borda-forte bg-superficie px-2 py-2 text-sm outline-none focus:border-dourado"
          >
            <option value="">Todos os procedimentos</option>
            {dados.opcoes.procedimentos.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
          <select
            name="responsavel"
            aria-label="Responsável"
            defaultValue={filtros.responsavelId ?? ""}
            className="rounded-lg border border-borda-forte bg-superficie px-2 py-2 text-sm outline-none focus:border-dourado"
          >
            <option value="">Todos os responsáveis</option>
            {dados.opcoes.responsaveis.map((r) => (
              <option key={r.id} value={r.id}>
                {r.nome}
              </option>
            ))}
          </select>
          <button className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black">Filtrar</button>
          {filtrando && (
            <a href="/funil" className="text-sm text-dourado-escuro underline underline-offset-4">
              Limpar
            </a>
          )}
        </form>
      </div>

      <div className="mt-6">
        <Quadro colunas={colunas} hoje={dados.hoje} opcoes={dados.opcoes} diasEncerradas={dados.diasEncerradas} />
      </div>
    </div>
  );
}
