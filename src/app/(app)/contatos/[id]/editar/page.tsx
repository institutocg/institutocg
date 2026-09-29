import { ArrowLeft } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { z } from "zod";
import { FormularioPaciente } from "@/components/contatos/formulario-paciente";
import { comoUsuaria } from "@/lib/db";
import { formatarTelefone } from "@/lib/telefone";
import { carregarOpcoes, type Contato } from "@/modules/contatos/servidor";
import { exigirSessao } from "@/modules/sessao/sessao";
import { salvarEdicao } from "../../acoes";

export const metadata = { title: "Editar cadastro · Instituto CG" };

export default async function EditarPaciente({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.uuid().safeParse(id).success) notFound();
  const sessao = await exigirSessao();

  const dados = await comoUsuaria(sessao.usuarioId, async (db) => {
    const c = (await db.query<Contato>("select * from public.v_contatos where id = $1", [id])).rows[0];
    if (!c) return null;
    const tratamentos = (
      await db.query<{ procedimento_id: string }>("select procedimento_id from public.tratamentos_anteriores where pessoa_id = $1", [id])
    ).rows.map((r) => r.procedimento_id);
    return { c, tratamentos, opcoes: await carregarOpcoes(db, sessao.clinicaId) };
  });
  if (!dados) notFound();
  const { c, tratamentos, opcoes } = dados;
  const fone = c.whatsapp_e164 ?? c.telefone_e164;

  const inicial = {
    nome: c.nome,
    nascimento: c.data_nascimento ?? "",
    whatsapp: fone ? formatarTelefone(fone) : "",
    email: c.email ?? "",
    cep: c.cep ?? "",
    endereco: c.logradouro ?? "",
    bairro: c.bairro ?? "",
    cidade: c.cidade ?? "",
    uf: c.uf ?? "",
    origemId: c.origem_id ?? "",
    procedimentoId: c.procedimento_interesse_id ?? "",
    responsavelId: c.responsavel_id ?? "",
    observacoes: c.observacoes_comerciais ?? "",
    aceitaMarketing: c.consentimento_marketing ? "on" : "",
    ultimoAtendimentoMes:
      !c.ultimo_atendimento_faixa && c.ultimo_atendimento_informado ? c.ultimo_atendimento_informado.slice(0, 7) : "",
    ultimoAtendimentoFaixa: c.ultimo_atendimento_faixa ?? "",
    tratamentos,
    emTratamento: c.em_tratamento ? "on" : "",
  };

  return (
    <div className="mx-auto max-w-3xl px-4 py-8 sm:px-8 lg:py-12">
      <Link href={`/contatos/${id}`} className="inline-flex items-center gap-1.5 text-sm text-suave hover:text-grafite">
        <ArrowLeft className="size-4" /> Voltar para a ficha
      </Link>
      <h1 className="mt-6 font-titulo text-4xl">Editar cadastro</h1>
      <p className="mt-2 text-suave">
        {c.nome} · {c.tipo_cadastro === "paciente_antigo" ? "Paciente antigo" : "Novo contato"}
      </p>
      {c.tipo_cadastro === "paciente_antigo" && (
        <p className="mt-2 text-xs text-sutil">Tratamentos já registrados não são removidos (o histórico é preservado); você pode acrescentar outros.</p>
      )}
      <div className="mt-8">
        <FormularioPaciente
          tipo={c.tipo_cadastro}
          modo="editar"
          opcoes={opcoes}
          acao={salvarEdicao.bind(null, id)}
          inicial={inicial}
          usuarioId={sessao.usuarioId}
          cancelarHref={`/contatos/${id}`}
        />
      </div>
    </div>
  );
}
