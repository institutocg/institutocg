import { ArrowLeft, ExternalLink } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import type { ReactNode } from "react";
import { z } from "zod";
import { comoUsuaria } from "@/lib/db";
import { formatarMoeda } from "@/lib/moeda";
import { formatarTelefone, linkWhatsApp } from "@/lib/telefone";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Paciente · Instituto CG" };

const RELACIONAMENTO: Record<string, string> = {
  lead: "Novo contato",
  paciente_ativo: "Paciente ativo",
  paciente_inativo: "Paciente inativo",
};
const STATUS: Record<string, string> = {
  em_negociacao: "Em negociação",
  sem_resposta: "Sem resposta",
  em_tratamento: "Em tratamento",
  sem_negociacao: "Sem negociação no momento",
  nao_contatar: "Não quer contato",
  arquivado: "Arquivado",
};
const SITUACAO_PARCELA: Record<string, string> = {
  paga: "Paga",
  atrasada: "Atrasada",
  vence_hoje: "Vence hoje",
  a_vencer: "A vencer",
  cancelada: "Cancelada",
  renegociada: "Renegociada",
};

type Contato = {
  nome: string;
  whatsapp_e164: string | null;
  telefone_e164: string | null;
  email: string | null;
  cidade: string | null;
  origem: string | null;
  responsavel: string | null;
  relacionamento: string;
  status_atual: string;
  procedimento_interesse: string | null;
  etapa_atual: string | null;
  dias_na_etapa: number | null;
  valor_estimado_centavos: number | null;
  observacoes_comerciais: string | null;
  primeiro_contato_em: string;
  proxima_acao: string | null;
  proxima_acao_em: string | null;
};

export default async function FichaContato({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.uuid().safeParse(id).success) notFound();
  const sessao = await exigirSessao();

  const dados = await comoUsuaria(sessao.usuarioId, async (db) => {
    const contato = (await db.query<Contato>("select * from public.v_contatos where id = $1", [id])).rows[0];
    if (!contato) return null;
    const historico = (
      await db.query<{ tipo: string; descricao: string | null; ocorreu_em: Date; anulada_em: Date | null }>(
        `select tipo, descricao, ocorreu_em, anulada_em from public.interacoes
          where pessoa_id = $1 order by ocorreu_em desc limit 30`,
        [id],
      )
    ).rows;
    const parcelas = (
      await db.query<{ id: string; numero: number; quantidade_parcelas: number; valor_centavos: number; saldo_centavos: number; vencimento: string; situacao: string; pago_em: string | null }>(
        `select id, numero, quantidade_parcelas, valor_centavos, saldo_centavos, vencimento, situacao, pago_em
           from public.v_parcelas where pessoa_id = $1 order by vencimento`,
        [id],
      )
    ).rows;
    return { contato, historico, parcelas };
  });
  if (!dados) notFound();
  const { contato: c, historico, parcelas } = dados;
  const fone = c.whatsapp_e164 ?? c.telefone_e164;

  return (
    <div className="mx-auto max-w-4xl px-4 py-8 sm:px-8 lg:py-12">
      <Link href="/hoje" className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Voltar para Hoje
      </Link>

      <header className="mt-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="text-sm text-dourado-escuro">
            {RELACIONAMENTO[c.relacionamento]} · {STATUS[c.status_atual]}
          </p>
          <h1 className="mt-1 font-titulo text-4xl">{c.nome}</h1>
        </div>
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
      </header>

      <div className="mt-8 grid gap-4 md:grid-cols-2">
        <Painel titulo="Próxima ação">
          {c.proxima_acao ? (
            <p>
              {c.proxima_acao}
              <span className="block text-sm text-suave">{c.proxima_acao_em?.split("-").reverse().join("/")}</span>
            </p>
          ) : (
            <p className="text-sm text-sutil">Nenhuma ação pendente.</p>
          )}
        </Painel>
        <Painel titulo="Negociação atual">
          {c.etapa_atual ? (
            <dl className="space-y-1 text-sm">
              <Linha rotulo="Interesse" valor={c.procedimento_interesse ?? "Não informado"} />
              <Linha rotulo="Etapa" valor={`${c.etapa_atual}${c.dias_na_etapa ? ` · há ${c.dias_na_etapa} dias` : ""}`} />
              {c.valor_estimado_centavos && <Linha rotulo="Valor estimado" valor={formatarMoeda(c.valor_estimado_centavos)} />}
            </dl>
          ) : (
            <p className="text-sm text-sutil">Nenhuma negociação em andamento.</p>
          )}
        </Painel>
        <Painel titulo="Contato">
          <dl className="space-y-1 text-sm">
            {fone && <Linha rotulo="Telefone" valor={formatarTelefone(fone)} />}
            {c.email && <Linha rotulo="E-mail" valor={c.email} />}
            {c.cidade && <Linha rotulo="Cidade" valor={c.cidade} />}
            {c.origem && <Linha rotulo="Como conheceu" valor={c.origem} />}
            {c.responsavel && <Linha rotulo="Responsável" valor={c.responsavel} />}
            <Linha rotulo="Primeiro contato" valor={c.primeiro_contato_em.split("-").reverse().join("/")} />
          </dl>
        </Painel>
        <Painel titulo="Observações comerciais">
          <p className="text-sm whitespace-pre-line text-suave">{c.observacoes_comerciais || "—"}</p>
        </Painel>
      </div>

      {sessao.podeVerFinanceiro && (
        <section id="financeiro" className="mt-10 scroll-mt-8">
          <h2 className="font-titulo text-2xl">Financeiro</h2>
          {parcelas.length === 0 ? (
            <p className="mt-2 text-sm text-sutil">Nenhuma parcela registrada.</p>
          ) : (
            <div className="mt-3 overflow-x-auto rounded-xl border border-borda bg-superficie">
              <table className="w-full text-sm">
                <thead className="text-left text-xs text-sutil">
                  <tr>
                    <th className="px-4 py-2.5 font-medium">Parcela</th>
                    <th className="px-4 py-2.5 font-medium">Vencimento</th>
                    <th className="px-4 py-2.5 font-medium">Valor</th>
                    <th className="px-4 py-2.5 font-medium">Situação</th>
                  </tr>
                </thead>
                <tbody>
                  {parcelas.map((p) => (
                    <tr key={p.id} className="border-t border-borda">
                      <td className="px-4 py-2.5">{p.numero === 0 ? "Entrada" : `${p.numero} de ${p.quantidade_parcelas}`}</td>
                      <td className="px-4 py-2.5">{p.vencimento.split("-").reverse().join("/")}</td>
                      <td className="px-4 py-2.5">{formatarMoeda(p.valor_centavos)}</td>
                      <td className={`px-4 py-2.5 ${p.situacao === "atrasada" ? "text-urgente" : ""}`}>
                        {SITUACAO_PARCELA[p.situacao] ?? p.situacao}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}

      <section className="mt-10">
        <h2 className="font-titulo text-2xl">Histórico de contatos</h2>
        {historico.length === 0 ? (
          <p className="mt-2 text-sm text-sutil">Nenhum contato registrado ainda.</p>
        ) : (
          <ol className="mt-3 space-y-2">
            {historico.map((h, i) => (
              <li key={i} className={`rounded-lg border border-borda bg-superficie px-4 py-2.5 text-sm ${h.anulada_em ? "line-through opacity-50" : ""}`}>
                <span className="text-sutil">
                  {h.ocorreu_em.toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short" })}
                </span>{" "}
                · {h.descricao ?? h.tipo.replaceAll("_", " ")}
              </li>
            ))}
          </ol>
        )}
      </section>
      <p className="mt-10 text-xs text-sutil">A edição completa do cadastro chega na próxima etapa.</p>
    </div>
  );
}

function Painel({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <div className="rounded-xl border border-borda bg-superficie p-5">
      <h2 className="text-xs font-semibold tracking-[0.12em] text-sutil uppercase">{titulo}</h2>
      <div className="mt-2">{children}</div>
    </div>
  );
}

function Linha({ rotulo, valor }: { rotulo: string; valor: string }) {
  return (
    <div className="flex gap-2">
      <dt className="w-32 shrink-0 text-sutil">{rotulo}</dt>
      <dd>{valor}</dd>
    </div>
  );
}
