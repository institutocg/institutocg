"use client";

import { cloneElement, useEffect, useId, useState, useTransition, type ReactElement } from "react";
import { listarFormas, mudarVencimento, registrarPagamento, type FormaPagamento } from "@/app/(app)/financeiro/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { formatarMoeda, paraCentavos } from "@/lib/moeda";

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";

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

function hojeLocal() {
  return new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}

/** "Marcar como pago": valor total ou parcial, data e forma. */
export function JanelaPagamento({
  parcelaId,
  saldoCentavos,
  subtitulo,
  aberto,
  aoFechar,
}: {
  parcelaId: string;
  saldoCentavos: number | null;
  subtitulo?: string | null;
  aberto: boolean;
  aoFechar: () => void;
}) {
  const [parcial, setParcial] = useState(false);
  const [valor, setValor] = useState("");
  const [data, setData] = useState(hojeLocal());
  const [formaId, setFormaId] = useState("");
  const [formas, setFormas] = useState<FormaPagamento[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

  useEffect(() => {
    if (aberto && !formas) listarFormas().then(setFormas);
  }, [aberto, formas]);

  function confirmar() {
    setErro(null);
    const centavos = parcial ? paraCentavos(valor) : null;
    if (parcial && (centavos === null || centavos <= 0)) return setErro("Informe o valor recebido.");
    iniciar(async () => {
      const r = await registrarPagamento({ parcelaId, valorCentavos: centavos ?? undefined, data, formaId });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  return (
    <Dialogo aberto={aberto} aoFechar={aoFechar} titulo="Confirmar pagamento" subtitulo={subtitulo}>
      <p className="text-sm text-suave">
        Registrar o recebimento de{" "}
        <strong className="text-grafite">{saldoCentavos !== null ? formatarMoeda(saldoCentavos) : "o valor em aberto"}</strong>. O
        lembrete sai da lista automaticamente.
      </p>
      <div role="radiogroup" aria-label="Quanto foi pago" className="mt-4 flex flex-wrap gap-2">
        {[
          { v: false, r: "Valor total" },
          { v: true, r: "Só uma parte" },
        ].map((o) => (
          <button
            key={o.r}
            type="button"
            role="radio"
            aria-checked={parcial === o.v}
            onClick={() => setParcial(o.v)}
            className={`rounded-lg border px-3 py-1.5 text-sm ${parcial === o.v ? "border-dourado bg-dourado-claro" : "border-borda-forte"}`}
          >
            {o.r}
          </button>
        ))}
      </div>
      {parcial && (
        <Campo rotulo="Valor recebido" ajuda="O saldo continua no lembrete, como “parcialmente pago”.">
          <input inputMode="decimal" placeholder="Ex.: 500" value={valor} onChange={(e) => setValor(e.target.value)} className={CAMPO} />
        </Campo>
      )}
      <div className="grid gap-x-3 sm:grid-cols-2">
        <Campo rotulo="Data do pagamento">
          <input type="date" max={hojeLocal()} value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
        </Campo>
        <Campo rotulo="Forma">
          <select value={formaId} onChange={(e) => setFormaId(e.target.value)} className={CAMPO}>
            <option value="">A combinada</option>
            {formas?.map((f) => (
              <option key={f.id} value={f.id}>
                {f.nome}
              </option>
            ))}
          </select>
        </Campo>
      </div>
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
          onClick={confirmar}
          className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Confirmar pagamento"}
        </button>
      </div>
    </Dialogo>
  );
}

/** Nova data prevista (ex.: o paciente pediu para pagar em outro dia). */
export function JanelaNovaData({
  parcelaId,
  subtitulo,
  aberto,
  aoFechar,
}: {
  parcelaId: string;
  subtitulo?: string | null;
  aberto: boolean;
  aoFechar: () => void;
}) {
  const [data, setData] = useState("");
  const [obs, setObs] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  return (
    <Dialogo aberto={aberto} aoFechar={aoFechar} titulo="Mudar a data prevista" subtitulo={subtitulo}>
      <Campo rotulo="Nova data">
        <input type="date" min={hojeLocal()} value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
      </Campo>
      <Campo rotulo="Observação (opcional)">
        <input value={obs} onChange={(e) => setObs(e.target.value)} maxLength={300} placeholder="Ex.: pediu para pagar no dia 15" className={CAMPO} />
      </Campo>
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
          onClick={() =>
            iniciar(async () => {
              const r = await mudarVencimento(parcelaId, data, obs);
              if (r.ok) {
                avisar(r.mensagem);
                aoFechar();
              } else setErro(r.erro);
            })
          }
          className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Salvar nova data"}
        </button>
      </div>
    </Dialogo>
  );
}
