"use client";

import { useState } from "react";
import {
  ARCADAS,
  CONDICOES,
  DENTES,
  descreverDente,
  FACES,
  ROTULO_FACE,
  SITUACAO_DENTE,
  type Condicao,
  type Dente,
  type Face,
  type Odontograma as Mapa,
  type SituacaoDente,
} from "@/modules/prontuario/prontuario";

/** Abreviação desenhada no dente para condições do dente inteiro. */
const SIGLA: Partial<Record<Condicao, string>> = {
  canal: "C",
  coroa: "P",
  faceta: "F",
  implante: "I",
  ausente: "×",
  extracao: "×",
  mancha: "M",
};

/** Polígonos das 5 faces num quadrado 40×40 (centro = oclusal/incisal). */
const POLIGONOS = {
  topo: "0,0 40,0 30,10 10,10",
  base: "10,30 30,30 40,40 0,40",
  esquerda: "0,0 10,10 10,30 0,40",
  direita: "40,0 40,40 30,30 30,10",
  centro: "10,10 30,10 30,30 10,30",
} as const;

/** Em qual lado de cada dente fica cada face (visto de frente). */
function lados(numero: number): Record<keyof typeof POLIGONOS, Face> {
  const superior = numero < 30;
  // Dentes à esquerda da tela (quadrantes 1 e 4): mesial fica à direita, perto do meio.
  const esquerdaDaTela = Math.floor(numero / 10) === 1 || Math.floor(numero / 10) === 4;
  return {
    topo: superior ? "V" : "L",
    base: superior ? "L" : "V",
    esquerda: esquerdaDaTela ? "D" : "M",
    direita: esquerdaDaTela ? "M" : "D",
    centro: "O",
  };
}

function DenteSvg({ numero, d, ativo, onClick, editavel }: { numero: number; d?: Dente; ativo: boolean; onClick?: () => void; editavel: boolean }) {
  const cor = d ? SITUACAO_DENTE[d.s].cor : null;
  const inteiro = d && !CONDICOES[d.c].faces;
  const mapa = lados(numero);
  const rotulo = `Dente ${numero}${d ? `: ${descreverDente(String(numero), d).slice(String(numero).length + 3)}` : ""}`;
  const conteudo = (
    <>
      <span className="text-[10px] tabular-nums text-sutil">{numero}</span>
      <svg viewBox="-2 -2 44 44" className="size-7 sm:size-8" aria-hidden>
        {(Object.keys(POLIGONOS) as (keyof typeof POLIGONOS)[]).map((k) => {
          const marcada = d && !inteiro && d.f.includes(mapa[k]);
          return (
            <polygon
              key={k}
              points={POLIGONOS[k]}
              fill={marcada ? cor! : inteiro && d.c !== "ausente" && d.c !== "extracao" ? `${cor}33` : "#ffffff"}
              stroke={inteiro ? cor! : "#d9d0c1"}
              strokeWidth={inteiro ? 2.5 : 1.2}
            />
          );
        })}
        {inteiro && SIGLA[d.c] && (
          <text x="20" y="27" textAnchor="middle" fontSize={d.c === "ausente" || d.c === "extracao" ? 30 : 18} fontWeight="600" fill={cor!}>
            {SIGLA[d.c]}
          </text>
        )}
      </svg>
    </>
  );
  const classe = `flex flex-col items-center gap-0.5 rounded-md px-0.5 py-1 ${ativo ? "bg-dourado-claro ring-2 ring-dourado" : ""}`;
  return editavel ? (
    <button type="button" onClick={onClick} aria-label={rotulo} aria-pressed={ativo} className={`${classe} hover:bg-fundo`}>
      {conteudo}
    </button>
  ) : (
    <div role="img" aria-label={rotulo} className={classe}>
      {conteudo}
    </div>
  );
}

export function LegendaOdontograma() {
  return (
    <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-suave">
      {(Object.keys(SITUACAO_DENTE) as SituacaoDente[]).map((s) => (
        <li key={s} className="flex items-center gap-1.5">
          <span className="size-2.5 rounded-sm" style={{ backgroundColor: SITUACAO_DENTE[s].cor }} aria-hidden />
          {SITUACAO_DENTE[s].rotulo}
        </li>
      ))}
      <li>C canal · P coroa/prótese · F faceta · I implante · M mancha · × ausente/extração</li>
    </ul>
  );
}

/** Odontograma (notação FDI). Com onChange, permite marcar; sem, só mostra. */
export function Odontograma({ valor, onChange }: { valor: Mapa; onChange?: (novo: Mapa) => void }) {
  const [sel, setSel] = useState<number | null>(null);
  const editavel = Boolean(onChange);
  const atual = sel !== null ? valor[String(sel)] : undefined;

  function mudar(d: Dente | null) {
    if (sel === null || !onChange) return;
    const novo = { ...valor };
    if (d) novo[String(sel)] = d;
    else delete novo[String(sel)];
    onChange(novo);
  }
  const condicao = (c: Condicao) =>
    mudar({ c, f: CONDICOES[c].faces ? (atual?.f.length ? atual.f : ["O"]) : [], s: atual?.s ?? "a_tratar", ...(atual?.o ? { o: atual.o } : {}) });

  const registrados = Object.entries(valor);
  return (
    <div>
      <div className="overflow-x-auto">
        <div className="mx-auto w-max space-y-2 py-1" role="group" aria-label="Odontograma">
          {(["superior", "inferior"] as const).map((arcada) => (
            <div key={arcada} className={`flex ${arcada === "superior" ? "border-b border-dashed border-borda-forte pb-2" : ""}`}>
              {ARCADAS[arcada].map((n, i) => (
                <div key={n} className={i === 8 ? "ml-2 border-l border-dashed border-borda-forte pl-2" : ""}>
                  <DenteSvg numero={n} d={valor[String(n)]} ativo={sel === n} editavel={editavel} onClick={() => setSel(sel === n ? null : n)} />
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
      <LegendaOdontograma />

      {editavel && sel !== null && (
        <div className="mt-4 rounded-xl border border-dourado/50 bg-dourado-claro/40 p-4" aria-label={`Editar dente ${sel}`} role="group">
          <div className="flex items-center justify-between gap-2">
            <p className="text-sm font-semibold">Dente {sel}</p>
            <button type="button" onClick={() => setSel(null)} className="text-xs text-suave underline">
              Fechar
            </button>
          </div>
          <p className="mt-2 text-xs text-sutil">Condição</p>
          <div className="mt-1 flex flex-wrap gap-1.5">
            {(Object.keys(CONDICOES) as Condicao[]).map((c) => (
              <button
                key={c}
                type="button"
                aria-pressed={atual?.c === c}
                onClick={() => condicao(c)}
                className={`rounded-full border px-2.5 py-1 text-xs ${atual?.c === c ? "border-dourado bg-dourado text-white" : "border-borda-forte bg-superficie hover:border-dourado"}`}
              >
                {CONDICOES[c].rotulo}
              </button>
            ))}
          </div>
          {atual && (
            <>
              {CONDICOES[atual.c].faces && (
                <>
                  <p className="mt-3 text-xs text-sutil">Faces</p>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {FACES.map((f) => {
                      const marcada = atual.f.includes(f);
                      return (
                        <button
                          key={f}
                          type="button"
                          aria-pressed={marcada}
                          title={ROTULO_FACE[f]}
                          aria-label={`Face ${ROTULO_FACE[f]}`}
                          onClick={() => mudar({ ...atual, f: marcada ? atual.f.filter((x) => x !== f) : [...atual.f, f] })}
                          className={`min-w-9 rounded-md border px-2 py-1 text-xs font-medium ${marcada ? "border-dourado bg-dourado text-white" : "border-borda-forte bg-superficie"}`}
                        >
                          {f}
                        </button>
                      );
                    })}
                  </div>
                </>
              )}
              <p className="mt-3 text-xs text-sutil">Situação</p>
              <div className="mt-1 flex flex-wrap gap-1.5">
                {(Object.keys(SITUACAO_DENTE) as SituacaoDente[]).map((s) => (
                  <button
                    key={s}
                    type="button"
                    aria-pressed={atual.s === s}
                    onClick={() => mudar({ ...atual, s })}
                    className={`rounded-full border px-2.5 py-1 text-xs ${atual.s === s ? "border-transparent text-white" : "border-borda-forte bg-superficie"}`}
                    style={atual.s === s ? { backgroundColor: SITUACAO_DENTE[s].cor } : undefined}
                  >
                    {SITUACAO_DENTE[s].rotulo}
                  </button>
                ))}
              </div>
              <label className="mt-3 block text-xs text-sutil">
                Observação do dente
                <input
                  value={atual.o ?? ""}
                  maxLength={200}
                  onChange={(e) => mudar({ ...atual, o: e.target.value || undefined })}
                  className="mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-1.5 text-sm text-grafite outline-none focus:border-dourado"
                />
              </label>
              <button type="button" onClick={() => mudar(null)} className="mt-3 text-xs text-urgente underline">
                Limpar dente {sel}
              </button>
            </>
          )}
        </div>
      )}

      {registrados.length > 0 && (
        <ul aria-label="Dentes registrados" className="mt-3 grid gap-1 text-sm sm:grid-cols-2">
          {registrados
            .sort(([a], [b]) => DENTES.indexOf(Number(a)) - DENTES.indexOf(Number(b)))
            .map(([n, d]) => (
              <li key={n} className="flex items-start gap-2">
                <span className="mt-1.5 size-2 shrink-0 rounded-full" style={{ backgroundColor: SITUACAO_DENTE[d.s].cor }} aria-hidden />
                <span>
                  {descreverDente(n, d)}
                  {d.o && <span className="text-sutil"> · {d.o}</span>}
                </span>
              </li>
            ))}
        </ul>
      )}
    </div>
  );
}
