"use client";

import { X } from "lucide-react";
import { useEffect, useId, useRef, type ReactNode } from "react";

/** Janela modal acessível (usa o <dialog> nativo do navegador). */
export function Dialogo({
  aberto,
  aoFechar,
  titulo,
  subtitulo,
  children,
}: {
  aberto: boolean;
  aoFechar: () => void;
  titulo: string;
  subtitulo?: string | null;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const idTitulo = useId();

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (aberto && !d.open) d.showModal();
    if (!aberto && d.open) d.close();
  }, [aberto]);

  return (
    <dialog
      ref={ref}
      aria-labelledby={idTitulo}
      onClose={aoFechar}
      onClick={(e) => e.target === ref.current && aoFechar()}
      className="m-auto w-[calc(100%-2rem)] max-w-lg rounded-2xl border border-borda bg-superficie p-0 text-grafite shadow-2xl"
    >
      {aberto && (
        <div className="p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 id={idTitulo} className="font-titulo text-2xl leading-tight">
                {titulo}
              </h2>
              {subtitulo && <p className="mt-1 text-sm text-suave">{subtitulo}</p>}
            </div>
            <button aria-label="Fechar" onClick={aoFechar} className="rounded-md p-1 text-sutil hover:text-grafite">
              <X className="size-5" />
            </button>
          </div>
          <div className="mt-5">{children}</div>
        </div>
      )}
    </dialog>
  );
}
