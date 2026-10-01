import { AlertTriangle, ArrowLeft, CalendarClock, ChevronRight, UserRound } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { z } from "zod";
import { LinhaParcela } from "@/components/financeiro/financeiro";
import { Bloco } from "@/components/prontuario/ficha";
import { Odontograma } from "@/components/prontuario/odontograma";
import { BotaoAbrirProntuario, BotaoNovaConsulta, PlanoTratamento } from "@/components/prontuario/plano";
import { comoUsuaria } from "@/lib/db";
import { formatarMoeda } from "@/lib/moeda";
import { formatarTelefone } from "@/lib/telefone";
import { ainda_a_fazer, idade, normalizarOdontograma, totaisPlano, tituloConsulta } from "@/modules/prontuario/prontuario";
import {
  carregarCatalogo,
  carregarConsultas,
  carregarFinanceiro,
  carregarPaciente,
  carregarPlano,
  carregarProximas,
} from "@/modules/prontuario/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import { SemAcessoProntuario } from "../sem-acesso";

export const metadata = { title: "Prontuário · Instituto CG" };

const br = (d: string) => d.split("-").reverse().join("/");
const TIPO: Record<string, string> = {
  avaliacao: "Avaliação",
  apresentacao_orcamento: "Retorno para decisão",
  procedimento: "Procedimento",
  retorno: "Retorno",
  manutencao: "Manutenção",
};

export default async function Prontuario({
  params,
  searchParams,
}: {
  params: Promise<{ pessoaId: string }>;
  searchParams: Promise<{ consulta?: string }>;
}) {
  const sessao = await exigirSessao();
  if (!sessao.podeVerProntuario) return <SemAcessoProntuario />;
  const { pessoaId } = await params;
  const busca = await searchParams;
  if (!z.uuid().safeParse(pessoaId).success) notFound();

  const d = await comoUsuaria(sessao.usuarioId, async (db) => {
    const paciente = await carregarPaciente(db, pessoaId);
    if (!paciente) return null;
    const hoje = (await db.query<{ hoje: string }>("select public.hoje_clinica($1) as hoje", [sessao.clinicaId])).rows[0].hoje;
    const consultas = await carregarConsultas(db, pessoaId);
    const plano = await carregarPlano(db, pessoaId);
    const proximas = await carregarProximas(db, pessoaId);
    const financeiro = sessao.podeVerFinanceiro ? await carregarFinanceiro(db, pessoaId) : null;
    const catalogo = await carregarCatalogo(db, sessao.clinicaId);
    // Odontograma: o da consulta escolhida (evolução) ou o da mais recente.
    const escolhida = consultas.find((c) => c.id === busca.consulta) ?? consultas[0];
    const odonto = escolhida
      ? (await db.query<{ odontograma: unknown }>("select odontograma from public.atendimentos where id = $1", [escolhida.id])).rows[0].odontograma
      : {};
    return { paciente, hoje, consultas, plano, proximas, financeiro, catalogo, escolhida, odonto: normalizarOdontograma(odonto) };
  });
  if (!d) notFound();

  const { paciente: p, consultas, plano, hoje } = d;
  const ultima = consultas[0] ?? null;
  const proxima = d.proximas[0] ?? null;
  const anos = idade(p.data_nascimento, hoje);
  const alertas = ultima?.anamnese ?? [];
  const totais = totaisPlano(plano);
  const realizados = plano.filter((i) => i.status === "realizado");
  const pendentes = plano.filter((i) => ainda_a_fazer(i.status));

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-8 lg:py-10">
      <Link href="/prontuario" className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Prontuários
      </Link>

      {/* Paciente */}
      <header className="mt-4 flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-[11px] font-semibold tracking-[0.12em] text-sutil uppercase">Prontuário</p>
          <h1 className="mt-1 font-titulo text-4xl leading-tight">{p.nome}</h1>
          <p className="mt-1 text-sm text-suave">
            {[anos !== null && `${anos} anos`, p.data_nascimento && `nasc. ${br(p.data_nascimento)}`, p.whatsapp && formatarTelefone(p.whatsapp)]
              .filter(Boolean)
              .join(" · ")}
          </p>
          {alertas.length > 0 && (
            <p className="mt-2 flex flex-wrap items-center gap-1.5" aria-label="Alertas de saúde">
              <AlertTriangle className="size-4 text-urgente" aria-hidden />
              {alertas.map((a) => (
                <span key={a} className="rounded-full bg-urgente-claro px-2 py-0.5 text-xs font-medium text-urgente">
                  {a}
                </span>
              ))}
            </p>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          <Link
            href={`/contatos/${p.id}`}
            className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte bg-superficie px-3.5 py-2 text-sm font-medium hover:border-dourado"
          >
            <UserRound className="size-4" /> Cadastro
          </Link>
          <BotaoNovaConsulta pessoaId={p.id} />
        </div>
      </header>

      {/* Resumo */}
      <dl className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="rounded-xl border border-borda bg-superficie p-4">
          <dt className="text-xs text-sutil">Última consulta</dt>
          <dd className="mt-1 text-sm font-medium">
            {ultima ? (
              <Link href={`/prontuario/${p.id}/consulta/${ultima.id}`} className="hover:underline">
                {tituloConsulta(ultima)}
              </Link>
            ) : (
              "Nenhuma ainda"
            )}
          </dd>
        </div>
        <div className="rounded-xl border border-borda bg-superficie p-4">
          <dt className="text-xs text-sutil">Próxima consulta</dt>
          <dd className="mt-1 text-sm font-medium">
            {proxima ? (
              <>
                {br(proxima.dia)} às {proxima.horario} · {TIPO[proxima.tipo] ?? proxima.tipo}
                {proxima.profissional && <span className="block text-xs font-normal text-sutil">{proxima.profissional}</span>}
              </>
            ) : (
              <Link href={`/agenda?novo=${p.id}`} className="inline-flex items-center gap-1 text-dourado-escuro underline">
                <CalendarClock className="size-4" /> Agendar
              </Link>
            )}
          </dd>
        </div>
        <div className="rounded-xl border border-borda bg-superficie p-4">
          <dt className="text-xs text-sutil">Plano de tratamento</dt>
          <dd className="mt-1 text-sm font-medium">
            {realizados.length} realizado{realizados.length === 1 ? "" : "s"} · {pendentes.length} a fazer
            <span className="block text-xs font-normal text-sutil">
              {formatarMoeda(totais.realizado)} realizado · {formatarMoeda(totais.aFazer)} a fazer
            </span>
          </dd>
        </div>
        <div className="rounded-xl border border-borda bg-superficie p-4">
          <dt className="text-xs text-sutil">Situação financeira</dt>
          <dd className="mt-1 text-sm font-medium">
            {d.financeiro ? (
              d.financeiro.em_aberto > 0 ? (
                <>
                  <span className={d.financeiro.atrasado > 0 ? "text-urgente" : ""}>{formatarMoeda(d.financeiro.em_aberto)} em aberto</span>
                  {d.financeiro.atrasado > 0 && <span className="block text-xs text-urgente">{formatarMoeda(d.financeiro.atrasado)} atrasado</span>}
                </>
              ) : (
                <span className="text-rotina">Em dia</span>
              )
            ) : (
              <span className="text-sutil">Sem acesso ao financeiro</span>
            )}
            {d.financeiro && d.financeiro.pago > 0 && <span className="block text-xs font-normal text-sutil">{formatarMoeda(d.financeiro.pago)} pago</span>}
          </dd>
        </div>
      </dl>

      {d.proximas.some((a) => a.dia === hoje) && (
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-dourado/50 bg-dourado-claro/50 px-4 py-3">
          <p className="text-sm">
            <strong>Consulta hoje</strong> às {d.proximas.find((a) => a.dia === hoje)!.horario}. Abra a ficha para registrar o atendimento.
          </p>
          <BotaoAbrirProntuario
            agendamentoId={d.proximas.find((a) => a.dia === hoje)!.id}
            classe="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black"
          />
        </div>
      )}

      <div className="mt-6 grid gap-5 lg:grid-cols-5">
        <div className="min-w-0 space-y-5 lg:col-span-3">
          <Bloco
            titulo="Odontograma"
            id="odontograma"
            acao={
              d.escolhida && (
                <span className="text-xs text-sutil">
                  {d.escolhida.id === ultima?.id ? "Estado atual · " : ""}
                  {tituloConsulta(d.escolhida)}
                </span>
              )
            }
          >
            {consultas.length === 0 ? (
              <p className="text-sm text-sutil">O odontograma é registrado dentro de cada consulta.</p>
            ) : (
              <>
                <Odontograma valor={d.odonto} />
                {consultas.length > 1 && (
                  <nav aria-label="Odontograma por consulta" className="mt-4 flex flex-wrap gap-1.5 text-xs">
                    <span className="py-1 text-sutil">Evolução:</span>
                    {[...consultas].reverse().map((c) => (
                      <Link
                        key={c.id}
                        href={`/prontuario/${p.id}?consulta=${c.id}#odontograma`}
                        aria-current={c.id === d.escolhida?.id ? "page" : undefined}
                        className={`rounded-full border px-2.5 py-1 ${c.id === d.escolhida?.id ? "border-dourado bg-dourado-claro text-dourado-escuro" : "border-borda-forte text-suave hover:border-dourado"}`}
                      >
                        {String(c.numero).padStart(2, "0")} · {br(c.data).slice(0, 5)}
                      </Link>
                    ))}
                  </nav>
                )}
              </>
            )}
          </Bloco>

          <Bloco titulo="Plano de tratamento / orçamento" id="plano">
            <PlanoTratamento
              pessoaId={p.id}
              itens={plano}
              procedimentos={d.catalogo.procedimentos}
              formas={d.catalogo.formas}
              podeVerFinanceiro={sessao.podeVerFinanceiro}
              editavel
            />
            {plano.length > 0 && (
              <p className="mt-3 text-xs text-sutil">
                Total do plano {formatarMoeda(totais.total)}. Para marcar um procedimento como realizado, abra a consulta em que ele foi feito.
              </p>
            )}
          </Bloco>

          {d.financeiro && d.financeiro.parcelas.length > 0 && (
            <Bloco titulo="Pagamentos em aberto" id="financeiro" acao={<Link href={`/financeiro?q=${encodeURIComponent(p.nome)}`} className="text-xs text-dourado-escuro underline">Ver no Financeiro</Link>}>
              <ul aria-label="Pagamentos em aberto do paciente" className="-my-3">
                {d.financeiro.parcelas.map((x) => (
                  <LinhaParcela key={x.id} p={x} hoje={hoje} />
                ))}
              </ul>
            </Bloco>
          )}
        </div>

        <div className="min-w-0 space-y-5 lg:col-span-2">
          <Bloco titulo="Histórico de consultas" id="historico">
            {consultas.length === 0 ? (
              <p className="text-sm text-sutil">Nenhuma consulta registrada. Use “Nova consulta” ou abra pelo agendamento.</p>
            ) : (
              <ol aria-label="Histórico de consultas" className="relative space-y-3 border-l-2 border-dourado/30 pl-4">
                {consultas.map((c) => (
                  <li key={c.id} className="relative">
                    <span className="absolute top-2 -left-[23px] size-3 rounded-full border-2 border-superficie" style={{ backgroundColor: c.profissional_cor ?? "#b08d57" }} aria-hidden />
                    <Link href={`/prontuario/${p.id}/consulta/${c.id}`} className="block rounded-lg border border-borda px-3 py-2 hover:border-dourado">
                      <span className="flex items-center justify-between gap-2">
                        <span className="text-sm font-semibold">{tituloConsulta(c)}</span>
                        <ChevronRight className="size-4 shrink-0 text-sutil" />
                      </span>
                      <span className="block text-xs text-sutil">
                        {[c.horario, c.profissional, c.status === "em_andamento" ? "em andamento" : "finalizada"].filter(Boolean).join(" · ")}
                      </span>
                      {c.procedimentos_realizados && <span className="mt-1 block text-xs text-rotina">✓ {c.procedimentos_realizados}</span>}
                      {c.diagnostico.length > 0 && <span className="block text-xs text-suave">Diagnóstico: {c.diagnostico.join(", ")}</span>}
                    </Link>
                  </li>
                ))}
              </ol>
            )}
          </Bloco>

          <Bloco titulo="Procedimentos" id="procedimentos">
            <h3 className="text-xs font-semibold tracking-wide text-sutil uppercase">Realizados</h3>
            {realizados.length === 0 ? (
              <p className="mt-1 text-sm text-sutil">Nenhum ainda.</p>
            ) : (
              <ul aria-label="Procedimentos realizados" className="mt-1 space-y-1 text-sm">
                {realizados.map((i) => (
                  <li key={i.id} className="flex justify-between gap-2">
                    <span>✓ {i.procedimento}</span>
                    <span className="text-xs text-sutil">
                      consulta {String(i.realizado_atendimento_numero).padStart(2, "0")} · {i.realizado_em && br(i.realizado_em)}
                    </span>
                  </li>
                ))}
              </ul>
            )}
            <h3 className="mt-4 text-xs font-semibold tracking-wide text-sutil uppercase">Pendentes</h3>
            {pendentes.length === 0 ? (
              <p className="mt-1 text-sm text-sutil">Nada pendente.</p>
            ) : (
              <ul aria-label="Procedimentos pendentes" className="mt-1 space-y-1 text-sm">
                {pendentes.map((i) => (
                  <li key={i.id} className="flex justify-between gap-2">
                    <span>☐ {i.procedimento}</span>
                    <span className="text-xs text-sutil">{formatarMoeda(i.valor_centavos)}</span>
                  </li>
                ))}
              </ul>
            )}
          </Bloco>
        </div>
      </div>
    </div>
  );
}
