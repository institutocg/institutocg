"use client";

import { AlertTriangle, CalendarPlus, ExternalLink, RotateCcw, Search, UserRound, X } from "lucide-react";
import Link from "next/link";
import { cloneElement, useEffect, useId, useState, useTransition, type ReactElement } from "react";
import {
  agendarConsulta,
  buscarPacientes,
  desmarcarConsulta,
  mudarStatusConsulta,
  registrarAtendimento,
  remarcarConsulta,
  type PacienteEncontrado,
  type RetornoAgenda,
} from "@/app/(app)/agenda/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { formatarMoeda } from "@/lib/moeda";
import { linkWhatsApp } from "@/lib/telefone";
import {
  acoesPermitidas,
  COBRANCA,
  descreverPerda,
  DURACOES,
  intervalo,
  prazoRecuperacao,
  SITUACAO_RECUPERACAO,
  STATUS,
  TIPOS,
  type AcaoConsulta,
  type ComoPagou,
  type Consulta,
  type Recuperacao,
  type TipoConsulta,
} from "@/modules/agenda/agenda";

type Opcao = { id: string; nome: string };
type Forma = Opcao & { max_parcelas: number; recebe_na_hora: boolean };

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";

/** Rótulo ligado ao campo por id (o nome acessível não inclui as opções nem a ajuda). */
function Campo({
  rotulo,
  ajuda,
  children,
}: {
  rotulo: string;
  ajuda?: string;
  children: ReactElement<{ id?: string; "aria-describedby"?: string }>;
}) {
  const id = useId();
  return (
    <div className="mt-4">
      <label htmlFor={id} className="text-sm text-suave">
        {rotulo}
      </label>
      {cloneElement(children, { id, "aria-describedby": ajuda ? `${id}-ajuda` : undefined })}
      {ajuda && (
        <span id={`${id}-ajuda`} className="mt-1 block text-xs text-sutil">
          {ajuda}
        </span>
      )}
    </div>
  );
}

function Rodape({ aoFechar, pendente, rotulo, onClick }: { aoFechar: () => void; pendente: boolean; rotulo: string; onClick: () => void }) {
  return (
    <div className="mt-6 flex justify-end gap-2">
      <button type="button" onClick={aoFechar} className="rounded-lg border border-borda-forte px-3.5 py-2 text-sm hover:border-dourado">
        Voltar
      </button>
      <button
        type="button"
        disabled={pendente}
        onClick={onClick}
        className="rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
      >
        {pendente ? "Salvando…" : rotulo}
      </button>
    </div>
  );
}

function Erro({ texto }: { texto: string | null }) {
  return texto ? (
    <p role="alert" className="mt-4 text-sm text-urgente">
      {texto}
    </p>
  ) : null;
}

/** Data/horário iniciais: amanhã (ou segunda) às 09:00. */
function sugestaoInicial(hoje: string) {
  const d = new Date(`${hoje}T12:00:00Z`);
  do d.setUTCDate(d.getUTCDate() + 1);
  while (d.getUTCDay() === 0 || d.getUTCDay() === 6);
  return { data: d.toISOString().slice(0, 10), horario: "09:00" };
}

function CamposHorario({
  data,
  setData,
  horario,
  setHorario,
  duracao,
  setDuracao,
  hoje,
}: {
  data: string;
  setData: (v: string) => void;
  horario: string;
  setHorario: (v: string) => void;
  duracao: string;
  setDuracao: (v: string) => void;
  hoje: string;
}) {
  return (
    <div className="grid grid-cols-2 gap-x-3 sm:grid-cols-3">
      <Campo rotulo="Data">
        <input type="date" min={hoje} value={data} onChange={(e) => setData(e.target.value)} className={CAMPO} />
      </Campo>
      <Campo rotulo="Horário">
        <input type="time" min="08:00" max="18:45" step={900} value={horario} onChange={(e) => setHorario(e.target.value)} className={CAMPO} />
      </Campo>
      <Campo rotulo="Duração">
        <select value={duracao} onChange={(e) => setDuracao(e.target.value)} className={CAMPO}>
          {DURACOES.map((d) => (
            <option key={d} value={d}>
              {d} min
            </option>
          ))}
        </select>
      </Campo>
    </div>
  );
}

function Encaixe({ conflito, encaixe, setEncaixe }: { conflito: boolean; encaixe: boolean; setEncaixe: (v: boolean) => void }) {
  if (!conflito) return null;
  return (
    <label className="mt-3 flex items-center gap-2 rounded-lg bg-importante-claro px-3.5 py-2.5 text-sm text-importante">
      <input type="checkbox" checked={encaixe} onChange={(e) => setEncaixe(e.target.checked)} className="size-4 accent-dourado" />
      Marcar como encaixe mesmo assim
    </label>
  );
}

// ─── Nova consulta ───────────────────────────────────────────────────────────

export function NovaConsulta({
  hoje,
  profissionais,
  procedimentos,
  pacienteInicial,
  dentistaInicial,
}: {
  hoje: string;
  profissionais: Opcao[];
  procedimentos: Opcao[];
  pacienteInicial?: PacienteEncontrado | null;
  dentistaInicial?: string | null;
}) {
  const [aberto, setAberto] = useState(Boolean(pacienteInicial));
  return (
    <>
      <button
        type="button"
        onClick={() => setAberto(true)}
        className="inline-flex items-center gap-1.5 rounded-lg bg-dourado px-4 py-2.5 text-sm font-medium tracking-wide text-white uppercase shadow-sm hover:bg-dourado-escuro"
      >
        <CalendarPlus className="size-4" /> Nova consulta
      </button>
      {aberto && (
        <JanelaNovaConsulta
          hoje={hoje}
          profissionais={profissionais}
          procedimentos={procedimentos}
          pacienteInicial={pacienteInicial ?? null}
          dentistaInicial={dentistaInicial ?? null}
          aoFechar={() => setAberto(false)}
        />
      )}
    </>
  );
}

function JanelaNovaConsulta({
  hoje,
  profissionais,
  procedimentos,
  pacienteInicial,
  dentistaInicial,
  aoFechar,
}: {
  hoje: string;
  profissionais: Opcao[];
  procedimentos: Opcao[];
  pacienteInicial: PacienteEncontrado | null;
  dentistaInicial: string | null;
  aoFechar: () => void;
}) {
  const inicial = sugestaoInicial(hoje);
  const [paciente, setPaciente] = useState<PacienteEncontrado | null>(pacienteInicial);
  const [novo, setNovo] = useState(false);
  const [busca, setBusca] = useState("");
  const [achados, setAchados] = useState<PacienteEncontrado[] | null>(null);
  const [nome, setNome] = useState("");
  const [whatsapp, setWhatsapp] = useState("");
  const [tipoCadastro, setTipoCadastro] = useState<"novo_contato" | "paciente_antigo">("novo_contato");
  const [tipo, setTipo] = useState<TipoConsulta>("avaliacao");
  const [procedimentoId, setProcedimentoId] = useState(pacienteInicial?.procedimento_id ?? "");
  const [data, setData] = useState(inicial.data);
  const [horario, setHorario] = useState(inicial.horario);
  const [duracao, setDuracao] = useState("60");
  const [profissionalId, setProfissionalId] = useState(dentistaInicial ?? profissionais[0]?.id ?? "");
  const [status, setStatus] = useState<"agendado" | "confirmado">("agendado");
  const [observacoes, setObservacoes] = useState("");
  const [valor, setValor] = useState("");
  const [encaixe, setEncaixe] = useState(false);
  const [conflito, setConflito] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const [, buscar] = useTransition();

  useEffect(() => {
    if (paciente || novo || busca.trim().length < 2) return;
    const t = setTimeout(() => buscar(async () => setAchados(await buscarPacientes(busca))), 250);
    return () => clearTimeout(t);
  }, [busca, paciente, novo]);

  function escolher(p: PacienteEncontrado) {
    setPaciente(p);
    setAchados(null);
    if (p.procedimento_id) setProcedimentoId(p.procedimento_id);
  }

  function salvar() {
    setErro(null);
    iniciar(async () => {
      const r: RetornoAgenda = await agendarConsulta({
        pessoaId: paciente?.id ?? "",
        nome: novo ? nome : undefined,
        whatsapp: novo ? whatsapp : undefined,
        tipoCadastro,
        tipo,
        procedimentoId,
        inicio: `${data}T${horario}`,
        duracao,
        profissionalId,
        status,
        observacoes,
        encaixe,
        valor,
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else {
        setErro(r.erro);
        setConflito("conflito" in r);
      }
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo="Nova consulta" subtitulo="A agenda avisa o CRM: confirmação, funil e recuperação acontecem sozinhos.">
      {/* Paciente */}
      {paciente ? (
        <div className="flex items-start justify-between gap-3 rounded-lg bg-dourado-claro px-3.5 py-2.5">
          <div>
            <p className="text-xs text-dourado-escuro">Paciente</p>
            <p className="font-medium">{paciente.nome}</p>
            <p className="text-xs text-suave">
              {[paciente.tipo_cadastro === "paciente_antigo" ? "Paciente antigo" : "Novo contato", paciente.etapa, paciente.procedimento]
                .filter(Boolean)
                .join(" · ")}
            </p>
          </div>
          <button
            type="button"
            onClick={() => {
              setPaciente(null);
              setBusca("");
            }}
            className="rounded-md p-1 text-sutil hover:text-grafite"
            aria-label="Trocar paciente"
          >
            <X className="size-4" />
          </button>
        </div>
      ) : novo ? (
        <fieldset className="rounded-lg border border-borda p-3.5">
          <legend className="px-1 text-sm font-medium">Paciente ainda não cadastrado</legend>
          <Campo rotulo="Nome completo">
            <input value={nome} onChange={(e) => setNome(e.target.value)} className={CAMPO} />
          </Campo>
          <Campo rotulo="WhatsApp" ajuda="Se o número já estiver cadastrado, usamos o cadastro existente.">
            <input value={whatsapp} onChange={(e) => setWhatsapp(e.target.value)} inputMode="tel" placeholder="(11) 90000-0000" className={CAMPO} />
          </Campo>
          <div role="radiogroup" aria-label="Tipo de cadastro" className="mt-3 flex gap-2">
            {(["novo_contato", "paciente_antigo"] as const).map((t) => (
              <button
                key={t}
                type="button"
                role="radio"
                aria-checked={tipoCadastro === t}
                onClick={() => setTipoCadastro(t)}
                className={`rounded-lg border px-3 py-1.5 text-sm ${tipoCadastro === t ? "border-dourado bg-dourado-claro" : "border-borda-forte"}`}
              >
                {t === "novo_contato" ? "Novo contato" : "Paciente antigo"}
              </button>
            ))}
          </div>
          <button type="button" onClick={() => setNovo(false)} className="mt-3 text-sm text-dourado-escuro underline">
            Buscar um paciente cadastrado
          </button>
        </fieldset>
      ) : (
        <div>
          <label className="block">
            <span className="text-sm text-suave">Paciente</span>
            <span className="relative mt-1.5 block">
              <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-sutil" />
              <input
                value={busca}
                onChange={(e) => setBusca(e.target.value)}
                placeholder="Digite o nome ou o telefone"
                className={`${CAMPO} mt-0 pl-8`}
                autoFocus
              />
            </span>
          </label>
          {achados && busca.trim().length >= 2 && (
            <ul aria-label="Pacientes encontrados" className="mt-2 divide-y divide-borda rounded-lg border border-borda">
              {achados.map((p) => (
                <li key={p.id}>
                  <button type="button" onClick={() => escolher(p)} className="w-full px-3.5 py-2 text-left text-sm hover:bg-fundo">
                    <span className="font-medium">{p.nome}</span>
                    <span className="block text-xs text-sutil">
                      {[p.tipo_cadastro === "paciente_antigo" ? "Paciente antigo" : "Novo contato", p.etapa, p.procedimento]
                        .filter(Boolean)
                        .join(" · ")}
                    </span>
                  </button>
                </li>
              ))}
              {achados.length === 0 && <li className="px-3.5 py-2 text-sm text-sutil">Nenhum paciente encontrado.</li>}
            </ul>
          )}
          <button
            type="button"
            onClick={() => {
              setNovo(true);
              setNome(busca.replace(/\d/g, "").trim());
            }}
            className="mt-2 text-sm text-dourado-escuro underline"
          >
            Paciente ainda não cadastrado
          </button>
        </div>
      )}

      <div className="grid gap-x-3 sm:grid-cols-2">
        <Campo rotulo="Tipo de consulta">
          <select value={tipo} onChange={(e) => setTipo(e.target.value as TipoConsulta)} className={CAMPO}>
            {(Object.keys(TIPOS) as TipoConsulta[]).map((t) => (
              <option key={t} value={t}>
                {TIPOS[t]}
              </option>
            ))}
          </select>
        </Campo>
        <Campo rotulo="Procedimento">
          <select value={procedimentoId} onChange={(e) => setProcedimentoId(e.target.value)} className={CAMPO}>
            <option value="">Ainda não definido</option>
            {procedimentos.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
      </div>
      <Campo rotulo="Valor do procedimento (opcional)" ajuda="Fica pronto para registrar o pagamento quando o paciente comparecer.">
        <input value={valor} onChange={(e) => setValor(e.target.value)} inputMode="decimal" placeholder="Ex.: 1.500,00" className={CAMPO} />
      </Campo>
      <CamposHorario data={data} setData={setData} horario={horario} setHorario={setHorario} duracao={duracao} setDuracao={setDuracao} hoje={hoje} />
      <div className="grid gap-x-3 sm:grid-cols-2">
        <Campo rotulo="Dentista">
          <select value={profissionalId} onChange={(e) => setProfissionalId(e.target.value)} className={CAMPO}>
            {profissionais.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
        <Campo rotulo="Status" ajuda={status === "agendado" ? "O sistema lembra de confirmar na véspera." : undefined}>
          <select value={status} onChange={(e) => setStatus(e.target.value as "agendado" | "confirmado")} className={CAMPO}>
            <option value="agendado">Agendado</option>
            <option value="confirmado">Já confirmado</option>
          </select>
        </Campo>
      </div>
      <Campo rotulo="Observação (opcional)">
        <input value={observacoes} onChange={(e) => setObservacoes(e.target.value)} maxLength={500} placeholder="Não registre informações clínicas." className={CAMPO} />
      </Campo>

      <Encaixe conflito={conflito} encaixe={encaixe} setEncaixe={setEncaixe} />
      <Erro texto={erro} />
      <Rodape aoFechar={aoFechar} pendente={pendente} rotulo="Marcar consulta" onClick={salvar} />
    </Dialogo>
  );
}

// ─── Consulta: cartão e ações ────────────────────────────────────────────────

export function CartaoConsulta({
  consulta: c,
  hoje,
  motivos,
  profissionais,
  formas,
  podeVerFinanceiro,
  mostrarDentista = false,
}: {
  consulta: Consulta;
  hoje: string;
  motivos: Opcao[];
  profissionais: Opcao[];
  formas: Forma[];
  podeVerFinanceiro: boolean;
  mostrarDentista?: boolean;
}) {
  const [aberto, setAberto] = useState(false);
  const st = STATUS[c.status];
  const perdida = c.status === "desmarcado" || c.status === "faltou" || c.status === "cancelado_clinica";
  const encerrada = perdida || c.status === "remarcado";
  return (
    <>
      <button
        type="button"
        onClick={() => setAberto(true)}
        aria-label={`${c.horario} ${c.pessoa_nome}`}
        className={`w-full rounded-lg border bg-superficie px-3 py-2.5 text-left transition hover:border-dourado ${
          c.recuperacao === "a_recuperar" || c.recuperacao === "sem_acao" ? "border-urgente/40" : "border-borda"
        } ${encerrada ? "opacity-75" : ""}`}
        style={{ borderLeftWidth: 3, borderLeftColor: c.profissional_cor ?? "#B08D57" }}
      >
        <span className="flex items-center justify-between gap-2">
          <span className="text-xs font-medium text-suave tabular-nums">{intervalo(c.horario, c.duracao_min)}</span>
          <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${st.classe}`}>{st.rotulo}</span>
        </span>
        <span className={`mt-0.5 block text-sm font-semibold ${encerrada ? "line-through decoration-sutil" : ""}`}>{c.pessoa_nome}</span>
        <span className="block text-xs text-sutil">{[TIPOS[c.tipo], c.procedimento].filter(Boolean).join(" · ")}</span>
        {mostrarDentista && c.profissional && (
          <span className="mt-0.5 flex items-center gap-1 text-[11px] text-suave">
            <span className="size-2 rounded-full" style={{ backgroundColor: c.profissional_cor ?? "#B08D57" }} aria-hidden />
            {c.profissional}
          </span>
        )}
        {podeVerFinanceiro && (c.cobranca || (c.valor_centavos && !encerrada)) && (
          <span className={`mt-0.5 block text-[11px] font-medium ${c.cobranca ? COBRANCA[c.cobranca].classe : "text-suave"}`}>
            {c.valor_centavos ? formatarMoeda(c.valor_centavos) : ""}
            {c.cobranca ? `${c.valor_centavos ? " · " : ""}${COBRANCA[c.cobranca].rotulo}` : ""}
          </span>
        )}
        {perdida && c.recuperacao && (
          <span
            className={`mt-1 inline-block text-[11px] font-medium ${
              c.recuperacao === "recuperado" ? "text-rotina" : c.recuperacao === "encerrado" ? "text-sutil" : "text-urgente"
            }`}
          >
            {SITUACAO_RECUPERACAO[c.recuperacao]}
          </span>
        )}
      </button>
      {aberto && (
        <JanelaConsulta
          c={c}
          hoje={hoje}
          motivos={motivos}
          profissionais={profissionais}
          formas={formas}
          podeVerFinanceiro={podeVerFinanceiro}
          aoFechar={() => setAberto(false)}
        />
      )}
    </>
  );
}

const ROTULO_ACAO: Record<AcaoConsulta, string> = {
  confirmar: "Confirmar presença",
  compareceu: "Compareceu",
  faltou: "Faltou",
  desmarcar: "Desmarcou",
  remarcar: "Remarcar",
  cancelar: "Cancelar (clínica)",
};

function JanelaConsulta({
  c,
  hoje,
  motivos,
  profissionais,
  formas,
  podeVerFinanceiro,
  aoFechar,
}: {
  c: Consulta;
  hoje: string;
  motivos: Opcao[];
  profissionais: Opcao[];
  formas: Forma[];
  podeVerFinanceiro: boolean;
  aoFechar: () => void;
}) {
  const [acao, setAcao] = useState<AcaoConsulta | "pagamento" | null>(null);
  // Sem cobrança registrada para quem já compareceu: dá para registrar depois.
  const semPagamento = podeVerFinanceiro && c.status === "compareceu" && !c.cobranca;
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const acoes = acoesPermitidas(c, hoje);
  const quando = `${c.dia.split("-").reverse().join("/")} · ${intervalo(c.horario, c.duracao_min)}`;

  function direto(status: "confirmado" | "compareceu" | "faltou") {
    setErro(null);
    iniciar(async () => {
      const r = await mudarStatusConsulta({ agendamentoId: c.id, status });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  return (
    <Dialogo aberto aoFechar={aoFechar} titulo={c.pessoa_nome} subtitulo={`${TIPOS[c.tipo]} · ${quando}`}>
      <dl className="grid grid-cols-2 gap-3 text-sm">
        <div>
          <dt className="text-xs text-sutil">Status</dt>
          <dd>
            <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS[c.status].classe}`}>{STATUS[c.status].rotulo}</span>
          </dd>
        </div>
        <div>
          <dt className="text-xs text-sutil">Procedimento</dt>
          <dd>{c.procedimento ?? "Não definido"}</dd>
        </div>
        <div>
          <dt className="text-xs text-sutil">Dentista</dt>
          <dd>{c.profissional ?? "—"}</dd>
        </div>
        {podeVerFinanceiro && (c.valor_centavos || c.cobranca) && (
          <div>
            <dt className="text-xs text-sutil">Valor</dt>
            <dd>
              {c.valor_centavos ? formatarMoeda(c.valor_centavos) : "—"}
              {c.cobranca && <span className={`ml-1.5 text-xs font-medium ${COBRANCA[c.cobranca].classe}`}>{COBRANCA[c.cobranca].rotulo}</span>}
            </dd>
          </div>
        )}
        {c.motivo && (
          <div>
            <dt className="text-xs text-sutil">Motivo</dt>
            <dd>{c.motivo}</dd>
          </div>
        )}
        {c.observacoes && (
          <div className="col-span-2">
            <dt className="text-xs text-sutil">Observação</dt>
            <dd>{c.observacoes}</dd>
          </div>
        )}
      </dl>

      {!acao && (
        <>
          {acoes.length > 0 ? (
            <div className="mt-5 grid grid-cols-2 gap-2">
              {acoes.map((a) => (
                <button
                  key={a}
                  type="button"
                  disabled={pendente}
                  onClick={() =>
                    a === "confirmar"
                      ? direto("confirmado")
                      : a === "compareceu"
                        ? podeVerFinanceiro
                          ? setAcao("compareceu")
                          : direto("compareceu")
                        : a === "faltou"
                          ? direto("faltou")
                          : setAcao(a)
                  }
                  className={`rounded-lg border px-3 py-2 text-sm font-medium disabled:opacity-50 ${
                    a === "desmarcar" || a === "faltou"
                      ? "border-urgente/40 text-urgente hover:bg-urgente-claro"
                      : "border-borda-forte hover:border-dourado"
                  }`}
                >
                  {ROTULO_ACAO[a]}
                </button>
              ))}
            </div>
          ) : semPagamento ? null : (
            <p className="mt-5 text-sm text-sutil">Nenhuma ação disponível para esta consulta.</p>
          )}
          {semPagamento && (
            <button
              type="button"
              onClick={() => setAcao("pagamento")}
              className="mt-5 w-full rounded-lg border border-borda-forte px-3 py-2 text-sm font-medium hover:border-dourado"
            >
              Registrar pagamento
            </button>
          )}
          <div className="mt-4 flex flex-wrap gap-3 text-sm">
            <Link href={`/contatos/${c.pessoa_id}`} className="inline-flex items-center gap-1 text-dourado-escuro underline">
              <UserRound className="size-4" /> Abrir paciente
            </Link>
          </div>
          <Erro texto={erro} />
        </>
      )}

      {(acao === "compareceu" || acao === "pagamento") && (
        <FormCompareceu c={c} formas={formas} hoje={hoje} soPagamento={acao === "pagamento"} aoVoltar={() => setAcao(null)} aoConcluir={aoFechar} />
      )}
      {acao === "desmarcar" && <FormDesmarcar c={c} motivos={motivos} aoVoltar={() => setAcao(null)} aoConcluir={aoFechar} />}
      {acao === "remarcar" && (
        <FormRemarcar
          agendamentoId={c.id}
          duracaoAtual={c.duracao_min}
          profissionalAtual={c.profissional_id}
          hoje={hoje}
          profissionais={profissionais}
          aoVoltar={() => setAcao(null)}
          aoConcluir={aoFechar}
        />
      )}
      {acao === "cancelar" && <FormCancelar c={c} aoVoltar={() => setAcao(null)} aoConcluir={aoFechar} />}
    </Dialogo>
  );
}

const OPCOES_PAGAMENTO: { id: ComoPagou; rotulo: string; ajuda: string }[] = [
  { id: "pago", rotulo: "Pagou agora", ajuda: "Entra no Financeiro como pago." },
  { id: "a_pagar", rotulo: "Vai pagar depois", ajuda: "Data prevista e parcelas: o sistema lembra no dia e avisa se atrasar." },
  { id: "ja_registrado", rotulo: "Já está no Financeiro", ajuda: "O pagamento foi registrado antes (ao fechar no funil, por exemplo)." },
  { id: "sem_cobranca", rotulo: "Sem cobrança", ajuda: "Avaliação gratuita, cortesia, retorno incluso…" },
];

/** "Compareceu": registra a presença e, no mesmo passo, como ficou o pagamento. */
function FormCompareceu({
  c,
  formas,
  hoje,
  soPagamento,
  aoVoltar,
  aoConcluir,
}: {
  c: Consulta;
  formas: Forma[];
  hoje: string;
  soPagamento: boolean;
  aoVoltar: () => void;
  aoConcluir: () => void;
}) {
  const [como, setComo] = useState<ComoPagou>(c.negociacao_registrada ? "ja_registrado" : "pago");
  const [valor, setValor] = useState(c.valor_centavos ? formatarMoeda(c.valor_centavos).replace("R$ ", "") : "");
  const [formaId, setFormaId] = useState("");
  const [vencimento, setVencimento] = useState("");
  const [parcelas, setParcelas] = useState("1");
  const [observacao, setObservacao] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  const forma = formas.find((f) => f.id === formaId);
  const cobra = como === "pago" || como === "a_pagar";
  const opcoes = OPCOES_PAGAMENTO.filter((o) => o.id !== "ja_registrado" || c.negociacao_registrada);
  const podeParcelar = forma ? forma.max_parcelas > 1 && (como === "a_pagar" || forma.recebe_na_hora) : como === "a_pagar";

  function salvar() {
    setErro(null);
    iniciar(async () => {
      const r = await registrarAtendimento({
        agendamentoId: c.id,
        como,
        valor,
        formaId,
        vencimento,
        parcelas: podeParcelar ? parcelas : "1",
        observacao,
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoConcluir();
      } else setErro(r.erro);
    });
  }

  return (
    <div className="mt-5 border-t border-borda pt-4">
      <p className="text-sm font-medium">{soPagamento ? "Registrar pagamento" : "Compareceu — como ficou o pagamento?"}</p>
      {c.negociacao_registrada && (
        <p className="mt-2 rounded-lg bg-fundo px-3 py-2 text-xs text-suave">
          Já registrado no Financeiro: <strong className="text-grafite">{c.negociacao_registrada}</strong>
        </p>
      )}
      <div role="radiogroup" aria-label="Pagamento" className="mt-3 grid gap-2 sm:grid-cols-2">
        {opcoes.map((o) => (
          <button
            key={o.id}
            type="button"
            role="radio"
            aria-checked={como === o.id}
            onClick={() => setComo(o.id)}
            className={`rounded-lg border px-3 py-2 text-left text-sm ${como === o.id ? "border-dourado bg-dourado-claro" : "border-borda-forte hover:border-dourado"}`}
          >
            <span className="font-medium">{o.rotulo}</span>
            <span className="block text-xs text-sutil">{o.ajuda}</span>
          </button>
        ))}
      </div>

      {cobra && (
        <>
          <div className="grid gap-x-3 sm:grid-cols-2">
            <Campo rotulo="Valor">
              <input value={valor} onChange={(e) => setValor(e.target.value)} inputMode="decimal" placeholder="Ex.: 1.500,00" className={CAMPO} />
            </Campo>
            <Campo rotulo="Forma de pagamento">
              <select value={formaId} onChange={(e) => setFormaId(e.target.value)} className={CAMPO}>
                <option value="">Escolha…</option>
                {formas.map((f) => (
                  <option key={f.id} value={f.id}>
                    {f.nome}
                  </option>
                ))}
              </select>
            </Campo>
          </div>
          {forma?.recebe_na_hora ? (
            <p className="mt-2 text-xs text-sutil">Cartão é recebido na hora: entra como pago, sem lembretes.</p>
          ) : (
            como === "a_pagar" && (
              <Campo rotulo={Number(parcelas) > 1 ? "Data prevista do 1º pagamento" : "Data prevista do pagamento"} ajuda="No dia, o lembrete aparece no painel; se passar, vira pagamento atrasado.">
                <input type="date" min={hoje} value={vencimento} onChange={(e) => setVencimento(e.target.value)} className={CAMPO} />
              </Campo>
            )
          )}
          {podeParcelar && (
            <Campo rotulo="Parcelas" ajuda={Number(parcelas) > 1 && !forma?.recebe_na_hora ? "Uma por mês, a partir da data prevista." : undefined}>
              <input type="number" min={1} max={forma?.max_parcelas ?? 60} value={parcelas} onChange={(e) => setParcelas(e.target.value)} className={CAMPO} />
            </Campo>
          )}
          <Campo rotulo="Observação (opcional)">
            <input value={observacao} onChange={(e) => setObservacao(e.target.value)} maxLength={300} className={CAMPO} />
          </Campo>
        </>
      )}
      <Erro texto={erro} />
      <Rodape aoFechar={aoVoltar} pendente={pendente} rotulo={soPagamento ? "Registrar pagamento" : "Registrar presença"} onClick={salvar} />
    </div>
  );
}

function FormDesmarcar({ c, motivos, aoVoltar, aoConcluir }: { c: Consulta; motivos: Opcao[]; aoVoltar: () => void; aoConcluir: () => void }) {
  const [motivoId, setMotivoId] = useState("");
  const [observacao, setObservacao] = useState("");
  const [contatoEm, setContatoEm] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  return (
    <div className="mt-5 border-t border-borda pt-4">
      <p className="text-sm font-medium">Registrar desmarcação</p>
      <Campo rotulo="Motivo">
        <select value={motivoId} onChange={(e) => setMotivoId(e.target.value)} className={CAMPO}>
          <option value="">Escolha…</option>
          {motivos.map((m) => (
            <option key={m.id} value={m.id}>
              {m.nome}
            </option>
          ))}
        </select>
      </Campo>
      <Campo rotulo="Observação (opcional)">
        <input value={observacao} onChange={(e) => setObservacao(e.target.value)} maxLength={300} className={CAMPO} />
      </Campo>
      <Campo rotulo="Combinou falar em outra data? (opcional)" ajuda="Se vazio, o contato para remarcar fica para o dia seguinte.">
        <input type="date" value={contatoEm} onChange={(e) => setContatoEm(e.target.value)} className={CAMPO} />
      </Campo>
      <p className="mt-4 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
        O sistema registra no histórico, cria a tarefa “Entrar em contato com {c.pessoa_nome.split(" ")[0]} para remarcar” e sugere
        a mensagem de remarcação. A tarefa aparece em “O que eu tenho que fazer hoje” na data definida.
      </p>
      <Erro texto={erro} />
      <Rodape
        aoFechar={aoVoltar}
        pendente={pendente}
        rotulo="Registrar desmarcação"
        onClick={() => {
          setErro(null);
          if (!motivoId) return setErro("Escolha o motivo.");
          iniciar(async () => {
            const r = await desmarcarConsulta({ agendamentoId: c.id, motivoId, observacao, contatoEm });
            if (r.ok) {
              avisar(r.mensagem);
              aoConcluir();
            } else setErro(r.erro);
          });
        }}
      />
    </div>
  );
}

function FormCancelar({ c, aoVoltar, aoConcluir }: { c: Consulta; aoVoltar: () => void; aoConcluir: () => void }) {
  const [motivo, setMotivo] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  return (
    <div className="mt-5 border-t border-borda pt-4">
      <p className="text-sm font-medium">Cancelar pela clínica</p>
      <Campo rotulo="Motivo do cancelamento" ajuda="Ex.: agenda da doutora. O sistema cria a tarefa para remarcar, com pedido de desculpas.">
        <input value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={300} className={CAMPO} />
      </Campo>
      <Erro texto={erro} />
      <Rodape
        aoFechar={aoVoltar}
        pendente={pendente}
        rotulo="Cancelar consulta"
        onClick={() => {
          setErro(null);
          if (!motivo.trim()) return setErro("Informe o motivo do cancelamento.");
          iniciar(async () => {
            const r = await mudarStatusConsulta({ agendamentoId: c.id, status: "cancelado_clinica", observacao: motivo });
            if (r.ok) {
              avisar(r.mensagem);
              aoConcluir();
            } else setErro(r.erro);
          });
        }}
      />
    </div>
  );
}

function FormRemarcar({
  agendamentoId,
  duracaoAtual,
  profissionalAtual,
  hoje,
  profissionais,
  aoVoltar,
  aoConcluir,
}: {
  agendamentoId: string;
  duracaoAtual: number;
  profissionalAtual: string | null;
  hoje: string;
  profissionais: Opcao[];
  aoVoltar: () => void;
  aoConcluir: () => void;
}) {
  const inicial = sugestaoInicial(hoje);
  const [data, setData] = useState(inicial.data);
  const [horario, setHorario] = useState(inicial.horario);
  const [duracao, setDuracao] = useState(String(duracaoAtual));
  const [profissionalId, setProfissionalId] = useState(profissionalAtual ?? profissionais[0]?.id ?? "");
  const [encaixe, setEncaixe] = useState(false);
  const [conflito, setConflito] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [pendente, iniciar] = useTransition();
  return (
    <div className="mt-5 border-t border-borda pt-4">
      <p className="text-sm font-medium">Nova data</p>
      <CamposHorario data={data} setData={setData} horario={horario} setHorario={setHorario} duracao={duracao} setDuracao={setDuracao} hoje={hoje} />
      {profissionais.length > 1 && (
        <Campo rotulo="Dentista">
          <select value={profissionalId} onChange={(e) => setProfissionalId(e.target.value)} className={CAMPO}>
            {profissionais.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
      )}
      <p className="mt-4 rounded-lg bg-fundo px-3.5 py-2.5 text-sm text-suave">
        A agenda é atualizada, a tarefa antiga é encerrada e a confirmação da nova data é criada sozinha.
      </p>
      <Encaixe conflito={conflito} encaixe={encaixe} setEncaixe={setEncaixe} />
      <Erro texto={erro} />
      <Rodape
        aoFechar={aoVoltar}
        pendente={pendente}
        rotulo="Remarcar"
        onClick={() => {
          setErro(null);
          iniciar(async () => {
            const r = await remarcarConsulta({ agendamentoId, inicio: `${data}T${horario}`, duracao, profissionalId, encaixe });
            if (r.ok) {
              avisar(r.mensagem);
              aoConcluir();
            } else {
              setErro(r.erro);
              setConflito("conflito" in r);
            }
          });
        }}
      />
    </div>
  );
}

// ─── Pacientes a recuperar ───────────────────────────────────────────────────

export function CartaoRecuperacao({ r, hoje, profissionais }: { r: Recuperacao; hoje: string; profissionais: Opcao[] }) {
  const [remarcando, setRemarcando] = useState(false);
  const semAcao = r.situacao === "sem_acao";
  const prazo = prazoRecuperacao(r.situacao === "acompanhando" ? r.proxima_acao_em : r.tarefa_vence_em, hoje);
  return (
    <li
      aria-label={r.pessoa_nome}
      className={`rounded-xl border bg-superficie p-4 ${semAcao ? "border-urgente" : r.situacao === "a_recuperar" ? "border-urgente/30" : "border-borda"}`}
    >
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <Link href={`/contatos/${r.pessoa_id}`} className="font-semibold hover:underline">
            {r.pessoa_nome}
          </Link>
          <p className="text-sm text-suave">
            {descreverPerda(r)}
            {r.procedimento ? ` · ${r.procedimento}` : ""}
          </p>
          {(r.motivo || r.observacoes) && (
            <p className="text-xs text-sutil">{[r.motivo && `Motivo: ${r.motivo.toLowerCase()}`, r.observacoes].filter(Boolean).join(" · ")}</p>
          )}
        </div>
        <span
          className={`rounded-full px-2 py-0.5 text-xs font-medium ${
            semAcao || prazo.atrasada ? "bg-urgente-claro text-urgente" : "bg-importante-claro text-importante"
          }`}
        >
          {semAcao ? "Sem ação!" : prazo.texto}
        </span>
      </div>

      <p className="mt-2 text-sm">
        {semAcao ? (
          <span className="flex items-center gap-1.5 text-urgente">
            <AlertTriangle className="size-4" /> Nenhuma ação programada — a rotina de hoje cria a recuperação.
          </span>
        ) : r.situacao === "a_recuperar" ? (
          <>→ {r.tarefa_titulo}</>
        ) : (
          <span className="text-suave">
            {r.desfecho ? `${r.desfecho}. ` : ""}Próxima ação: {r.proxima_acao}
          </span>
        )}
      </p>

      <div className="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          onClick={() => setRemarcando(true)}
          className="inline-flex items-center gap-1.5 rounded-lg bg-grafite px-3 py-1.5 text-sm font-medium text-white hover:bg-black"
        >
          <RotateCcw className="size-4" /> Remarcar
        </button>
        {r.whatsapp && (
          <a
            href={linkWhatsApp(r.whatsapp, r.mensagem_sugerida ?? undefined)}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
          >
            <ExternalLink className="size-4" /> WhatsApp com mensagem
          </a>
        )}
        <Link
          href={`/contatos/${r.pessoa_id}`}
          className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
        >
          <UserRound className="size-4" /> Abrir paciente
        </Link>
      </div>
      {r.mensagem_sugerida && r.situacao === "a_recuperar" && (
        <details className="mt-2 text-sm">
          <summary className="cursor-pointer text-dourado-escuro">Ver mensagem de remarcação</summary>
          <p className="mt-2 rounded-lg bg-fundo px-3.5 py-2.5 text-suave">{r.mensagem_sugerida}</p>
        </details>
      )}
      {remarcando && (
        <Dialogo aberto aoFechar={() => setRemarcando(false)} titulo={`Remarcar ${r.pessoa_nome}`} subtitulo={descreverPerda(r)}>
          <FormRemarcar
            agendamentoId={r.agendamento_id}
            duracaoAtual={r.duracao_min}
            profissionalAtual={r.profissional_id}
            hoje={hoje}
            profissionais={profissionais}
            aoVoltar={() => setRemarcando(false)}
            aoConcluir={() => setRemarcando(false)}
          />
        </Dialogo>
      )}
    </li>
  );
}
