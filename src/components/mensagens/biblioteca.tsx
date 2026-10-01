"use client";

import { Check, Copy, ExternalLink, PenLine, Plus, Search, Star, X } from "lucide-react";
import { cloneElement, useEffect, useId, useRef, useState, useTransition, type ReactElement, type ReactNode } from "react";
import { buscarPacientes, type PacienteEncontrado } from "@/app/(app)/agenda/acoes";
import { preencherParaPaciente, salvarModelo } from "@/app/(app)/mensagens/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { linkWhatsApp } from "@/lib/telefone";
import {
  CATEGORIAS,
  preencherExemplo,
  ROTULO_CATEGORIA,
  trechos,
  VARIAVEIS,
  type Categoria,
  type Modelo,
} from "@/modules/mensagens/mensagens";

type Opcao = { id: string; nome: string };

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";
const BOTAO = "inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado";

/** Rótulo ligado ao campo por id (o nome acessível não inclui as opções). */
function Campo({ rotulo, className, children }: { rotulo: string; className?: string; children: ReactElement<{ id?: string }> }) {
  const id = useId();
  return (
    <div className={className}>
      <label htmlFor={id} className="text-sm text-suave">
        {rotulo}
      </label>
      {cloneElement(children, { id })}
    </div>
  );
}

/** Copia para a área de transferência (com aviso). */
export async function copiarTexto(texto: string) {
  try {
    await navigator.clipboard.writeText(texto);
    avisar("Mensagem copiada. Cole no WhatsApp ou no canal que preferir.");
    return true;
  } catch {
    avisar("Não foi possível copiar. Selecione o texto e copie manualmente.", "erro");
    return false;
  }
}

/** Texto com as variáveis destacadas. */
export function TextoComVariaveis({ texto }: { texto: string }) {
  return (
    <p className="text-sm leading-relaxed whitespace-pre-line text-grafite">
      {trechos(texto).map((t, i) =>
        t.variavel ? (
          <mark key={i} className="rounded bg-dourado-claro px-1 font-medium text-dourado-escuro">
            {t.texto}
          </mark>
        ) : (
          <span key={i}>{t.texto}</span>
        ),
      )}
    </p>
  );
}

export function Biblioteca({ modelos, procedimentos }: { modelos: Modelo[]; procedimentos: Opcao[] }) {
  const [paciente, setPaciente] = useState<PacienteEncontrado | null>(null);
  const [preenchidos, setPreenchidos] = useState<Record<string, string>>({});
  const [procedimento, setProcedimento] = useState("");
  const [editando, setEditando] = useState<Modelo | "nova" | null>(null);
  const [usando, setUsando] = useState<{ modelo: Modelo; texto: string } | null>(null);

  async function escolher(p: PacienteEncontrado | null) {
    setPaciente(p);
    setPreenchidos(p ? await preencherParaPaciente(p.id) : {});
  }

  const ativos = modelos.filter((m) => m.ativo && (!procedimento || !m.procedimento_id || m.procedimento_id === procedimento));
  const arquivados = modelos.filter((m) => !m.ativo);
  const textoDe = (m: Modelo) => preenchidos[m.id] ?? m.texto;

  return (
    <div>
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-titulo text-4xl">Mensagens prontas</h1>
          <p className="mt-1 max-w-2xl text-suave">
            Textos elegantes e próximos, organizados por situação. As variáveis (como <mark className="rounded bg-dourado-claro px-1 text-dourado-escuro">{"{{nome}}"}</mark>)
            são preenchidas pelo CRM. Nada é enviado sozinho: você copia, adapta se quiser e envia pelo canal que preferir.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setEditando("nova")}
          className="inline-flex items-center gap-1.5 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase shadow-sm hover:bg-dourado-escuro"
        >
          <Plus className="size-4" /> Criar nova mensagem
        </button>
      </div>

      <div className="mt-6 grid gap-3 rounded-xl border border-borda bg-superficie p-4 sm:grid-cols-[1fr_16rem]">
        <PreencherPara paciente={paciente} aoEscolher={escolher} />
        <Campo rotulo="Procedimento">
          <select value={procedimento} onChange={(e) => setProcedimento(e.target.value)} className={CAMPO}>
            <option value="">Todos</option>
            {procedimentos.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
      </div>

      <nav aria-label="Situações" className="mt-6 flex flex-wrap gap-2">
        {CATEGORIAS.map((c) => (
          <a key={c.id} href={`#${c.id}`} className="rounded-full px-3 py-1 text-sm ring-1 ring-borda-forte hover:ring-dourado">
            {c.rotulo}
          </a>
        ))}
      </nav>

      {CATEGORIAS.map((c) => {
        const lista = ativos.filter((m) => m.categoria === c.id);
        return (
          <section key={c.id} id={c.id} aria-labelledby={`t-${c.id}`} className="mt-10 scroll-mt-6">
            <h2 id={`t-${c.id}`} className="font-titulo text-2xl">
              {c.rotulo}
            </h2>
            <p className="text-sm text-sutil">{c.quando}</p>
            {lista.length === 0 ? (
              <p className="mt-3 text-sm text-sutil">Nenhuma mensagem nesta situação{procedimento ? " para este procedimento" : ""}.</p>
            ) : (
              <ul className="mt-4 grid gap-3 lg:grid-cols-2">
                {lista.map((m) => (
                  <li key={m.id} aria-label={m.titulo} className="flex flex-col rounded-xl border border-borda bg-superficie p-4">
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="font-semibold">{m.titulo}</h3>
                      {m.padrao && (
                        <span className="inline-flex items-center gap-1 rounded-full bg-dourado-claro px-2 py-0.5 text-[11px] font-medium text-dourado-escuro">
                          <Star className="size-3" /> Sugerida
                        </span>
                      )}
                      {m.procedimento && (
                        <span className="rounded-full bg-fundo px-2 py-0.5 text-[11px] text-suave ring-1 ring-borda">{m.procedimento}</span>
                      )}
                    </div>
                    <div className="mt-2 flex-1">
                      <TextoComVariaveis texto={textoDe(m)} />
                    </div>
                    <div className="mt-3 flex flex-wrap gap-2">
                      <button
                        type="button"
                        onClick={() => copiarTexto(textoDe(m))}
                        className="inline-flex items-center gap-1.5 rounded-lg bg-grafite px-3 py-1.5 text-sm font-medium text-white hover:bg-black"
                      >
                        <Copy className="size-4" /> Copiar mensagem
                      </button>
                      <button type="button" onClick={() => setUsando({ modelo: m, texto: textoDe(m) })} className={BOTAO}>
                        Adaptar antes de copiar
                      </button>
                      <button type="button" onClick={() => setEditando(m)} className={BOTAO} aria-label={`Editar mensagem ${m.titulo}`}>
                        <PenLine className="size-4" /> Editar mensagem
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>
        );
      })}

      {arquivados.length > 0 && (
        <details className="mt-10">
          <summary className="cursor-pointer text-sm text-dourado-escuro">Mensagens arquivadas ({arquivados.length})</summary>
          <ul className="mt-3 grid gap-2">
            {arquivados.map((m) => (
              <li key={m.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-borda bg-superficie px-4 py-2 text-sm">
                <span>
                  {m.titulo} <span className="text-sutil">· {ROTULO_CATEGORIA[m.categoria]}</span>
                </span>
                <button type="button" onClick={() => setEditando(m)} className={BOTAO}>
                  Editar ou reativar
                </button>
              </li>
            ))}
          </ul>
        </details>
      )}

      {editando && (
        <EditorModelo
          modelo={editando === "nova" ? null : editando}
          procedimentos={procedimentos}
          aoFechar={() => setEditando(null)}
        />
      )}
      {usando && (
        <UsarMensagem
          titulo={usando.modelo.titulo}
          textoInicial={usando.texto}
          whatsapp={paciente?.whatsapp ?? null}
          paraQuem={paciente?.nome ?? null}
          aoFechar={() => setUsando(null)}
        />
      )}
    </div>
  );
}

function PreencherPara({ paciente, aoEscolher }: { paciente: PacienteEncontrado | null; aoEscolher: (p: PacienteEncontrado | null) => void }) {
  const [busca, setBusca] = useState("");
  const [achados, setAchados] = useState<PacienteEncontrado[]>([]);
  const [, iniciar] = useTransition();

  useEffect(() => {
    if (paciente || busca.trim().length < 2) return;
    const t = setTimeout(() => iniciar(async () => setAchados(await buscarPacientes(busca))), 250);
    return () => clearTimeout(t);
  }, [busca, paciente]);

  if (paciente) {
    return (
      <div>
        <span className="text-sm text-suave">Preenchendo para</span>
        <div className="mt-1.5 flex items-center justify-between gap-2 rounded-lg bg-dourado-claro px-3 py-2">
          <span className="text-sm font-medium">{paciente.nome}</span>
          <button
            type="button"
            onClick={() => {
              aoEscolher(null);
              setBusca("");
              setAchados([]);
            }}
            aria-label="Limpar paciente"
            className="text-sutil hover:text-grafite"
          >
            <X className="size-4" />
          </button>
        </div>
      </div>
    );
  }
  return (
    <div className="relative">
      <label className="block">
        <span className="text-sm text-suave">Preencher para um paciente (opcional)</span>
        <span className="relative mt-1.5 block">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-sutil" />
          <input value={busca} onChange={(e) => setBusca(e.target.value)} placeholder="Nome ou telefone" className={`${CAMPO} mt-0 pl-8`} />
        </span>
      </label>
      {busca.trim().length >= 2 && achados.length > 0 && (
        <ul aria-label="Pacientes encontrados" className="absolute z-10 mt-1 w-full divide-y divide-borda rounded-lg border border-borda bg-superficie shadow-lg">
          {achados.map((p) => (
            <li key={p.id}>
              <button type="button" onClick={() => aoEscolher(p)} className="w-full px-3.5 py-2 text-left text-sm hover:bg-fundo">
                {p.nome}
                <span className="block text-xs text-sutil">{[p.procedimento, p.etapa].filter(Boolean).join(" · ")}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** Adaptar o texto antes de usar: editar, copiar e (se houver paciente) abrir no WhatsApp. */
export function UsarMensagem({
  titulo,
  textoInicial,
  whatsapp,
  paraQuem,
  aoFechar,
  extra,
}: {
  titulo: string;
  textoInicial: string;
  whatsapp: string | null;
  paraQuem: string | null;
  aoFechar: () => void;
  extra?: ReactNode;
}) {
  const [texto, setTexto] = useState(textoInicial);
  const [copiado, setCopiado] = useState(false);
  return (
    <Dialogo aberto aoFechar={aoFechar} titulo={titulo} subtitulo={paraQuem ? `Para ${paraQuem}` : "Ajuste o texto antes de copiar."}>
      {extra}
      <label className="block">
        <span className="text-xs text-suave">Você pode ajustar o texto antes de enviar.</span>
        <textarea
          value={texto}
          onChange={(e) => setTexto(e.target.value)}
          rows={7}
          className="mt-1.5 w-full resize-y rounded-lg border border-borda-forte bg-fundo p-3 text-sm leading-relaxed outline-none focus:border-dourado"
        />
      </label>
      {trechos(texto).some((t) => t.variavel) && (
        <p className="mt-2 text-xs text-importante">Ainda há variáveis sem preencher — escolha um paciente ou ajuste o texto.</p>
      )}
      <div className="mt-5 flex flex-wrap justify-end gap-2">
        <button
          type="button"
          onClick={async () => {
            if (await copiarTexto(texto)) {
              setCopiado(true);
              setTimeout(() => setCopiado(false), 2000);
            }
          }}
          className="inline-flex items-center gap-1.5 rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black"
        >
          {copiado ? <Check className="size-4" /> : <Copy className="size-4" />} {copiado ? "Copiada" : "Copiar mensagem"}
        </button>
        {whatsapp && (
          <a
            href={linkWhatsApp(whatsapp, texto)}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3.5 py-2 text-sm hover:border-dourado"
          >
            <ExternalLink className="size-4" /> Abrir no WhatsApp
          </a>
        )}
      </div>
      <p className="mt-3 text-xs text-sutil">A mensagem nunca é enviada pelo sistema: você decide quando e por onde enviar.</p>
    </Dialogo>
  );
}

function EditorModelo({ modelo, procedimentos, aoFechar }: { modelo: Modelo | null; procedimentos: Opcao[]; aoFechar: () => void }) {
  const [categoria, setCategoria] = useState<Categoria>(modelo?.categoria ?? "primeiro_contato");
  const [procedimentoId, setProcedimentoId] = useState(modelo?.procedimento_id ?? "");
  const [titulo, setTitulo] = useState(modelo?.titulo ?? "");
  const [texto, setTexto] = useState(modelo?.texto ?? "Olá, {{nome}}! Tudo bem?\n");
  const [padrao, setPadrao] = useState(modelo?.padrao ?? false);
  const [ativo, setAtivo] = useState(modelo?.ativo ?? true);
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const area = useRef<HTMLTextAreaElement>(null);

  function inserir(token: string) {
    const el = area.current;
    const v = `{{${token}}}`;
    if (!el) return setTexto((t) => t + v);
    const ini = el.selectionStart ?? texto.length;
    const fim = el.selectionEnd ?? texto.length;
    const novo = texto.slice(0, ini) + v + texto.slice(fim);
    setTexto(novo);
    requestAnimationFrame(() => {
      el.focus();
      el.setSelectionRange(ini + v.length, ini + v.length);
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo={modelo ? "Editar mensagem" : "Nova mensagem"} subtitulo="A mensagem fica disponível para toda a equipe.">
      <div className="grid gap-x-3 sm:grid-cols-2">
        <Campo rotulo="Situação">
          <select value={categoria} onChange={(e) => setCategoria(e.target.value as Categoria)} className={CAMPO}>
            {CATEGORIAS.map((c) => (
              <option key={c.id} value={c.id}>
                {c.rotulo}
              </option>
            ))}
          </select>
        </Campo>
        <Campo rotulo="Procedimento (opcional)">
          <select value={procedimentoId} onChange={(e) => setProcedimentoId(e.target.value)} className={CAMPO}>
            <option value="">Qualquer procedimento</option>
            {procedimentos.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
      </div>
      <Campo rotulo="Nome da mensagem" className="mt-4">
        <input value={titulo} onChange={(e) => setTitulo(e.target.value)} maxLength={80} placeholder="Ex.: Depois da avaliação de implantes" className={CAMPO} />
      </Campo>
      <Campo rotulo="Texto" className="mt-4">
        <textarea ref={area} value={texto} onChange={(e) => setTexto(e.target.value)} rows={6} maxLength={2000} className={`${CAMPO} leading-relaxed`} />
      </Campo>
      <div className="mt-2" role="group" aria-label="Inserir variável">
        <p className="text-xs text-sutil">Inserir variável (preenchida pelo CRM):</p>
        <div className="mt-1.5 flex flex-wrap gap-1.5">
          {VARIAVEIS.map((v) => (
            <button
              key={v.token}
              type="button"
              onClick={() => inserir(v.token)}
              className="rounded-md bg-dourado-claro px-2 py-0.5 text-xs text-dourado-escuro hover:bg-dourado hover:text-white"
            >
              {v.rotulo}
            </button>
          ))}
        </div>
      </div>
      <div className="mt-4 rounded-lg bg-fundo px-3.5 py-2.5">
        <p className="text-[11px] font-semibold tracking-[0.08em] text-sutil uppercase">Prévia</p>
        <p className="mt-1 text-sm whitespace-pre-line text-suave">{preencherExemplo(texto)}</p>
      </div>
      <label className="mt-4 flex items-center gap-2 text-sm">
        <input type="checkbox" checked={padrao} onChange={(e) => setPadrao(e.target.checked)} className="size-4 accent-dourado" />
        Sugerir automaticamente nesta situação{procedimentoId ? " (para este procedimento)" : ""}
      </label>
      {modelo && (
        <label className="mt-2 flex items-center gap-2 text-sm">
          <input type="checkbox" checked={ativo} onChange={(e) => setAtivo(e.target.checked)} className="size-4 accent-dourado" />
          Ativa (desmarque para arquivar)
        </label>
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
          onClick={() => {
            setErro(null);
            iniciar(async () => {
              const r = await salvarModelo({ id: modelo?.id ?? "", categoria, procedimentoId, titulo, texto, padrao, ativo });
              if (r.ok) {
                avisar(r.mensagem);
                aoFechar();
              } else setErro(r.erro);
            });
          }}
          className="rounded-lg bg-dourado px-3.5 py-2 text-sm font-medium text-white hover:bg-dourado-escuro disabled:opacity-50"
        >
          {pendente ? "Salvando…" : "Salvar mensagem"}
        </button>
      </div>
    </Dialogo>
  );
}
