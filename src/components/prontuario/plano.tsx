"use client";

import { CheckCircle2, Plus } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useId, useState, useTransition } from "react";
import {
  abrirProntuarioDaConsulta,
  adicionarAoPlano,
  mudarStatusDoItem,
  negociacoesDoPaciente,
  novaConsulta,
  realizarProcedimento,
  type NegociacaoPaciente,
} from "@/app/(app)/prontuario/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { formatarMoeda } from "@/lib/moeda";
import { SITUACAO } from "@/modules/financeiro/financeiro";
import { ainda_a_fazer, STATUS_ITEM, STATUS_MANUAIS, type ItemPlano, type StatusItem } from "@/modules/prontuario/prontuario";

export type ProcedimentoPlano = { id: string; nome: string; ticket_medio_centavos: number | null };
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

// ─── Plano de tratamento ─────────────────────────────────────────────────────

function SeloFinanceiro({ i }: { i: ItemPlano }) {
  if (i.status !== "realizado") return null;
  if (!i.financeiro) return <span className="text-xs text-sutil">Sem cobrança</span>;
  const st = SITUACAO[i.financeiro];
  return (
    <span className={`text-xs font-medium ${i.financeiro === "atrasado" ? "text-urgente" : i.financeiro === "pago" ? "text-rotina" : "text-dourado-escuro"}`}>
      Pagamento: {i.financeiro === "pendente" ? "a receber" : st.rotulo.toLowerCase()}
      {i.financeiro !== "pago" && i.saldo_centavos ? ` · em aberto ${formatarMoeda(i.saldo_centavos)}` : ""}
      {i.financeiro !== "pago" && i.proximo_vencimento ? ` · próx. ${br(i.proximo_vencimento)}` : ""}
    </span>
  );
}

/**
 * Lista do plano. No prontuário: status editável. Na consulta (atendimentoId):
 * botão "Realizar" para o que ainda está a fazer.
 */
export function PlanoTratamento({
  pessoaId,
  itens,
  procedimentos,
  formas,
  atendimentoId,
  podeVerFinanceiro,
  editavel,
}: {
  pessoaId: string;
  itens: ItemPlano[];
  procedimentos: ProcedimentoPlano[];
  formas: FormaPlano[];
  atendimentoId?: string;
  podeVerFinanceiro: boolean;
  editavel: boolean;
}) {
  const [realizando, setRealizando] = useState<ItemPlano | null>(null);
  const [, iniciar] = useTransition();
  const visiveis = itens.filter((i) => i.status !== "cancelado" || !atendimentoId);

  return (
    <div>
      {visiveis.length === 0 ? (
        <p className="rounded-xl border border-dashed border-borda-forte bg-superficie p-4 text-sm text-sutil">Nenhum procedimento no plano ainda.</p>
      ) : (
        <ul aria-label="Plano de tratamento" className="divide-y divide-borda rounded-xl border border-borda bg-superficie">
          {visiveis.map((i) => {
            const st = STATUS_ITEM[i.status];
            const aFazer = ainda_a_fazer(i.status);
            return (
              <li key={i.id} aria-label={`${i.procedimento} — ${formatarMoeda(i.valor_centavos)}`} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                <div className="min-w-0">
                  <p className="flex flex-wrap items-center gap-2">
                    {i.status === "realizado" ? (
                      <CheckCircle2 className="size-4 text-rotina" aria-hidden />
                    ) : (
                      <span className="size-4 rounded border border-borda-forte" aria-hidden />
                    )}
                    <span className={`font-medium ${i.status === "cancelado" ? "line-through text-sutil" : ""}`}>{i.procedimento}</span>
                    <span className="text-sm tabular-nums">— {formatarMoeda(i.valor_centavos)}</span>
                    {i.dente && <span className="text-xs text-sutil">dente {i.dente}</span>}
                  </p>
                  <p className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-sutil">
                    <span className={`rounded-full px-2 py-0.5 font-medium ${st.classe}`}>{st.rotulo}</span>
                    {i.status === "realizado" && i.realizado_em && (
                      <span>
                        na consulta {String(i.realizado_atendimento_numero).padStart(2, "0")} · {br(i.realizado_em)}
                      </span>
                    )}
                    {podeVerFinanceiro && <SeloFinanceiro i={i} />}
                  </p>
                </div>
                {editavel && (
                  <div className="flex flex-wrap items-center gap-2">
                    {aFazer && !atendimentoId && (
                      <select
                        aria-label={`Status de ${i.procedimento}`}
                        value={i.status}
                        onChange={(e) =>
                          iniciar(async () => {
                            const r = await mudarStatusDoItem(i.id, e.target.value as StatusItem);
                            avisar(r.ok ? r.mensagem : r.erro, r.ok ? "sucesso" : "erro");
                          })
                        }
                        className="rounded-lg border border-borda-forte bg-superficie px-2 py-1 text-xs"
                      >
                        {STATUS_MANUAIS.map((s) => (
                          <option key={s} value={s}>
                            {STATUS_ITEM[s].rotulo}
                          </option>
                        ))}
                      </select>
                    )}
                    {!aFazer && i.status !== "realizado" && !atendimentoId && (
                      <button
                        type="button"
                        onClick={() =>
                          iniciar(async () => {
                            const r = await mudarStatusDoItem(i.id, "pendente");
                            avisar(r.ok ? r.mensagem : r.erro, r.ok ? "sucesso" : "erro");
                          })
                        }
                        className="text-xs text-dourado-escuro underline"
                      >
                        Voltar para pendente
                      </button>
                    )}
                    {aFazer && atendimentoId && (
                      <button
                        type="button"
                        onClick={() => setRealizando(i)}
                        className="rounded-lg bg-grafite px-3 py-1.5 text-xs font-medium text-white hover:bg-black"
                      >
                        Realizar nesta consulta
                      </button>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {editavel && <AdicionarAoPlano pessoaId={pessoaId} procedimentos={procedimentos} atendimentoId={atendimentoId} />}
      {realizando && atendimentoId && (
        <JanelaRealizar
          item={realizando}
          pessoaId={pessoaId}
          atendimentoId={atendimentoId}
          formas={formas}
          podeVerFinanceiro={podeVerFinanceiro}
          aoFechar={() => setRealizando(null)}
        />
      )}
    </div>
  );
}

function AdicionarAoPlano({ pessoaId, procedimentos, atendimentoId }: { pessoaId: string; procedimentos: ProcedimentoPlano[]; atendimentoId?: string }) {
  const [aberto, setAberto] = useState(false);
  const [procedimentoId, setProcedimentoId] = useState("");
  const [valor, setValor] = useState("");
  const [dente, setDente] = useState("");
  const [status, setStatus] = useState<"orcado" | "aceito" | "pendente">("orcado");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

  if (!aberto)
    return (
      <button type="button" onClick={() => setAberto(true)} className="mt-3 inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado">
        <Plus className="size-4 text-dourado" /> Adicionar procedimento ao plano
      </button>
    );
  return (
    <div className="mt-3 rounded-xl border border-borda bg-superficie p-4" role="group" aria-label="Adicionar ao plano">
      <div className="grid gap-x-3 sm:grid-cols-2">
        <Rotulo texto="Procedimento">
          {(id) => (
            <select
              id={id}
              value={procedimentoId}
              onChange={(e) => {
                setProcedimentoId(e.target.value);
                const p = procedimentos.find((x) => x.id === e.target.value);
                if (p?.ticket_medio_centavos && !valor) setValor(reais(p.ticket_medio_centavos));
              }}
              className={CAMPO}
            >
              <option value="">Escolha…</option>
              {procedimentos.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nome}
                </option>
              ))}
            </select>
          )}
        </Rotulo>
        <Rotulo texto="Valor (R$)">
          {(id) => <input id={id} value={valor} onChange={(e) => setValor(e.target.value)} inputMode="decimal" placeholder="Ex.: 1.200,00" className={CAMPO} />}
        </Rotulo>
        <Rotulo texto="Dente(s) (opcional)">
          {(id) => <input id={id} value={dente} onChange={(e) => setDente(e.target.value)} maxLength={60} placeholder="Ex.: 11, 21" className={CAMPO} />}
        </Rotulo>
        <Rotulo texto="Status">
          {(id) => (
            <select id={id} value={status} onChange={(e) => setStatus(e.target.value as typeof status)} className={CAMPO}>
              <option value="orcado">Orçado</option>
              <option value="aceito">Aceito</option>
              <option value="pendente">Pendente</option>
            </select>
          )}
        </Rotulo>
      </div>
      {erro && (
        <p role="alert" className="mt-3 text-sm text-urgente">
          {erro}
        </p>
      )}
      <div className="mt-4 flex justify-end gap-2">
        <button type="button" onClick={() => setAberto(false)} className="rounded-lg border border-borda-forte px-3.5 py-2 text-sm">
          Cancelar
        </button>
        <button
          type="button"
          disabled={pendente}
          onClick={() =>
            iniciar(async () => {
              setErro(null);
              if (!procedimentoId) return setErro("Escolha o procedimento.");
              const r = await adicionarAoPlano({ pessoaId, procedimentoId, valor, dente, atendimentoId: atendimentoId ?? "", status });
              if (r.ok) {
                avisar(r.mensagem);
                setAberto(false);
                setProcedimentoId("");
                setValor("");
                setDente("");
              } else setErro(r.erro);
            })
          }
          className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Adicionar ao plano"}
        </button>
      </div>
    </div>
  );
}

// ─── Realizar + pagamento ────────────────────────────────────────────────────

type Como = "pago" | "parcial" | "a_pagar" | "ja_registrado" | "sem_cobranca";
const OPCOES: { id: Como; rotulo: string; ajuda: string }[] = [
  { id: "pago", rotulo: "Pago", ajuda: "Recebido hoje." },
  { id: "parcial", rotulo: "Pagamento parcial", ajuda: "Pagou uma parte; o resto na data prevista." },
  { id: "a_pagar", rotulo: "Não pago", ajuda: "Vai pagar depois: data prevista e parcelas." },
  { id: "ja_registrado", rotulo: "Já está no Financeiro", ajuda: "Ligar a um pagamento já registrado." },
  { id: "sem_cobranca", rotulo: "Sem cobrança", ajuda: "Cortesia, garantia, retorno incluso…" },
];

function JanelaRealizar({
  item,
  pessoaId,
  atendimentoId,
  formas,
  podeVerFinanceiro,
  aoFechar,
}: {
  item: ItemPlano;
  pessoaId: string;
  atendimentoId: string;
  formas: FormaPlano[];
  podeVerFinanceiro: boolean;
  aoFechar: () => void;
}) {
  const [negociacoes, setNegociacoes] = useState<NegociacaoPaciente[] | null>(null);
  const [como, setComo] = useState<Como>(podeVerFinanceiro ? "pago" : "sem_cobranca");
  const [valor, setValor] = useState(reais(item.valor_centavos));
  const [formaId, setFormaId] = useState("");
  const [pagoAgora, setPagoAgora] = useState("");
  const [vencimento, setVencimento] = useState("");
  const [parcelas, setParcelas] = useState("1");
  const [vendaId, setVendaId] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const forma = formas.find((f) => f.id === formaId);
  const cobra = como === "pago" || como === "parcial" || como === "a_pagar";
  const podeParcelar = forma ? forma.max_parcelas > 1 && (como !== "pago" || forma.recebe_na_hora) : como !== "pago";

  useEffect(() => {
    if (podeVerFinanceiro) negociacoesDoPaciente(pessoaId).then(setNegociacoes);
  }, [pessoaId, podeVerFinanceiro]);

  const opcoes = OPCOES.filter((o) => (podeVerFinanceiro ? o.id !== "ja_registrado" || negociacoes?.length : o.id === "sem_cobranca"));

  function salvar() {
    setErro(null);
    iniciar(async () => {
      const r = await realizarProcedimento({
        itemId: item.id,
        atendimentoId,
        como,
        valor,
        formaId,
        pagoAgora,
        vencimento,
        parcelas: podeParcelar ? parcelas : "1",
        vendaId,
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo={`Realizar: ${item.procedimento}`} subtitulo={`${formatarMoeda(item.valor_centavos)}${item.dente ? ` · dente ${item.dente}` : ""}`}>
      <p className="text-sm font-medium">Como ficou o pagamento?</p>
      {!podeVerFinanceiro && <p className="mt-1 text-xs text-sutil">Seu acesso não inclui o financeiro: o pagamento é registrado por quem cuida dele.</p>}
      <div role="radiogroup" aria-label="Pagamento" className="mt-2 grid gap-2 sm:grid-cols-2">
        {opcoes.map((o) => (
          <button
            key={o.id}
            type="button"
            role="radio"
            aria-checked={como === o.id}
            onClick={() => setComo(o.id)}
            className={`rounded-lg border px-3 py-2 text-left text-sm ${como === o.id ? "border-dourado bg-dourado-claro" : "border-borda-forte hover:border-dourado"}`}
          >
            <span className="font-medium">{o.rotulo}</span>
            <span className="block text-xs text-sutil">{o.ajuda}</span>
          </button>
        ))}
      </div>

      {como === "ja_registrado" && (
        <Rotulo texto="Pagamento no Financeiro">
          {(id) => (
            <select id={id} value={vendaId} onChange={(e) => setVendaId(e.target.value)} className={CAMPO}>
              <option value="">Escolha…</option>
              {negociacoes?.map((n) => (
                <option key={n.id} value={n.id}>
                  {n.descricao}
                </option>
              ))}
            </select>
          )}
        </Rotulo>
      )}

      {cobra && (
        <>
          <div className="grid gap-x-3 sm:grid-cols-2">
            <Rotulo texto="Valor">
              {(id) => <input id={id} value={valor} onChange={(e) => setValor(e.target.value)} inputMode="decimal" className={CAMPO} />}
            </Rotulo>
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
          </div>
          {forma?.recebe_na_hora ? (
            <p className="mt-2 text-xs text-sutil">Cartão é recebido na hora: entra como pago, sem lembretes.</p>
          ) : (
            <>
              {como === "parcial" && (
                <Rotulo texto="Pago agora">
                  {(id) => <input id={id} value={pagoAgora} onChange={(e) => setPagoAgora(e.target.value)} inputMode="decimal" placeholder="Ex.: 500,00" className={CAMPO} />}
                </Rotulo>
              )}
              {como !== "pago" && (
                <Rotulo texto={como === "parcial" ? "Data prevista do restante" : "Data prevista do pagamento"}>
                  {(id) => <input id={id} type="date" value={vencimento} onChange={(e) => setVencimento(e.target.value)} className={CAMPO} />}
                </Rotulo>
              )}
            </>
          )}
          {podeParcelar && (
            <Rotulo texto="Parcelas">
              {(id) => <input id={id} type="number" min={1} max={forma?.max_parcelas ?? 60} value={parcelas} onChange={(e) => setParcelas(e.target.value)} className={CAMPO} />}
            </Rotulo>
          )}
        </>
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
          {pendente ? "Salvando…" : "Marcar como realizado"}
        </button>
      </div>
    </Dialogo>
  );
}
