/**
 * Dinheiro é sempre guardado em centavos (inteiro) para evitar erros de
 * arredondamento. Estas funções convertem entre centavos e texto em R$.
 */

const formatador = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
});

const formatadorCompacto = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
  maximumFractionDigits: 0,
});

/** 123456 → "R$ 1.234,56" */
export function formatarMoeda(centavos: number): string {
  return normalizarEspacos(formatador.format(centavos / 100));
}

/** 1250000 → "R$ 12.500" (sem centavos, para cartões e resumos) */
export function formatarMoedaCompacta(centavos: number): string {
  return normalizarEspacos(formatadorCompacto.format(Math.round(centavos / 100)));
}

/**
 * Converte o que a pessoa digitou em centavos.
 * Aceita "1.234,56", "1234,56", "R$ 1.234", "1234.56" e "1234".
 * Retorna null se não for um valor válido.
 */
export function paraCentavos(texto: string): number | null {
  const limpo = texto.replace(/R\$|\s/g, "");
  if (!/^\d[\d.,]*$/.test(limpo)) return null;

  let normalizado: string;
  const ultimaVirgula = limpo.lastIndexOf(",");
  if (ultimaVirgula !== limpo.indexOf(",")) return null;
  const ultimoPonto = limpo.lastIndexOf(".");

  if (ultimaVirgula > -1) {
    // Formato brasileiro: pontos só como milhar (grupos de 3) antes da vírgula.
    if (!/^(\d{1,3}(\.\d{3})+|\d+),\d+$/.test(limpo)) return null;
    normalizado = limpo.replace(/\./g, "").replace(",", ".");
  } else if (ultimoPonto > -1 && limpo.length - ultimoPonto - 1 !== 3) {
    // "1234.5" ou "1234.56": ponto decimal.
    normalizado = limpo;
  } else {
    // "1.234" ou "1.234.567": pontos de milhar.
    normalizado = limpo.replace(/\./g, "");
  }

  if ((normalizado.match(/\./g) ?? []).length > 1) return null;
  const valor = Number(normalizado);
  if (!Number.isFinite(valor)) return null;
  return Math.round(valor * 100);
}

function normalizarEspacos(texto: string) {
  // Intl usa espaço não separável; trocamos por espaço comum para consistência.
  return texto.replace(/ /g, " ");
}
