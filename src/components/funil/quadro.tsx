"use client";

import { ArrowRightLeft, CircleAlert, Clock, MessageCircle } from "lucide-react";
import Link from "next/link";
import { useState, type DragEvent } from "react";
import { formatarMoedaCompacta } from "@/lib/moeda";
import type { OpcoesFunil } from "@/modules/funil/servidor";
import { rotuloTempoNaEtapa, rotuloUltimaInteracao, type CartaoFunil, type ColunaFunil } from "@/modules/funil/funil";
import { rotuloData } from "@/modules/painel/painel";
import { MudarEtapa } from "./mudar-etapa";

type Movimento = { cartao: CartaoFunil; destino: ColunaFunil | null };

export function Quadro({
  colunas,
  hoje,
  opcoes,
  diasEncerradas,
}: {
  colunas: ColunaFunil[];
  hoje: string;
  opcoes: OpcoesFunil;
  diasEncerradas: number;
}) {
  const [arrastando, setArrastando] = useState<string | null>(null);
  const [sobre, setSobre] = useState<string | null>(null);
  const [movimento, setMovimento] = useState<Movimento | null>(null);

  const cartaoPorId = (id: string) => colunas.flatMap((c) => c.cartoes).find((c) => c.id === id);

  function soltar(e: DragEvent, coluna: ColunaFunil) {
    e.preventDefault();
    setSobre(null);
    const cartao = cartaoPorId(e.dataTransfer.getData("text/plain") || arrastando || "");
    setArrastando(null);
    if (!cartao || coluna.etapasIds.includes(cartao.etapa_id)) return;
    setMovimento({ cartao, destino: coluna });
  }

  return (
    <>
      <div className="flex gap-3 overflow-x-auto pb-4" role="list" aria-label="Etapas do funil">
        {colunas.map((coluna) => (
          <section
            key={coluna.etapa.id}
            role="listitem"
            aria-label={coluna.etapa.nome}
            onDragOver={(e) => {
              e.preventDefault();
              setSobre(coluna.etapa.id);
            }}
            onDragLeave={() => setSobre((s) => (s === coluna.etapa.id ? null : s))}
            onDrop={(e) => soltar(e, coluna)}
            className={`flex w-72 shrink-0 flex-col rounded-2xl border transition ${
              sobre === coluna.etapa.id
                ? "border-dourado bg-dourado-claro/60"
                : coluna.encerrada
                  ? "border-borda bg-fundo"
                  : "border-borda bg-superficie/70"
            }`}
          >
            <header className="border-b border-borda px-4 pt-3 pb-2.5">
              <div className="flex items-center gap-2">
                <span className="size-2.5 shrink-0 rounded-full" style={{ background: coluna.etapa.cor }} aria-hidden />
                <h2 className="text-sm font-semibold">{coluna.etapa.nome}</h2>
                <span className="ml-auto rounded-full bg-fundo px-2 text-xs text-suave ring-1 ring-borda">{coluna.cartoes.length}</span>
              </div>
              <p className="mt-1 text-[11px] leading-snug text-sutil">
                {coluna.descricao}
                {coluna.encerrada && ` Últimos ${diasEncerradas} dias.`}
              </p>
              {coluna.totalCentavos > 0 && (
                <p className="mt-1 text-xs font-medium text-dourado-escuro">{formatarMoedaCompacta(coluna.totalCentavos)} em potencial</p>
              )}
            </header>

            <div className="flex-1 space-y-2 p-2.5">
              {coluna.cartoes.length === 0 && (
                <p className="rounded-lg border border-dashed border-borda px-2 py-4 text-center text-xs text-sutil">
                  Arraste um cartão para cá
                </p>
              )}
              {coluna.cartoes.map((c) => (
                <article
                  key={c.id}
                  aria-label={c.nome}
                  draggable
                  onDragStart={(e) => {
                    e.dataTransfer.setData("text/plain", c.id);
                    e.dataTransfer.effectAllowed = "move";
                    setArrastando(c.id);
                  }}
                  onDragEnd={() => setArrastando(null)}
                  className={`group cursor-grab rounded-xl border bg-superficie p-3 text-sm shadow-[0_1px_2px_rgba(43,40,36,0.04)] transition active:cursor-grabbing ${
                    arrastando === c.id ? "opacity-40" : ""
                  } ${c.acaoAtrasada || c.semProximaAcao ? "border-urgente/40" : c.parada ? "border-importante/50" : "border-borda"}`}
                >
                  <div className="flex items-start justify-between gap-2">
                    <Link href={`/contatos/${c.pessoa_id}`} className="font-semibold hover:text-dourado-escuro hover:underline">
                      {c.nome}
                    </Link>
                    {c.valor_potencial_centavos ? (
                      <span className="shrink-0 text-xs font-medium text-dourado-escuro">{formatarMoedaCompacta(c.valor_potencial_centavos)}</span>
                    ) : null}
                  </div>
                  <p className="text-xs text-dourado-escuro">{c.procedimento ?? "Interesse a definir"}</p>
                  {c.desistiu && <p className="mt-0.5 text-[11px] text-sutil">Desistiu{c.motivo ? ` · ${c.motivo.toLowerCase()}` : ""}</p>}
                  {!c.desistiu && c.motivo && coluna.encerrada && <p className="mt-0.5 text-[11px] text-sutil">{c.motivo}</p>}

                  <dl className="mt-2 grid grid-cols-2 gap-x-2 gap-y-0.5 text-[11px] text-suave">
                    <dt className="text-sutil">1º contato</dt>
                    <dd>{c.primeiro_contato_em.split("-").reverse().join("/")}</dd>
                    <dt className="text-sutil">Última interação</dt>
                    <dd>{rotuloUltimaInteracao(c.ultimo_contato_em, hoje)}</dd>
                  </dl>

                  <div className={`mt-2 rounded-lg px-2 py-1.5 text-xs ${c.acaoAtrasada || c.semProximaAcao ? "bg-urgente-claro" : "bg-fundo"}`}>
                    {c.proxima_acao ? (
                      <>
                        <p className="flex items-center gap-1 text-grafite">
                          <MessageCircle className="size-3 shrink-0 text-dourado" /> {c.proxima_acao}
                        </p>
                        <p className={`mt-0.5 ${c.acaoAtrasada ? "font-medium text-urgente" : "text-sutil"}`}>
                          {rotuloData(c.proxima_acao_em!, hoje)}
                        </p>
                      </>
                    ) : c.semProximaAcao ? (
                      <p className="flex items-center gap-1 text-urgente">
                        <CircleAlert className="size-3" /> Sem próxima ação
                      </p>
                    ) : (
                      <p className="text-sutil">Nenhum contato programado</p>
                    )}
                  </div>

                  <div className="mt-2 flex items-center justify-between">
                    <span className={`flex items-center gap-1 text-[11px] ${c.parada ? "text-importante" : "text-sutil"}`}>
                      <Clock className="size-3" /> {rotuloTempoNaEtapa(c.dias_na_etapa)}
                    </span>
                    <button
                      type="button"
                      onClick={() => setMovimento({ cartao: c, destino: null })}
                      className="flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs text-suave hover:bg-fundo hover:text-dourado-escuro"
                      aria-label={`Mover ${c.nome}`}
                    >
                      <ArrowRightLeft className="size-3" /> Mover
                    </button>
                  </div>
                </article>
              ))}
            </div>
          </section>
        ))}
      </div>

      {movimento && (
        <MudarEtapa
          cartao={movimento.cartao}
          destinoInicial={movimento.destino}
          colunas={colunas}
          opcoes={opcoes}
          hoje={hoje}
          aoFechar={() => setMovimento(null)}
        />
      )}
    </>
  );
}
