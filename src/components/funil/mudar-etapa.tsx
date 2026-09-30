"use client";

import { Lightbulb } from "lucide-react";
import { useEffect, useMemo, useState, useTransition, type ReactNode } from "react";
import { moverEtapa, sugerirAcao, type Sugestao } from "@/app/(app)/funil/acoes";
import { avisar } from "@/components/avisos";
import { Dialogo } from "@/components/dialogo";
import { formatarMoeda, paraCentavos } from "@/lib/moeda";
import type { CartaoFunil, ColunaFunil } from "@/modules/funil/funil";
import type { OpcoesFunil } from "@/modules/funil/servidor";

const CAMPO =
  "mt-1 w-full rounded-lg border border-borda-forte bg-superficie px-3 py-2 text-sm outline-none focus:border-dourado";

export function MudarEtapa({
  cartao,
  destinoInicial,
  colunas,
  opcoes,
  hoje,
  aoFechar,
}: {
  hoje: string;
  cartao: CartaoFunil;
  destinoInicial: ColunaFunil | null;
  colunas: ColunaFunil[];
  opcoes: OpcoesFunil;
  aoFechar: () => void;
}) {
  const [destino, setDestino] = useState<ColunaFunil | null>(destinoInicial);
  const [motivoId, setMotivoId] = useState("");
  const [sugestao, setSugestao] = useState<Sugestao | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [criar, setCriar] = useState(true);
  const [titulo, setTitulo] = useState("");
  const [venceEm, setVenceEm] = useState("");
  const [mensagem, setMensagem] = useState("");
  const [agendarEm, setAgendarEm] = useState("");
  const [valor, setValor] = useState("");
  const [observacao, setObservacao] = useState("");
  const [registrarValores, setRegistrarValores] = useState(true);
  const [venda, setVenda] = useState({ total: "", desconto: "", entrada: "", parcelas: "1", formaId: "", primeiro: "" });
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, iniciar] = useTransition();

  const motivo = opcoes.motivos.find((m) => m.id === motivoId);
  // "Não fechou" e "Desistiu" dividem a mesma coluna; o motivo escolhido decide a etapa.
  const etapaId = destino
    ? motivo?.aplica_a === "desistiu" && destino.etapasIds[1]
      ? destino.etapasIds[1]
      : destino.etapa.id
    : null;

  useEffect(() => {
    if (!etapaId) return;
    let ativo = true;
    (async () => {
      setCarregando(true);
      const r = await sugerirAcao(cartao.id, etapaId, motivoId || null);
      if (!ativo) return;
      setCarregando(false);
      if (!r.ok) return setErro(r.erro);
      const s = r.sugestao;
      setSugestao(s);
      // Avaliação ainda sem data: a ação é combinar a data (editável), para hoje.
      const semData = s.requer === "agendamento";
      setTitulo(semData ? `Combinar a data da avaliação com ${cartao.nome.split(" ")[0]}` : (s.titulo ?? ""));
      setVenceEm(s.vence_em ?? (semData ? hoje : ""));
      setMensagem(s.mensagem ?? "");
      setCriar(Boolean(s.tipo && s.vence_em) || s.requer === "agendamento");
    })();
    return () => {
      ativo = false;
    };
  }, [cartao.id, cartao.nome, etapaId, motivoId, hoje]);

  const requer = sugestao?.requer ?? null;
  const agendandoComData = requer === "agendamento" && agendarEm !== "";
  const centavosVenda = useMemo(() => {
    const total = paraCentavos(venda.total) ?? 0;
    const desconto = paraCentavos(venda.desconto) ?? 0;
    const entrada = paraCentavos(venda.entrada) ?? 0;
    const parcelas = Math.max(1, Number(venda.parcelas) || 1);
    const final = total - desconto;
    return { total, desconto, entrada, parcelas, final, parcela: parcelas ? Math.floor((final - entrada) / parcelas) : 0 };
  }, [venda]);

  function confirmar() {
    setErro(null);
    if (!destino || !etapaId) return setErro("Escolha a etapa.");
    if (requer === "motivo" && !motivoId) return setErro("Escolha o motivo.");
    if (criar && !agendandoComData && !titulo.trim()) return setErro("Escreva o que precisa ser feito.");
    if (criar && !agendandoComData && !venceEm) return setErro("Escolha a data da próxima ação.");
    const valorCentavos = valor.trim() ? paraCentavos(valor) : undefined;
    if (valor.trim() && valorCentavos === null) return setErro("Valor do orçamento inválido.");
    const comVenda = requer === "financeiro" && registrarValores;
    if (comVenda && centavosVenda.total <= 0) return setErro("Informe o valor do tratamento (ou desmarque “Registrar valores agora”).");

    iniciar(async () => {
      const r = await moverEtapa({
        oportunidadeId: cartao.id,
        etapaId,
        observacao: observacao || undefined,
        motivoId: motivoId || undefined,
        criar: criar && !agendandoComData,
        titulo,
        venceEm: venceEm || undefined,
        mensagem,
        agendarEm: agendarEm || undefined,
        valorCentavos: valorCentavos ?? undefined,
        venda: comVenda
          ? {
              valorTotalCentavos: centavosVenda.total,
              descontoCentavos: centavosVenda.desconto,
              entradaCentavos: centavosVenda.entrada,
              parcelas: centavosVenda.parcelas,
              formaPagamentoId: venda.formaId || undefined,
              primeiroVencimento: venda.primeiro || undefined,
            }
          : undefined,
      });
      if (r.ok) {
        avisar(r.mensagem);
        aoFechar();
      } else setErro(r.erro);
    });
  }

  const opcoesDestino = colunas.filter((c) => !c.etapasIds.includes(cartao.etapa_id));

  return (
    <Dialogo
      aberto
      aoFechar={aoFechar}
      titulo={destino ? `Mover para “${destino.etapa.nome}”` : "Mover no funil"}
      subtitulo={`${cartao.nome}${cartao.procedimento ? ` · ${cartao.procedimento}` : ""}`}
    >
      <div className="space-y-4">
        <Rotulo texto="Etapa">
          <select
            value={destino?.etapa.id ?? ""}
            onChange={(e) => {
              setDestino(colunas.find((c) => c.etapa.id === e.target.value) ?? null);
              setMotivoId("");
              setSugestao(null);
            }}
            className={CAMPO}
          >
            <option value="">Escolha…</option>
            {opcoesDestino.map((c) => (
              <option key={c.etapa.id} value={c.etapa.id}>
                {c.etapa.nome}
              </option>
            ))}
          </select>
        </Rotulo>

        {requer === "motivo" && (
          <Rotulo texto="Motivo">
            <select value={motivoId} onChange={(e) => setMotivoId(e.target.value)} className={CAMPO}>
              <option value="">Escolha…</option>
              <optgroup label="Não fechou">
                {opcoes.motivos.filter((m) => m.aplica_a === "nao_fechou").map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.nome}
                  </option>
                ))}
              </optgroup>
              <optgroup label="Desistiu">
                {opcoes.motivos.filter((m) => m.aplica_a === "desistiu").map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.nome}
                  </option>
                ))}
              </optgroup>
            </select>
          </Rotulo>
        )}

        {requer === "agendamento" && (
          <Rotulo texto="Data e horário da avaliação">
            <input type="datetime-local" value={agendarEm} onChange={(e) => setAgendarEm(e.target.value)} className={CAMPO} />
            <span className="mt-1 block text-xs text-sutil">
              {agendarEm ? "A confirmação fica marcada para a véspera (dia útil)." : "Ainda sem data? Deixe em branco e combine depois."}
            </span>
          </Rotulo>
        )}

        {destino?.etapa.marco === "orcamento_apresentado" && (
          <Rotulo texto="Valor do orçamento (opcional)">
            <input inputMode="decimal" placeholder="Ex.: 14.000" value={valor} onChange={(e) => setValor(e.target.value)} className={CAMPO} />
          </Rotulo>
        )}

        {requer === "financeiro" && (
          <fieldset className="rounded-xl border border-borda p-4">
            <label className="flex items-center gap-2 text-sm font-medium">
              <input type="checkbox" checked={registrarValores} onChange={(e) => setRegistrarValores(e.target.checked)} className="size-4 accent-dourado" />
              Registrar valores agora
            </label>
            {registrarValores && (
              <>
                <div className="mt-3 grid grid-cols-2 gap-3">
                  <Rotulo texto="Valor do tratamento">
                    <input inputMode="decimal" value={venda.total} onChange={(e) => setVenda({ ...venda, total: e.target.value })} className={CAMPO} />
                  </Rotulo>
                  <Rotulo texto="Desconto">
                    <input inputMode="decimal" value={venda.desconto} onChange={(e) => setVenda({ ...venda, desconto: e.target.value })} className={CAMPO} />
                  </Rotulo>
                  <Rotulo texto="Entrada">
                    <input inputMode="decimal" value={venda.entrada} onChange={(e) => setVenda({ ...venda, entrada: e.target.value })} className={CAMPO} />
                  </Rotulo>
                  <Rotulo texto="Parcelas">
                    <input type="number" min={1} max={60} value={venda.parcelas} onChange={(e) => setVenda({ ...venda, parcelas: e.target.value })} className={CAMPO} />
                  </Rotulo>
                  <Rotulo texto="Forma de pagamento">
                    <select value={venda.formaId} onChange={(e) => setVenda({ ...venda, formaId: e.target.value })} className={CAMPO}>
                      <option value="">A definir</option>
                      {opcoes.formas.map((f) => (
                        <option key={f.id} value={f.id}>
                          {f.nome}
                        </option>
                      ))}
                    </select>
                  </Rotulo>
                  <Rotulo texto="1º vencimento">
                    <input type="date" value={venda.primeiro} onChange={(e) => setVenda({ ...venda, primeiro: e.target.value })} className={CAMPO} />
                    {!venda.primeiro && (
                      <span className="mt-1 block text-[11px] text-sutil">
                        Em branco: {centavosVenda.entrada > 0 ? "30 dias após a entrada" : "hoje"}.
                      </span>
                    )}
                  </Rotulo>
                </div>
                {centavosVenda.total > 0 && (
                  <p className="mt-3 text-xs text-suave">
                    Valor final {formatarMoeda(centavosVenda.final)}
                    {centavosVenda.entrada > 0 && ` · entrada ${formatarMoeda(centavosVenda.entrada)}`}
                    {` · ${centavosVenda.parcelas}x de ${formatarMoeda(centavosVenda.parcela)}`}. Cada parcela vira um lembrete de pagamento.
                  </p>
                )}
              </>
            )}
          </fieldset>
        )}

        {sugestao && !agendandoComData && (sugestao.tipo || requer === "motivo" || requer === "agendamento") && (
          <div className="rounded-xl border border-dourado/30 bg-dourado-claro/50 p-4">
            <p className="flex items-start gap-2 text-sm text-grafite">
              <Lightbulb className="mt-0.5 size-4 shrink-0 text-dourado" />
              <span>
                <strong className="font-medium">Sugestão do sistema.</strong> {sugestao.explicacao}
              </span>
            </p>
            <label className="mt-3 flex items-center gap-2 text-sm">
              <input type="checkbox" checked={criar} onChange={(e) => setCriar(e.target.checked)} className="size-4 accent-dourado" />
              Criar a próxima ação
            </label>
            {criar && (
              <div className="mt-3 space-y-3">
                <Rotulo texto="O que fazer">
                  <input value={titulo} onChange={(e) => setTitulo(e.target.value)} className={CAMPO} />
                </Rotulo>
                <Rotulo texto="Quando">
                  <input type="date" value={venceEm} onChange={(e) => setVenceEm(e.target.value)} className={CAMPO} />
                </Rotulo>
                {mensagem !== "" && (
                  <Rotulo texto="Mensagem sugerida (edite à vontade)">
                    <textarea rows={3} value={mensagem} onChange={(e) => setMensagem(e.target.value)} className={CAMPO} />
                  </Rotulo>
                )}
              </div>
            )}
          </div>
        )}
        {carregando && <p className="text-xs text-sutil">Preparando a sugestão…</p>}

        <Rotulo texto="Observação (opcional)">
          <textarea
            rows={2}
            value={observacao}
            onChange={(e) => setObservacao(e.target.value)}
            placeholder="Fica no histórico. Não registre informações clínicas."
            className={CAMPO}
          />
        </Rotulo>

        {erro && (
          <p role="alert" className="text-sm text-urgente">
            {erro}
          </p>
        )}
        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={aoFechar} className="rounded-lg border border-borda-forte px-4 py-2 text-sm font-medium hover:border-dourado">
            Cancelar
          </button>
          <button
            type="button"
            onClick={confirmar}
            disabled={enviando || carregando || !destino}
            className="rounded-lg bg-grafite px-4 py-2 text-sm font-medium text-white hover:bg-black disabled:opacity-50"
          >
            {enviando ? "Movendo…" : "Mover"}
          </button>
        </div>
      </div>
    </Dialogo>
  );
}

function Rotulo({ texto, children }: { texto: string; children: ReactNode }) {
  return (
    <label className="block text-sm text-suave">
      {texto}
      {children}
    </label>
  );
}
