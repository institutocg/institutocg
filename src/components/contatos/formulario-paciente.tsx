"use client";

import { CircleAlert, ShieldCheck } from "lucide-react";
import Link from "next/link";
import { cloneElement, useActionState, useId, useState, type ReactElement, type ReactNode } from "react";
import type { EstadoCadastro } from "@/app/(app)/contatos/acoes";
import { FAIXAS_ATENDIMENTO, type FaixaAtendimento } from "@/modules/contatos/cadastro";
import type { OpcoesCadastro } from "@/modules/contatos/servidor";

type Valores = Record<string, string | string[] | undefined>;

export function FormularioPaciente({
  tipo,
  modo,
  opcoes,
  acao,
  inicial = {},
  usuarioId,
  cancelarHref,
}: {
  tipo: "novo_contato" | "paciente_antigo";
  modo: "novo" | "editar";
  opcoes: OpcoesCadastro;
  acao: (anterior: EstadoCadastro, form: FormData) => Promise<EstadoCadastro>;
  inicial?: Valores;
  usuarioId: string;
  cancelarHref: string;
}) {
  const [estado, enviar, enviando] = useActionState(acao, { versao: 0 });
  const valores: Valores = estado.valores ?? inicial;
  const erros = estado.erros ?? {};
  const antigo = tipo === "paciente_antigo";

  return (
    // A chave remonta o formulário depois de cada envio, mantendo o que foi digitado.
    <form key={estado.versao} action={enviar} noValidate className="space-y-6">
      <input type="hidden" name="tipo" value={tipo} />

      {estado.duplicado && (
        <div role="alert" className="flex items-start gap-3 rounded-xl border border-importante/30 bg-importante-claro px-4 py-3 text-sm">
          <CircleAlert className="mt-0.5 size-4 shrink-0 text-importante" />
          <p>
            Já existe um cadastro com este WhatsApp ou e-mail: <strong>{estado.duplicado.nome}</strong>.{" "}
            <Link href={`/contatos/${estado.duplicado.id}`} className="font-medium text-dourado-escuro underline underline-offset-4">
              Abrir o cadastro existente
            </Link>
          </p>
        </div>
      )}
      {erros.geral && (
        <p role="alert" className="rounded-xl bg-urgente-claro px-4 py-3 text-sm text-urgente">
          {erros.geral}
        </p>
      )}

      <Secao titulo="Dados do paciente">
        <Campo nome="nome" rotulo="Nome completo" obrigatorio erro={erros.nome} largo>
          <input name="nome" defaultValue={texto(valores.nome)} autoComplete="off" required className={CAMPO} />
        </Campo>
        <Campo nome="nascimento" rotulo="Data de nascimento" erro={erros.nascimento}>
          <input name="nascimento" type="date" defaultValue={texto(valores.nascimento)} className={CAMPO} />
        </Campo>
        <Campo nome="whatsapp" rotulo="WhatsApp" obrigatorio erro={erros.whatsapp} dica="Com DDD. Ex.: (11) 99999-8888">
          <input name="whatsapp" type="tel" inputMode="tel" defaultValue={texto(valores.whatsapp)} className={CAMPO} />
        </Campo>
        <Campo nome="email" rotulo="E-mail" erro={erros.email}>
          <input name="email" type="email" defaultValue={texto(valores.email)} className={CAMPO} />
        </Campo>
      </Secao>

      <Secao titulo="Endereço" descricao="Opcional">
        <Campo nome="cep" rotulo="CEP" erro={erros.cep}>
          <input name="cep" inputMode="numeric" defaultValue={texto(valores.cep)} className={CAMPO} />
        </Campo>
        <Campo nome="endereco" rotulo="Endereço (rua e número)" erro={erros.endereco}>
          <input name="endereco" defaultValue={texto(valores.endereco)} className={CAMPO} />
        </Campo>
        <Campo nome="bairro" rotulo="Bairro" erro={erros.bairro}>
          <input name="bairro" defaultValue={texto(valores.bairro)} className={CAMPO} />
        </Campo>
        <div className="grid grid-cols-[1fr_5rem] gap-3">
          <Campo nome="cidade" rotulo="Cidade" erro={erros.cidade}>
            <input name="cidade" defaultValue={texto(valores.cidade)} className={CAMPO} />
          </Campo>
          <Campo nome="uf" rotulo="UF" erro={erros.uf}>
            <input name="uf" maxLength={2} defaultValue={texto(valores.uf ?? "SP")} className={`${CAMPO} uppercase`} />
          </Campo>
        </div>
      </Secao>

      {antigo && <HistoricoNaClinica valores={valores} opcoes={opcoes} erros={erros} />}

      <Secao titulo={antigo ? "Interesse agora" : "Interesse"} descricao={antigo ? "Opcional — preencha se ele já quer algum tratamento" : undefined}>
        {!antigo && (
          <Campo nome="origemId" rotulo="Como conheceu a clínica" obrigatorio erro={erros.origemId}>
            <select name="origemId" defaultValue={texto(valores.origemId)} className={CAMPO}>
              <option value="">Escolha…</option>
              {opcoes.origens.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.nome}
                </option>
              ))}
            </select>
          </Campo>
        )}
        <Campo nome="procedimentoId" rotulo="Procedimento de interesse" erro={erros.procedimentoId}>
          <select name="procedimentoId" defaultValue={texto(valores.procedimentoId)} className={CAMPO}>
            <option value="">{antigo ? "Nenhum no momento" : "Ainda não sabe"}</option>
            {opcoes.procedimentos.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome}
              </option>
            ))}
          </select>
        </Campo>
        <Campo nome="responsavelId" rotulo="Responsável pelo atendimento">
          <select name="responsavelId" defaultValue={texto(valores.responsavelId) || usuarioId} className={CAMPO}>
            {opcoes.responsaveis.map((r) => (
              <option key={r.id} value={r.id}>
                {r.nome}
              </option>
            ))}
          </select>
        </Campo>
        <Campo nome="observacoes" rotulo="Observações" erro={erros.observacoes} largo dica="Somente informações comerciais — nada clínico.">
          <textarea name="observacoes" rows={3} maxLength={1000} defaultValue={texto(valores.observacoes)} className={CAMPO} />
        </Campo>
        <label className="flex items-start gap-2.5 text-sm sm:col-span-2">
          <input
            type="checkbox"
            name="aceitaMarketing"
            defaultChecked={valores.aceitaMarketing === "on" || valores.aceitaMarketing === "true"}
            className="mt-0.5 size-4 accent-dourado"
          />
          <span>
            Aceita receber novidades e campanhas da clínica
            <span className="block text-xs text-sutil">Contatos sobre o próprio atendimento não dependem disto.</span>
          </span>
        </label>
      </Secao>

      <div className="flex flex-col-reverse gap-3 border-t border-borda pt-6 sm:flex-row sm:items-center sm:justify-between">
        <p className="flex items-center gap-1.5 text-xs text-sutil">
          <ShieldCheck className="size-3.5" /> Nenhuma informação clínica é guardada neste cadastro.
        </p>
        <div className="flex flex-wrap justify-end gap-2">
          <Link href={cancelarHref} className="rounded-lg border border-borda-forte px-4 py-2.5 text-sm font-medium hover:border-dourado">
            Cancelar
          </Link>
          {modo === "novo" && antigo && (
            <button
              type="submit"
              name="depois"
              value="ficha"
              disabled={enviando}
              className="rounded-lg border border-borda-forte px-4 py-2.5 text-sm font-medium hover:border-dourado disabled:opacity-50"
            >
              Salvar e abrir ficha
            </button>
          )}
          <button
            type="submit"
            name="depois"
            value={modo === "novo" && antigo ? "proximo" : "ficha"}
            disabled={enviando}
            className="rounded-lg bg-grafite px-5 py-2.5 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
          >
            {enviando ? "Salvando…" : modo === "editar" ? "Salvar alterações" : antigo ? "Salvar e cadastrar o próximo" : "Salvar"}
          </button>
        </div>
      </div>
    </form>
  );
}

// ─── Paciente antigo: último atendimento e tratamentos ─────────────────────

function HistoricoNaClinica({
  valores,
  opcoes,
  erros,
}: {
  valores: Valores;
  opcoes: OpcoesCadastro;
  erros: Record<string, string | undefined>;
}) {
  const inicialOpcao = valores.ultimoAtendimentoMes ? "mes" : texto(valores.ultimoAtendimentoFaixa) || "mes";
  const [opcao, setOpcao] = useState<string>(inicialOpcao);
  const [tratamentos, setTratamentos] = useState<string[]>(lista(valores.tratamentos));

  function alternar(id: string) {
    setTratamentos((atual) => (atual.includes(id) ? atual.filter((x) => x !== id) : [...atual, id]));
  }

  return (
    <Secao titulo="Histórico na clínica" descricao="Usado para resgatar o paciente (manutenção, limpeza, retorno)">
      <fieldset className="sm:col-span-2">
        <legend className="text-sm text-suave">Quando foi o último atendimento?</legend>
        <div role="radiogroup" className="mt-2 flex flex-wrap gap-2">
          <Pilula ativo={opcao === "mes"} onClick={() => setOpcao("mes")}>
            Lembra o mês
          </Pilula>
          {(Object.keys(FAIXAS_ATENDIMENTO) as FaixaAtendimento[]).map((f) => (
            <Pilula key={f} ativo={opcao === f} onClick={() => setOpcao(f)}>
              {FAIXAS_ATENDIMENTO[f].rotulo}
            </Pilula>
          ))}
        </div>
        {opcao === "mes" ? (
          <label className="mt-3 block max-w-xs">
            <span className="text-xs text-sutil">Mês e ano</span>
            <input
              name="ultimoAtendimentoMes"
              type="month"
              defaultValue={texto(valores.ultimoAtendimentoMes)}
              className={CAMPO}
              aria-label="Mês e ano do último atendimento"
            />
          </label>
        ) : (
          <input type="hidden" name="ultimoAtendimentoFaixa" value={opcao} />
        )}
        {(erros.ultimoAtendimentoMes || erros.ultimoAtendimentoFaixa) && (
          <p className="mt-1 text-xs text-urgente">{erros.ultimoAtendimentoMes ?? erros.ultimoAtendimentoFaixa}</p>
        )}
      </fieldset>

      <fieldset className="sm:col-span-2">
        <legend className="text-sm text-suave">O que o paciente já fez na clínica?</legend>
        <p className="text-xs text-sutil">Só o nome do tratamento — sem detalhes clínicos.</p>
        <div className="mt-2 flex flex-wrap gap-2">
          {opcoes.procedimentos.map((p) => (
            <Pilula key={p.id} ativo={tratamentos.includes(p.id)} onClick={() => alternar(p.id)} papel="checkbox">
              {p.nome}
            </Pilula>
          ))}
        </div>
        {tratamentos.map((id) => (
          <input key={id} type="hidden" name="tratamentos" value={id} />
        ))}
      </fieldset>

      <label className="flex items-center gap-2.5 text-sm sm:col-span-2">
        <input
          type="checkbox"
          name="emTratamento"
          defaultChecked={valores.emTratamento === "on" || valores.emTratamento === "true"}
          className="size-4 accent-dourado"
        />
        Está em tratamento na clínica agora
      </label>
    </Secao>
  );
}

// ─── Peças ──────────────────────────────────────────────────────────────────

const CAMPO =
  "mt-1.5 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2.5 text-sm outline-none transition focus:border-dourado aria-[invalid=true]:border-urgente";

function texto(v: string | string[] | undefined): string {
  return Array.isArray(v) ? (v[0] ?? "") : (v ?? "");
}

function lista(v: string | string[] | undefined): string[] {
  return Array.isArray(v) ? v : v ? [v] : [];
}

function Secao({ titulo, descricao, children }: { titulo: string; descricao?: string; children: ReactNode }) {
  return (
    <section className="rounded-2xl border border-borda bg-superficie p-5 sm:p-6">
      <div className="mb-4 flex flex-wrap items-baseline gap-x-3">
        <h2 className="font-titulo text-2xl">{titulo}</h2>
        {descricao && <p className="text-xs text-sutil">{descricao}</p>}
      </div>
      <div className="grid gap-4 sm:grid-cols-2">{children}</div>
    </section>
  );
}

function Campo({
  nome,
  rotulo,
  obrigatorio,
  erro,
  dica,
  largo,
  children,
}: {
  nome: string;
  rotulo: string;
  obrigatorio?: boolean;
  erro?: string;
  dica?: string;
  largo?: boolean;
  children: ReactElement<Record<string, unknown>>;
}) {
  const id = useId();
  const idAjuda = `${id}-ajuda`;
  const campo = cloneElement(children, {
    id,
    "aria-invalid": erro ? true : undefined,
    "aria-describedby": erro || dica ? idAjuda : undefined,
    "aria-required": obrigatorio || undefined,
  });
  return (
    <div className={largo ? "sm:col-span-2" : undefined} data-campo={nome}>
      <label htmlFor={id} className="text-sm text-suave">
        {rotulo}
        {obrigatorio && <span aria-hidden className="text-dourado-escuro"> *</span>}
      </label>
      {campo}
      {erro ? (
        <p id={idAjuda} role="alert" className="mt-1 text-xs text-urgente">
          {erro}
        </p>
      ) : (
        dica && (
          <p id={idAjuda} className="mt-1 text-xs text-sutil">
            {dica}
          </p>
        )
      )}
    </div>
  );
}

function Pilula({
  ativo,
  onClick,
  children,
  papel = "radio",
}: {
  ativo: boolean;
  onClick: () => void;
  children: ReactNode;
  papel?: "radio" | "checkbox";
}) {
  return (
    <button
      type="button"
      role={papel}
      aria-checked={ativo}
      onClick={onClick}
      className={`rounded-full border px-3.5 py-1.5 text-sm transition ${
        ativo ? "border-dourado bg-dourado-claro font-medium text-dourado-escuro" : "border-borda-forte text-grafite hover:border-dourado"
      }`}
    >
      {children}
    </button>
  );
}
