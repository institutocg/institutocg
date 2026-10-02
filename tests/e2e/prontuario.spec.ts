import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page, email = "dona@institutocg.local") {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}
function daquiA(dias: number) {
  return new Date(Date.now() + dias * 86_400_000).toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}
const br = (d: string) => d.split("-").reverse().join("/");
const menu = (page: Page) => page.getByRole("navigation", { name: "Menu principal" });
const plano = (page: Page) => page.getByRole("list", { name: "Plano de tratamento" });
const quadro = (page: Page, rotulo: string) => page.locator("dl > div").filter({ has: page.locator("dt").getByText(rotulo, { exact: true }) });

async function abrirRenata(page: Page) {
  await page.goto("/prontuario?q=renata");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Renata Alves/ }).click();
  await expect(page.getByRole("heading", { name: "Renata Alves", level: 1 })).toBeVisible();
}

async function adicionar(page: Page, nome: string, valor: string, feitoHoje = false) {
  const g = page.getByRole("group", { name: "Novo procedimento" });
  await g.getByLabel("Procedimento").fill(nome);
  await g.getByLabel("Valor (R$)").fill(valor);
  if (feitoHoje) await g.getByLabel("Feito hoje").check();
  await g.getByRole("button", { name: "Adicionar" }).click();
  await expect(page.getByRole("status").filter({ hasText: `${nome} — ` }).last()).toBeVisible();
}

test("agenda sem financeiro; compareceu → abrir prontuário cria a consulta do dia", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  const cartao = page.getByRole("button", { name: "08:30 Renata Alves" });
  await expect(cartao).not.toContainText("R$");
  await cartao.click();
  const j = page.getByRole("dialog");
  await expect(j.getByText("Valor")).toHaveCount(0);
  await j.getByRole("button", { name: "Compareceu" }).click();
  await expect(j.getByText("Comparecimento registrado. Registre a consulta no prontuário.")).toBeVisible();
  await j.getByRole("button", { name: "Abrir prontuário" }).click();
  await expect(page).toHaveURL(/\/prontuario\/[0-9a-f-]+\/consulta\/[0-9a-f-]+$/);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(`Consulta 01 — Clareamento dental — ${br(daquiA(0))}`);
  await expect(page.getByText("às 08:30 · Dra. Lívia Moraes · aberta pela agenda · em andamento")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Motivo da consulta", exact: true })).toHaveValue("Clareamento dental");
});

test("consulta simples: textos livres, odontograma, procedimentos livres com total e 'feito hoje'", async ({ page }) => {
  await entrar(page);
  await abrirRenata(page);
  await page.getByRole("list", { name: "Histórico de consultas" }).getByRole("link", { name: /Consulta 01/ }).click();

  await page.getByRole("textbox", { name: "Queixa principal", exact: true }).fill("Dentes amarelados e uma restauração escura");
  await page.getByRole("textbox", { name: "Anamnese / observações", exact: true }).fill("Diabética, usa metformina. Alergia a dipirona.");
  await page.getByRole("button", { name: "Dente 26", exact: true }).click();
  const dente = page.getByRole("group", { name: "Editar dente 26" });
  await dente.getByRole("button", { name: "Cárie" }).click();
  await page.getByRole("button", { name: "Salvar ficha" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Ficha salva." })).toBeVisible();

  // Procedimentos escritos livremente (inclusive um que nunca foi cadastrado)
  await adicionar(page, "Clareamento", "1.200", true);
  await adicionar(page, "Facetas em resina", "5.000");
  await adicionar(page, "Limpeza", "350");
  await expect(plano(page).getByRole("listitem", { name: "Total do orçamento" })).toContainText("R$ 6.550,00");
  await expect(plano(page).getByRole("listitem", { name: "Clareamento — R$ 1.200,00" })).toContainText("Feito hoje");
  await expect(plano(page).getByRole("listitem", { name: "Facetas em resina — R$ 5.000,00" })).toContainText("Pendente");
});

test("pagamento do plano: paga tudo hoje, faz depois (pagamento ≠ realização)", async ({ page }) => {
  await entrar(page);
  await abrirRenata(page);
  await expect(quadro(page, "Total do orçamento")).toContainText("R$ 6.550,00");
  await expect(quadro(page, "Pendente")).toContainText("R$ 6.550,00");
  await page.getByRole("button", { name: "Registrar pagamento" }).click();
  const j = page.getByRole("dialog", { name: "Registrar pagamento" });
  await expect(j).toContainText("Valor a registrar: R$ 6.550,00");
  await j.getByRole("radio", { name: "Parcialmente pago" }).click();
  await j.getByLabel("Forma de pagamento").selectOption({ label: "PIX" });
  await j.getByLabel("Valor pago").fill("3.000");
  await expect(j.getByText("Valor restante: R$ 3.550,00")).toBeVisible();
  await j.getByLabel("Data prevista para o restante").fill(daquiA(0));
  await j.getByRole("button", { name: "Registrar pagamento" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Pagamento registrado." })).toContainText("Pago R$ 3.000,00 · pendente R$ 3.550,00");
  await expect(quadro(page, "Pago")).toContainText("R$ 3.000,00");
  await expect(quadro(page, "Pendente")).toContainText("R$ 3.550,00");
  await expect(plano(page).getByRole("listitem", { name: "Facetas em resina — R$ 5.000,00" })).toContainText("Pendente");

  // Pendência de hoje no painel
  await menu(page).getByRole("link", { name: "Hoje" }).click();
  const card = page.getByRole("article", { name: "Renata Alves — R$ 3.550,00" });
  await expect(card).toContainText("Pagamento previsto");

  // No Financeiro, o mesmo pagamento (sem cadastrar duas vezes)
  await menu(page).getByRole("link", { name: "Financeiro" }).click();
  await expect(page.getByRole("listitem", { name: "Renata Alves — Plano de tratamento" })).toContainText("Parcialmente pago");
});

test("consulta 02: pendentes aparecem para marcar; odontograma parte do anterior", async ({ page }) => {
  await entrar(page);
  await abrirRenata(page);
  await page.getByRole("button", { name: "Nova consulta" }).click();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(new RegExp(`^Consulta 02 — .*${br(daquiA(0))}$`));
  await expect(page.getByText("Começou igual ao da consulta 01.")).toBeVisible();
  await expect(plano(page).getByRole("listitem", { name: "Clareamento — R$ 1.200,00" })).toContainText("Feito na consulta 01");
  await plano(page).getByRole("listitem", { name: "Limpeza — R$ 350,00" }).getByRole("checkbox").check();
  await expect(page.getByRole("status").filter({ hasText: "Marcado como feito nesta consulta." })).toBeVisible();
  await expect(plano(page).getByRole("listitem", { name: "Limpeza — R$ 350,00" })).toContainText("Feito hoje");
  await expect(plano(page).getByRole("listitem", { name: "Facetas em resina — R$ 5.000,00" })).toContainText("Pendente");

  await page.getByRole("link", { name: /Prontuário de Renata Alves/ }).click();
  await expect(page.getByRole("list", { name: "Histórico de consultas" }).getByRole("link")).toHaveCount(2);
  await expect(page.getByLabel("Anamnese", { exact: true })).toContainText("Diabética");
  await expect(page.getByRole("list", { name: "Procedimentos realizados" })).toContainText("Limpeza");
  await expect(page.getByRole("list", { name: "Procedimentos pendentes" })).toContainText("Facetas em resina");
});

test("procedimento livre também na agenda", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await page.getByRole("button", { name: "Nova consulta" }).click();
  const j = page.getByRole("dialog");
  await j.getByLabel("Paciente").fill("beat");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Beatriz Almeida/ }).click();
  await j.getByLabel("Procedimento", { exact: true }).fill("Gengivoplastia a laser");
  const dia = new Date(Date.now() + 86_400_000 * 7);
  while ([0, 6].includes(dia.getDay())) dia.setDate(dia.getDate() + 1);
  await j.getByLabel("Data").fill(dia.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" }));
  await j.getByLabel("Horário").fill("18:00");
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Consulta marcada para" })).toBeVisible();
  await page.goto(`/agenda?semana=${dia.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" })}`);
  await expect(page.getByRole("button", { name: "18:00 Beatriz Almeida" })).toContainText("Gengivoplastia a laser");
});

test("paciente com histórico (exemplo): Maria, pelo cadastro", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos?q=maria silva");
  await page.getByRole("link", { name: /Maria Silva/ }).click();
  await page.getByRole("main").getByRole("link", { name: "Prontuário", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Maria Silva", level: 1 })).toBeVisible();
  await expect(page.getByLabel("Anamnese", { exact: true })).toContainText("Hipertensa");
  await expect(page.getByRole("list", { name: "Histórico de consultas" })).toContainText(`Consulta 01 — Facetas de porcelana — ${br(daquiA(-14))}`);
  await expect(plano(page).getByRole("listitem", { name: "Total do orçamento" })).toContainText("R$ 15.550,00");
});

test("secretária não vê o prontuário (dados de saúde)", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await expect(menu(page).getByRole("link", { name: "Prontuário" })).toHaveCount(0);
  await page.goto("/prontuario");
  await expect(page.getByText("Seu acesso não inclui o prontuário")).toBeVisible();
});

test("celular: prontuário cabe na tela", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page);
  await page.goto("/prontuario?q=maria");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Maria Silva/ }).click();
  await expect(page.getByRole("heading", { name: "Maria Silva", level: 1 })).toBeVisible();
  const sobra = () => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(await sobra()).toBeLessThanOrEqual(0);
  await page.getByRole("list", { name: "Histórico de consultas" }).getByRole("link").first().click();
  await expect(page.getByRole("heading", { level: 1 })).toContainText("Consulta 01");
  expect(await sobra()).toBeLessThanOrEqual(0);
});
