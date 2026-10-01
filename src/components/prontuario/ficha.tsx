"use client";

import { Lock } from "lucide-react";
import { useRouter } from "next/navigation";
import { useId, useState, useTransition, type ReactNode } from "react";
import { salvarConsulta } from "@/app/(app)/prontuario/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { somarDias } from "@/lib/datas";
import { ANAMNESE, DIAGNOSTICOS, MOTIVOS, ORIENTACOES, RETORNOS, type Ficha, type Odontograma as Mapa } from "@/modules/prontuario/prontuario";
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

/** Seleção múltipla em "pílulas" (preenchimento rápido, sem digitar). */
function Pilulas({ rotulo, opcoes, valor, onChange, travado }: { rotulo: string; opcoes: readonly string[]; valor: string[]; onChange: (v: string[]) => void; travado: boolean }) {
  const extras = valor.filter((v) => !opcoes.includes(v));
  return (
    <div role="group" aria-label={rotulo} className="flex flex-wrap gap-1.5">
      {[...opcoes, ...extras].map((o) => {
        const marcada = valor.includes(o);
        return (
          <button
            key={o}
            type="button"
            disabled={travado}
            aria-pressed={marcada}
            onClick={() => onChange(marcada ? valor.filter((x) => x !== o) : [...valor, o])}
            className={`rounded-full border px-3 py-1 text-sm transition disabled:cursor-default ${
              marcada ? "border-dourado bg-dourado-claro font-medium text-dourado-escuro" : "border-borda-forte bg-superficie text-suave hover:border-dourado"
            } ${travado && !marcada ? "opacity-50" : ""}`}
          >
            {marcada ? "✓ " : ""}
            {o}
          </button>
        );
      })}
    </div>
  );
}

function Texto({ rotulo, valor, onChange, travado, linhas = 2, max }: { rotulo: string; valor: string; onChange: (v: string) => void; travado: boolean; linhas?: number; max: number }) {
  const id = useId();
  return (
    <div className="mt-3">
      <label htmlFor={id} className="text-xs text-sutil">
        {rotulo}
      </label>
      <textarea id={id} rows={linhas} maxLength={max} value={valor} disabled={travado} onChange={(e) => onChange(e.target.value)} className={CAMPO} />
    </div>
  );
}

export type FichaInicial = Required<Omit<Ficha, "odontograma">> & { odontograma: Mapa };

export function FichaConsulta({
  atendimentoId,
  inicial,
  finalizada,
  hoje,
  profissionais,
  odontogramaAnterior,
  plano,
}: {
  atendimentoId: string;
  inicial: FichaInicial;
  finalizada: boolean;
  hoje: string;
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
  const idRetorno = useId();
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
        <Pilulas rotulo="Motivo" opcoes={MOTIVOS} valor={f.motivo} onChange={(v) => mudar("motivo", v)} travado={travado} />
        <Texto rotulo="Detalhes do motivo (opcional)" valor={f.motivo_obs} onChange={(v) => mudar("motivo_obs", v)} travado={travado} linhas={1} max={500} />
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

      <Bloco titulo="Anamnese" id="anamnese">
        <Pilulas rotulo="Anamnese" opcoes={ANAMNESE} valor={f.anamnese} onChange={(v) => mudar("anamnese", v)} travado={travado} />
        <Texto rotulo="Observações (medicamentos em uso, alergias específicas…)" valor={f.anamnese_obs} onChange={(v) => mudar("anamnese_obs", v)} travado={travado} max={2000} />
      </Bloco>

      <Bloco titulo="Odontograma" id="odontograma" acao={!travado ? <span className="text-xs text-sutil">Toque num dente para registrar</span> : undefined}>
        {odontogramaAnterior && <p className="mb-2 text-xs text-sutil">{odontogramaAnterior}</p>}
        <Odontograma valor={f.odontograma} onChange={travado ? undefined : (v) => mudar("odontograma", v)} />
      </Bloco>

      <Bloco titulo="Diagnóstico / avaliação" id="diagnostico">
        <Pilulas rotulo="Diagnóstico" opcoes={DIAGNOSTICOS} valor={f.diagnostico} onChange={(v) => mudar("diagnostico", v)} travado={travado} />
        <Texto rotulo="Observações do diagnóstico" valor={f.diagnostico_obs} onChange={(v) => mudar("diagnostico_obs", v)} travado={travado} max={2000} />
      </Bloco>

      {plano}

      <Bloco titulo="Evolução / conduta" id="evolucao">
        <Texto rotulo="O que foi feito e a conduta" valor={f.evolucao} onChange={(v) => mudar("evolucao", v)} travado={travado} linhas={4} max={4000} />
      </Bloco>

      <Bloco titulo="Orientações" id="orientacoes">
        <Pilulas rotulo="Orientações" opcoes={ORIENTACOES} valor={f.orientacoes} onChange={(v) => mudar("orientacoes", v)} travado={travado} />
        <Texto rotulo="Outras orientações" valor={f.orientacoes_obs} onChange={(v) => mudar("orientacoes_obs", v)} travado={travado} linhas={1} max={1000} />
      </Bloco>

      <Bloco titulo="Retorno / próxima consulta" id="retorno">
        {!travado && (
          <div role="group" aria-label="Retorno em" className="flex flex-wrap gap-1.5">
            {RETORNOS.map((r) => {
              const data = somarDias(hoje, r.dias);
              return (
                <button
                  key={r.rotulo}
                  type="button"
                  aria-pressed={f.retorno_em === data}
                  onClick={() => mudar("retorno_em", data)}
                  className={`rounded-full border px-3 py-1 text-sm ${f.retorno_em === data ? "border-dourado bg-dourado-claro font-medium text-dourado-escuro" : "border-borda-forte text-suave hover:border-dourado"}`}
                >
                  {r.rotulo}
                </button>
              );
            })}
          </div>
        )}
        <div className="mt-3 grid gap-x-3 sm:grid-cols-2">
          <div>
            <label htmlFor={idRetorno} className="text-xs text-sutil">
              Data do retorno
            </label>
            <input id={idRetorno} type="date" value={f.retorno_em} disabled={travado} onChange={(e) => mudar("retorno_em", e.target.value)} className={CAMPO} />
          </div>
          <Texto rotulo="Para quê (opcional)" valor={f.retorno_obs} onChange={(v) => mudar("retorno_obs", v)} travado={travado} linhas={1} max={300} />
        </div>
      </Bloco>

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
          A ficha e o odontograma desta consulta ficam guardados exatamente como estão e não podem mais ser alterados. A próxima consulta começa a partir
          deste odontograma.
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
