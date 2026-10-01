import {
  ArrowLeft,
  CalendarClock,
  CircleCheck,
  CircleDot,
  ClipboardList,
  ExternalLink,
  LifeBuoy,
  Pencil,
  Phone,
} from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import type { ReactNode } from "react";
import { z } from "zod";
import { AbrirNegociacao, BotaoResgate, ConcluirTratamento } from "@/components/contatos/acoes-ficha";
import { CartaoAcao } from "@/components/painel/cartao-acao";
import { comoUsuaria } from "@/lib/db";
import { formatarMoeda } from "@/lib/moeda";
import { formatarTelefone, linkWhatsApp } from "@/lib/telefone";
import { rotuloUltimoAtendimento } from "@/modules/contatos/cadastro";
import { resumoComercial } from "@/modules/contatos/resumo";
import { carregarFicha, carregarOpcoes, type Ficha } from "@/modules/contatos/servidor";
import { carregarMotivos } from "@/modules/painel/consultas";
import { montarCartao, rotuloData } from "@/modules/painel/painel";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Paciente · Instituto CG" };

const RELACIONAMENTO = {
  lead: { rotulo: "Novo contato", classe: "bg-dourado-claro text-dourado-escuro" },
  paciente_ativo: { rotulo: "Paciente ativo", classe: "bg-rotina-claro text-rotina" },
  paciente_inativo: { rotulo: "Paciente inativo", classe: "bg-importante-claro text-importante" },
} as const;

const STATUS: Record<string, string> = {
  em_negociacao: "Negociação em andamento",
  sem_resposta: "Sem resposta",
  em_tratamento: "Em tratamento",
  sem_negociacao: "Sem negociação",
  nao_contatar: "Não quer contato",
  arquivado: "Arquivado",
};

const TEMPERATURA: Record<string, string> = { quente: "🔥 Quente", morna: "Morna", fria: "Fria" };

const EVENTO: Record<string, string> = {
  whatsapp: "WhatsApp",
  ligacao: "Ligação",
  email: "E-mail",
  instagram: "Instagram",
  atendimento: "Atendimento",
  orcamento_enviado: "Orçamento enviado",
  retorno_solicitado: "Pediu retorno",
  paciente_respondeu: "Respondeu",
  paciente_nao_respondeu: "Não respondeu",
  paciente_desmarcou: "Desmarcou",
  paciente_faltou: "Faltou",
  paciente_fechou: "Fechou",
  paciente_recusou: "Recusou",
  pagamento_recebido: "Pagamento recebido",
  nota: "Anotação",
  outro: "Contato",
};

const RESULTADO: Record<string, string> = {
  fechou: "Fechou",
  nao_fechou: "Não fechou",
  desistiu: "Desistiu",
  sem_resposta: "Sem resposta",
};

const SITUACAO_PARCELA: Record<string, { rotulo: string; classe: string }> = {
  paga: { rotulo: "Paga", classe: "text-rotina" },
  atrasada: { rotulo: "Atrasada", classe: "text-urgente font-medium" },
  vence_hoje: { rotulo: "Vence hoje", classe: "text-importante font-medium" },
  a_vencer: { rotulo: "A vencer", classe: "text-suave" },
  cancelada: { rotulo: "Cancelada", classe: "text-sutil line-through" },
  renegociada: { rotulo: "Renegociada", classe: "text-sutil" },
};

const SECOES = [
  ["proxima-acao", "Próxima ação"],
  ["funil", "Funil"],
  ["interesse", "Interesse"],
  ["dados", "Dados"],
  ["historico", "Histórico"],
  ["financeiro", "Financeiro"],
  ["tarefas", "Tarefas"],
] as const;

export default async function FichaPaciente({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ novo?: string; salvo?: string }>;
}) {
  const { id } = await params;
  const aviso = await searchParams;
  if (!z.uuid().safeParse(id).success) notFound();
  const sessao = await exigirSessao();

  const dados = await comoUsuaria(sessao.usuarioId, async (db) => {
    const ficha = await carregarFicha(db, sessao, id);
    if (!ficha) return null;
    const [motivos, opcoes] = await Promise.all([carregarMotivos(db, sessao.clinicaId), carregarOpcoes(db, sessao.clinicaId)]);
    return { ficha, motivos, procedimentos: opcoes.procedimentos };
  });
  if (!dados) notFound();
  const { ficha, motivos, procedimentos } = dados;
  const c = ficha.contato;
  const fone = c.whatsapp_e164 ?? c.telefone_e164;
  const rel = RELACIONAMENTO[c.relacionamento];
  const cartao = ficha.proximaTarefa ? montarCartao(ficha.proximaTarefa, ficha.hoje) : null;
  const resumo = resumoComercial(c, ficha.hoje, ficha.tratamentos[0]?.procedimento);
  const antigo = c.tipo_cadastro === "paciente_antigo" || c.relacionamento !== "lead";
  const manutencao = ficha.tratamentos.find((t) => t.ciclo_retorno_meses);
  // Manutenção devida: tratamento com ciclo de retorno cujo prazo já passou (ou sem data conhecida).
  const manutencaoDevida = ficha.tratamentos.find(
    (t) => t.ciclo_retorno_meses && (!t.realizado_em || somarMeses(t.realizado_em, t.ciclo_retorno_meses) <= ficha.hoje),
  );
  // Resgate só faz sentido para quem está inativo ou com manutenção vencida — nunca para quem está em tratamento.
  const podeResgatar =
    !c.oportunidade_id && !c.nao_contatar && !c.em_tratamento && !ficha.resgatePendente &&
    (c.relacionamento === "paciente_inativo" || Boolean(manutencaoDevida));

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-8 lg:py-10">
      <Link href="/contatos" className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Contatos
      </Link>

      {aviso.novo && (
        <Faixa>
          Cadastro criado. {c.etapa_atual ? `Já está no funil em “${c.etapa_atual}”. ` : ""}
          {c.proxima_acao ? `Próxima ação: ${c.proxima_acao} — ${rotuloData(c.proxima_acao_em!, ficha.hoje).toLowerCase()}.` : ""}
        </Faixa>
      )}
      {aviso.salvo && <Faixa>Alterações salvas.</Faixa>}

      {/* Cabeçalho */}
      <header className="mt-6 flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${rel.classe}`}>{rel.rotulo}</span>
            <span className="rounded-full bg-fundo px-2.5 py-0.5 text-xs text-suave ring-1 ring-borda">{STATUS[c.status_atual]}</span>
            {c.temperatura && (
              <span className="rounded-full bg-fundo px-2.5 py-0.5 text-xs text-suave ring-1 ring-borda">{TEMPERATURA[c.temperatura]}</span>
            )}
          </div>
          <h1 className="mt-2 font-titulo text-4xl leading-tight sm:text-5xl">{c.nome}</h1>
          <p className="mt-1 text-sm text-suave">
            {[fone && formatarTelefone(fone), c.email, c.cidade].filter(Boolean).join(" · ")}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {fone && (
            <a
              href={linkWhatsApp(fone)}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1.5 rounded-lg bg-grafite px-3.5 py-2 text-sm font-medium text-white hover:bg-black"
            >
              <ExternalLink className="size-4" /> WhatsApp
            </a>
          )}
          {fone && (
            <a
              href={`tel:${fone}`}
              className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte bg-superficie px-3.5 py-2 text-sm font-medium hover:border-dourado"
            >
              <Phone className="size-4" /> Ligar
            </a>
          )}
          {sessao.podeVerProntuario && (
            <Link
              href={`/prontuario/${c.id}`}
              className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte bg-superficie px-3.5 py-2 text-sm font-medium hover:border-dourado"
            >
              <ClipboardList className="size-4" /> Prontuário
            </Link>
          )}
          <Link
            href={`/contatos/${c.id}/editar`}
            className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte bg-superficie px-3.5 py-2 text-sm font-medium hover:border-dourado"
          >
            <Pencil className="size-4" /> Editar dados
          </Link>
        </div>
      </header>

      {/* Resumo em segundos */}
      <div className="mt-6 rounded-2xl border-l-4 border-dourado bg-superficie px-5 py-4 shadow-[0_1px_2px_rgba(43,40,36,0.04)]">
        <p className="text-[11px] font-semibold tracking-[0.12em] text-sutil uppercase">Situação comercial</p>
        <ul className="mt-1.5 space-y-0.5">
          {resumo.map((f) => (
            <li key={f}>{f}</li>
          ))}
        </ul>
      </div>

      <nav aria-label="Seções da ficha" className="mt-6 flex gap-2 overflow-x-auto pb-1">
        {SECOES.map(([ancora, rotulo]) => (
          <a
            key={ancora}
            href={`#${ancora}`}
            className="shrink-0 rounded-full border border-borda bg-superficie px-3 py-1 text-xs text-suave hover:border-dourado hover:text-dourado-escuro"
          >
            {rotulo}
          </a>
        ))}
      </nav>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          {/* PRÓXIMA AÇÃO */}
          <Secao id="proxima-acao" titulo="Próxima ação">
            {cartao ? (
              <CartaoAcao cartao={cartao} motivos={motivos} naFicha />
            ) : (
              <div className="rounded-xl border border-dashed border-borda-forte bg-superficie p-5">
                <p className="text-sm text-suave">
                  {c.nao_contatar ? "Esta pessoa pediu para não receber contatos." : "Nenhuma ação pendente."}
                </p>
                {!c.nao_contatar && !c.oportunidade_id && (
                  <div className="mt-4">
                    <p className="mb-2 text-sm font-medium">Tem interesse em algum tratamento?</p>
                    <AbrirNegociacao pessoaId={c.id} procedimentos={procedimentos} />
                  </div>
                )}
              </div>
            )}
            {!c.nao_contatar && (
              <Link
                href={`/agenda?novo=${c.id}`}
                className="mt-3 inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
              >
                <CalendarClock className="size-4 text-dourado" /> Agendar consulta
              </Link>
            )}
            {ficha.proximasConsultas.map((a) => (
              <p key={a.inicio.toISOString()} className="mt-3 flex items-center gap-2 text-sm text-suave">
                <CalendarClock className="size-4 text-dourado" />
                {a.tipo === "avaliacao" ? "Avaliação" : "Consulta"} em{" "}
                {a.inicio.toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short" })}
                {a.status === "confirmado" ? " · confirmada" : ""}
              </p>
            ))}
          </Secao>

          {/* FUNIL */}
          <Secao id="funil" titulo="Funil">
            <Funil ficha={ficha} />
          </Secao>

          {/* HISTÓRICO */}
          <Secao id="historico" titulo="Histórico">
            {ficha.linha.length === 0 ? (
              <p className="text-sm text-sutil">Nenhum registro ainda.</p>
            ) : (
              <ol className="relative ml-2 border-l border-borda-forte">
                {ficha.linha.map((e, i) => (
                  <li key={i} className={`relative mb-4 pl-6 ${e.anulado ? "opacity-50" : ""}`}>
                    <span
                      className={`absolute top-1.5 -left-[5px] size-2.5 rounded-full ring-4 ring-fundo ${
                        e.tipo === "etapa" || e.tipo === "cadastro" ? "bg-dourado" : e.tipo === "pagamento_recebido" ? "bg-rotina" : "bg-borda-forte"
                      }`}
                      aria-hidden
                    />
                    <p className="text-xs text-sutil">
                      {e.quando.toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short" })}
                      {e.autor ? ` · ${e.autor}` : ""}
                    </p>
                    <p className={`text-sm ${e.anulado ? "line-through" : ""}`}>
                      <span className="font-medium">{EVENTO[e.titulo] ?? e.titulo}</span>
                      {e.detalhe && <span className="text-suave"> — {e.detalhe}</span>}
                    </p>
                  </li>
                ))}
              </ol>
            )}
          </Secao>
        </div>

        <div className="space-y-6">
          {/* INTERESSE */}
          <Secao id="interesse" titulo="Interesse">
            <Painel>
              {c.procedimento_interesse || ficha.interesses.length ? (
                <>
                  <p className="font-titulo text-2xl text-dourado-escuro">{c.procedimento_interesse ?? "A definir"}</p>
                  {ficha.interesses.length > 0 && (
                    <p className="mt-1 text-sm text-suave">Também: {ficha.interesses.join(", ")}</p>
                  )}
                  {c.valor_estimado_centavos && (
                    <p className="mt-1 text-sm text-suave">Valor estimado: {formatarMoeda(c.valor_estimado_centavos)}</p>
                  )}
                </>
              ) : (
                <p className="text-sm text-sutil">{c.oportunidade_id ? "Procedimento ainda não definido." : "Sem interesse registrado no momento."}</p>
              )}
              {ficha.negociacoesAnteriores.length > 0 && (
                <div className="mt-4 border-t border-borda pt-3">
                  <p className="text-xs text-sutil">Negociações anteriores</p>
                  <ul className="mt-1 space-y-1 text-sm">
                    {ficha.negociacoesAnteriores.map((n, i) => (
                      <li key={i}>
                        {n.procedimento ?? "Tratamento"} · <span className={n.resultado === "fechou" ? "text-rotina" : "text-suave"}>{RESULTADO[n.resultado]}</span>
                        {n.motivo ? <span className="text-sutil"> ({n.motivo.toLowerCase()})</span> : null}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </Painel>
          </Secao>

          {antigo && (
            <Secao id="na-clinica" titulo="Na clínica">
              <Painel>
                <Dados
                  itens={[
                    ["Último atendimento", rotuloUltimoAtendimento(c.ultimo_atendimento_informado, c.ultimo_atendimento_faixa) ?? "Não informado"],
                    ["Em tratamento", c.em_tratamento ? "Sim" : "Não"],
                    ...(c.retorno_previsto_em
                      ? ([["Convite de retorno", c.retorno_previsto_em.split("-").reverse().join("/")]] as [string, string][])
                      : []),
                  ]}
                />
                {c.em_tratamento && (
                  <div className="mt-4">
                    <ConcluirTratamento pessoaId={c.id} meses={ficha.mesesRetorno} />
                  </div>
                )}
                <p className="mt-3 text-xs text-sutil">Já fez</p>
                {ficha.tratamentos.length ? (
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {ficha.tratamentos.map((t) => (
                      <span key={t.procedimento} className="rounded-full bg-dourado-claro px-2.5 py-0.5 text-xs text-dourado-escuro">
                        {t.procedimento}
                      </span>
                    ))}
                  </div>
                ) : (
                  <p className="text-sm text-sutil">Nada registrado.</p>
                )}
                {podeResgatar && (
                  <div className="mt-4 rounded-lg bg-fundo p-3">
                    <p className="flex items-center gap-1.5 text-sm font-medium">
                      <LifeBuoy className="size-4 text-dourado" /> Oportunidade de resgate
                    </p>
                    <p className="mt-1 text-xs text-suave">
                      {manutencao
                        ? `Convidar para a manutenção (${(manutencaoDevida ?? manutencao).procedimento.toLowerCase()}).`
                        : "Convidar para uma nova visita."}
                    </p>
                    <div className="mt-3">
                      <BotaoResgate pessoaId={c.id} rotulo={manutencao ? "Criar tarefa de manutenção" : "Criar tarefa de reativação"} />
                    </div>
                  </div>
                )}
                {ficha.resgatePendente && (
                  <p className="mt-3 flex items-center gap-1.5 text-xs text-rotina">
                    <CircleCheck className="size-3.5" /> Resgate já programado (veja Próxima ação).
                  </p>
                )}
              </Painel>
            </Secao>
          )}

          {/* DADOS */}
          <Secao id="dados" titulo="Dados">
            <Painel>
              <Dados
                itens={[
                  ["Nascimento", c.data_nascimento ? dataBr(c.data_nascimento) : null],
                  ["WhatsApp", fone ? formatarTelefone(fone) : null],
                  ["E-mail", c.email],
                  ["Endereço", [c.logradouro, c.bairro].filter(Boolean).join(", ") || null],
                  ["Cidade", [c.cidade, c.uf].filter(Boolean).join(" / ") || null],
                  ["CEP", c.cep ? `${c.cep.slice(0, 5)}-${c.cep.slice(5)}` : null],
                  ["Como conheceu", c.origem],
                  ["Responsável", c.responsavel],
                  ["Primeiro contato", dataBr(c.primeiro_contato_em)],
                  ["Último contato", c.ultimo_contato_em ? c.ultimo_contato_em.toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" }) : null],
                  ["Campanhas", c.consentimento_marketing ? "Aceita receber" : "Não aceita"],
                ]}
              />
              {c.observacoes_comerciais && (
                <div className="mt-4 border-t border-borda pt-3">
                  <p className="text-xs text-sutil">Observações</p>
                  <p className="mt-1 text-sm whitespace-pre-line">{c.observacoes_comerciais}</p>
                </div>
              )}
            </Painel>
          </Secao>
        </div>
      </div>

      {/* FINANCEIRO */}
      <Secao id="financeiro" titulo="Financeiro" className="mt-6">
        <Financeiro ficha={ficha} />
        {ficha.financeiro && (
          <div className="mt-3 flex flex-wrap gap-2">
            <Link
              href={`/financeiro?nova=${c.id}`}
              className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
            >
              Registrar negociação
            </Link>
            <Link
              href={`/financeiro?q=${encodeURIComponent(c.nome)}`}
              className="inline-flex items-center gap-1.5 rounded-lg border border-borda-forte px-3 py-1.5 text-sm hover:border-dourado"
            >
              Ver no financeiro
            </Link>
          </div>
        )}
      </Secao>

      {/* TAREFAS */}
      <Secao id="tarefas" titulo="Tarefas" className="mt-6">
        <div className="grid gap-4 md:grid-cols-2">
          <Painel>
            <p className="text-xs font-semibold tracking-[0.1em] text-sutil uppercase">Próximas ({ficha.tarefasFuturas.length})</p>
            {ficha.tarefasFuturas.length === 0 ? (
              <p className="mt-2 text-sm text-sutil">Nenhuma tarefa pendente.</p>
            ) : (
              <ul className="mt-2 divide-y divide-borda">
                {ficha.tarefasFuturas.map((t) => (
                  <li key={t.id} className="flex items-center justify-between gap-3 py-2 text-sm">
                    <span className="flex items-center gap-2">
                      <CircleDot className="size-3.5 shrink-0 text-dourado" /> {t.titulo}
                    </span>
                    <span className={`shrink-0 text-xs ${t.vence_em < ficha.hoje ? "text-urgente" : "text-suave"}`}>
                      {rotuloData(t.vence_em, ficha.hoje)}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </Painel>
          <Painel>
            <p className="text-xs font-semibold tracking-[0.1em] text-sutil uppercase">Concluídas e canceladas</p>
            {ficha.tarefasFeitas.length === 0 ? (
              <p className="mt-2 text-sm text-sutil">Nenhuma ainda.</p>
            ) : (
              <ul className="mt-2 divide-y divide-borda">
                {ficha.tarefasFeitas.map((t, i) => (
                  <li key={i} className="py-2 text-sm">
                    <p className={t.status === "cancelada" ? "text-sutil line-through" : ""}>
                      {t.status === "concluida" ? "✓ " : ""}
                      {t.titulo}
                    </p>
                    <p className="text-xs text-sutil">
                      {t.quando.toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" })}
                      {t.autor ? ` · ${t.autor}` : ""}
                      {t.resultado ? ` · ${t.resultado}` : ""}
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </Painel>
        </div>
      </Secao>
    </div>
  );
}

// ─── Funil: etapas em linha, a atual em destaque ────────────────────────────

function Funil({ ficha }: { ficha: Ficha }) {
  const c = ficha.contato;
  const abertas = ficha.etapas.filter((e) => e.tipo === "aberta");
  const atual = ficha.etapas.find((e) => e.id === c.etapa_id);

  if (!c.oportunidade_id) {
    const ultima = ficha.negociacoesAnteriores[0];
    return (
      <Painel>
        <p className="text-sm text-suave">
          {ultima
            ? `Nenhuma negociação em andamento. A última terminou como “${RESULTADO[ultima.resultado]}”.`
            : "Nenhuma negociação em andamento."}
        </p>
      </Painel>
    );
  }

  const ordemAtual = atual?.tipo === "aberta" ? atual.ordem : Infinity;
  return (
    <Painel>
      <ol className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-6" aria-label="Etapas do funil">
        {abertas.map((e) => {
          const ehAtual = e.id === c.etapa_id;
          const passou = e.ordem < ordemAtual;
          return (
            <li
              key={e.id}
              aria-current={ehAtual ? "step" : undefined}
              className={`rounded-lg px-2.5 py-2 text-xs ${
                ehAtual
                  ? "bg-dourado font-semibold text-white shadow-sm"
                  : passou
                    ? "bg-dourado-claro text-dourado-escuro"
                    : "bg-fundo text-sutil"
              }`}
            >
              {e.nome}
            </li>
          );
        })}
      </ol>
      <p className="mt-3 text-sm text-suave">
        {atual?.tipo === "aberta" ? (
          <>
            Etapa atual: <strong className="text-grafite">{atual.nome}</strong>
            {c.dias_na_etapa !== null &&
              (c.dias_na_etapa === 0 ? " · desde hoje" : ` · há ${c.dias_na_etapa} ${c.dias_na_etapa === 1 ? "dia" : "dias"}`)}
          </>
        ) : (
          <>
            Situação: <strong className="text-grafite">{atual?.nome}</strong> (negociação pausada)
          </>
        )}
      </p>
    </Painel>
  );
}

// ─── Financeiro ─────────────────────────────────────────────────────────────

function Financeiro({ ficha }: { ficha: Ficha }) {
  const f = ficha.financeiro;
  if (!f) return <Painel><p className="text-sm text-sutil">Seu usuário não tem permissão para ver valores.</p></Painel>;
  if (f.vendas.length === 0 && f.orcamentos.length === 0) {
    return <Painel><p className="text-sm text-sutil">Nenhuma negociação com valores registrada.</p></Painel>;
  }

  const ativas = f.vendas.filter((v) => v.status === "ativa");
  const idsAtivas = new Set(ativas.map((v) => v.id));
  const parcelas = f.parcelas.filter((p) => idsAtivas.has(p.venda_id));
  const vendido = ativas.filter((v) => v.tipo === "venda").reduce((s, v) => s + v.valor_final_centavos, 0);
  const recebido = parcelas.reduce((s, p) => s + p.valor_pago_centavos, 0);
  const emAberto = parcelas
    .filter((p) => p.situacao !== "paga" && p.situacao !== "cancelada" && p.situacao !== "renegociada")
    .reduce((s, p) => s + p.valor_centavos - p.valor_pago_centavos, 0);
  const atrasado = parcelas.filter((p) => p.situacao === "atrasada").reduce((s, p) => s + p.valor_centavos - p.valor_pago_centavos, 0);

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Indicador rotulo="Fechado" valor={vendido} />
        <Indicador rotulo="Recebido" valor={recebido} cor="text-rotina" />
        <Indicador rotulo="A receber" valor={emAberto} />
        <Indicador rotulo="Em atraso" valor={atrasado} cor={atrasado > 0 ? "text-urgente" : undefined} />
      </div>

      {f.vendas.map((v) => (
        <Painel key={v.id}>
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <p className="font-medium">
              {v.tipo === "saldo_anterior" ? "Saldo de tratamento anterior" : "Negociação fechada"} · {dataBr(v.fechada_em)}
              {v.status === "cancelada" && <span className="ml-2 text-xs text-urgente">cancelada</span>}
            </p>
            <p className="font-titulo text-2xl">{formatarMoeda(v.valor_final_centavos)}</p>
          </div>
          <p className="mt-1 text-sm text-suave">
            {[
              v.desconto_centavos > 0 && `Total ${formatarMoeda(v.valor_total_centavos)} − desconto ${formatarMoeda(v.desconto_centavos)}`,
              v.condicao_pagamento === "a_vista" ? "À vista" : `Parcelado em ${v.quantidade_parcelas}x`,
              v.forma,
            ]
              .filter(Boolean)
              .join(" · ")}
          </p>
          {v.observacao_financeira && <p className="mt-1 text-xs text-sutil">{v.observacao_financeira}</p>}
          <div className="mt-3 overflow-x-auto">
            <table className="w-full min-w-md text-sm">
              <thead className="text-left text-xs text-sutil">
                <tr>
                  <th className="py-1.5 pr-3 font-medium">Parcela</th>
                  <th className="py-1.5 pr-3 font-medium">Vencimento</th>
                  <th className="py-1.5 pr-3 font-medium">Valor</th>
                  <th className="py-1.5 pr-3 font-medium">Pago em</th>
                  <th className="py-1.5 font-medium">Situação</th>
                </tr>
              </thead>
              <tbody>
                {f.parcelas
                  .filter((p) => p.venda_id === v.id)
                  .map((p) => {
                    const s = SITUACAO_PARCELA[p.situacao] ?? { rotulo: p.situacao, classe: "" };
                    return (
                      <tr key={p.id} className="border-t border-borda">
                        <td className="py-1.5 pr-3">{p.numero === 0 ? "Entrada" : `${p.numero} de ${v.quantidade_parcelas}`}</td>
                        <td className="py-1.5 pr-3">{dataBr(p.vencimento)}</td>
                        <td className="py-1.5 pr-3">{formatarMoeda(p.valor_centavos)}</td>
                        <td className="py-1.5 pr-3">{p.pago_em ? dataBr(p.pago_em) : "—"}</td>
                        <td className={`py-1.5 ${s.classe}`}>{s.rotulo}</td>
                      </tr>
                    );
                  })}
              </tbody>
            </table>
          </div>
        </Painel>
      ))}

      {f.orcamentos.length > 0 && (
        <Painel>
          <p className="text-xs font-semibold tracking-[0.1em] text-sutil uppercase">Orçamentos</p>
          <ul className="mt-2 divide-y divide-borda text-sm">
            {f.orcamentos.map((o) => (
              <li key={`${o.numero}-${o.versao}`} className="flex flex-wrap items-baseline justify-between gap-2 py-2">
                <span>
                  Nº {o.numero}
                  {o.versao > 1 ? ` (v${o.versao})` : ""}
                  {o.itens ? ` · ${o.itens}` : ""}
                  {o.apresentado_em && <span className="text-sutil"> · apresentado em {dataBr(o.apresentado_em)}</span>}
                </span>
                <span>
                  {formatarMoeda(o.valor_final_centavos)} <span className="text-xs text-suave">· {o.status.replace("_", " ")}</span>
                </span>
              </li>
            ))}
          </ul>
        </Painel>
      )}
    </div>
  );
}

// ─── Peças ──────────────────────────────────────────────────────────────────

function somarMeses(data: string, meses: number): string {
  const [a, m, d] = data.split("-").map(Number);
  const total = a * 12 + (m - 1) + meses;
  const ano = Math.floor(total / 12);
  const mes = (total % 12) + 1;
  const ultimo = new Date(Date.UTC(ano, mes, 0)).getUTCDate();
  return `${ano}-${String(mes).padStart(2, "0")}-${String(Math.min(d, ultimo)).padStart(2, "0")}`;
}

function dataBr(d: string) {
  return d.split("-").reverse().join("/");
}

function Faixa({ children }: { children: ReactNode }) {
  return (
    <div role="status" className="mt-4 flex items-start gap-3 rounded-xl border border-rotina/30 bg-rotina-claro px-4 py-3 text-sm">
      <CircleCheck className="mt-0.5 size-4 shrink-0 text-rotina" />
      <p>{children}</p>
    </div>
  );
}

function Secao({ id, titulo, className, children }: { id: string; titulo: string; className?: string; children: ReactNode }) {
  return (
    <section id={id} aria-labelledby={`titulo-${id}`} className={`scroll-mt-6 ${className ?? ""}`}>
      <h2 id={`titulo-${id}`} className="mb-2 text-xs font-semibold tracking-[0.16em] text-dourado-escuro uppercase">
        {titulo}
      </h2>
      {children}
    </section>
  );
}

function Painel({ children }: { children: ReactNode }) {
  return <div className="rounded-xl border border-borda bg-superficie p-5">{children}</div>;
}

function Dados({ itens }: { itens: [string, string | null][] }) {
  return (
    <dl className="space-y-1.5 text-sm">
      {itens.map(([rotulo, valor]) => (
        <div key={rotulo} className="flex gap-3">
          <dt className="w-32 shrink-0 text-sutil">{rotulo}</dt>
          <dd className={valor ? "" : "text-sutil"}>{valor ?? "—"}</dd>
        </div>
      ))}
    </dl>
  );
}

function Indicador({ rotulo, valor, cor }: { rotulo: string; valor: number; cor?: string }) {
  return (
    <div className="rounded-xl border border-borda bg-superficie px-4 py-3">
      <p className="text-xs text-sutil">{rotulo}</p>
      <p className={`mt-0.5 font-titulo text-2xl ${cor ?? ""}`}>{formatarMoeda(valor)}</p>
    </div>
  );
}
