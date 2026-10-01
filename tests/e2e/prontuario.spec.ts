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

test("agenda → abrir prontuário cria a consulta do dia com os dados do agendamento", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await page.getByRole("button", { name: "08:30 Renata Alves" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Abrir prontuário" }).click();
  await expect(page).toHaveURL(/\/prontuario\/[0-9a-f-]+\/consulta\/[0-9a-f-]+$/);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(`Consulta 01 — Clareamento dental — ${br(daquiA(0))}`);
  await expect(page.getByText("às 08:30 · Dra. Lívia Moraes · aberta pela agenda · em andamento")).toBeVisible();
  await expect(page.getByRole("group", { name: "Motivo" }).getByRole("button", { name: /Continuidade do tratamento/ })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
});

test("ficha por seleção, odontograma, plano de tratamento e realizar com pagamento parcial", async ({ page }) => {
  await entrar(page);
  await page.goto("/prontuario?q=renata");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Renata Alves/ }).click();
  await page.getByRole("list", { name: "Histórico de consultas" }).getByRole("link", { name: /Consulta 01/ }).click();

  await page.getByRole("group", { name: "Anamnese" }).getByRole("button", { name: "Diabetes" }).click();
  await page.getByRole("group", { name: "Diagnóstico" }).getByRole("button", { name: "Manchas / escurecimento" }).click();
  await page.getByRole("button", { name: "Dente 26", exact: true }).click();
  const dente = page.getByRole("group", { name: "Editar dente 26" });
  await dente.getByRole("button", { name: "Cárie" }).click();
  await dente.getByRole("button", { name: "Face Mesial" }).click();
  await expect(page.getByRole("button", { name: "Dente 26: Cárie (OM) · a tratar" })).toBeVisible();
  await page.getByLabel("O que foi feito e a conduta").fill("Clareamento em consultório, 3 sessões de 15 min.");
  await page.getByRole("group", { name: "Retorno em" }).getByRole("button", { name: "15 dias" }).click();
  await page.getByRole("button", { name: "Salvar ficha" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Ficha salva." })).toBeVisible();

  // Plano: vários procedimentos
  for (const [proc, valor, status] of [
    ["Clareamento dental", "1.800", "Aceito"],
    ["Manutenção e limpeza", "350", "Pendente"],
  ]) {
    await page.getByRole("button", { name: "Adicionar procedimento ao plano" }).click();
    const g = page.getByRole("group", { name: "Adicionar ao plano" });
    await g.getByLabel("Procedimento").selectOption({ label: proc });
    await g.getByLabel("Valor (R$)").fill(valor);
    await g.getByLabel("Status").selectOption({ label: status });
    await g.getByRole("button", { name: "Adicionar ao plano" }).click();
    await expect(page.getByRole("status").filter({ hasText: "Adicionado ao plano" }).last()).toBeVisible();
  }

  // Realizar o clareamento: pagou uma parte
  await page.getByRole("listitem", { name: "Clareamento dental — R$ 1.800,00" }).getByRole("button", { name: "Realizar nesta consulta" }).click();
  const j = page.getByRole("dialog", { name: "Realizar: Clareamento dental" });
  await j.getByRole("radio", { name: /Pagamento parcial/ }).click();
  await j.getByLabel("Forma de pagamento").selectOption({ label: "PIX" });
  await j.getByLabel("Pago agora").fill("800");
  await j.getByLabel("Data prevista do restante").fill(daquiA(10));
  await j.getByRole("button", { name: "Marcar como realizado" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Realizado. A parte paga e o saldo" })).toBeVisible();
  const realizado = page.getByRole("listitem", { name: "Clareamento dental — R$ 1.800,00" }).first();
  await expect(realizado).toContainText("Realizado");
  await expect(realizado).toContainText("Pagamento: parcialmente pago · em aberto R$ 1.000,00");

  await page.getByRole("button", { name: "Finalizar consulta" }).click();
  await page.getByRole("dialog", { name: "Finalizar a consulta?" }).getByRole("button", { name: "Salvar e finalizar" }).click();
  await expect(page.getByText("Consulta finalizada: o registro fica guardado")).toBeVisible();
  await expect(page.getByRole("group", { name: "Anamnese" }).getByRole("button", { name: /Diabetes/ })).toBeDisabled();
});

test("visão geral: histórico, realizados, pendentes, odontograma e financeiro integrados", async ({ page }) => {
  await entrar(page);
  await page.goto("/prontuario?q=renata");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Renata Alves/ }).click();
  await expect(page.getByRole("heading", { name: "Renata Alves", level: 1 })).toBeVisible();
  await expect(page.getByLabel("Alertas de saúde")).toContainText("Diabetes");
  await expect(page.getByRole("list", { name: "Procedimentos realizados" })).toContainText("Clareamento dental");
  await expect(page.getByRole("list", { name: "Procedimentos pendentes" })).toContainText("Manutenção e limpeza");
  await expect(page.getByRole("img", { name: "Dente 26: Cárie (OM) · a tratar" })).toBeVisible();
  await expect(page.getByRole("list", { name: "Pagamentos em aberto do paciente" }).getByRole("listitem", { name: "Renata Alves — R$ 1.000,00" })).toBeVisible();

  // O mesmo pagamento está no Financeiro (sem cadastrar de novo)
  await menu(page).getByRole("link", { name: "Financeiro" }).click();
  const neg = page.getByRole("listitem", { name: "Renata Alves — Clareamento dental" });
  await expect(neg).toContainText("Parcialmente pago");

  // Quitado no Financeiro → aparece no prontuário
  await page.getByRole("list", { name: "Previstos" }).getByRole("listitem", { name: "Renata Alves — R$ 1.000,00" }).getByRole("button", { name: "Marcar como pago" }).click();
  await page.getByRole("dialog", { name: "Confirmar pagamento" }).getByRole("button", { name: "Confirmar pagamento" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Pagamento registrado" })).toBeVisible();
  await page.goto("/prontuario?q=renata");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Renata Alves/ }).click();
  await expect(page.getByRole("listitem", { name: "Clareamento dental — R$ 1.800,00" })).toContainText("Pagamento: pago");
});

test("consulta 02: nova ficha começa do odontograma anterior, sem apagar a consulta 01", async ({ page }) => {
  await entrar(page);
  await page.goto("/prontuario?q=renata");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("link", { name: /Renata Alves/ }).click();
  await page.getByRole("button", { name: "Nova consulta" }).click();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(new RegExp(`^Consulta 02 — .*${br(daquiA(0))}$`));
  await expect(page.getByText("Começou igual ao da consulta 01.")).toBeVisible();
  await page.getByRole("button", { name: "Dente 26: Cárie (OM) · a tratar" }).click();
  const dente = page.getByRole("group", { name: "Editar dente 26" });
  await dente.getByRole("button", { name: "Restauração" }).click();
  await dente.getByRole("button", { name: "Existente / realizado" }).click();
  await page.getByRole("button", { name: "Salvar ficha" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Ficha salva." })).toBeVisible();
  await expect(page.getByText("Desde a consulta 01: 26: Cárie → Restauração (OM) · existente / realizado.")).toBeVisible();

  await page.getByRole("link", { name: /Prontuário de Renata Alves/ }).click();
  const historico = page.getByRole("list", { name: "Histórico de consultas" });
  await expect(historico.getByRole("link")).toHaveCount(2);
  await page.getByRole("navigation", { name: "Odontograma por consulta" }).getByRole("link", { name: /^01/ }).click();
  await expect(page.getByRole("img", { name: "Dente 26: Cárie (OM) · a tratar" })).toBeVisible();
  await page.getByRole("navigation", { name: "Odontograma por consulta" }).getByRole("link", { name: /^02/ }).click();
  await expect(page.getByRole("img", { name: "Dente 26: Restauração (OM) · existente / realizado" })).toBeVisible();
});

test("paciente com histórico (exemplo): Maria, pelo cadastro", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos?q=maria silva");
  await page.getByRole("link", { name: /Maria Silva/ }).click();
  await page.getByRole("main").getByRole("link", { name: "Prontuário", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Maria Silva", level: 1 })).toBeVisible();
  await expect(page.getByLabel("Alertas de saúde")).toContainText("Hipertensão");
  await expect(page.getByRole("list", { name: "Histórico de consultas" })).toContainText(`Consulta 01 — Facetas de porcelana — ${br(daquiA(-14))}`);
  const plano = page.getByRole("list", { name: "Plano de tratamento" });
  await expect(plano.getByRole("listitem", { name: "Clareamento dental — R$ 1.200,00" })).toContainText("Aceito");
  await plano.getByLabel("Status de Facetas de porcelana").selectOption({ label: "Aceito" });
  await expect(page.getByRole("status").filter({ hasText: "Status atualizado." })).toBeVisible();
});

test("secretária não vê o prontuário (dados de saúde)", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await expect(menu(page).getByRole("link", { name: "Prontuário" })).toHaveCount(0);
  await page.goto("/prontuario");
  await expect(page.getByText("Seu acesso não inclui o prontuário")).toBeVisible();
  await page.goto("/agenda");
  await page.getByRole("button", { name: "08:30 Renata Alves" }).click();
  await expect(page.getByRole("dialog").getByRole("button", { name: "Abrir prontuário" })).toHaveCount(0);
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
