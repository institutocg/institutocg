"use client";

import { Megaphone, Search } from "lucide-react";
import { useState, useTransition, type ReactNode } from "react";
import { criarCampanha, encerrarCampanha, preverCampanha } from "@/app/(app)/campanhas/acoes";
import { avisar } from "@/components/avisos";
import { SEGMENTOS, terminoPrevisto, type Destinatario, type Segmento } from "@/modules/campanhas/campanhas";
import { exemplo } from "@/modules/regras/regras";

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";

function Campo({ rotulo, ajuda, children }: { rotulo: string; ajuda?: string; children: ReactNode }) {
  return (
    <label className="mt-4 block">
      <span className="text-sm text-suave">{rotulo}</span>
      {children}
      {ajuda && <span className="mt-1 block text-xs text-sutil">{ajuda}</span>}
    </label>
  );
}

const br = (d: string) => d.split("-").reverse().join("/");

export function NovaCampanha({
  procedimentos,
  hoje,
  limitePadrao,
}: {
  procedimentos: { id: string; nome: string }[];
  hoje: string;
  limitePadrao: number;
}) {
  const [segmento, setSegmento] = useState<Segmento>("inativos");
  const [meses, setMeses] = useState(String(SEGMENTOS.inativos.mesesPadrao));
  const [procedimentoId, setProcedimentoId] = useState("");
  const [somenteMarketing, setSomenteMarketing] = useState(false);
  const [nome, setNome] = useState("");
  const [mensagem, setMensagem] = useState(SEGMENTOS.inativos.mensagem);
  const [limiteDia, setLimiteDia] = useState(String(limitePadrao));
  const [iniciaEm, setIniciaEm] = useState(hoje);
  const [lista, setLista] = useState<Destinatario[] | null>(null);
  const [fora, setFora] = useState<Set<string>>(new Set());
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

  function trocarSegmento(s: Segmento) {
    setSegmento(s);
    setMeses(String(SEGMENTOS[s].mesesPadrao));
    setMensagem(SEGMENTOS[s].mensagem);
    setLista(null);
  }

  function ver() {
    setErro(null);
    iniciar(async () => {
      const r = await preverCampanha({ segmento, meses, procedimentoId, somenteMarketing });
      if (r.ok) {
        setLista(r.pessoas);
        setFora(new Set());
      } else setErro(r.erro);
    });
  }

  const selecionadas = (lista ?? []).filter((p) => !fora.has(p.pessoa_id));
  const fim = terminoPrevisto(iniciaEm, selecionadas.length, Number(limiteDia) || 1);
  const procNome = procedimentos.find((p) => p.id === procedimentoId)?.nome.toLowerCase();

  function criar() {
    setErro(null);
    iniciar(async () => {
      const r = await criarCampanha({
        segmento, meses, procedimentoId, somenteMarketing, nome, mensagem, limiteDia, iniciaEm,
        pessoas: selecionadas.map((p) => p.pessoa_id),
      });
      if (r.ok) {
        avisar(r.mensagem);
        setLista(null);
        setNome("");
      } else setErro(r.erro);
    });
  }

  return (
    <div className="rounded-xl border border-borda bg-superficie p-4 sm:p-6">
      <h2 className="flex items-center gap-2 font-titulo text-2xl">
        <Megaphone className="size-5 text-dourado" /> Nova campanha
      </h2>

      <fieldset className="mt-4">
        <legend className="text-sm text-suave">Para quem?</legend>
        <div role="radiogroup" className="mt-2 grid gap-2 sm:grid-cols-3">
          {(Object.keys(SEGMENTOS) as Segmento[]).map((s) => (
            <button
              key={s}
              type="button"
              role="radio"
              aria-checked={segmento === s}
              onClick={() => trocarSegmento(s)}
              className={`rounded-lg border px-3.5 py-2.5 text-left text-sm transition ${
                segmento === s ? "border-dourado bg-dourado-claro" : "border-borda-forte hover:border-dourado"
              }`}
            >
              <span className="block font-medium">{SEGMENTOS[s].rotulo}</span>
              <span className="block text-xs text-sutil">{SEGMENTOS[s].ajuda}</span>
            </button>
          ))}
        </div>
      </fieldset>

      <div className="grid gap-x-3 sm:grid-cols-3">
        <Campo rotulo={segmento === "nao_fecharam" ? "Encerradas há mais de (meses)" : segmento === "procedimento" ? "Feito há mais de (meses)" : "Sem atendimento há mais de (meses)"}>
          <input type="number" min={1} max={120} value={meses} onChange={(e) => { setMeses(e.target.value); setLista(null); }} className={CAMPO} />
        </Campo>
        <Campo rotulo={segmento === "procedimento" ? "Procedimento" : "Procedimento (opcional)"}>
          <select
            value={procedimentoId}
            onChange={(e) => { setProcedimentoId(e.target.value); setLista(null); }}
            disabled={segmento === "inativos"}
            className={CAMPO}
          >
            <option value="">{segmento === "inativos" ? "Todos" : "Escolha…"}</option>
            {procedimentos.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
        <label className="mt-4 flex items-center gap-2 self-end pb-2 text-sm">
          <input
            type="checkbox"
            checked={somenteMarketing}
            onChange={(e) => { setSomenteMarketing(e.target.checked); setLista(null); }}
            className="size-4 accent-dourado"
          />
          Só quem aceitou comunicações
        </label>
      </div>

      <button
        type="button"
        onClick={ver}
        disabled={pendente}
        className="mt-4 inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3.5 py-2 text-sm font-medium hover:border-dourado disabled:opacity-50"
      >
        <Search className="size-4" /> {pendente && !lista ? "Buscando…" : "Ver quem entra"}
      </button>

      {lista && (
        <div className="mt-5">
          <p className="text-sm font-medium" aria-live="polite">
            {lista.length === 0
              ? "Ninguém se encaixa agora (quem não aceita contato, já está negociando ou participou de campanha nos últimos 30 dias fica de fora)."
              : `${selecionadas.length} de ${lista.length} ${lista.length === 1 ? "pessoa selecionada" : "pessoas selecionadas"}`}
          </p>
          {lista.length > 0 && (
            <ul aria-label="Pessoas da campanha" className="mt-2 max-h-64 divide-y divide-borda overflow-y-auto rounded-lg border border-borda">
              {lista.map((p) => (
                <li key={p.pessoa_id}>
                  <label className="flex items-start gap-2.5 px-3.5 py-2 text-sm">
                    <input
                      type="checkbox"
                      className="mt-0.5 size-4 accent-dourado"
                      checked={!fora.has(p.pessoa_id)}
                      onChange={(e) => {
                        const n = new Set(fora);
                        if (e.target.checked) n.delete(p.pessoa_id);
                        else n.add(p.pessoa_id);
                        setFora(n);
                      }}
                    />
                    <span>
                      <span className="font-medium">{p.nome}</span>
                      <span className="block text-xs text-sutil">{p.detalhe}</span>
                    </span>
                  </label>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {lista && lista.length > 0 && (
        <>
          <Campo rotulo="Nome da campanha">
            <input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={80} placeholder="Ex.: Revisão de fim de ano" className={CAMPO} />
          </Campo>
          <Campo rotulo="Mensagem sugerida" ajuda="Use {{nome}} e {{procedimento}}. Cada mensagem é revisada e enviada por você.">
            <textarea value={mensagem} onChange={(e) => setMensagem(e.target.value)} rows={4} maxLength={2000} className={CAMPO} />
          </Campo>
          <p className="mt-2 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
            <span className="text-xs tracking-wide text-sutil uppercase">Prévia · </span>
            {exemplo(mensagem, procNome)}
          </p>
          <div className="grid gap-x-3 sm:grid-cols-2">
            <Campo rotulo="Contatos por dia (no máximo)" ajuda="Um ritmo tranquilo permite conversas de verdade.">
              <input type="number" min={1} max={50} value={limiteDia} onChange={(e) => setLimiteDia(e.target.value)} className={CAMPO} />
            </Campo>
            <Campo rotulo="Começar em">
              <input type="date" min={hoje} value={iniciaEm} onChange={(e) => setIniciaEm(e.target.value)} className={CAMPO} />
            </Campo>
          </div>
          {fim && selecionadas.length > 0 && (
            <p className="mt-3 text-sm text-suave">
              {selecionadas.length} {selecionadas.length === 1 ? "contato" : "contatos"} de {br(iniciaEm)} até cerca de {br(fim)} (só dias úteis).
            </p>
          )}
          <button
            type="button"
            onClick={criar}
            disabled={pendente || selecionadas.length === 0}
            className="mt-4 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase hover:bg-dourado-escuro disabled:opacity-50"
          >
            {pendente ? "Criando…" : "Criar campanha"}
          </button>
        </>
      )}

      {erro && (
        <p role="alert" className="mt-3 text-sm text-urgente">
          {erro}
        </p>
      )}
    </div>
  );
}

export function BotaoEncerrar({ id, nome }: { id: string; nome: string }) {
  const [pendente, iniciar] = useTransition();
  return (
    <button
      type="button"
      disabled={pendente}
      onClick={() => {
        if (!confirm(`Encerrar a campanha “${nome}”? Contatos ainda não feitos serão cancelados.`)) return;
        iniciar(async () => {
          const r = await encerrarCampanha(id);
          if (r.ok) avisar(r.mensagem);
          else avisar(r.erro, "erro");
        });
      }}
      className="rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-urgente hover:text-urgente disabled:opacity-50"
    >
      {pendente ? "Encerrando…" : "Encerrar"}
    </button>
  );
}
