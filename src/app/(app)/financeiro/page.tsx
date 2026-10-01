import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import Link from "next/link";
import { z } from "zod";
import {
  FiltroProcedimento,
  LinhaParcela,
  RegistrarNegociacao,
  VerPaciente,
} from "@/components/financeiro/financeiro";
import { comoUsuaria } from "@/lib/db";
import { somarDias } from "@/lib/datas";
import { formatarMoeda } from "@/lib/moeda";
import {
  mesDe,
  rotuloMes,
  rotuloParcela,
  somarMes,
  SITUACAO,
  type NegociacaoFin,
  type PagamentoMes,
  type ParcelaFin,
  type Resumo,
  type PorProcedimento,
  type Situacao,
} from "@/modules/financeiro/financeiro";
import { exigirSessao } from "@/modules/sessao/sessao";
import type { PacienteEncontrado } from "../agenda/acoes";
import type { FormaPagamento } from "./acoes";

export const metadata = { title: "Financeiro · Instituto CG" };

const FILTROS: { id: "" | Situacao; rotulo: string }[] = [
  { id: "", rotulo: "Todas" },
  { id: "pendente", rotulo: "Pendente" },
  { id: "parcial", rotulo: "Parcialmente pago" },
  { id: "atrasado", rotulo: "Atrasado" },
  { id: "pago", rotulo: "Pago" },
];

const br = (d: string) => d.split("-").reverse().join("/");

export default async function Financeiro({
  searchParams,
}: {
  searchParams: Promise<{
    mes?: string;
    status?: string;
    q?: string;
    nova?: string;
    procedimento?: string;
  }>;
}) {
  const sessao = await exigirSessao();
  if (!sessao.podeVerFinanceiro) {
    return (
      <div className="px-4 py-10 sm:px-8">
        <h1 className="font-titulo text-4xl">Financeiro</h1>
        <p className="mt-2 text-suave">
          Seu acesso não inclui o financeiro. Fale com a administradora.
        </p>
      </div>
    );
  }
  const busca = await searchParams;
  const status = FILTROS.some((f) => f.id === busca.status)
    ? (busca.status as Situacao)
    : "";
  const q = (busca.q ?? "").trim().slice(0, 60);
  const proc =
    busca.procedimento && z.uuid().safeParse(busca.procedimento).success
      ? busca.procedimento
      : "";

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    // Uma consulta de cada vez: a conexão (transação) é compartilhada.
    const hoje = (
      await db.query<{ hoje: string }>(
        "select public.hoje_clinica($1) as hoje",
        [sessao.clinicaId],
      )
    ).rows[0].hoje;
    const mes =
      busca.mes && /^\d{4}-\d{2}(-\d{2})?$/.test(busca.mes)
        ? mesDe(`${busca.mes.slice(0, 7)}-01`)
        : mesDe(hoje);
    const resumo = (
      await db.query<{ r: Resumo }>(
        "select public.resumo_financeiro($1, $2::date, $3::uuid) as r",
        [sessao.clinicaId, mes, proc || null],
      )
    ).rows[0].r;
    const atrasadas = await db.query<ParcelaFin>(
      `select * from public.v_financeiro_parcelas where clinica_id = $1 and situacao = 'atrasado'
          and ($2 = '' or procedimento_id::text = $2) order by vencimento, pessoa_nome`,
      [sessao.clinicaId, proc],
    );
    const proximas = await db.query<ParcelaFin>(
      `select * from public.v_financeiro_parcelas
        where clinica_id = $1 and situacao in ('pendente', 'parcial') and vencimento <= $2::date
          and ($3 = '' or procedimento_id::text = $3)
        order by vencimento, pessoa_nome limit 50`,
      [sessao.clinicaId, somarDias(hoje, 30), proc],
    );
    const pagamentos = await db.query<PagamentoMes>(
      `select pg.id, pg.pago_em, pg.valor_centavos, p.pessoa_id, p.pessoa_nome, p.procedimento,
              coalesce(fp.nome, p.forma_pagamento) as forma_pagamento, p.numero, p.quantidade_parcelas
         from public.pagamentos pg
         join public.v_financeiro_parcelas p on p.id = pg.parcela_id
         left join public.formas_pagamento fp on fp.id = pg.forma_pagamento_id
        where pg.clinica_id = $1 and pg.estornado_em is null
          and pg.pago_em >= $2::date and pg.pago_em < ($2::date + interval '1 month')
          and ($3 = '' or p.procedimento_id::text = $3)
        order by pg.pago_em desc, pg.criado_em desc`,
      [sessao.clinicaId, mes, proc],
    );
    const negociacoes = await db.query<NegociacaoFin>(
      `select * from public.v_financeiro_negociacoes
        where clinica_id = $1 and ($2 = '' or situacao = $2)
          and ($3 = '' or public.sem_acento(pessoa_nome) like '%' || public.sem_acento($3) || '%')
          and ($4 = '' or procedimento_id::text = $4)
        order by case situacao when 'atrasado' then 0 when 'parcial' then 1 when 'pendente' then 2 else 3 end,
                 proximo_vencimento nulls last, fechada_em desc
        limit 100`,
      [sessao.clinicaId, status, q, proc],
    );
    const parcelas = await db.query<ParcelaFin>(
      "select * from public.v_financeiro_parcelas where venda_id = any($1::uuid[]) order by numero",
      [negociacoes.rows.map((n) => n.id)],
    );
    const porProcedimento = await db.query<PorProcedimento>(
      "select * from public.financeiro_por_procedimento($1, $2::date)",
      [sessao.clinicaId, mes],
    );
    const procedimentos = await db.query<{ id: string; nome: string }>(
      "select id, nome from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
      [sessao.clinicaId],
    );
    const formas = await db.query<FormaPagamento>(
      `select id, nome, permite_parcelamento, max_parcelas, recebe_na_hora
         from public.formas_pagamento where clinica_id = $1 and ativo order by ordem`,
      [sessao.clinicaId],
    );
    let paciente: PacienteEncontrado | null = null;
    if (busca.nova && z.uuid().safeParse(busca.nova).success) {
      paciente =
        (
          await db.query<PacienteEncontrado>(
            `select id, nome, coalesce(whatsapp_e164, telefone_e164) as whatsapp, tipo_cadastro,
                    procedimento_interesse_id as procedimento_id, procedimento_interesse as procedimento, etapa_atual as etapa
               from public.v_contatos where id = $1`,
            [busca.nova],
          )
        ).rows[0] ?? null;
    }
    return {
      hoje,
      mes,
      resumo,
      atrasadas: atrasadas.rows,
      proximas: proximas.rows,
      pagamentos: pagamentos.rows,
      negociacoes: negociacoes.rows,
      parcelas: parcelas.rows,
      procedimentos: procedimentos.rows,
      porProcedimento: porProcedimento.rows,
      formas: formas.rows,
      paciente,
    };
  });

  const { hoje, mes, resumo } = d;
  const link = (extra: Record<string, string>) => {
    const p = new URLSearchParams(
      Object.entries({
        mes: mes.slice(0, 7),
        status,
        q,
        procedimento: proc,
        ...extra,
      }).filter(([, v]) => v) as [string, string][],
    );
    return `/financeiro?${p}`;
  };
  const totalPagoMes = d.pagamentos.reduce(
    (s, p) => s + Number(p.valor_centavos),
    0,
  );
  const procNome = d.procedimentos.find((p) => p.id === proc)?.nome ?? null;

  const tiles = [
    {
      rotulo: "Recebido no mês",
      valor: resumo.recebido_mes,
      detalhe: `${resumo.pagamentos_mes} ${resumo.pagamentos_mes === 1 ? "pagamento" : "pagamentos"}`,
      cor: "text-rotina",
    },
    {
      rotulo: "Previsto no mês",
      valor: resumo.previsto_mes,
      detalhe: "a receber neste mês",
      cor: "text-grafite",
    },
    {
      rotulo: "Pendente",
      valor: resumo.pendente,
      detalhe: "a vencer (todas as datas)",
      cor: "text-grafite",
    },
    {
      rotulo: "Atrasado",
      valor: resumo.atrasado,
      detalhe: `${resumo.atrasados} ${resumo.atrasados === 1 ? "pagamento" : "pagamentos"}`,
      cor: "text-urgente",
    },
    {
      rotulo: "Vendido no mês",
      valor: resumo.vendido_mes,
      detalhe: "negociações fechadas",
      cor: "text-dourado-escuro",
    },
  ];

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-8 lg:py-10">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-titulo text-4xl">Financeiro</h1>
          <p className="mt-1 text-suave">
            O que a clínica tem a receber — simples, sem contabilidade.
          </p>
        </div>
        <RegistrarNegociacao
          procedimentos={d.procedimentos}
          formas={d.formas}
          hoje={hoje}
          pacienteInicial={d.paciente}
        />
      </div>

      <div className="mt-6 flex flex-wrap items-center justify-between gap-3">
        <nav aria-label="Mês" className="flex items-center gap-2">
          <Link
            href={link({ mes: somarMes(mes, -1).slice(0, 7) })}
            aria-label="Mês anterior"
            className="rounded-lg border border-borda-forte p-1.5 hover:border-dourado"
          >
            <ChevronLeft className="size-4" />
          </Link>
          <span className="min-w-44 text-center font-medium">
            {rotuloMes(mes)}
          </span>
          <Link
            href={link({ mes: somarMes(mes, 1).slice(0, 7) })}
            aria-label="Próximo mês"
            className="rounded-lg border border-borda-forte p-1.5 hover:border-dourado"
          >
            <ChevronRight className="size-4" />
          </Link>
        </nav>
        <FiltroProcedimento procedimentos={d.procedimentos} atual={proc} />
      </div>
      {procNome && (
        <p className="mt-3 rounded-lg bg-dourado-claro px-3.5 py-2 text-sm text-dourado-escuro">
          Mostrando apenas <strong>{procNome}</strong>.{" "}
          <Link href={link({ procedimento: "" })} className="underline">
            Ver todos os procedimentos
          </Link>
        </p>
      )}

      <dl className="mt-4 grid grid-cols-2 gap-3 md:grid-cols-5">
        {tiles.map((t) => (
          <div
            key={t.rotulo}
            className="rounded-xl border border-borda bg-superficie p-4"
          >
            <dt className="text-xs text-sutil">{t.rotulo}</dt>
            <dd className={`mt-1 text-xl font-semibold tabular-nums ${t.cor}`}>
              {formatarMoeda(Number(t.valor))}
            </dd>
            <dd className="text-xs text-sutil">{t.detalhe}</dd>
          </div>
        ))}
      </dl>

      {!proc && d.porProcedimento.length > 0 && (
        <section aria-labelledby="por-procedimento" className="mt-10">
          <h2 id="por-procedimento" className="font-titulo text-2xl">
            Por procedimento
          </h2>
          <p className="text-sm text-sutil">
            Vendido e recebido em {rotuloMes(mes).toLowerCase()}; em aberto e
            atrasado hoje. Clique para filtrar.
          </p>
          <div className="mt-3 overflow-x-auto rounded-xl border border-borda bg-superficie">
            <table
              className="w-full text-sm"
              aria-label="Financeiro por procedimento"
            >
              <thead className="text-left text-xs text-sutil">
                <tr>
                  <th className="px-4 py-2 font-normal">Procedimento</th>
                  <th className="px-4 py-2 text-right font-normal">
                    Negociações
                  </th>
                  <th className="px-4 py-2 text-right font-normal">
                    Vendido no mês
                  </th>
                  <th className="px-4 py-2 text-right font-normal">
                    Recebido no mês
                  </th>
                  <th className="px-4 py-2 text-right font-normal">
                    Em aberto
                  </th>
                  <th className="px-4 py-2 text-right font-normal">Atrasado</th>
                </tr>
              </thead>
              <tbody>
                {d.porProcedimento.map((r) => (
                  <tr key={r.procedimento} className="border-t border-borda">
                    <td className="px-4 py-2">
                      {r.procedimento_id ? (
                        <Link
                          href={link({ procedimento: r.procedimento_id })}
                          className="font-medium hover:underline"
                        >
                          {r.procedimento}
                        </Link>
                      ) : (
                        <span className="text-suave">{r.procedimento}</span>
                      )}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums">
                      {r.negociacoes}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums">
                      {formatarMoeda(Number(r.vendido_mes))}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums text-rotina">
                      {formatarMoeda(Number(r.recebido_mes))}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums">
                      {formatarMoeda(Number(r.em_aberto))}
                    </td>
                    <td
                      className={`px-4 py-2 text-right tabular-nums ${Number(r.atrasado) > 0 ? "text-urgente" : ""}`}
                    >
                      {formatarMoeda(Number(r.atrasado))}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <section aria-labelledby="atrasados" className="mt-10">
        <h2 id="atrasados" className="font-titulo text-2xl">
          Pagamentos atrasados
        </h2>
        {d.atrasadas.length === 0 ? (
          <p className="mt-2 text-sm text-rotina">Nenhum pagamento atrasado.</p>
        ) : (
          <ul
            aria-label="Atrasados"
            className="mt-3 rounded-xl border border-urgente/30 bg-superficie px-4"
          >
            {d.atrasadas.map((p) => (
              <LinhaParcela key={p.id} p={p} hoje={hoje} />
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="proximos" className="mt-10">
        <h2 id="proximos" className="font-titulo text-2xl">
          Próximos 30 dias
        </h2>
        {d.proximas.length === 0 ? (
          <p className="mt-2 text-sm text-sutil">Nenhum pagamento previsto.</p>
        ) : (
          <ul
            aria-label="Previstos"
            className="mt-3 rounded-xl border border-borda bg-superficie px-4"
          >
            {d.proximas.map((p) => (
              <LinhaParcela key={p.id} p={p} hoje={hoje} />
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="pagos" className="mt-10">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h2 id="pagos" className="font-titulo text-2xl">
            Pagamentos de {rotuloMes(mes).toLowerCase()}
          </h2>
          <p className="text-sm text-suave">
            Total {formatarMoeda(totalPagoMes)}
          </p>
        </div>
        {d.pagamentos.length === 0 ? (
          <p className="mt-2 text-sm text-sutil">
            Nenhum pagamento registrado neste mês.
          </p>
        ) : (
          <div className="mt-3 overflow-x-auto rounded-xl border border-borda bg-superficie">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-sutil">
                <tr>
                  <th className="px-4 py-2 font-normal">Data</th>
                  <th className="px-4 py-2 font-normal">Paciente</th>
                  <th className="px-4 py-2 font-normal">Procedimento</th>
                  <th className="px-4 py-2 font-normal">Forma</th>
                  <th className="px-4 py-2 text-right font-normal">Valor</th>
                </tr>
              </thead>
              <tbody>
                {d.pagamentos.map((p) => (
                  <tr key={p.id} className="border-t border-borda">
                    <td className="px-4 py-2 tabular-nums">{br(p.pago_em)}</td>
                    <td className="px-4 py-2">
                      <Link
                        href={`/contatos/${p.pessoa_id}#financeiro`}
                        className="hover:underline"
                      >
                        {p.pessoa_nome}
                      </Link>
                      <span className="block text-xs text-sutil">
                        {rotuloParcela(p.numero, p.quantidade_parcelas)}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-suave">
                      {p.procedimento ?? "—"}
                    </td>
                    <td className="px-4 py-2 text-suave">
                      {p.forma_pagamento ?? "—"}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums">
                      {formatarMoeda(Number(p.valor_centavos))}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section aria-labelledby="negociacoes" className="mt-10">
        <h2 id="negociacoes" className="font-titulo text-2xl">
          Negociações
        </h2>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
          <nav aria-label="Filtrar por status" className="flex flex-wrap gap-2">
            {FILTROS.map((f) => (
              <Link
                key={f.rotulo}
                href={link({ status: f.id })}
                aria-current={status === f.id ? "page" : undefined}
                className={`rounded-full px-3 py-1 text-sm ring-1 ${status === f.id ? "bg-grafite text-white ring-grafite" : "ring-borda-forte hover:ring-dourado"}`}
              >
                {f.rotulo}
              </Link>
            ))}
          </nav>
          <form role="search" className="relative">
            <input type="hidden" name="mes" value={mes.slice(0, 7)} />
            {status && <input type="hidden" name="status" value={status} />}
            {proc && <input type="hidden" name="procedimento" value={proc} />}
            <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-sutil" />
            <input
              name="q"
              defaultValue={q}
              placeholder="Buscar paciente"
              aria-label="Buscar paciente"
              className="w-48 rounded-lg border border-borda-forte bg-superficie py-2 pr-2 pl-8 text-sm outline-none focus:border-dourado"
            />
          </form>
        </div>
        {d.negociacoes.length === 0 ? (
          <p className="mt-3 text-sm text-sutil">
            Nenhuma negociação{" "}
            {status || q ? "com este filtro" : "registrada ainda"}.
          </p>
        ) : (
          <ul aria-label="Lista de negociações" className="mt-3 grid gap-2">
            {d.negociacoes.map((n) => {
              const st = SITUACAO[n.situacao];
              const parcelas = d.parcelas.filter((p) => p.venda_id === n.id);
              return (
                <li
                  key={n.id}
                  aria-label={`${n.pessoa_nome} — ${n.procedimento ?? "Negociação"}`}
                  className="rounded-xl border border-borda bg-superficie"
                >
                  <details>
                    <summary className="grid cursor-pointer grid-cols-2 items-center gap-x-4 gap-y-1 px-4 py-3 text-sm md:grid-cols-[1.4fr_1fr_1fr_1fr_auto]">
                      <span>
                        <span className="font-medium">{n.pessoa_nome}</span>
                        <span className="block text-xs text-sutil">
                          {n.procedimento ?? "Procedimento não informado"}
                        </span>
                      </span>
                      <span className="tabular-nums">
                        {formatarMoeda(Number(n.valor_final_centavos))}
                        <span className="block text-xs text-sutil">
                          {n.forma_pagamento ?? "—"}
                        </span>
                      </span>
                      <span className="text-suave">
                        {n.entrada_centavos > 0
                          ? `Entrada ${formatarMoeda(Number(n.entrada_centavos))} + `
                          : ""}
                        {n.quantidade_parcelas}x{" "}
                        {formatarMoeda(Number(n.valor_parcela_centavos))}
                      </span>
                      <span className="text-xs text-suave">
                        {n.situacao === "pago"
                          ? n.ultimo_pagamento_em
                            ? `Pago em ${br(n.ultimo_pagamento_em)}`
                            : "Pago"
                          : n.proximo_vencimento
                            ? `Próximo: ${br(n.proximo_vencimento)}`
                            : ""}
                        {n.saldo_centavos > 0 && (
                          <span className="block">
                            Em aberto {formatarMoeda(Number(n.saldo_centavos))}
                          </span>
                        )}
                      </span>
                      <span
                        className={`justify-self-start rounded-full px-2 py-0.5 text-[11px] font-medium md:justify-self-end ${st.classe}`}
                      >
                        {st.rotulo}
                      </span>
                    </summary>
                    <div className="border-t border-borda px-4 pb-3">
                      <p className="mt-3 text-xs text-sutil">
                        Fechada em {br(n.fechada_em)}
                        {n.desconto_centavos > 0
                          ? ` · desconto ${formatarMoeda(Number(n.desconto_centavos))}`
                          : ""}
                        {` · pago ${formatarMoeda(Number(n.pago_centavos))}`}
                      </p>
                      {n.observacao && (
                        <p className="mt-1 text-sm text-suave">
                          Observações: {n.observacao}
                        </p>
                      )}
                      <ul aria-label="Pagamentos da negociação">
                        {parcelas.map((p) => (
                          <LinhaParcela key={p.id} p={p} hoje={hoje} />
                        ))}
                      </ul>
                      <div className="mt-2">
                        <VerPaciente pessoaId={n.pessoa_id} />
                      </div>
                    </div>
                  </details>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
