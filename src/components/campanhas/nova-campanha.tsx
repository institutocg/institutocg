"use client";

import { Megaphone, Search } from "lucide-react";
import { useEffect, useMemo, useState, useTransition, type ReactNode } from "react";
import { criarCampanha, encerrarCampanha, preverCampanha } from "@/app/(app)/campanhas/acoes";
import { avisar } from "@/components/avisos";
import {
  comOferta,
  GRUPOS_SEGMENTO,
  ORDEM_SEGMENTOS,
  SEGMENTOS,
  terminoPrevisto,
  type Destinatario,
  type Segmento,
} from "@/modules/campanhas/campanhas";
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
const MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];

/** Ritmo e data de início (iguais em todas as campanhas). */
function Ritmo({ hoje, limiteDia, setLimiteDia, iniciaEm, setIniciaEm }: {
  hoje: string; limiteDia: string; setLimiteDia: (v: string) => void; iniciaEm: string; setIniciaEm: (v: string) => void;
}) {
  return (
    <div className="grid gap-x-3 sm:grid-cols-2">
      <Campo rotulo="Contatos por dia (no máximo)" ajuda="Um ritmo tranquilo permite conversas de verdade.">
        <input type="number" min={1} max={50} value={limiteDia} onChange={(e) => setLimiteDia(e.target.value)} className={CAMPO} />
      </Campo>
      <Campo rotulo="Começar em">
        <input type="date" min={hoje} value={iniciaEm} onChange={(e) => setIniciaEm(e.target.value)} className={CAMPO} />
      </Campo>
    </div>
  );
}

function Erro({ erro }: { erro: string | null }) {
  return erro ? (
    <p role="alert" className="mt-3 text-sm text-urgente">
      {erro}
    </p>
  ) : null;
}

export function NovaCampanha({
  procedimentos,
  hoje,
  limitePadrao,
}: {
  procedimentos: { id: string; nome: string }[];
  hoje: string;
  limitePadrao: number;
}) {
  const [segmento, setSegmento] = useState<Segmento>("interesse");
  return (
    <div className="rounded-xl border border-borda bg-superficie p-4 sm:p-6">
      <h2 className="flex items-center gap-2 font-titulo text-2xl">
        <Megaphone className="size-5 text-dourado" /> Nova campanha
      </h2>

      {GRUPOS_SEGMENTO.map((g) => (
        <fieldset key={g.id} className="mt-4">
          <legend className="text-sm font-medium">{g.titulo}</legend>
          <p className="text-xs text-sutil">{g.ajuda}</p>
          <div role="radiogroup" aria-label={g.titulo} className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {ORDEM_SEGMENTOS.filter((s) => SEGMENTOS[s].grupo === g.id).map((s) => (
              <button
                key={s}
                type="button"
                role="radio"
                aria-checked={segmento === s}
                onClick={() => setSegmento(s)}
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
      ))}

      {segmento === "personalizada" ? (
        <MinhaCampanha hoje={hoje} limitePadrao={limitePadrao} />
      ) : (
        <CampanhaPronta key={segmento} segmento={segmento} procedimentos={procedimentos} hoje={hoje} limitePadrao={limitePadrao} />
      )}
    </div>
  );
}

/** Tipos prontos: o sistema encontra quem entra. */
function CampanhaPronta({
  segmento,
  procedimentos,
  hoje,
  limitePadrao,
}: {
  segmento: Segmento;
  procedimentos: { id: string; nome: string }[];
  hoje: string;
  limitePadrao: number;
}) {
  const def = SEGMENTOS[segmento];
  const [meses, setMeses] = useState(String(def.mesesPadrao));
  const [procedimentoId, setProcedimentoId] = useState("");
  const [somenteMarketing, setSomenteMarketing] = useState(false);
  const [nome, setNome] = useState("");
  const [mensagem, setMensagem] = useState(def.mensagem);
  const [limiteDia, setLimiteDia] = useState(String(limitePadrao));
  const [iniciaEm, setIniciaEm] = useState(hoje);
  const [lista, setLista] = useState<Destinatario[] | null>(null);
  const [fora, setFora] = useState<Set<string>>(new Set());
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

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
    <>
      <div className="grid gap-x-3 sm:grid-cols-3">
        {def.rotuloMeses && (
          <Campo rotulo={def.rotuloMeses}>
            <input type="number" min={1} max={120} value={meses} onChange={(e) => { setMeses(e.target.value); setLista(null); }} className={CAMPO} />
          </Campo>
        )}
        {def.procedimento !== "nao" && (
          <Campo rotulo={def.procedimento === "obrigatorio" ? "Procedimento" : "Procedimento (opcional)"}>
            <select value={procedimentoId} onChange={(e) => { setProcedimentoId(e.target.value); setLista(null); }} className={CAMPO}>
              <option value="">{def.procedimento === "opcional" ? "Todos" : "Escolha…"}</option>
              {procedimentos.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nome}
                </option>
              ))}
            </select>
          </Campo>
        )}
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
              ? segmento === "aniversario"
                ? "Ninguém faz aniversário neste período (ou o parabéns já está programado)."
                : "Ninguém se encaixa agora (quem não aceita contato, já está negociando ou participou de campanha nos últimos 30 dias fica de fora)."
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
          <Campo
            rotulo="Mensagem sugerida"
            ajuda="Use {{nome}} e {{procedimento}}. Cada mensagem é revisada e enviada por você. Evite preço, desconto ou promoção (publicidade odontológica)."
          >
            <textarea value={mensagem} onChange={(e) => setMensagem(e.target.value)} rows={4} maxLength={2000} className={CAMPO} />
          </Campo>
          <p className="mt-2 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
            <span className="text-xs tracking-wide text-sutil uppercase">Prévia · </span>
            {exemplo(mensagem, procNome)}
          </p>
          {segmento === "aniversario" ? (
            <p className="mt-3 text-sm text-suave">Cada parabéns fica para o dia do aniversário (ou o dia útil anterior, se cair no fim de semana).</p>
          ) : (
            <Ritmo hoje={hoje} limiteDia={limiteDia} setLimiteDia={setLimiteDia} iniciaEm={iniciaEm} setIniciaEm={setIniciaEm} />
          )}
          {fim && selecionadas.length > 0 && segmento !== "aniversario" && (
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
      <Erro erro={erro} />
    </>
  );
}

type Ordem = "nome" | "vindas" | "aniversario" | "ultima";

/** Dias até o próximo aniversário (0 = hoje). */
function diasAteAniversario(nascimento: string, hoje: string): number {
  const [ah, mh, dh] = hoje.split("-").map(Number);
  const [, mn, dn] = nascimento.split("-").map(Number);
  const h = Date.UTC(ah, mh - 1, dh);
  let a = Date.UTC(ah, mn - 1, dn);
  if (a < h) a = Date.UTC(ah + 1, mn - 1, dn);
  return Math.round((a - h) / 86_400_000);
}

/** Campanha criada por ela: escreve tudo e escolhe os pacientes. */
function MinhaCampanha({ hoje, limitePadrao }: { hoje: string; limitePadrao: number }) {
  const [nome, setNome] = useState("");
  const [publicoAlvo, setPublicoAlvo] = useState("");
  const [oferta, setOferta] = useState("");
  const [mensagem, setMensagem] = useState(SEGMENTOS.personalizada.mensagem);
  const [limiteDia, setLimiteDia] = useState(String(limitePadrao));
  const [iniciaEm, setIniciaEm] = useState(hoje);
  const [somenteMarketing, setSomenteMarketing] = useState(false);
  const [lista, setLista] = useState<Destinatario[] | null>(null);
  const [escolhidos, setEscolhidos] = useState<Set<string>>(new Set());
  const [busca, setBusca] = useState("");
  const [ordem, setOrdem] = useState<Ordem>("nome");
  const [mostrar, setMostrar] = useState<"todos" | "mes" | "proximo">("todos");
  const [minVindas, setMinVindas] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();

  useEffect(() => {
    iniciar(async () => {
      const r = await preverCampanha({ segmento: "personalizada", meses: 1, procedimentoId: "", somenteMarketing });
      if (r.ok) {
        setLista(r.pessoas);
        setEscolhidos((e) => new Set(r.pessoas.filter((p) => e.has(p.pessoa_id)).map((p) => p.pessoa_id)));
      } else setErro(r.erro);
    });
  }, [somenteMarketing]);

  const mesAtual = Number(hoje.slice(5, 7));
  const mesProximo = (mesAtual % 12) + 1;
  const mostrados = useMemo(() => {
    const termo = busca.trim().toLocaleLowerCase("pt-BR");
    const min = Number(minVindas) || 0;
    const mes = mostrar === "mes" ? mesAtual : mostrar === "proximo" ? mesProximo : null;
    const r = (lista ?? []).filter(
      (p) =>
        (!termo || p.nome.toLocaleLowerCase("pt-BR").includes(termo)) &&
        (p.vindas ?? 0) >= min &&
        (mes === null || (p.nascimento != null && Number(p.nascimento.slice(5, 7)) === mes)),
    );
    const aniv = (p: Destinatario) => (p.nascimento ? diasAteAniversario(p.nascimento, hoje) : 9999);
    return r.sort((a, b) =>
      ordem === "vindas"
        ? (b.vindas ?? 0) - (a.vindas ?? 0) || a.nome.localeCompare(b.nome)
        : ordem === "aniversario"
          ? aniv(a) - aniv(b)
          : ordem === "ultima"
            ? (a.ultima_vinda ?? "0").localeCompare(b.ultima_vinda ?? "0")
            : a.nome.localeCompare(b.nome, "pt-BR"),
    );
  }, [lista, busca, minVindas, mostrar, ordem, hoje, mesAtual, mesProximo]);

  function marcar(ids: string[], sim: boolean) {
    setEscolhidos((e) => {
      const n = new Set(e);
      for (const id of ids) {
        if (sim) n.add(id);
        else n.delete(id);
      }
      return n;
    });
  }

  const final = comOferta(mensagem, oferta);
  const fim = terminoPrevisto(iniciaEm, escolhidos.size, Number(limiteDia) || 1);

  function criar() {
    setErro(null);
    iniciar(async () => {
      const r = await criarCampanha({
        segmento: "personalizada", meses: 1, procedimentoId: "", somenteMarketing, nome, mensagem, limiteDia, iniciaEm,
        pessoas: [...escolhidos], publicoAlvo, oferta,
      });
      if (r.ok) {
        avisar(r.mensagem);
        setEscolhidos(new Set());
        setNome("");
        setPublicoAlvo("");
        setOferta("");
        setMensagem(SEGMENTOS.personalizada.mensagem);
      } else setErro(r.erro);
    });
  }

  function detalhe(p: Destinatario) {
    const v = p.vindas ?? 0;
    return [
      v > 0 ? `${v} ${v === 1 ? "vinda" : "vindas"}` : p.ultima_vinda ? "Paciente antigo" : "Ainda não veio",
      p.ultima_vinda ? `última vinda ${br(p.ultima_vinda).slice(3)}` : null,
      p.nascimento ? `aniversário ${br(p.nascimento).slice(0, 5)}` : null,
    ]
      .filter(Boolean)
      .join(" · ");
  }

  return (
    <>
      <Campo rotulo="Nome da campanha">
        <input value={nome} onChange={(e) => setNome(e.target.value)} maxLength={80} placeholder="Ex.: Indique um amigo" className={CAMPO} />
      </Campo>
      <Campo rotulo="Público-alvo" ajuda="Para você lembrar para quem é a campanha. Os pacientes você escolhe logo abaixo.">
        <input
          value={publicoAlvo}
          onChange={(e) => setPublicoAlvo(e.target.value)}
          maxLength={200}
          placeholder="Ex.: pacientes que vieram mais de 3 vezes"
          className={CAMPO}
        />
      </Campo>
      <Campo rotulo="Oferta (opcional)" ajuda="Entra na mensagem no lugar de {{oferta}}. Evite preço e desconto (publicidade odontológica).">
        <textarea
          value={oferta}
          onChange={(e) => setOferta(e.target.value)}
          rows={2}
          maxLength={300}
          placeholder="Ex.: Indique um amigo e ganhe um mimo especial na sua próxima consulta."
          className={CAMPO}
        />
      </Campo>
      <Campo rotulo="Mensagem" ajuda="Use {{nome}} para o primeiro nome e {{oferta}} para a oferta. Cada mensagem é revisada e enviada por você.">
        <textarea value={mensagem} onChange={(e) => setMensagem(e.target.value)} rows={4} maxLength={2000} className={CAMPO} />
      </Campo>
      <p className="mt-2 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
        <span className="text-xs tracking-wide text-sutil uppercase">Prévia · </span>
        {exemplo(final)}
      </p>

      <div className="mt-6 border-t border-borda pt-4">
        <p className="text-sm font-medium">Escolha os pacientes</p>
        <p className="text-xs text-sutil">
          Marque quem entra. Para achar mais rápido, use a busca ou organize a lista (tudo opcional).
        </p>
        <div className="mt-1 grid gap-x-3 sm:grid-cols-4">
          <Campo rotulo="Buscar pelo nome">
            <input type="search" value={busca} onChange={(e) => setBusca(e.target.value)} className={CAMPO} />
          </Campo>
          <Campo rotulo="Organizar por">
            <select value={ordem} onChange={(e) => setOrdem(e.target.value as Ordem)} className={CAMPO}>
              <option value="nome">Nome</option>
              <option value="vindas">Mais vindas à clínica</option>
              <option value="aniversario">Próximo aniversário</option>
              <option value="ultima">Há mais tempo sem vir</option>
            </select>
          </Campo>
          <Campo rotulo="Mostrar">
            <select value={mostrar} onChange={(e) => setMostrar(e.target.value as typeof mostrar)} className={CAMPO}>
              <option value="todos">Todos</option>
              <option value="mes">Aniversariantes de {MESES[mesAtual - 1]}</option>
              <option value="proximo">Aniversariantes de {MESES[mesProximo - 1]}</option>
            </select>
          </Campo>
          <Campo rotulo="Vieram pelo menos (vezes)">
            <input type="number" min={0} max={999} value={minVindas} onChange={(e) => setMinVindas(e.target.value)} placeholder="—" className={CAMPO} />
          </Campo>
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-2 text-sm">
          <button
            type="button"
            onClick={() => marcar(mostrados.map((p) => p.pessoa_id), true)}
            disabled={mostrados.length === 0}
            className="rounded-lg border border-borda-forte px-3 py-1.5 hover:border-dourado disabled:opacity-50"
          >
            Marcar os {mostrados.length} mostrados
          </button>
          <button
            type="button"
            onClick={() => setEscolhidos(new Set())}
            disabled={escolhidos.size === 0}
            className="rounded-lg border border-borda-forte px-3 py-1.5 hover:border-dourado disabled:opacity-50"
          >
            Desmarcar todos
          </button>
          <label className="ml-auto flex items-center gap-2">
            <input type="checkbox" checked={somenteMarketing} onChange={(e) => setSomenteMarketing(e.target.checked)} className="size-4 accent-dourado" />
            Só quem aceitou comunicações
          </label>
        </div>
        <p className="mt-3 text-sm font-medium" aria-live="polite">
          {lista === null
            ? "Carregando pacientes…"
            : `${escolhidos.size} ${escolhidos.size === 1 ? "paciente escolhido" : "pacientes escolhidos"}`}
        </p>
        {lista !== null && (
          <ul aria-label="Pacientes para escolher" className="mt-2 max-h-80 divide-y divide-borda overflow-y-auto rounded-lg border border-borda">
            {mostrados.length === 0 && <li className="px-3.5 py-3 text-sm text-sutil">Ninguém aparece com essa busca.</li>}
            {mostrados.map((p) => (
              <li key={p.pessoa_id}>
                <label className="flex items-start gap-2.5 px-3.5 py-2 text-sm">
                  <input
                    type="checkbox"
                    className="mt-0.5 size-4 accent-dourado"
                    checked={escolhidos.has(p.pessoa_id)}
                    onChange={(e) => marcar([p.pessoa_id], e.target.checked)}
                  />
                  <span>
                    <span className="font-medium">{p.nome}</span>
                    <span className="block text-xs text-sutil">{detalhe(p)}</span>
                  </span>
                </label>
              </li>
            ))}
          </ul>
        )}
        <p className="mt-2 text-xs text-sutil">
          Não aparecem: quem não aceita contato, quem está em negociação, quem teve contato nos últimos dias ou participou de outra
          campanha há menos de 30 dias, e quem está com pagamento atrasado.
        </p>
      </div>

      <Ritmo hoje={hoje} limiteDia={limiteDia} setLimiteDia={setLimiteDia} iniciaEm={iniciaEm} setIniciaEm={setIniciaEm} />
      {fim && escolhidos.size > 0 && (
        <p className="mt-3 text-sm text-suave">
          {escolhidos.size} {escolhidos.size === 1 ? "contato" : "contatos"} de {br(iniciaEm)} até cerca de {br(fim)} (só dias úteis).
          Cada um aparece em “Hoje” com a mensagem pronta.
        </p>
      )}
      <button
        type="button"
        onClick={criar}
        disabled={pendente || escolhidos.size === 0}
        className="mt-4 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase hover:bg-dourado-escuro disabled:opacity-50"
      >
        {pendente && lista !== null ? "Criando…" : "Criar campanha"}
      </button>
      <Erro erro={erro} />
    </>
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
