import Link from "next/link";
import type { ReactNode } from "react";
import { z } from "zod";
import { comoUsuaria } from "@/lib/db";
import {
  ATALHOS,
  CANAIS,
  etapasConversao,
  GRUPOS_PERDA,
  pct,
  resolverPeriodo,
  rotuloPeriodo,
  type Indicadores,
} from "@/modules/indicadores/indicadores";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Indicadores · Instituto CG" };

const plural = (n: number, um: string, varios: string) => `${n} ${n === 1 ? um : varios}`;

function Barra({ valor, max, cor = "bg-dourado" }: { valor: number; max: number; cor?: string }) {
  const largura = max > 0 ? Math.max(valor > 0 ? 2 : 0, Math.round((valor / max) * 100)) : 0;
  return (
    <div className="h-2 w-full overflow-hidden rounded-full bg-fundo" aria-hidden>
      <div className={`h-full rounded-full ${cor}`} style={{ width: `${largura}%` }} />
    </div>
  );
}

function Secao({ id, titulo, nota, children }: { id: string; titulo: string; nota?: string; children: ReactNode }) {
  return (
    <section aria-labelledby={id} className="mt-10">
      <h2 id={id} className="font-titulo text-2xl">
        {titulo}
      </h2>
      {nota && <p className="text-sm text-sutil">{nota}</p>}
      <div className="mt-3">{children}</div>
    </section>
  );
}

function Quadros({ itens }: { itens: { rotulo: string; valor: number; detalhe?: string; cor?: string }[] }) {
  return (
    <dl className="grid grid-cols-2 gap-3 md:grid-cols-5">
      {itens.map((t) => (
        <div key={t.rotulo} className="rounded-xl border border-borda bg-superficie p-4">
          <dt className="text-xs text-sutil">{t.rotulo}</dt>
          <dd className={`mt-1 text-2xl font-semibold tabular-nums ${t.cor ?? "text-grafite"}`}>{t.valor}</dd>
          {t.detalhe && <dd className="text-xs text-sutil">{t.detalhe}</dd>}
        </div>
      ))}
    </dl>
  );
}

/** Lista de barras horizontais: rótulo, barra e número. */
function Barras({
  rotulo,
  linhas,
}: {
  rotulo: string;
  linhas: { chave: string; nome: ReactNode; valor: number; detalhe?: string; cor?: string; ponto?: string | null }[];
}) {
  const max = Math.max(0, ...linhas.map((l) => l.valor));
  return (
    <ul aria-label={rotulo} className="space-y-3 rounded-xl border border-borda bg-superficie p-4">
      {linhas.map((l) => (
        <li key={l.chave} aria-label={`${typeof l.nome === "string" ? l.nome : l.chave}: ${l.valor}`}>
          <div className="flex items-baseline justify-between gap-3 text-sm">
            <span className="flex min-w-0 items-center gap-2">
              {l.ponto !== undefined && (
                <span className="size-2.5 shrink-0 rounded-full" style={{ background: l.ponto ?? "#d9d0c1" }} aria-hidden />
              )}
              <span className="truncate">{l.nome}</span>
            </span>
            <span className="shrink-0 text-right">
              <strong className="tabular-nums">{l.valor}</strong>
              {l.detalhe && <span className="ml-2 text-xs text-sutil">{l.detalhe}</span>}
            </span>
          </div>
          <div className="mt-1.5">
            <Barra valor={l.valor} max={max} cor={l.cor} />
          </div>
        </li>
      ))}
    </ul>
  );
}

export default async function PaginaIndicadores({
  searchParams,
}: {
  searchParams: Promise<{ periodo?: string; de?: string; ate?: string; procedimento?: string }>;
}) {
  const sessao = await exigirSessao();
  const busca = await searchParams;
  const proc = busca.procedimento && z.uuid().safeParse(busca.procedimento).success ? busca.procedimento : "";

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    // Uma consulta de cada vez: a conexão (transação) é compartilhada.
    const hoje = (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId])).rows[0].hoje;
    const periodo = resolverPeriodo(busca, hoje);
    const ind = (
      await db.query<{ r: Indicadores }>("select public.indicadores($1, $2::date, $3::date, $4::uuid) as r", [
        sessao.clinicaId,
        periodo.de,
        periodo.ate,
        proc || null,
      ])
    ).rows[0].r;
    const procedimentos = await db.query<{ id: string; nome: string }>(
      "select id, nome from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
      [sessao.clinicaId],
    );
    return { hoje, periodo, ind, procedimentos: procedimentos.rows };
  });

  const { periodo, ind } = d;
  const procNome = d.procedimentos.find((p) => p.id === proc)?.nome ?? null;
  const link = (extra: Record<string, string>) => {
    const base = periodo.atalho ? { periodo: periodo.atalho } : { de: periodo.de, ate: periodo.ate };
    const p = new URLSearchParams(
      Object.entries({ ...base, procedimento: proc, ...extra }).filter(([, v]) => v) as [string, string][],
    );
    return `/indicadores?${p}`;
  };
  const { leads, reativacao: r } = ind;
  const semLeads = leads.novos === 0;

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-8 lg:py-10">
      <h1 className="font-titulo text-4xl">Indicadores</h1>
      <p className="mt-1 text-suave">
        Como os leads chegam, avançam e por que se perdem — para cuidar da clínica, não para comparar pessoas.
      </p>

      <div className="mt-6 rounded-xl border border-borda bg-superficie p-4">
        <nav aria-label="Período" className="flex flex-wrap gap-2">
          {ATALHOS.map((a) => {
            const ativo = periodo.atalho === a.id;
            return (
              <Link
                key={a.id}
                href={`/indicadores?${new URLSearchParams(Object.entries({ periodo: a.id, procedimento: proc }).filter(([, v]) => v))}`}
                aria-current={ativo ? "page" : undefined}
                className={`rounded-full border px-3 py-1 text-sm transition ${
                  ativo ? "border-dourado bg-dourado-claro font-medium text-dourado-escuro" : "border-borda-forte text-suave hover:border-dourado"
                }`}
              >
                {a.rotulo}
              </Link>
            );
          })}
        </nav>
        <form action="/indicadores" className="mt-4 flex flex-wrap items-end gap-3">
          <div className="flex flex-col gap-1">
            <label htmlFor="ind-de" className="text-xs text-suave">
              De
            </label>
            <input
              id="ind-de"
              type="date"
              name="de"
              defaultValue={periodo.de}
              className="rounded-lg border border-borda-forte bg-superficie px-3 py-1.5 text-sm outline-none focus:border-dourado"
            />
          </div>
          <div className="flex flex-col gap-1">
            <label htmlFor="ind-ate" className="text-xs text-suave">
              Até
            </label>
            <input
              id="ind-ate"
              type="date"
              name="ate"
              defaultValue={periodo.ate}
              className="rounded-lg border border-borda-forte bg-superficie px-3 py-1.5 text-sm outline-none focus:border-dourado"
            />
          </div>
          <div className="flex min-w-0 flex-col gap-1">
            <label htmlFor="ind-proc" className="text-xs text-suave">
              Procedimento
            </label>
            <select
              id="ind-proc"
              name="procedimento"
              defaultValue={proc}
              className="max-w-full rounded-lg border border-borda-forte bg-superficie px-3 py-1.5 text-sm outline-none focus:border-dourado"
            >
              <option value="">Todos os procedimentos</option>
              {d.procedimentos.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nome}
                </option>
              ))}
            </select>
          </div>
          <button
            type="submit"
            className="rounded-lg bg-dourado px-4 py-2 text-xs font-medium tracking-wide text-white uppercase hover:bg-dourado-escuro"
          >
            Aplicar
          </button>
        </form>
        <p className="mt-3 text-sm text-suave">
          Período: <strong className="text-grafite">{rotuloPeriodo(periodo)}</strong>
          {procNome && (
            <>
              {" "}· apenas <strong className="text-grafite">{procNome}</strong> ·{" "}
              <Link href={link({ procedimento: "" })} className="text-dourado-escuro underline">
                Ver todos os procedimentos
              </Link>
            </>
          )}
        </p>
      </div>

      <Secao
        id="leads"
        titulo="Leads"
        nota="Pessoas que chegaram no período e onde estão agora. Pacientes antigos que voltaram ficam em Reativação."
      >
        <Quadros
          itens={[
            { rotulo: "Novos leads", valor: leads.novos, detalhe: "chegaram no período", cor: "text-dourado-escuro" },
            { rotulo: "Convertidos", valor: leads.convertidos, detalhe: `${pct(leads.convertidos, leads.novos)}% dos leads`, cor: "text-rotina" },
            { rotulo: "Em negociação", valor: leads.em_negociacao, detalhe: "ainda em andamento" },
            { rotulo: "Sem resposta", valor: leads.sem_resposta, detalhe: "pararam de responder" },
            { rotulo: "Perdidos", valor: leads.perdidos, detalhe: "não fecharam ou desistiram", cor: "text-urgente" },
          ]}
        />
      </Secao>

      <Secao id="conversao" titulo="Conversão" nota="Dos novos leads do período, quantos chegaram a cada passo.">
        {semLeads ? (
          <p className="text-sm text-sutil">Nenhum lead neste período.</p>
        ) : (
          <ol aria-label="Conversão" className="space-y-3 rounded-xl border border-borda bg-superficie p-4">
            {etapasConversao(ind.conversao).map((e) => (
              <li key={e.id} aria-label={`${e.rotulo}: ${e.valor}`}>
                <div className="flex flex-wrap items-baseline justify-between gap-x-3 text-sm">
                  <span>{e.rotulo}</span>
                  <span>
                    <strong className="tabular-nums">{e.valor}</strong>
                    <span className="ml-2 text-xs text-sutil">
                      {e.sobreLeads}% dos leads
                      {e.sobreAnterior !== null && ` · ${e.sobreAnterior}% do passo anterior`}
                    </span>
                  </span>
                </div>
                <div className="mt-1.5">
                  <Barra valor={e.sobreLeads} max={100} cor={e.id === "fechamento" ? "bg-rotina" : "bg-dourado"} />
                </div>
              </li>
            ))}
          </ol>
        )}
      </Secao>

      <Secao id="funil" titulo="Funil" nota="Em que etapa está agora cada pessoa que entrou no funil no período (inclui reativações).">
        <Barras
          rotulo="Pessoas por etapa"
          linhas={ind.funil.map((f) => ({
            chave: f.etapa,
            nome: f.etapa,
            valor: f.quantidade,
            ponto: f.cor,
            cor: f.tipo === "ganho" ? "bg-rotina" : f.tipo === "perda" ? "bg-urgente/70" : "bg-dourado",
          }))}
        />
      </Secao>

      <div className="grid gap-x-8 lg:grid-cols-2">
        <Secao id="origem" titulo="Origem" nota="De onde vieram os novos leads e quantos fecharam.">
          <Barras
            rotulo="Leads por origem"
            linhas={ind.por_canal.map((c) => ({
              chave: c.canal,
              nome: CANAIS[c.canal],
              valor: c.leads,
              detalhe: c.leads > 0 ? `${plural(c.convertidos, "fechou", "fecharam")} (${pct(c.convertidos, c.leads)}%)` : undefined,
            }))}
          />
          {ind.por_origem.length > 0 && (
            <details className="mt-2 text-sm">
              <summary className="cursor-pointer text-suave">Ver origens detalhadas</summary>
              <table aria-label="Origens detalhadas" className="mt-2 w-full">
                <thead className="text-left text-xs text-sutil">
                  <tr>
                    <th className="py-1 font-normal">Origem</th>
                    <th className="py-1 text-right font-normal">Leads</th>
                    <th className="py-1 text-right font-normal">Fecharam</th>
                  </tr>
                </thead>
                <tbody>
                  {ind.por_origem.map((o) => (
                    <tr key={o.origem} className="border-t border-borda">
                      <td className="py-1">{o.origem}</td>
                      <td className="py-1 text-right tabular-nums">{o.leads}</td>
                      <td className="py-1 text-right tabular-nums">{o.convertidos}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </details>
          )}
        </Secao>

        <Secao id="procedimentos" titulo="Procedimentos" nota="Os que geram mais procura entre os novos leads.">
          {ind.por_procedimento.length === 0 ? (
            <p className="text-sm text-sutil">Nenhum lead neste período.</p>
          ) : (
            <Barras
              rotulo="Procura por procedimento"
              linhas={ind.por_procedimento.map((p) => ({
                chave: p.procedimento,
                nome:
                  p.procedimento_id && !proc ? (
                    <Link href={link({ procedimento: p.procedimento_id })} className="hover:underline">
                      {p.procedimento}
                    </Link>
                  ) : (
                    p.procedimento
                  ),
                valor: p.leads,
                detalhe: `${plural(p.convertidos, "fechou", "fecharam")} (${pct(p.convertidos, p.leads)}%)`,
              }))}
            />
          )}
        </Secao>
      </div>

      <Secao
        id="perdas"
        titulo="Perdas"
        nota="Negociações encerradas sem fechar no período, pelo motivo registrado, e quem parou de responder."
      >
        {ind.perdas.total === 0 ? (
          <p className="text-sm text-rotina">Nenhuma perda neste período.</p>
        ) : (
          <div className="grid gap-4 lg:grid-cols-2">
            <Barras
              rotulo="Perdas por motivo"
              linhas={GRUPOS_PERDA.map((g) => ({
                chave: g.id,
                nome: g.rotulo,
                valor: ind.perdas.grupos[g.id],
                detalhe: `${pct(ind.perdas.grupos[g.id], ind.perdas.total)}%`,
                cor: "bg-urgente/60",
              }))}
            />
            <div className="rounded-xl border border-borda bg-superficie p-4">
              <h3 className="text-sm font-medium">Motivos registrados</h3>
              <ul aria-label="Motivos registrados" className="mt-2 divide-y divide-borda text-sm">
                {ind.perdas.motivos.map((m) => (
                  <li key={m.motivo} className="flex justify-between gap-3 py-1.5">
                    <span>{m.motivo}</span>
                    <span className="tabular-nums">{m.quantidade}</span>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        )}
      </Secao>

      <Secao id="reativacao" titulo="Reativação" nota="Pacientes antigos procurados de novo e o que aconteceu.">
        <Quadros
          itens={[
            { rotulo: "Pacientes elegíveis", valor: r.elegiveis, detalhe: "inativos, sem negociação aberta (hoje)" },
            { rotulo: "Pacientes reativados", valor: r.reativados, detalhe: "contatados no período", cor: "text-dourado-escuro" },
            { rotulo: "Responderam", valor: r.responderam, detalhe: `${pct(r.responderam, r.reativados)}% dos reativados` },
            { rotulo: "Agendaram", valor: r.agendaram, detalhe: `${pct(r.agendaram, r.reativados)}% dos reativados` },
            { rotulo: "Fecharam", valor: r.fecharam, detalhe: `${pct(r.fecharam, r.reativados)}% dos reativados`, cor: "text-rotina" },
          ]}
        />
        <p className="mt-3 text-sm text-suave">
          {plural(r.aguardando, "aguardando resposta", "aguardando resposta")} · {plural(r.sem_retorno, "sem retorno", "sem retorno")}
          {r.elegiveis > 0 && (
            <>
              {" "}·{" "}
              <Link href="/campanhas" className="text-dourado-escuro underline">
                Reativar pacientes em Campanhas
              </Link>
            </>
          )}
        </p>
      </Secao>
    </div>
  );
}
