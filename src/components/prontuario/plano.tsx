"use client";

import { CheckCircle2, Plus, Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useId, useOptimistic, useState, useTransition } from "react";
import {
  abrirProntuarioDaConsulta,
  adicionarProcedimento,
  marcarFeito,
  novaConsulta,
  registrarPagamentoDoPlano,
  removerDoPlano,
} from "@/app/(app)/prontuario/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { LinhaParcela } from "@/components/financeiro/financeiro";
import { CampoProcedimento } from "@/components/procedimento";
import { formatarMoeda, paraCentavos } from "@/lib/moeda";
import type { ParcelaFin } from "@/modules/financeiro/financeiro";
import { ainda_a_fazer, type ItemPlano } from "@/modules/prontuario/prontuario";

export type ProcedimentoPlano = { id: string; nome: string; ticket_medio_centavos: number | null };
export type SituacaoPlano = {
  total: number;
  registrado: number;
  pago: number;
  pendente: number;
  a_registrar: number;
  atrasado: number;
  proximo_vencimento: string | null;
};
export type FormaPlano = { id: string; nome: string; max_parcelas: number; recebe_na_hora: boolean };

const CAMPO = "mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";
const reais = (c: number) => formatarMoeda(c).replace("R$ ", "");
const br = (d: string) => d.split("-").reverse().join("/");

function Rotulo({ texto, children }: { texto: string; children: (id: string) => React.ReactNode }) {
  const id = useId();
  return (
    <div className="mt-3">
      <label htmlFor={id} className="text-sm text-suave">
        {texto}
      </label>
      {children(id)}
    </div>
  );
}

// ─── Botões de navegação para o prontuário ───────────────────────────────────

export function BotaoAbrirProntuario({ agendamentoId, classe }: { agendamentoId: string; classe?: string }) {
  const router = useRouter();
  const [pendente, iniciar] = useTransition();
  return (
    <button
      type="button"
      disabled={pendente}
      onClick={() =>
        iniciar(async () => {
          const r = await abrirProntuarioDaConsulta(agendamentoId);
          if (r.ok) router.push(r.url);
          else avisar(r.erro, "erro");
        })
      }
      className={classe ?? "rounded-lg border border-borda-forte px-3 py-2 text-sm font-medium hover:border-dourado disabled:opacity-50"}
    >
      {pendente ? "Abrindo…" : "Abrir prontuário"}
    </button>
  );
}

export function BotaoNovaConsulta({ pessoaId }: { pessoaId: string }) {
  const router = useRouter();
  const [pendente, iniciar] = useTransition();
  return (
    <button
      type="button"
      disabled={pendente}
      onClick={() =>
        iniciar(async () => {
          const r = await novaConsulta(pessoaId);
          if (r.ok) router.push(r.url);
          else avisar(r.erro, "erro");
        })
      }
      className="inline-flex items-center gap-1.5 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase shadow-sm hover:bg-dourado-escuro disabled:opacity-60"
    >
      <Plus className="size-4" /> {pendente ? "Abrindo…" : "Nova consulta"}
    </button>
  );
}

// ─── Plano de tratamento: procedimento livre, valor e "feito hoje" ──────────

function Avisar(r: { ok: true; mensagem: string } | { ok: false; erro: string }) {
  avisar(r.ok ? r.mensagem : r.erro, r.ok ? "sucesso" : "erro");
}

/**
 * Lista do plano com total. Na consulta (atendimentoId): caixinha "Feito hoje"
 * para cada procedimento pendente e para os que entram agora.
 */
export function PlanoTratamento({
  pessoaId,
  itens,
  sugestoes,
  atendimentoId,
  travado = false,
}: {
  pessoaId: string;
  itens: ItemPlano[];
  sugestoes: ProcedimentoPlano[];
  atendimentoId?: string;
  travado?: boolean;
}) {
  const [pendente, iniciar] = useTransition();
  // A caixinha muda na hora; o servidor confirma em seguida.
  const [otimista, marcar] = useOptimistic<Record<string, boolean>, [string, boolean]>({}, (atual, [id, v]) => ({ ...atual, [id]: v }));
  const visiveis = itens.filter((i) => i.status !== "cancelado" && i.status !== "nao_realizado");
  const total = visiveis.reduce((t, i) => t + Number(i.valor_centavos), 0);
  const naConsulta = Boolean(atendimentoId);

  return (
    <div>
      {visiveis.length === 0 ? (
        <p className="rounded-xl border border-dashed border-borda-forte p-4 text-sm text-sutil">Nenhum procedimento ainda. Escreva abaixo.</p>
      ) : (
        <ul aria-label="Plano de tratamento" className="divide-y divide-borda rounded-xl border border-borda">
          {visiveis.map((i) => {
            const feitoAqui = otimista[i.id] ?? (i.status === "realizado" && i.realizado_atendimento_id === atendimentoId);
            const feitoAntes = i.status === "realizado" && i.realizado_atendimento_id !== atendimentoId;
            const aFazer = ainda_a_fazer(i.status) && !feitoAqui;
            return (
              <li key={i.id} aria-label={`${i.procedimento} — ${formatarMoeda(i.valor_centavos)}`} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2.5 sm:px-4">
                {naConsulta && !feitoAntes ? (
                  <label className="flex items-center gap-2">
                    <input
                      type="checkbox"
                      checked={feitoAqui}
                      disabled={travado || pendente}
                      onChange={(e) => {
                        const v = e.target.checked;
                        iniciar(async () => {
                          marcar([i.id, v]);
                          Avisar(await marcarFeito(i.id, atendimentoId!, v));
                        });
                      }}
                      className="size-4 accent-[#b08d57]"
                    />
                    <span className="sr-only">Feito hoje: {i.procedimento}</span>
                  </label>
                ) : i.status === "realizado" ? (
                  <CheckCircle2 className="size-4 shrink-0 text-rotina" aria-hidden />
                ) : (
                  <span className="size-4 shrink-0 rounded border border-borda-forte" aria-hidden />
                )}
                <span className="min-w-0 flex-1 font-medium">{i.procedimento}</span>
                <span className="text-sm tabular-nums">{formatarMoeda(i.valor_centavos)}</span>
                <span className="w-full pl-6 text-xs sm:w-auto sm:pl-0">
                  {feitoAqui ? (
                    <span className="font-medium text-rotina">Feito hoje</span>
                  ) : feitoAntes ? (
                    <span className="text-rotina">
                      Feito na consulta {String(i.realizado_atendimento_numero).padStart(2, "0")}
                      {i.realizado_em ? ` · ${br(i.realizado_em)}` : ""}
                    </span>
                  ) : (
                    <span className="text-importante">Pendente</span>
                  )}
                </span>
                {aFazer && !travado && (
                  <button
                    type="button"
                    aria-label={`Remover ${i.procedimento} do plano`}
                    disabled={pendente}
                    onClick={() => iniciar(async () => Avisar(await removerDoPlano(i.id)))}
                    className="rounded p-1 text-sutil hover:text-urgente"
                  >
                    <Trash2 className="size-4" />
                  </button>
                )}
              </li>
            );
          })}
          <li className="flex items-center justify-between bg-fundo px-3 py-2.5 sm:px-4" aria-label="Total do orçamento">
            <span className="text-sm font-semibold tracking-wide uppercase">Total</span>
            <span className="font-semibold tabular-nums">{formatarMoeda(total)}</span>
          </li>
        </ul>
      )}
      {!travado && <NovoProcedimento pessoaId={pessoaId} sugestoes={sugestoes} atendimentoId={atendimentoId} />}
    </div>
  );
}

function NovoProcedimento({ pessoaId, sugestoes, atendimentoId }: { pessoaId: string; sugestoes: ProcedimentoPlano[]; atendimentoId?: string }) {
  const [nome, setNome] = useState("");
  const [valor, setValor] = useState("");
  const [feito, setFeito] = useState(false);
  const [pendente, iniciar] = useTransition();
  const idNome = useId();
  const idValor = useId();

  function escolher(v: string) {
    setNome(v);
    const s = sugestoes.find((x) => x.nome.toLowerCase() === v.trim().toLowerCase());
    if (s?.ticket_medio_centavos && !valor) setValor(reais(s.ticket_medio_centavos));
  }

  return (
    <div className="mt-3 grid gap-2 rounded-xl border border-dashed border-borda-forte p-3 sm:grid-cols-[1fr_9rem_auto_auto] sm:items-end" role="group" aria-label="Novo procedimento">
      <div>
        <label htmlFor={idNome} className="text-xs text-sutil">
          Procedimento
        </label>
        <CampoProcedimento id={idNome} value={nome} onChange={escolher} sugestoes={sugestoes} placeholder="Ex.: Facetas em resina" className={CAMPO} />
      </div>
      <div>
        <label htmlFor={idValor} className="text-xs text-sutil">
          Valor (R$)
        </label>
        <input id={idValor} value={valor} onChange={(e) => setValor(e.target.value)} inputMode="decimal" placeholder="0,00" className={CAMPO} />
      </div>
      {atendimentoId && (
        <label className="flex items-center gap-2 pb-2 text-sm">
          <input type="checkbox" checked={feito} onChange={(e) => setFeito(e.target.checked)} className="size-4 accent-[#b08d57]" />
          Feito hoje
        </label>
      )}
      <button
        type="button"
        disabled={pendente}
        onClick={() =>
          iniciar(async () => {
            const r = await adicionarProcedimento({ pessoaId, nome, valor, atendimentoId: atendimentoId ?? "", feito });
            Avisar(r);
            if (r.ok) {
              setNome("");
              setValor("");
              setFeito(false);
            }
          })
        }
        className="inline-flex items-center justify-center gap-1.5 rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
      >
        <Plus className="size-4" /> {pendente ? "Adicionando…" : "Adicionar"}
      </button>
    </div>
  );
}

// ─── Pagamento do plano (pagamento ≠ realização) ─────────────────────────────

export function PagamentoPlano({
  planoId,
  situacao,
  formas,
  parcelas,
  hoje,
}: {
  planoId: string | null;
  situacao: SituacaoPlano | null;
  formas: FormaPlano[];
  parcelas: ParcelaFin[];
  hoje: string;
}) {
  const [aberto, setAberto] = useState(false);
  const s = situacao ?? { total: 0, registrado: 0, pago: 0, pendente: 0, a_registrar: 0, atrasado: 0, proximo_vencimento: null };
  const quadros = [
    { rotulo: "Total do orçamento", valor: s.total, cor: "text-grafite" },
    { rotulo: "Pago", valor: s.pago, cor: "text-rotina" },
    { rotulo: "Pendente", valor: s.pendente, cor: Number(s.pendente) > 0 ? (Number(s.atrasado) > 0 ? "text-urgente" : "text-importante") : "text-rotina" },
  ];
  return (
    <div>
      <dl className="grid grid-cols-3 gap-2">
        {quadros.map((q) => (
          <div key={q.rotulo} className="rounded-xl border border-borda bg-fundo/60 px-3 py-2.5">
            <dt className="text-[11px] font-semibold tracking-wide text-sutil uppercase">{q.rotulo}</dt>
            <dd className={`mt-0.5 text-lg font-semibold tabular-nums ${q.cor}`}>{formatarMoeda(Number(q.valor))}</dd>
          </div>
        ))}
      </dl>
      {Number(s.atrasado) > 0 && <p className="mt-2 text-sm text-urgente">{formatarMoeda(Number(s.atrasado))} em atraso.</p>}
      {Number(s.pendente) > 0 && Number(s.a_registrar) === 0 && s.proximo_vencimento && (
        <p className="mt-2 text-sm text-suave">Próximo pagamento previsto para {br(s.proximo_vencimento)}.</p>
      )}
      {Number(s.a_registrar) > 0 && planoId && (
        <div className="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-dourado/50 bg-dourado-claro/50 px-3 py-2.5">
          <p className="text-sm">
            {formatarMoeda(Number(s.a_registrar))} ainda sem pagamento registrado.
          </p>
          <button type="button" onClick={() => setAberto(true)} className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black">
            Registrar pagamento
          </button>
        </div>
      )}
      {parcelas.length > 0 && (
        <>
          <h3 className="mt-4 text-xs font-semibold tracking-wide text-sutil uppercase">Pagamentos previstos</h3>
          <ul aria-label="Pagamentos previstos do plano" className="-mb-3">
            {parcelas.map((x) => (
              <LinhaParcela key={x.id} p={x} hoje={hoje} />
            ))}
          </ul>
        </>
      )}
      {aberto && planoId && <JanelaPagamentoPlano planoId={planoId} aRegistrar={Number(s.a_registrar)} formas={formas} hoje={hoje} aoFechar={() => setAberto(false)} />}
    </div>
  );
}

type Como = "integral" | "parcial" | "nao_pago";
const OPCOES: { id: Como; rotulo: string }[] = [
  { id: "integral", rotulo: "Pago integralmente" },
  { id: "parcial", rotulo: "Parcialmente pago" },
  { id: "nao_pago", rotulo: "Não pago" },
];

function JanelaPagamentoPlano({ planoId, aRegistrar, formas, hoje, aoFechar }: { planoId: string; aRegistrar: number; formas: FormaPlano[]; hoje: string; aoFechar: () => void }) {
  const [como, setComo] = useState<Como>("integral");
  const [formaId, setFormaId] = useState("");
  const [valorPago, setValorPago] = useState("");
  const [dataPagamento, setDataPagamento] = useState(hoje);
  const [vencimento, setVencimento] = useState("");
  const [parcelas, setParcelas] = useState("1");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const forma = formas.find((f) => f.id === formaId);
  const cartao = Boolean(forma?.recebe_na_hora);
  const pago = como === "integral" ? aRegistrar : como === "parcial" ? (paraCentavos(valorPago) ?? 0) : 0;
  const restante = Math.max(aRegistrar - pago, 0);
  const podeParcelar = como !== "integral" || cartao;

  function salvar() {
    setErro(null);
    iniciar(async () => {
      const r = await registrarPagamentoDoPlano({
        planoId,
        como,
        formaId,
        valorPago,
        dataPagamento,
        vencimento,
        parcelas: podeParcelar ? parcelas : "1",
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo="Registrar pagamento" subtitulo={`Valor a registrar: ${formatarMoeda(aRegistrar)}`}>
      <div role="radiogroup" aria-label="Como foi o pagamento" className="grid grid-cols-3 gap-2">
        {OPCOES.map((o) => (
          <button
            key={o.id}
            type="button"
            role="radio"
            aria-checked={como === o.id}
            onClick={() => setComo(o.id)}
            className={`rounded-lg border px-2 py-2 text-sm ${como === o.id ? "border-dourado bg-dourado-claro font-medium" : "border-borda-forte hover:border-dourado"}`}
          >
            {o.rotulo}
          </button>
        ))}
      </div>
      <Rotulo texto="Forma de pagamento">
        {(id) => (
          <select id={id} value={formaId} onChange={(e) => setFormaId(e.target.value)} className={CAMPO}>
            <option value="">Escolha…</option>
            {formas.map((f) => (
              <option key={f.id} value={f.id}>
                {f.nome}
              </option>
            ))}
          </select>
        )}
      </Rotulo>
      {cartao && <p className="mt-2 text-xs text-sutil">Cartão é recebido na hora: entra como pago, sem lembretes.</p>}
      {!cartao && como !== "nao_pago" && (
        <div className="grid gap-x-3 sm:grid-cols-2">
          {como === "parcial" && (
            <Rotulo texto="Valor pago">
              {(id) => <input id={id} value={valorPago} onChange={(e) => setValorPago(e.target.value)} inputMode="decimal" placeholder="Ex.: 3.000,00" className={CAMPO} />}
            </Rotulo>
          )}
          <Rotulo texto="Data do pagamento">
            {(id) => <input id={id} type="date" max={hoje} value={dataPagamento} onChange={(e) => setDataPagamento(e.target.value)} className={CAMPO} />}
          </Rotulo>
        </div>
      )}
      {!cartao && como !== "integral" && (
        <>
          <p className="mt-3 rounded-lg bg-fundo px-3 py-2 text-sm">
            Valor restante: <strong className="tabular-nums">{formatarMoeda(restante)}</strong>
          </p>
          <div className="grid gap-x-3 sm:grid-cols-2">
            <Rotulo texto="Data prevista para o restante">
              {(id) => <input id={id} type="date" min={hoje} value={vencimento} onChange={(e) => setVencimento(e.target.value)} className={CAMPO} />}
            </Rotulo>
            <Rotulo texto="Parcelas do restante">
              {(id) => <input id={id} type="number" min={1} max={60} value={parcelas} onChange={(e) => setParcelas(e.target.value)} className={CAMPO} />}
            </Rotulo>
          </div>
          <p className="mt-2 text-xs text-sutil">No dia previsto, o lembrete aparece nas pendências de hoje; se passar, aparece como vencido.</p>
        </>
      )}
      {cartao && (
        <Rotulo texto="Parcelas no cartão">
          {(id) => <input id={id} type="number" min={1} max={forma?.max_parcelas ?? 12} value={parcelas} onChange={(e) => setParcelas(e.target.value)} className={CAMPO} />}
        </Rotulo>
      )}
      {erro && (
        <p role="alert" className="mt-3 text-sm text-urgente">
          {erro}
        </p>
      )}
      <div className="mt-6 flex justify-end gap-2">
        <button type="button" onClick={aoFechar} className="rounded-lg border border-borda-forte px-3.5 py-2 text-sm">
          Voltar
        </button>
        <button type="button" disabled={pendente} onClick={salvar} className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50">
          {pendente ? "Salvando…" : "Registrar pagamento"}
        </button>
      </div>
    </Dialogo>
  );
}
