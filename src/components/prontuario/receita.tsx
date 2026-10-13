"use client";

import { Plus, Printer, Trash2, X } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState, useTransition, type ReactNode } from "react";
import { emitirReceita, excluirModeloReceita } from "@/app/(app)/prontuario/acoes";
import { avisar } from "@/components/avisos";
import {
  ITEM_VAZIO,
  SUGESTOES_MEDICAMENTOS,
  TIPOS_RECEITA,
  USOS,
  type ItemReceita,
  type ModeloReceita,
  type TipoReceita,
  type Uso,
} from "@/modules/receitas/receitas";

const CAMPO =
  "mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";

function Campo({ rotulo, children, classe = "" }: { rotulo: string; children: ReactNode; classe?: string }) {
  return (
    <label className={`block ${classe}`}>
      <span className="text-xs text-suave">{rotulo}</span>
      {children}
    </label>
  );
}

export interface InicialReceita {
  tipo: TipoReceita;
  vias: 1 | 2;
  itens: ItemReceita[];
  orientacoes: string;
}

export function FormularioReceita({
  pessoaId,
  atendimentoId,
  profissionais,
  profissionalPadrao,
  hoje,
  modelos: modelosIniciais,
  inicial,
}: {
  pessoaId: string;
  atendimentoId: string;
  profissionais: { id: string; nome: string; cro: string | null }[];
  profissionalPadrao: string;
  hoje: string;
  modelos: ModeloReceita[];
  inicial: InicialReceita | null;
}) {
  const router = useRouter();
  const [profissionalId, setProfissionalId] = useState(profissionalPadrao);
  const [tipo, setTipo] = useState<TipoReceita>(inicial?.tipo ?? "simples");
  const [duasVias, setDuasVias] = useState(inicial?.vias === 2);
  const [data, setData] = useState(hoje);
  const [itens, setItens] = useState<ItemReceita[]>(inicial?.itens.length ? inicial.itens : [{ ...ITEM_VAZIO }]);
  const [orientacoes, setOrientacoes] = useState(inicial?.orientacoes ?? "");
  const [modelos, setModelos] = useState(modelosIniciais);
  const [modeloId, setModeloId] = useState("");
  const [guardar, setGuardar] = useState(false);
  const [nomeModelo, setNomeModelo] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

  const prof = profissionais.find((p) => p.id === profissionalId);

  function mudarItem(i: number, mudanca: Partial<ItemReceita>) {
    setItens((lista) => lista.map((x, j) => (j === i ? { ...x, ...mudanca } : x)));
  }

  function usarModelo(id: string) {
    setModeloId(id);
    const m = modelos.find((x) => x.id === id);
    if (!m) return;
    setTipo(m.tipo);
    setItens(m.itens.map((x) => ({ ...ITEM_VAZIO, ...x })));
    setOrientacoes(m.orientacoes ?? "");
  }

  function excluirModelo() {
    const m = modelos.find((x) => x.id === modeloId);
    if (!m || !confirm(`Excluir o modelo “${m.nome}”? As receitas já emitidas não mudam.`)) return;
    iniciar(async () => {
      const r = await excluirModeloReceita(m.id);
      if (r.ok) {
        setModelos((l) => l.filter((x) => x.id !== m.id));
        setModeloId("");
        avisar(r.mensagem);
      } else avisar(r.erro, "erro");
    });
  }

  function emitir() {
    setErro(null);
    iniciar(async () => {
      const r = await emitirReceita({
        pessoaId,
        atendimentoId,
        profissionalId,
        tipo,
        vias: tipo === "controle_especial" || duasVias ? 2 : 1,
        data,
        itens,
        orientacoes,
        salvarModelo: guardar ? nomeModelo : "",
      });
      if (r.ok) router.push(r.url);
      else setErro(r.erro);
    });
  }

  return (
    <div className="space-y-5">
      {modelos.length > 0 && (
        <div className="flex flex-wrap items-end gap-2 rounded-xl border border-dourado/40 bg-dourado-claro/40 p-4">
          <Campo rotulo="Começar de um modelo" classe="min-w-56 flex-1">
            <select value={modeloId} onChange={(e) => usarModelo(e.target.value)} className={CAMPO}>
              <option value="">Escolha um modelo…</option>
              {modelos.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.nome}
                </option>
              ))}
            </select>
          </Campo>
          {modeloId && (
            <button
              type="button"
              onClick={excluirModelo}
              disabled={pendente}
              className="inline-flex items-center gap-1 rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm text-suave hover:border-urgente hover:text-urgente"
            >
              <Trash2 className="size-4" /> Excluir modelo
            </button>
          )}
        </div>
      )}

      <div className="grid gap-4 rounded-xl border border-borda bg-superficie p-4 sm:grid-cols-3 sm:p-5">
        <Campo rotulo="Dentista que assina">
          <select value={profissionalId} onChange={(e) => setProfissionalId(e.target.value)} className={CAMPO}>
            <option value="">Escolha…</option>
            {profissionais.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
          {prof && !prof.cro && (
            <span className="mt-1 block text-xs text-importante">Sem CRO cadastrado (Configurações → Dentistas).</span>
          )}
        </Campo>
        <Campo rotulo="Data">
          <input type="date" value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
        </Campo>
        <fieldset>
          <legend className="text-xs text-suave">Tipo</legend>
          <div role="radiogroup" aria-label="Tipo de receita" className="mt-1 flex gap-1.5">
            {(Object.keys(TIPOS_RECEITA) as TipoReceita[]).map((t) => (
              <button
                key={t}
                type="button"
                role="radio"
                aria-checked={tipo === t}
                onClick={() => setTipo(t)}
                className={`flex-1 rounded-lg border px-2.5 py-2 text-sm ${tipo === t ? "border-dourado bg-dourado-claro font-medium" : "border-borda-forte hover:border-dourado"}`}
              >
                {TIPOS_RECEITA[t]}
              </button>
            ))}
          </div>
          {tipo === "simples" ? (
            <label className="mt-2 flex items-center gap-2 text-xs text-suave">
              <input type="checkbox" checked={duasVias} onChange={(e) => setDuasVias(e.target.checked)} className="size-4 accent-dourado" />
              Imprimir em 2 vias (ex.: antibiótico)
            </label>
          ) : (
            <p className="mt-2 text-xs text-suave">Sai em 2 vias (farmácia e paciente), com os campos do comprador e do fornecedor.</p>
          )}
        </fieldset>
      </div>

      <section aria-label="Medicamentos" className="rounded-xl border border-borda bg-superficie p-4 sm:p-5">
        <h2 className="font-titulo text-xl">Medicamentos</h2>
        <datalist id="sugestoes-medicamentos">
          {SUGESTOES_MEDICAMENTOS.map((m) => (
            <option key={m} value={m} />
          ))}
        </datalist>
        <ol className="mt-3 space-y-3">
          {itens.map((it, i) => (
            <li key={i} aria-label={`Medicamento ${i + 1}`} className="rounded-lg border border-borda p-3">
              <div className="flex items-start gap-2">
                <span className="mt-6 w-5 shrink-0 text-sm font-semibold text-dourado-escuro">{i + 1}.</span>
                <div className="grid flex-1 gap-3 sm:grid-cols-6">
                  <Campo rotulo="Medicamento e dose" classe="sm:col-span-3">
                    <input
                      value={it.medicamento}
                      list="sugestoes-medicamentos"
                      maxLength={120}
                      placeholder="Ex.: Amoxicilina 500 mg"
                      onChange={(e) => mudarItem(i, { medicamento: e.target.value })}
                      className={CAMPO}
                    />
                  </Campo>
                  <Campo rotulo="Quantidade" classe="sm:col-span-2">
                    <input
                      value={it.quantidade}
                      maxLength={60}
                      placeholder="Ex.: 21 cápsulas"
                      onChange={(e) => mudarItem(i, { quantidade: e.target.value })}
                      className={CAMPO}
                    />
                  </Campo>
                  <Campo rotulo="Via">
                    <select value={it.uso} onChange={(e) => mudarItem(i, { uso: e.target.value as Uso })} className={CAMPO}>
                      {(Object.keys(USOS) as Uso[]).map((u) => (
                        <option key={u} value={u}>
                          {USOS[u].replace("Uso ", "")}
                        </option>
                      ))}
                    </select>
                  </Campo>
                  <Campo rotulo="Como usar" classe="sm:col-span-6">
                    <input
                      value={it.posologia}
                      maxLength={500}
                      placeholder="Ex.: Tomar 1 cápsula de 8 em 8 horas, por 7 dias."
                      onChange={(e) => mudarItem(i, { posologia: e.target.value })}
                      className={CAMPO}
                    />
                  </Campo>
                </div>
                {itens.length > 1 && (
                  <button
                    type="button"
                    aria-label={`Tirar o medicamento ${i + 1}`}
                    onClick={() => setItens((l) => l.filter((_, j) => j !== i))}
                    className="mt-6 rounded-lg p-1.5 text-sutil hover:bg-fundo hover:text-urgente"
                  >
                    <X className="size-4" />
                  </button>
                )}
              </div>
            </li>
          ))}
        </ol>
        {itens.length < 20 && (
          <button
            type="button"
            onClick={() => setItens((l) => [...l, { ...ITEM_VAZIO }])}
            className="mt-3 inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
          >
            <Plus className="size-4" /> Adicionar medicamento
          </button>
        )}

        <Campo rotulo="Orientações (opcional)" classe="mt-5">
          <textarea
            value={orientacoes}
            maxLength={2000}
            rows={3}
            placeholder="Ex.: Evitar alimentos quentes e esforço físico nas primeiras 24 horas."
            onChange={(e) => setOrientacoes(e.target.value)}
            className={CAMPO}
          />
        </Campo>
      </section>

      <div className="rounded-xl border border-borda bg-superficie p-4 sm:p-5">
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={guardar} onChange={(e) => setGuardar(e.target.checked)} className="size-4 accent-dourado" />
          Guardar também como modelo, para usar de novo
        </label>
        {guardar && (
          <Campo rotulo="Nome do modelo" classe="mt-3 max-w-sm">
            <input value={nomeModelo} maxLength={60} placeholder="Ex.: Pós-extração" onChange={(e) => setNomeModelo(e.target.value)} className={CAMPO} />
          </Campo>
        )}
        <p className="mt-3 text-xs text-sutil">Depois de emitida, a receita fica guardada no prontuário e não muda. Você pode imprimir de novo ou repetir quando quiser.</p>
        <button
          type="button"
          onClick={emitir}
          disabled={pendente}
          className="mt-4 inline-flex items-center gap-2 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase hover:bg-dourado-escuro disabled:opacity-50"
        >
          <Printer className="size-4" /> {pendente ? "Emitindo…" : "Emitir e imprimir"}
        </button>
        {erro && (
          <p role="alert" className="mt-3 text-sm text-urgente">
            {erro}
          </p>
        )}
      </div>
    </div>
  );
}
