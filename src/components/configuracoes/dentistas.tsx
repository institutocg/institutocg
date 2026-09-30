"use client";

import { Plus } from "lucide-react";
import { useState, useTransition } from "react";
import { salvarDentista } from "@/app/(app)/configuracoes/acoes";
import { avisar } from "@/components/avisos";

export interface Dentista {
  id: string;
  nome: string;
  cor: string;
  ativo: boolean;
  consultas_futuras: number;
}

/** Cores da agenda (tons da marca), uma por dentista. */
export const CORES = ["#B08D57", "#5F8A6A", "#7A6FA8", "#4F7FA3", "#B4533A", "#8A6A3A"];

const CAMPO =
  "w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado disabled:bg-fundo";

function Linha({ d, podeEditar, novo, aoConcluir }: { d: Dentista; podeEditar: boolean; novo?: boolean; aoConcluir?: () => void }) {
  const [nome, setNome] = useState(d.nome);
  const [cor, setCor] = useState(d.cor);
  const [ativo, setAtivo] = useState(d.ativo);
  const [pendente, iniciar] = useTransition();
  const mudou = novo || nome !== d.nome || cor !== d.cor || ativo !== d.ativo;
  return (
    <li aria-label={novo ? "Nova dentista" : d.nome} className="flex flex-wrap items-center gap-3 border-b border-borda py-3 last:border-0">
      <span className="size-4 shrink-0 rounded-full" style={{ backgroundColor: cor }} aria-hidden />
      <label className="min-w-48 flex-1">
        <span className="sr-only">Nome</span>
        <input value={nome} disabled={!podeEditar} onChange={(e) => setNome(e.target.value)} placeholder="Nome da dentista" className={CAMPO} />
      </label>
      {podeEditar && (
        <div role="radiogroup" aria-label="Cor na agenda" className="flex gap-1.5">
          {CORES.map((c) => (
            <button
              key={c}
              type="button"
              role="radio"
              aria-checked={cor === c}
              aria-label={`Cor ${c}`}
              onClick={() => setCor(c)}
              className={`size-6 rounded-full ring-offset-2 ${cor === c ? "ring-2 ring-grafite" : ""}`}
              style={{ backgroundColor: c }}
            />
          ))}
        </div>
      )}
      {!novo && (
        <label className="flex items-center gap-1.5 text-sm">
          <input type="checkbox" checked={ativo} disabled={!podeEditar} onChange={(e) => setAtivo(e.target.checked)} className="size-4 accent-dourado" />
          Atende
        </label>
      )}
      {!novo && <span className="text-xs text-sutil">{d.consultas_futuras} {d.consultas_futuras === 1 ? "consulta futura" : "consultas futuras"}</span>}
      {podeEditar && mudou && (
        <button
          type="button"
          disabled={pendente}
          onClick={() =>
            iniciar(async () => {
              const r = await salvarDentista({ id: novo ? "" : d.id, nome, cor, ativo });
              if (r.ok) {
                avisar(r.mensagem);
                aoConcluir?.();
              } else avisar(r.erro, "erro");
            })
          }
          className="rounded-lg bg-dourado px-3 py-1.5 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
        >
          {pendente ? "Salvando…" : novo ? "Incluir" : "Salvar"}
        </button>
      )}
    </li>
  );
}

export function Dentistas({ dentistas, podeEditar }: { dentistas: Dentista[]; podeEditar: boolean }) {
  const [incluindo, setIncluindo] = useState(false);
  const livre = CORES.find((c) => !dentistas.some((d) => d.cor === c)) ?? CORES[0];
  return (
    <div>
      <ul aria-label="Dentistas">
        {dentistas.map((d) => (
          <Linha key={`${d.id}-${d.nome}-${d.cor}-${d.ativo}`} d={d} podeEditar={podeEditar} />
        ))}
        {incluindo && (
          <Linha
            d={{ id: "", nome: "", cor: livre, ativo: true, consultas_futuras: 0 }}
            podeEditar
            novo
            aoConcluir={() => setIncluindo(false)}
          />
        )}
      </ul>
      {podeEditar && !incluindo && (
        <button
          type="button"
          onClick={() => setIncluindo(true)}
          className="mt-3 inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
        >
          <Plus className="size-4" /> Incluir dentista
        </button>
      )}
    </div>
  );
}
