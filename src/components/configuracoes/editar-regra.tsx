"use client";

import { Pencil } from "lucide-react";
import { useState, useTransition, type ReactNode } from "react";
import { salvarLimites, salvarRegra } from "@/app/(app)/configuracoes/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import {
  campos,
  descreverRegra,
  exemplo,
  lerIntervalos,
  ROTULO_AO_ESGOTAR,
  ROTULO_PRIORIDADE,
  type AoEsgotar,
  type Prioridade,
  type Regra,
} from "@/modules/regras/regras";

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado disabled:bg-fundo";

function Campo({ rotulo, ajuda, children }: { rotulo: string; ajuda?: string; children: ReactNode }) {
  return (
    <label className="mt-4 block">
      <span className="text-sm text-suave">{rotulo}</span>
      {children}
      {ajuda && <span className="mt-1 block text-xs text-sutil">{ajuda}</span>}
    </label>
  );
}

export function EditarRegra({ regra }: { regra: Regra }) {
  const [aberto, setAberto] = useState(false);
  return (
    <>
      <button
        type="button"
        onClick={() => setAberto(true)}
        aria-label={`Editar regra ${regra.nome}`}
        className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
      >
        <Pencil className="size-3.5" /> Editar
      </button>
      {aberto && <JanelaRegra regra={regra} aoFechar={() => setAberto(false)} />}
    </>
  );
}

function JanelaRegra({ regra, aoFechar }: { regra: Regra; aoFechar: () => void }) {
  const c = campos(regra.situacao);
  const [ativa, setAtiva] = useState(regra.ativa);
  const [titulo, setTitulo] = useState(regra.titulo_modelo);
  const [prazo, setPrazo] = useState(regra.prazo_dias === null ? "" : String(regra.prazo_dias));
  const [intervalos, setIntervalos] = useState(regra.intervalos.join(", "));
  const [prioridade, setPrioridade] = useState<Prioridade>(regra.prioridade);
  const [aoEsgotar, setAoEsgotar] = useState<AoEsgotar>(regra.ao_esgotar);
  const [espera, setEspera] = useState(regra.espera_reativacao_dias === null ? "" : String(regra.espera_reativacao_dias));
  const [periodo, setPeriodo] = useState(regra.periodo_meses === null ? "" : String(regra.periodo_meses));
  const [mensagem, setMensagem] = useState(regra.mensagem ?? "");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

  const previa = descreverRegra({
    situacao: regra.situacao,
    ativa,
    prazo_dias: prazo === "" ? null : Number(prazo),
    intervalos: lerIntervalos(intervalos) ?? [],
    ao_esgotar: aoEsgotar,
    espera_reativacao_dias: espera === "" ? null : Number(espera),
    periodo_meses: periodo === "" ? null : Number(periodo),
  });

  function salvar() {
    setErro(null);
    iniciar(async () => {
      const r = await salvarRegra({
        id: regra.id,
        situacao: regra.situacao,
        ativa,
        titulo_modelo: titulo,
        prazo_dias: prazo,
        intervalos: c.tentativas ? intervalos : regra.intervalos.join(", "),
        prioridade,
        ao_esgotar: aoEsgotar,
        espera_reativacao_dias: espera,
        periodo_meses: periodo,
        mensagem,
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo={regra.nome} subtitulo={regra.quando}>
      <label className="flex items-center gap-2.5 rounded-lg bg-fundo px-3.5 py-2.5 text-sm">
        <input type="checkbox" checked={ativa} onChange={(e) => setAtiva(e.target.checked)} className="size-4 accent-dourado" />
        Regra ligada (criar a tarefa automaticamente)
      </label>

      <Campo rotulo="Tarefa criada" ajuda={`Ex.: “${exemplo(titulo)}”. Use {primeiro_nome} e {procedimento}.`}>
        <input value={titulo} onChange={(e) => setTitulo(e.target.value)} maxLength={200} className={CAMPO} />
      </Campo>

      <div className="grid gap-x-3 sm:grid-cols-2">
        {c.prazo && (
          <Campo
            rotulo={c.prazoEmDiasUteisAntes ? "Dias úteis antes da consulta" : c.prazoOpcional ? "Prazo padrão (dias)" : "Quando (dias depois)"}
            ajuda={c.prazoOpcional ? "Usado quando o motivo não tem prazo." : c.prazoEmDiasUteisAntes ? undefined : "0 = no mesmo dia"}
          >
            <input type="number" min={0} max={730} value={prazo} onChange={(e) => setPrazo(e.target.value)} className={CAMPO} />
          </Campo>
        )}
        {c.periodo && (
          <Campo rotulo={regra.situacao === "pos_tratamento" ? "Meses após o tratamento" : "Meses sem atendimento"}>
            <input type="number" min={1} max={60} value={periodo} onChange={(e) => setPeriodo(e.target.value)} className={CAMPO} />
          </Campo>
        )}
        <Campo rotulo="Prioridade">
          <select value={prioridade} onChange={(e) => setPrioridade(e.target.value as Prioridade)} className={CAMPO}>
            {(Object.keys(ROTULO_PRIORIDADE) as Prioridade[]).map((p) => (
              <option key={p} value={p}>
                {ROTULO_PRIORIDADE[p]}
              </option>
            ))}
          </select>
        </Campo>
      </div>

      {c.tentativas && (
        <>
          <Campo rotulo="Se não responder, tentar de novo após (dias)" ajuda="Ex.: 3, 7 = nova tentativa 3 dias depois e outra 7 dias depois. Deixe vazio para não repetir.">
            <input value={intervalos} onChange={(e) => setIntervalos(e.target.value)} inputMode="numeric" className={CAMPO} />
          </Campo>
          <Campo rotulo="Se continuar sem resposta">
            <select value={aoEsgotar} onChange={(e) => setAoEsgotar(e.target.value as AoEsgotar)} className={CAMPO}>
              {c.opcoesAoEsgotar.map((o) => (
                <option key={o} value={o}>
                  {ROTULO_AO_ESGOTAR[o]}
                </option>
              ))}
            </select>
          </Campo>
          {aoEsgotar === "reativacao" && (
            <Campo rotulo="Tentar de novo depois de (dias)">
              <input type="number" min={1} max={365} value={espera} onChange={(e) => setEspera(e.target.value)} className={CAMPO} />
            </Campo>
          )}
        </>
      )}

      {regra.mensagem_situacao && (
        <Campo rotulo="Mensagem sugerida (WhatsApp)" ajuda="O sistema só sugere: você revisa e decide quando enviar.">
          <textarea value={mensagem} onChange={(e) => setMensagem(e.target.value)} rows={4} maxLength={2000} className={CAMPO} />
        </Campo>
      )}

      <p className="mt-4 rounded-lg bg-dourado-claro px-3.5 py-2.5 text-sm text-dourado-escuro" aria-live="polite">
        {previa}
      </p>
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
          {pendente ? "Salvando…" : "Salvar regra"}
        </button>
      </div>
    </Dialogo>
  );
}

export function EditarLimites({ limite, intervalo, podeEditar }: { limite: number; intervalo: number; podeEditar: boolean }) {
  const [limiteDia, setLimiteDia] = useState(String(limite));
  const [intervaloDias, setIntervaloDias] = useState(String(intervalo));
  const [pendente, iniciar] = useTransition();
  return (
    <div>
      <div className="grid gap-x-3 sm:grid-cols-2">
        <Campo rotulo="Reativações por dia (no máximo)" ajuda="Evita uma avalanche de contatos de uma vez.">
          <input type="number" min={1} max={50} value={limiteDia} disabled={!podeEditar} onChange={(e) => setLimiteDia(e.target.value)} className={CAMPO} />
        </Campo>
        <Campo rotulo="Intervalo mínimo entre contatos (dias)" ajuda="Reativações nunca ficam coladas no último contato.">
          <input type="number" min={0} max={30} value={intervaloDias} disabled={!podeEditar} onChange={(e) => setIntervaloDias(e.target.value)} className={CAMPO} />
        </Campo>
      </div>
      {podeEditar && (
        <button
          type="button"
          disabled={pendente}
          onClick={() =>
            iniciar(async () => {
              const r = await salvarLimites({ limiteReativacaoDia: limiteDia, intervaloMinContatoDias: intervaloDias });
              if (r.ok) avisar(r.mensagem);
              else avisar(r.erro, "erro");
            })
          }
          className="mt-4 rounded-lg bg-dourado px-3.5 py-2 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Salvar limites"}
        </button>
      )}
    </div>
  );
}
