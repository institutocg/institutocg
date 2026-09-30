"use client";

import { Check, Copy, ExternalLink, HandCoins, MessageCircle, Pencil, Phone, UserRound } from "lucide-react";
import Link from "next/link";
import { useState, useTransition, type ReactNode } from "react";
import {
  cancelarTarefa,
  concluirTarefa,
  editarTarefa,
  marcarComoPago,
  registrarContato,
  type DadosRegistro,
  type Retorno,
} from "@/app/(app)/hoje/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { formatarMoeda } from "@/lib/moeda";
import { linkWhatsApp } from "@/lib/telefone";
import type { Motivo } from "@/modules/painel/consultas";
import type { Cartao, Grupo } from "@/modules/painel/painel";

const COR: Record<Grupo, { faixa: string; chip: string; rotulo: string }> = {
  urgente: { faixa: "bg-urgente", chip: "bg-urgente-claro text-urgente", rotulo: "Urgente" },
  importante: { faixa: "bg-importante", chip: "bg-importante-claro text-importante", rotulo: "Importante" },
  rotina: { faixa: "bg-rotina", chip: "bg-rotina-claro text-rotina", rotulo: "Rotina" },
};

type Janela = "mensagem" | "registro" | "pago" | "editar" | null;

export function CartaoAcao({
  cartao,
  motivos,
  mostrarGrupo = false,
  compacto = false,
  naFicha = false,
}: {
  cartao: Cartao;
  motivos: Motivo[];
  mostrarGrupo?: boolean;
  compacto?: boolean;
  /** Dentro da ficha do paciente: sem o botão "Abrir paciente". */
  naFicha?: boolean;
}) {
  const [janela, setJanela] = useState<Janela>(null);
  const [pendente, iniciar] = useTransition();
  const cor = COR[cartao.grupo];

  function executar(acao: () => Promise<Retorno>) {
    iniciar(async () => {
      const r = await acao();
      if (r.ok) {
        setJanela(null);
        avisar(r.mensagem);
      } else {
        avisar(r.erro, "erro");
      }
    });
  }

  return (
    <article
      aria-label={cartao.subtitulo ?? cartao.titulo}
      aria-busy={pendente}
      className={`relative overflow-hidden rounded-xl border border-borda bg-superficie transition ${
        pendente ? "opacity-60" : ""
      }`}
    >
      <span className={`absolute inset-y-0 left-0 w-1 ${cor.faixa}`} aria-hidden />
      <div className={compacto ? "py-3.5 pr-4 pl-5" : "py-4 pr-4 pl-5 sm:py-5 sm:pr-5 sm:pl-6"}>
        <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-1">
          <div className="min-w-0">
            <h3 className="text-base font-semibold text-grafite">{cartao.titulo}</h3>
            {cartao.subtitulo && <p className="text-sm font-medium text-grafite">{cartao.subtitulo}</p>}
          </div>
          <div className="flex items-center gap-2">
            {mostrarGrupo && (
              <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${cor.chip}`}>{cor.rotulo}</span>
            )}
            <span
              className={`rounded-full px-2 py-0.5 text-xs ${
                cartao.diasAtraso > 0 ? "bg-urgente-claro text-urgente" : "bg-fundo text-suave"
              }`}
            >
              {cartao.quando}
            </span>
            <button
              type="button"
              onClick={() => setJanela("editar")}
              aria-label="Editar ação"
              title="Editar ação"
              className="rounded-md p-1 text-sutil hover:bg-fundo hover:text-dourado-escuro"
            >
              <Pencil className="size-3.5" />
            </button>
          </div>
        </div>

        {cartao.procedimento && (
          <p className="mt-1 text-sm font-medium text-dourado-escuro">{cartao.procedimento}</p>
        )}
        <p className="mt-1 text-sm text-suave">{cartao.motivo}</p>

        {!compacto && (
          <div className="mt-3 rounded-lg bg-fundo px-3.5 py-2.5">
            <p className="text-[11px] font-semibold tracking-[0.08em] text-sutil uppercase">Ação recomendada</p>
            {/* A tarefa como está gravada (a usuária pode editá-la) e, abaixo, a orientação do sistema. */}
            {!cartao.pagamento && <p className="mt-0.5 text-sm font-medium text-grafite">{cartao.tituloTarefa}</p>}
            <p className={`mt-0.5 text-sm ${cartao.pagamento ? "text-grafite" : "text-suave"}`}>{cartao.acaoRecomendada}</p>
            {cartao.regraNome && <p className="mt-1 text-xs text-sutil">Criada pela regra “{cartao.regraNome}”</p>}
          </div>
        )}
        {compacto && <p className="mt-1 text-sm text-grafite">→ {cartao.pagamento ? cartao.acaoRecomendada : cartao.tituloTarefa}</p>}

        <div className="mt-3 flex flex-wrap gap-2">
          {cartao.botoes.filter((b) => !(naFicha && b === "abrir_paciente")).map((b) => {
            switch (b) {
              case "abrir_paciente":
                return (
                  <BotaoLink key={b} href={`/contatos/${cartao.pessoaId}`} icone={<UserRound className="size-4" />}>
                    Abrir paciente
                  </BotaoLink>
                );
              case "ver_negociacao":
                return (
                  <BotaoLink key={b} href={`/contatos/${cartao.pessoaId}#financeiro`} icone={<UserRound className="size-4" />}>
                    Ver negociação
                  </BotaoLink>
                );
              case "ver_mensagem":
                return (
                  <Botao key={b} onClick={() => setJanela("mensagem")} icone={<MessageCircle className="size-4" />}>
                    Ver mensagem
                  </Botao>
                );
              case "registrar_contato":
                return (
                  <Botao key={b} onClick={() => setJanela("registro")} icone={<Phone className="size-4" />}>
                    Registrar contato
                  </Botao>
                );
              case "concluir":
                return (
                  <Botao
                    key={b}
                    principal
                    disabled={pendente}
                    onClick={() => executar(() => concluirTarefa(cartao.id))}
                    icone={<Check className="size-4" />}
                  >
                    Concluir
                  </Botao>
                );
              case "marcar_pago":
                return (
                  <Botao key={b} principal onClick={() => setJanela("pago")} icone={<HandCoins className="size-4" />}>
                    Marcar como pago
                  </Botao>
                );
            }
          })}
        </div>
      </div>

      <JanelaMensagem cartao={cartao} aberto={janela === "mensagem"} aoFechar={() => setJanela(null)} />
      {janela === "editar" && (
        <JanelaEditar
          cartao={cartao}
          aoFechar={() => setJanela(null)}
          pendente={pendente}
          salvar={(dados) => executar(() => editarTarefa(dados))}
          cancelar={(motivo) => executar(() => cancelarTarefa(cartao.id, motivo))}
        />
      )}
      <JanelaRegistro
        cartao={cartao}
        motivos={motivos}
        aberto={janela === "registro"}
        aoFechar={() => setJanela(null)}
        pendente={pendente}
        enviar={(dados) => executar(() => registrarContato(dados))}
      />
      <Dialogo
        aberto={janela === "pago"}
        aoFechar={() => setJanela(null)}
        titulo="Confirmar pagamento"
        subtitulo={cartao.subtitulo}
      >
        <p className="text-sm text-suave">
          Registrar o recebimento de{" "}
          <strong className="text-grafite">
            {cartao.valorCentavos !== null ? formatarMoeda(cartao.valorCentavos) : "o valor em aberto"}
          </strong>{" "}
          com data de hoje? O lembrete sai da lista automaticamente.
        </p>
        <Rodape>
          <Botao onClick={() => setJanela(null)}>Cancelar</Botao>
          <Botao
            principal
            disabled={pendente || !cartao.parcelaId}
            onClick={() => executar(() => marcarComoPago(cartao.parcelaId!))}
          >
            {pendente ? "Salvando…" : "Confirmar pagamento"}
          </Botao>
        </Rodape>
      </Dialogo>
    </article>
  );
}

// ─── Janela: editar ou cancelar a ação ──────────────────────────────────────

function JanelaEditar({
  cartao,
  aoFechar,
  pendente,
  salvar,
  cancelar,
}: {
  cartao: Cartao;
  aoFechar: () => void;
  pendente: boolean;
  salvar: (dados: { tarefaId: string; titulo: string; venceEm?: string; horario?: string; mensagem?: string }) => void;
  cancelar: (motivo: string) => void;
}) {
  const [titulo, setTitulo] = useState(cartao.tituloTarefa);
  const [venceEm, setVenceEm] = useState(cartao.vence);
  const [horario, setHorario] = useState(cartao.horario?.slice(0, 5) ?? "");
  const [mensagem, setMensagem] = useState(cartao.mensagem ?? "");
  const [cancelando, setCancelando] = useState(false);
  const [motivo, setMotivo] = useState("");

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo="Editar ação" subtitulo={cartao.subtitulo ?? cartao.titulo}>
      {!cancelando ? (
        <>
          <Campo rotulo="O que fazer">
            <input value={titulo} onChange={(e) => setTitulo(e.target.value)} className={CAMPO} />
          </Campo>
          <div className="grid grid-cols-2 gap-3">
            <Campo rotulo="Data">
              <input type="date" value={venceEm} disabled={cartao.pagamento} onChange={(e) => setVenceEm(e.target.value)} className={CAMPO} />
            </Campo>
            <Campo rotulo="Horário (opcional)">
              <input type="time" value={horario} onChange={(e) => setHorario(e.target.value)} className={CAMPO} />
            </Campo>
          </div>
          {cartao.pagamento && <p className="mt-1 text-xs text-sutil">A data do lembrete acompanha o vencimento da parcela.</p>}
          {!cartao.pagamento && !cartao.recusavel && (
            <p className="mt-1 text-xs text-sutil">
              Recuperação de consulta: não pode ser descartada. Registre o resultado do contato (ex.: não tem interesse).
            </p>
          )}
          <Campo rotulo="Mensagem sugerida">
            <textarea rows={4} value={mensagem} onChange={(e) => setMensagem(e.target.value)} className={CAMPO} />
          </Campo>
          <Rodape>
            {cartao.recusavel && (
              <button type="button" onClick={() => setCancelando(true)} className="mr-auto text-sm text-urgente underline-offset-4 hover:underline">
                Não fazer esta ação
              </button>
            )}
            <Botao onClick={aoFechar}>Voltar</Botao>
            <Botao
              principal
              disabled={pendente}
              onClick={() => salvar({ tarefaId: cartao.id, titulo, venceEm: cartao.pagamento ? undefined : venceEm, horario, mensagem })}
            >
              {pendente ? "Salvando…" : "Salvar"}
            </Botao>
          </Rodape>
        </>
      ) : (
        <>
          <p className="text-sm text-suave">
            A ação sai da lista e fica registrada como cancelada. Se esta pessoa estiver em negociação, o sistema vai
            perguntar qual é o próximo passo na rotina de amanhã.
          </p>
          <Campo rotulo="Motivo (opcional)">
            <input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Ex.: já conversamos pessoalmente" className={CAMPO} />
          </Campo>
          <Rodape>
            <Botao onClick={() => setCancelando(false)}>Voltar</Botao>
            <Botao principal disabled={pendente} onClick={() => cancelar(motivo)}>
              {pendente ? "Cancelando…" : "Cancelar a ação"}
            </Botao>
          </Rodape>
        </>
      )}
    </Dialogo>
  );
}

// ─── Janela: mensagem sugerida ──────────────────────────────────────────────

function JanelaMensagem({ cartao, aberto, aoFechar }: { cartao: Cartao; aberto: boolean; aoFechar: () => void }) {
  const [texto, setTexto] = useState(cartao.mensagem ?? "");
  const [copiado, setCopiado] = useState(false);

  async function copiar() {
    try {
      await navigator.clipboard.writeText(texto);
      setCopiado(true);
      setTimeout(() => setCopiado(false), 2000);
    } catch {
      avisar("Não foi possível copiar. Selecione o texto e copie manualmente.", "erro");
    }
  }

  return (
    <Dialogo aberto={aberto} aoFechar={aoFechar} titulo="Mensagem sugerida" subtitulo={cartao.subtitulo ?? cartao.titulo}>
      <label className="block">
        <span className="text-xs text-suave">Você pode ajustar o texto antes de enviar.</span>
        <textarea
          value={texto}
          onChange={(e) => setTexto(e.target.value)}
          rows={6}
          className="mt-1.5 w-full resize-y rounded-lg border border-borda-forte bg-fundo p-3 text-sm leading-relaxed outline-none focus:border-dourado"
        />
      </label>
      <Rodape>
        <Botao onClick={copiar} icone={copiado ? <Check className="size-4" /> : <Copy className="size-4" />}>
          {copiado ? "Copiado" : "Copiar"}
        </Botao>
        {cartao.whatsapp ? (
          <a
            href={linkWhatsApp(cartao.whatsapp, texto)}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black"
          >
            <ExternalLink className="size-4" /> Abrir no WhatsApp
          </a>
        ) : (
          <span className="text-xs text-sutil">Sem WhatsApp cadastrado</span>
        )}
      </Rodape>
      <p className="mt-3 text-xs text-sutil">
        Depois de enviar, use <strong>Registrar contato</strong> para anotar a resposta.
      </p>
    </Dialogo>
  );
}

// ─── Janela: registrar contato ──────────────────────────────────────────────

type Opcao = { valor: DadosRegistro["resultado"]; rotulo: string; ajuda?: string };

const OPCOES: Record<Cartao["registro"], Opcao[]> = {
  venda: [
    { valor: "respondeu_interesse", rotulo: "Respondeu com interesse" },
    { valor: "agendou", rotulo: "Agendou horário", ajuda: "Informe data e horário" },
    { valor: "vai_pensar", rotulo: "Vai pensar" },
    { valor: "pediu_retorno", rotulo: "Pediu retorno em outra data" },
    { valor: "nao_respondeu", rotulo: "Não respondeu" },
    { valor: "fechou", rotulo: "Fechou o tratamento" },
    { valor: "nao_fechou", rotulo: "Não fechou" },
    { valor: "desistiu", rotulo: "Desistiu" },
    { valor: "numero_invalido", rotulo: "Número não funciona" },
    { valor: "nao_contatar", rotulo: "Não quer mais contato" },
    { valor: "outro", rotulo: "Outro" },
  ],
  // Desmarcou, faltou, sem resposta: as cinco respostas possíveis da conversa.
  recuperacao: [
    { valor: "agendou", rotulo: "Remarcou", ajuda: "Informe data e horário" },
    { valor: "pediu_retorno", rotulo: "Pediu para falar depois" },
    { valor: "nao_respondeu", rotulo: "Não respondeu" },
    { valor: "sem_interesse", rotulo: "Não tem interesse" },
    { valor: "outro", rotulo: "Outro" },
  ],
  reativacao: [
    { valor: "respondeu_interesse", rotulo: "Respondeu com interesse" },
    { valor: "agendou", rotulo: "Agendou horário", ajuda: "Informe data e horário" },
    { valor: "pediu_retorno", rotulo: "Pediu para falar depois" },
    { valor: "nao_respondeu", rotulo: "Não respondeu" },
    { valor: "sem_interesse", rotulo: "Não tem interesse" },
    { valor: "nao_contatar", rotulo: "Não quer mais contato" },
    { valor: "outro", rotulo: "Outro" },
  ],
  agendamento: [
    { valor: "confirmou", rotulo: "Confirmou presença" },
    { valor: "nao_respondeu", rotulo: "Não respondeu" },
    { valor: "desmarcou", rotulo: "Desmarcou" },
  ],
  pagamento: [
    { valor: "prometeu_pagar", rotulo: "Combinou pagar em outra data" },
    { valor: "nao_respondeu", rotulo: "Não respondeu" },
    { valor: "numero_invalido", rotulo: "Número não funciona" },
  ],
};

const CANAIS = [
  { valor: "whatsapp", rotulo: "WhatsApp" },
  { valor: "ligacao", rotulo: "Ligação" },
  { valor: "presencial", rotulo: "Presencial" },
] as const;

function JanelaRegistro({
  cartao,
  motivos,
  aberto,
  aoFechar,
  pendente,
  enviar,
}: {
  cartao: Cartao;
  motivos: Motivo[];
  aberto: boolean;
  aoFechar: () => void;
  pendente: boolean;
  enviar: (dados: DadosRegistro) => void;
}) {
  const [resultado, setResultado] = useState<Opcao["valor"] | null>(null);
  const [canal, setCanal] = useState<(typeof CANAIS)[number]["valor"]>("whatsapp");
  const [observacao, setObservacao] = useState("");
  const [data, setData] = useState("");
  const [agendarEm, setAgendarEm] = useState("");
  const [motivoId, setMotivoId] = useState("");
  const [erro, setErro] = useState<string | null>(null);

  const precisaData = resultado === "pediu_retorno" || resultado === "prometeu_pagar";
  const precisaMotivo = resultado === "nao_fechou" || resultado === "desistiu";
  const listaMotivos = motivos.filter((m) => m.aplica_a === resultado);

  function salvar() {
    setErro(null);
    if (!resultado) return setErro("Escolha o que aconteceu.");
    if (resultado === "agendou" && !agendarEm) return setErro("Informe a data e o horário.");
    if (precisaData && !data) return setErro("Informe a data combinada.");
    if (precisaMotivo && !motivoId) return setErro("Escolha o motivo.");
    if (resultado === "outro" && !observacao.trim()) return setErro("Descreva o que aconteceu.");
    enviar({
      tarefaId: cartao.id,
      resultado,
      canal,
      observacao: observacao || undefined,
      data: data || undefined,
      motivoId: motivoId || undefined,
      agendarEm: agendarEm || undefined,
    });
  }

  return (
    <Dialogo aberto={aberto} aoFechar={aoFechar} titulo="Registrar contato" subtitulo={cartao.subtitulo ?? cartao.titulo}>
      <fieldset>
        <legend className="text-sm font-medium">Como foi o contato?</legend>
        <div role="radiogroup" className="mt-2 flex flex-wrap gap-2">
          {CANAIS.map((c) => (
            <Escolha key={c.valor} ativo={canal === c.valor} onClick={() => setCanal(c.valor)}>
              {c.rotulo}
            </Escolha>
          ))}
        </div>
      </fieldset>

      <fieldset className="mt-5">
        <legend className="text-sm font-medium">O que aconteceu?</legend>
        <div role="radiogroup" className="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
          {OPCOES[cartao.registro].map((o) => (
            <Escolha key={o.valor} ativo={resultado === o.valor} onClick={() => setResultado(o.valor)} largo>
              {o.rotulo}
            </Escolha>
          ))}
        </div>
      </fieldset>

      {resultado === "agendou" && (
        <Campo rotulo="Data e horário">
          <input type="datetime-local" value={agendarEm} onChange={(e) => setAgendarEm(e.target.value)} className={CAMPO} />
        </Campo>
      )}
      {precisaMotivo && (
        <>
          <Campo rotulo="Motivo">
            <select value={motivoId} onChange={(e) => setMotivoId(e.target.value)} className={CAMPO}>
              <option value="">Escolha…</option>
              {listaMotivos.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.nome}
                  {m.retorno_sugerido_dias ? ` (voltar a falar em ${m.retorno_sugerido_dias} dias)` : ""}
                </option>
              ))}
            </select>
          </Campo>
          <Campo rotulo="Quando falar de novo? (opcional — se vazio, usamos o prazo do motivo)">
            <input type="date" value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
          </Campo>
        </>
      )}
      {resultado === "outro" && (
        <Campo rotulo="Próximo contato (opcional)">
          <input type="date" value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
        </Campo>
      )}
      {resultado === "nao_respondeu" && (
        <p className="mt-4 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
          O sistema agenda a próxima tentativa conforme a regra. Se as tentativas acabarem, segue o que a regra define
          (por exemplo, mover para “Sem resposta” ou “Reativação”).
        </p>
      )}
      {resultado === "sem_interesse" && (
        <p className="mt-4 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
          A negociação é encerrada com gentileza. Um contato leve fica programado para daqui a alguns meses.
        </p>
      )}
      {precisaData && (
        <Campo rotulo="Data combinada">
          <input type="date" value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
        </Campo>
      )}
      {resultado === "nao_contatar" && (
        <p className="mt-4 rounded-lg bg-importante-claro px-3.5 py-2.5 text-sm text-importante">
          Esta pessoa não receberá mais nenhuma tarefa de contato. Lembretes financeiros continuam.
        </p>
      )}

      <Campo rotulo={resultado === "outro" ? "O que aconteceu?" : "Observação (opcional)"}>
        <textarea
          value={observacao}
          onChange={(e) => setObservacao(e.target.value)}
          rows={2}
          maxLength={1000}
          placeholder="Não registre informações clínicas."
          className={CAMPO}
        />
      </Campo>

      {erro && (
        <p role="alert" className="mt-4 text-sm text-urgente">
          {erro}
        </p>
      )}
      <Rodape>
        <Botao onClick={aoFechar}>Cancelar</Botao>
        <Botao principal disabled={pendente} onClick={salvar}>
          {pendente ? "Salvando…" : "Salvar"}
        </Botao>
      </Rodape>
    </Dialogo>
  );
}

// ─── Peças ──────────────────────────────────────────────────────────────────

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";

function Campo({ rotulo, children }: { rotulo: string; children: ReactNode }) {
  return (
    <label className="mt-4 block">
      <span className="text-sm text-suave">{rotulo}</span>
      {children}
    </label>
  );
}

function Escolha({
  ativo,
  onClick,
  children,
  largo,
}: {
  ativo: boolean;
  onClick: () => void;
  children: ReactNode;
  largo?: boolean;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={ativo}
      onClick={onClick}
      className={`rounded-lg border px-3 py-2 text-sm transition ${largo ? "text-left" : ""} ${
        ativo
          ? "border-dourado bg-dourado-claro font-medium text-dourado-escuro"
          : "border-borda-forte bg-superficie text-grafite hover:border-dourado"
      }`}
    >
      {children}
    </button>
  );
}

function Rodape({ children }: { children: ReactNode }) {
  return <div className="mt-6 flex flex-wrap items-center justify-end gap-2">{children}</div>;
}

function Botao({
  children,
  onClick,
  icone,
  principal,
  disabled,
}: {
  children: ReactNode;
  onClick?: () => void;
  icone?: ReactNode;
  principal?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`inline-flex items-center gap-1.5 rounded-lg px-3.5 py-2 text-sm font-medium transition disabled:opacity-50 ${
        principal
          ? "bg-grafite text-white hover:bg-black"
          : "border border-borda-forte bg-superficie text-grafite hover:border-dourado hover:text-dourado-escuro"
      }`}
    >
      {icone}
      {children}
    </button>
  );
}

function BotaoLink({ href, children, icone }: { href: string; children: ReactNode; icone?: ReactNode }) {
  return (
    <Link
      href={href}
      className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte bg-superficie px-3.5 py-2 text-sm font-medium text-grafite transition hover:border-dourado hover:text-dourado-escuro"
    >
      {icone}
      {children}
    </Link>
  );
}
