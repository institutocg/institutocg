import { Biblioteca } from "@/components/mensagens/biblioteca";
import { comoUsuaria } from "@/lib/db";
import type { Modelo } from "@/modules/mensagens/mensagens";
import { exigirSessao } from "@/modules/sessao/sessao";

export const metadata = { title: "Mensagens prontas · Instituto CG" };

export default async function Mensagens() {
  const sessao = await exigirSessao();
  const { modelos, procedimentos } = await comoUsuaria(sessao.usuarioId, async (db) => {
    const modelos = await db.query<Modelo>(
      `select m.id, m.categoria, m.situacao, m.procedimento_id, pr.nome as procedimento, m.titulo, m.texto, m.padrao, m.ativo
         from public.modelos_mensagem m left join public.procedimentos pr on pr.id = m.procedimento_id
        where m.clinica_id = $1
        order by m.padrao desc, (m.procedimento_id is null) desc, m.titulo`,
      [sessao.clinicaId],
    );
    const procedimentos = await db.query<{ id: string; nome: string }>(
      "select id, nome from public.procedimentos where clinica_id = $1 and ativo order by ordem, nome",
      [sessao.clinicaId],
    );
    return { modelos: modelos.rows, procedimentos: procedimentos.rows };
  });
  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-8 lg:py-10">
      <Biblioteca modelos={modelos} procedimentos={procedimentos} />
    </div>
  );
}
