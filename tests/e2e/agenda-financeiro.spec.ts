import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill("secretaria@institutocg.local");
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

const FERIADOS_FIXOS = ["01-01", "04-21", "05-01", "09-07", "10-12", "11-02", "11-15", "11-20", "12-25"];
function daquiA(dias: number) {
  return new Date(Date.now() + dias * 86_400_000).toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}
function diaUtil(dias: number) {
  let n = dias;
  const fechado = (d: string) => [0, 6].includes(new Date(`${d}T12:00:00Z`).getUTCDay()) || FERIADOS_FIXOS.includes(d.slice(5));
  while (fechado(daquiA(n))) n++;
  return daquiA(n);
}
const janela = (page: Page) => page.getByRole("dialog");

test("ao agendar, o valor do procedimento fica na consulta", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await page.getByRole("button", { name: "Nova consulta" }).click();
  const j = janela(page);
  await j.getByLabel("Paciente").fill("beat");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Beatriz Almeida/ }).click();
  await j.getByLabel("Tipo de consulta").selectOption({ label: "Procedimento" });
  await j.getByLabel("Valor do procedimento (opcional)").fill("2.400");
  const dia = diaUtil(1);
  await j.getByLabel("Data").fill(dia);
  await j.getByLabel("Horário").fill("17:00");
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Consulta marcada para" })).toBeVisible();
  await page.goto(`/agenda?semana=${dia}`);
  await expect(page.getByRole("button", { name: "17:00 Beatriz Almeida" })).toContainText("R$ 2.400,00");
});

test("compareceu: no mesmo passo, como ficou o pagamento — e o Financeiro se preenche sozinho", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  const cartao = page.getByRole("button", { name: "08:30 Renata Alves" });
  await expect(cartao).toContainText("R$ 1.800,00");
  await cartao.click();
  const j = janela(page);
  await j.getByRole("button", { name: "Compareceu" }).click();
  await expect(j.getByText("Compareceu — como ficou o pagamento?")).toBeVisible();
  await expect(j.getByLabel("Valor", { exact: true })).toHaveValue("1.800,00");

  await j.getByRole("radio", { name: /Vai pagar depois/ }).click();
  await j.getByRole("button", { name: "Registrar presença" }).click();
  await expect(j.getByRole("alert")).toHaveText("Escolha a forma de pagamento.");
  await j.getByLabel("Forma de pagamento").selectOption({ label: "PIX" });
  await j.getByLabel("Parcelas").fill("2");
  await j.getByLabel("Data prevista do 1º pagamento").fill(daquiA(7));
  await j.getByRole("button", { name: "Registrar presença" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Comparecimento registrado" })).toContainText("lembrete na data prevista");
  await expect(cartao).toContainText("Compareceu");
  await expect(cartao).toContainText("A receber");

  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Financeiro" }).click();
  const renata = page.getByRole("listitem", { name: "Renata Alves — Clareamento dental" });
  await expect(renata).toContainText("Pendente");
  await expect(renata).toContainText("2x R$ 900,00");
  await expect(page.getByRole("list", { name: "Previstos" }).getByRole("listitem", { name: "Renata Alves — R$ 900,00" }).first()).toBeVisible();
});
