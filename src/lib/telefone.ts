/**
 * Telefones são guardados no formato internacional E.164 (+5511999998888),
 * exigido pela API oficial do WhatsApp e usado na verificação de duplicidade.
 */

const DDDS_VALIDOS = new Set([
  11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 24, 27, 28, 31, 32, 33, 34, 35,
  37, 38, 41, 42, 43, 44, 45, 46, 47, 48, 49, 51, 53, 54, 55, 61, 62, 63, 64,
  65, 66, 67, 68, 69, 71, 73, 74, 75, 77, 79, 81, 82, 83, 84, 85, 86, 87, 88,
  89, 91, 92, 93, 94, 95, 96, 97, 98, 99,
]);

/**
 * Normaliza um telefone brasileiro digitado de qualquer jeito.
 * "(11) 99999-8888", "11999998888", "+55 11 99999-8888" → "+5511999998888".
 * Retorna null quando não parece um telefone brasileiro válido.
 */
export function normalizarTelefone(entrada: string): string | null {
  let digitos = entrada.replace(/\D/g, "");
  if (digitos.startsWith("0")) digitos = digitos.replace(/^0+/, "");
  if (digitos.length === 12 || digitos.length === 13) {
    if (!digitos.startsWith("55")) return null;
    digitos = digitos.slice(2);
  }
  if (digitos.length !== 10 && digitos.length !== 11) return null;

  const ddd = Number(digitos.slice(0, 2));
  if (!DDDS_VALIDOS.has(ddd)) return null;

  const numero = digitos.slice(2);
  // Celular: 9 dígitos começando com 9. Fixo: 8 dígitos começando com 2–5.
  if (numero.length === 9 && numero[0] !== "9") return null;
  if (numero.length === 8 && !/^[2-5]/.test(numero)) return null;

  return `+55${digitos}`;
}

/** "+5511999998888" → "(11) 99999-8888" */
export function formatarTelefone(e164: string): string {
  const d = e164.replace(/^\+55/, "");
  const ddd = d.slice(0, 2);
  const numero = d.slice(2);
  const corte = numero.length === 9 ? 5 : 4;
  return `(${ddd}) ${numero.slice(0, corte)}-${numero.slice(corte)}`;
}

/** Link que abre o WhatsApp (web ou celular) já com a mensagem escrita. */
export function linkWhatsApp(e164: string, mensagem?: string): string {
  const numero = e164.replace(/\D/g, "");
  const texto = mensagem ? `?text=${encodeURIComponent(mensagem)}` : "";
  return `https://wa.me/${numero}${texto}`;
}
