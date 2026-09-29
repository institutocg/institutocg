"use client";

import { CircleAlert, CircleCheck, X } from "lucide-react";
import { useEffect, useState } from "react";

type Aviso = { id: number; texto: string; tipo: "sucesso" | "erro" };

const EVENTO = "crm:aviso";
let contador = 0;

/** Mostra uma mensagem curta no canto da tela. */
export function avisar(texto: string, tipo: Aviso["tipo"] = "sucesso") {
  window.dispatchEvent(new CustomEvent<Aviso>(EVENTO, { detail: { id: ++contador, texto, tipo } }));
}

export function Avisos() {
  const [avisos, setAvisos] = useState<Aviso[]>([]);

  useEffect(() => {
    const ouvir = (e: Event) => {
      const aviso = (e as CustomEvent<Aviso>).detail;
      setAvisos((lista) => [...lista, aviso]);
      setTimeout(() => setAvisos((lista) => lista.filter((a) => a.id !== aviso.id)), 7000);
    };
    window.addEventListener(EVENTO, ouvir);
    return () => window.removeEventListener(EVENTO, ouvir);
  }, []);

  return (
    <div aria-live="polite" className="pointer-events-none fixed inset-x-0 bottom-4 z-50 flex flex-col items-center gap-2 px-4">
      {avisos.map((a) => (
        <div
          key={a.id}
          role={a.tipo === "erro" ? "alert" : "status"}
          className={`pointer-events-auto flex w-full max-w-lg items-start gap-3 rounded-xl border px-4 py-3 text-sm shadow-lg ${
            a.tipo === "erro"
              ? "border-urgente/30 bg-urgente-claro text-urgente"
              : "border-rotina/30 bg-superficie text-grafite"
          }`}
        >
          {a.tipo === "erro" ? (
            <CircleAlert className="mt-0.5 size-4 shrink-0" />
          ) : (
            <CircleCheck className="mt-0.5 size-4 shrink-0 text-rotina" />
          )}
          <p className="flex-1">{a.texto}</p>
          <button
            aria-label="Fechar aviso"
            onClick={() => setAvisos((lista) => lista.filter((x) => x.id !== a.id))}
            className="text-sutil hover:text-grafite"
          >
            <X className="size-4" />
          </button>
        </div>
      ))}
    </div>
  );
}
