"use client";

import { CalendarClock, HandCoins, Plus, Search, UserRound, X } from "lucide-react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { cloneElement, useEffect, useId, useState, useTransition, type ReactElement } from "react";
import { buscarPacientes, type PacienteEncontrado } from "@/app/(app)/agenda/acoes";
import { registrarNegociacao, type FormaPagamento } from "@/app/(app)/financeiro/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { JanelaNovaData, JanelaPagamento } from "@/components/financeiro/pagamento";
import { formatarMoeda, paraCentavos } from "@/lib/moeda";
import { rotuloParcela, rotuloVencimento, simularParcelas, SITUACAO, type ParcelaFin } from "@/modules/financeiro/financeiro";

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";
const BOTAO = "inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado";

function Campo({ rotulo, ajuda, children }: { rotulo: string; ajuda?: string; children: ReactElement<{ id?: string }> }) {
  const id = useId();
  return (
    <div className="mt-4">
      <label htmlFor={id} className="text-sm text-suave">
        {rotulo}
      </label>
      {cloneElement(children, { id })}
      {ajuda && <span className="mt-1 block text-xs text-sutil">{ajuda}</span>}
    </div>
  );
}

/** Uma parcela: paciente, procedimento, valor, vencimento, status e ações. */
export function LinhaParcela({ p, hoje }: { p: ParcelaFin; hoje: string }) {
  const [janela, setJanela] = useState<"pago" | "data" | null>(null);
  const st = SITUACAO[p.situacao];
  const aberta = p.situacao !== "pago";
  const titulo = `${p.pessoa_nome} — ${formatarMoeda(aberta ? p.saldo_centavos : p.valor_centavos)}`;
  return (
    <li aria-label={titulo} className="flex flex-wrap items-center justify-between gap-3 border-b border-borda py-3 last:border-0">
      <div className="min-w-0">
        <p className="font-medium">
          <Link href={`/contatos/${p.pessoa_id}#financeiro`} className="hover:underline">
            {p.pessoa_nome}
          </Link>{" "}
          <span className="text-grafite">— {formatarMoeda(aberta ? p.saldo_centavos : p.valor_centavos)}</span>
        </p>
        <p className="text-xs text-sutil">
          {[p.procedimento, rotuloParcela(p.numero, p.quantidade_parcelas), p.forma_pagamento].filter(Boolean).join(" · ")}
          {p.situacao === "parcial" || (p.situacao === "atrasado" && p.valor_pago_centavos > 0)
            ? ` · já pago ${formatarMoeda(p.valor_pago_centavos)}`
            : ""}
        </p>
        {p.observacao && <p className="text-xs text-suave">{p.observacao}</p>}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <span className={`text-xs ${p.situacao === "atrasado" ? "font-medium text-urgente" : "text-suave"}`}>
          {aberta ? rotuloVencimento(p.vencimento, hoje) : `Pago em ${p.pago_em?.split("-").reverse().join("/")}`}
        </span>
        <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${st.classe}`}>{st.rotulo}</span>
        {aberta && (
          <>
            <button
              type="button"
              onClick={() => setJanela("pago")}
              className="inline-flex items-center gap-1.5 rounded-lg bg-grafite px-3 py-1.5 text-sm font-medium text-white hover:bg-black"
            >
              <HandCoins className="size-4" /> Marcar como pago
            </button>
            <button type="button" onClick={() => setJanela("data")} className={BOTAO}>
              <CalendarClock className="size-4" /> Mudar data
            </button>
          </>
        )}
      </div>
      {aberta && (
        <>
          <JanelaPagamento
            parcelaId={p.id}
            saldoCentavos={p.saldo_centavos}
            subtitulo={titulo}
            aberto={janela === "pago"}
            aoFechar={() => setJanela(null)}
          />
          <JanelaNovaData parcelaId={p.id} subtitulo={titulo} aberto={janela === "data"} aoFechar={() => setJanela(null)} />
        </>
      )}
    </li>
  );
}

// ─── Registrar negociação ────────────────────────────────────────────────────

export function RegistrarNegociacao({
  procedimentos,
  formas,
  hoje,
  pacienteInicial,
}: {
  procedimentos: { id: string; nome: string }[];
  formas: FormaPagamento[];
  hoje: string;
  pacienteInicial: PacienteEncontrado | null;
}) {
  const [aberto, setAberto] = useState(Boolean(pacienteInicial));
  return (
    <>
      <button
        type="button"
        onClick={() => setAberto(true)}
        className="inline-flex items-center gap-1.5 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase shadow-sm hover:bg-dourado-escuro"
      >
        <Plus className="size-4" /> Registrar negociação
      </button>
      {aberto && (
        <JanelaNegociacao
          procedimentos={procedimentos}
          formas={formas}
          hoje={hoje}
          pacienteInicial={pacienteInicial}
          aoFechar={() => setAberto(false)}
        />
      )}
    </>
  );
}

function JanelaNegociacao({
  procedimentos,
  formas,
  hoje,
  pacienteInicial,
  aoFechar,
}: {
  procedimentos: { id: string; nome: string }[];
  formas: FormaPagamento[];
  hoje: string;
  pacienteInicial: PacienteEncontrado | null;
  aoFechar: () => void;
}) {
  const [paciente, setPaciente] = useState<PacienteEncontrado | null>(pacienteInicial);
  const [busca, setBusca] = useState("");
  const [achados, setAchados] = useState<PacienteEncontrado[]>([]);
  const [procedimentoId, setProcedimentoId] = useState(pacienteInicial?.procedimento_id ?? "");
  const [valor, setValor] = useState("");
  const [desconto, setDesconto] = useState("");
  const [entrada, setEntrada] = useState("");
  const [entradaEm, setEntradaEm] = useState(hoje);
  const [entradaFormaId, setEntradaFormaId] = useState("");
  const [formaId, setFormaId] = useState(formas[0]?.id ?? "");
  const [parcelas, setParcelas] = useState("1");
  const [primeiro, setPrimeiro] = useState("");
  const [observacao, setObservacao] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const [, buscar] = useTransition();

  useEffect(() => {
    if (paciente || busca.trim().length < 2) return;
    const t = setTimeout(() => buscar(async () => setAchados(await buscarPacientes(busca))), 250);
    return () => clearTimeout(t);
  }, [busca, paciente]);

  const forma = formas.find((f) => f.id === formaId);
  const total = paraCentavos(valor) ?? 0;
  const desc = paraCentavos(desconto) ?? 0;
  const entr = paraCentavos(entrada) ?? 0;
  const n = Math.max(Number(parcelas) || 1, 1);
  const sim = simularParcelas(total - desc, entr, n);

  function salvar() {
    setErro(null);
    if (!paciente) return setErro("Selecione o paciente.");
    if (total <= 0) return setErro("Informe o valor.");
    iniciar(async () => {
      const r = await registrarNegociacao({
        pessoaId: paciente.id,
        procedimentoId,
        valorCentavos: total,
        descontoCentavos: desc,
        entradaCentavos: entr,
        entradaEm: entr > 0 ? entradaEm : "",
        entradaFormaId: entr > 0 ? entradaFormaId : "",
        parcelas: n,
        primeiroVencimento: primeiro,
        formaId,
        observacao,
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo="Registrar negociação" subtitulo="Valores, forma e datas. Pagamentos futuros viram lembretes no painel.">
      {paciente ? (
        <div className="flex items-start justify-between gap-3 rounded-lg bg-dourado-claro px-3.5 py-2.5">
          <div>
            <p className="text-xs text-dourado-escuro">Paciente</p>
            <p className="font-medium">{paciente.nome}</p>
          </div>
          <button type="button" onClick={() => setPaciente(null)} aria-label="Trocar paciente" className="p-1 text-sutil hover:text-grafite">
            <X className="size-4" />
          </button>
        </div>
      ) : (
        <div>
          <Campo rotulo="Paciente">
            <input value={busca} onChange={(e) => setBusca(e.target.value)} placeholder="Nome ou telefone" className={CAMPO} />
          </Campo>
          {busca.trim().length >= 2 && (
            <ul aria-label="Pacientes encontrados" className="mt-2 divide-y divide-borda rounded-lg border border-borda">
              {achados.map((p) => (
                <li key={p.id}>
                  <button
                    type="button"
                    onClick={() => {
                      setPaciente(p);
                      if (p.procedimento_id) setProcedimentoId(p.procedimento_id);
                    }}
                    className="w-full px-3.5 py-2 text-left text-sm hover:bg-fundo"
                  >
                    {p.nome}
                    <span className="block text-xs text-sutil">{[p.procedimento, p.etapa].filter(Boolean).join(" · ")}</span>
                  </button>
                </li>
              ))}
              {achados.length === 0 && (
                <li className="flex items-center gap-1.5 px-3.5 py-2 text-sm text-sutil">
                  <Search className="size-4" /> Nenhum paciente encontrado.
                </li>
              )}
            </ul>
          )}
        </div>
      )}

      <Campo rotulo="Procedimento">
        <select value={procedimentoId} onChange={(e) => setProcedimentoId(e.target.value)} className={CAMPO}>
          <option value="">Não informado</option>
          {procedimentos.map((p) => (
            <option key={p.id} value={p.id}>
              {p.nome}
            </option>
          ))}
        </select>
      </Campo>
      <div className="grid gap-x-3 sm:grid-cols-2">
        <Campo rotulo="Valor">
          <input inputMode="decimal" placeholder="Ex.: 5.000" value={valor} onChange={(e) => setValor(e.target.value)} className={CAMPO} />
        </Campo>
        <Campo rotulo="Desconto (opcional)">
          <input inputMode="decimal" placeholder="0" value={desconto} onChange={(e) => setDesconto(e.target.value)} className={CAMPO} />
        </Campo>
      </div>

      <fieldset className="mt-4 rounded-lg border border-borda p-3.5">
        <legend className="px-1 text-sm font-medium">Entrada (opcional)</legend>
        <div className="grid gap-x-3 sm:grid-cols-3">
          <Campo rotulo="Valor da entrada">
            <input inputMode="decimal" placeholder="0" value={entrada} onChange={(e) => setEntrada(e.target.value)} className={CAMPO} />
          </Campo>
          <Campo rotulo="Data da entrada">
            <input type="date" min={hoje} value={entradaEm} onChange={(e) => setEntradaEm(e.target.value)} className={CAMPO} />
          </Campo>
          <Campo rotulo="Forma da entrada">
            <select value={entradaFormaId} onChange={(e) => setEntradaFormaId(e.target.value)} className={CAMPO}>
              <option value="">Mesma forma</option>
              {formas.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.nome}
                </option>
              ))}
            </select>
          </Campo>
        </div>
      </fieldset>

      <div className="grid gap-x-3 sm:grid-cols-3">
        <Campo rotulo="Forma de pagamento">
          <select
            value={formaId}
            onChange={(e) => {
              setFormaId(e.target.value);
              const f = formas.find((x) => x.id === e.target.value);
              if (f && n > f.max_parcelas) setParcelas(String(f.max_parcelas));
            }}
            className={CAMPO}
          >
            {formas.map((f) => (
              <option key={f.id} value={f.id}>
                {f.nome}
              </option>
            ))}
          </select>
        </Campo>
        <Campo rotulo="Parcelas">
          <input
            type="number"
            min={1}
            max={forma?.max_parcelas ?? 24}
            value={parcelas}
            onChange={(e) => setParcelas(e.target.value)}
            className={CAMPO}
          />
        </Campo>
        <Campo rotulo="1º vencimento" ajuda="Se vazio: hoje (ou 30 dias após, com entrada).">
          <input type="date" min={hoje} value={primeiro} onChange={(e) => setPrimeiro(e.target.value)} className={CAMPO} />
        </Campo>
      </div>
      {forma?.recebe_na_hora && (
        <p className="mt-2 text-xs text-rotina">Cartão é recebido na hora: entra como pago, sem lembretes de cobrança.</p>
      )}
      <Campo rotulo="Observações (opcional)">
        <input value={observacao} onChange={(e) => setObservacao(e.target.value)} maxLength={1000} className={CAMPO} />
      </Campo>

      {total > 0 && (
        <p className="mt-4 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave" aria-live="polite">
          Valor final {formatarMoeda(total - desc)}
          {entr > 0 ? ` · entrada ${formatarMoeda(entr)}` : ""}
          {sim.restante > 0 ? ` · ${n}x de ${formatarMoeda(sim.valor)}${sim.ultima !== sim.valor ? ` (última ${formatarMoeda(sim.ultima)})` : ""}` : ""}
        </p>
      )}
      {erro && (
        <p role="alert" className="mt-3 text-sm text-urgente">
          {erro}
        </p>
      )}
      <div className="mt-6 flex justify-end gap-2">
        <button type="button" onClick={aoFechar} className="rounded-lg border border-borda-forte px-3.5 py-2 text-sm hover:border-dourado">
          Cancelar
        </button>
        <button
          type="button"
          disabled={pendente}
          onClick={salvar}
          className="rounded-lg bg-dourado px-3.5 py-2 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Registrar"}
        </button>
      </div>
    </Dialogo>
  );
}

export function VerPaciente({ pessoaId }: { pessoaId: string }) {
  return (
    <Link href={`/contatos/${pessoaId}#financeiro`} className={BOTAO}>
      <UserRound className="size-4" /> Ver paciente
    </Link>
  );
}

/** Filtra toda a visão financeira por procedimento (mantém mês, status e busca). */
export function FiltroProcedimento({ procedimentos, atual }: { procedimentos: { id: string; nome: string }[]; atual: string }) {
  const router = useRouter();
  const params = useSearchParams();
  const id = useId();
  return (
    <div className="flex items-center gap-2">
      <label htmlFor={id} className="text-sm text-suave">
        Procedimento
      </label>
      <select
        id={id}
        value={atual}
        onChange={(e) => {
          const q = new URLSearchParams(params.toString());
          if (e.target.value) q.set("procedimento", e.target.value);
          else q.delete("procedimento");
          router.push(`/financeiro?${q}`);
        }}
        className="rounded-lg border border-borda-forte bg-superficie px-3 py-1.5 text-sm outline-none focus:border-dourado"
      >
        <option value="">Todos os procedimentos</option>
        {procedimentos.map((p) => (
          <option key={p.id} value={p.id}>
            {p.nome}
          </option>
        ))}
      </select>
    </div>
  );
}
