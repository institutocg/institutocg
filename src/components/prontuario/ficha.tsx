"use client";

import { Lock } from "lucide-react";
import { useRouter } from "next/navigation";
import { useId, useState, useTransition, type ReactNode } from "react";
import { salvarConsulta } from "@/app/(app)/prontuario/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import type { Ficha, Odontograma as Mapa } from "@/modules/prontuario/prontuario";
import { Odontograma } from "./odontograma";

const CAMPO = "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado disabled:bg-fundo";

export function Bloco({ titulo, id, children, acao }: { titulo: string; id: string; children: ReactNode; acao?: ReactNode }) {
  return (
    <section aria-labelledby={id} className="min-w-0 rounded-2xl border border-borda bg-superficie p-4 sm:p-5">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 id={id} className="font-titulo text-xl">
          {titulo}
        </h2>
        {acao}
      </div>
      <div className="mt-3">{children}</div>
    </section>
  );
}

/** Campo de texto livre com rótulo ligado (o rótulo é o título do bloco). */
function Texto({ rotulo, valor, onChange, travado, linhas, max, dica }: { rotulo: string; valor: string; onChange: (v: string) => void; travado: boolean; linhas: number; max: number; dica?: string }) {
  const id = useId();
  return (
    <div>
      <label htmlFor={id} className="sr-only">
        {rotulo}
      </label>
      <textarea id={id} rows={linhas} maxLength={max} value={valor} disabled={travado} placeholder={dica} onChange={(e) => onChange(e.target.value)} className={`${CAMPO} mt-0`} />
    </div>
  );
}

export type FichaInicial = Required<Omit<Ficha, "odontograma">> & { odontograma: Mapa };

/**
 * Consulta simples: motivo, queixa principal e anamnese em texto livre, odontograma
 * e (no meio) os procedimentos do plano.
 */
export function FichaConsulta({
  atendimentoId,
  inicial,
  finalizada,
  profissionais,
  odontogramaAnterior,
  plano,
}: {
  atendimentoId: string;
  inicial: FichaInicial;
  finalizada: boolean;
  profissionais: { id: string; nome: string }[];
  odontogramaAnterior: string | null;
  plano: ReactNode;
}) {
  const router = useRouter();
  const [f, setF] = useState<FichaInicial>(inicial);
  const [alterada, setAlterada] = useState(false);
  const [confirmar, setConfirmar] = useState(false);
  const [pendente, iniciar] = useTransition();
  const idProf = useId();
  const travado = finalizada;

  function mudar<K extends keyof FichaInicial>(campo: K, valor: FichaInicial[K]) {
    setF((x) => ({ ...x, [campo]: valor }));
    setAlterada(true);
  }

  function salvar(finalizar: boolean) {
    iniciar(async () => {
      const r = await salvarConsulta(atendimentoId, f, finalizar);
      if (r.ok) {
        avisar(r.mensagem);
        setAlterada(false);
        setConfirmar(false);
        router.refresh();
      } else avisar(r.erro, "erro");
    });
  }

  return (
    <div className="space-y-5">
      {finalizada && (
        <p className="flex items-center gap-2 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave ring-1 ring-borda">
          <Lock className="size-4" /> Consulta finalizada: o registro fica guardado como foi feito. Para continuar o tratamento, abra uma nova consulta.
        </p>
      )}

      <Bloco titulo="Motivo da consulta" id="motivo">
        <Texto rotulo="Motivo da consulta" valor={f.motivo_obs} onChange={(v) => mudar("motivo_obs", v)} travado={travado} linhas={2} max={500} />
        <div className="mt-3 max-w-xs">
          <label htmlFor={idProf} className="text-xs text-sutil">
            Dentista
          </label>
          <select id={idProf} value={f.profissional_id} disabled={travado} onChange={(e) => mudar("profissional_id", e.target.value)} className={CAMPO}>
            <option value="">—</option>
            {profissionais.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </div>
      </Bloco>

      <Bloco titulo="O que mais incomoda / queixa principal" id="queixa">
        <Texto rotulo="Queixa principal" valor={f.queixa} onChange={(v) => mudar("queixa", v)} travado={travado} linhas={2} max={1000} />
      </Bloco>

      <Bloco titulo="Anamnese / observações" id="anamnese">
        <Texto
          rotulo="Anamnese / observações"
          valor={f.anamnese_obs}
          onChange={(v) => mudar("anamnese_obs", v)}
          travado={travado}
          linhas={5}
          max={2000}
          dica="Saúde geral, medicamentos, alergias, o que for relevante…"
        />
      </Bloco>

      <Bloco titulo="Odontograma" id="odontograma" acao={!travado ? <span className="text-xs text-sutil">Toque num dente para registrar</span> : undefined}>
        {odontogramaAnterior && <p className="mb-2 text-xs text-sutil">{odontogramaAnterior}</p>}
        <Odontograma valor={f.odontograma} onChange={travado ? undefined : (v) => mudar("odontograma", v)} />
      </Bloco>

      {plano}

      {!travado && (
        <div className="sticky bottom-0 z-10 -mx-4 flex flex-wrap items-center justify-end gap-2 border-t border-borda bg-fundo/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-xl sm:border">
          {alterada && <span className="mr-auto text-xs text-importante">Alterações não salvas</span>}
          <button type="button" disabled={pendente} onClick={() => salvar(false)} className="rounded-lg bg-grafite px-4 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50">
            {pendente ? "Salvando…" : "Salvar ficha"}
          </button>
          <button type="button" disabled={pendente} onClick={() => setConfirmar(true)} className="rounded-lg border border-borda-forte px-4 py-2 text-sm font-medium hover:border-dourado">
            Finalizar consulta
          </button>
        </div>
      )}
      <Dialogo aberto={confirmar} aoFechar={() => setConfirmar(false)} titulo="Finalizar a consulta?">
        <p className="text-sm text-suave">
          A ficha e o odontograma desta consulta ficam guardados exatamente como estão. A próxima consulta começa a partir deste odontograma, e os
          procedimentos que não foram feitos continuam pendentes.
        </p>
        <div className="mt-6 flex justify-end gap-2">
          <button type="button" onClick={() => setConfirmar(false)} className="rounded-lg border border-borda-forte px-3.5 py-2 text-sm">
            Voltar
          </button>
          <button type="button" disabled={pendente} onClick={() => salvar(true)} className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white disabled:opacity-50">
            Salvar e finalizar
          </button>
        </div>
      </Dialogo>
    </div>
  );
}
