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

const secao = (page: Page, nome: string) => page.getByRole("region", { name: nome, exact: true });
const mensagem = (page: Page, titulo: string) => page.getByRole("listitem", { name: titulo, exact: true });

test("biblioteca organizada por situação, com variáveis destacadas", async ({ page }) => {
  await entrar(page);
  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Mensagens" }).click();
  await expect(page.getByRole("heading", { name: "Mensagens prontas", level: 1 })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Situações" }).getByRole("link")).toHaveCount(13);
  for (const s of ["Primeiro contato", "Passou pela primeira consulta (pensando)", "Cobrança amigável", "Paciente antigo"]) {
    await expect(page.getByRole("heading", { name: s, level: 2 })).toBeVisible();
  }
  const calma = mensagem(page, "Conseguiu avaliar com calma?");
  await expect(calma).toContainText("Estou passando para saber se conseguiu avaliar com calma as informações sobre {{procedimento}}.");
  await expect(calma.locator("mark").first()).toHaveText("{{nome}}");
  await expect(mensagem(page, "Depois da consulta")).toContainText("Sugerida");
});

test("copiar mensagem e adaptar antes de usar, preenchida para um paciente", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await entrar(page);
  await page.goto("/mensagens");
  await mensagem(page, "Que saudade").getByRole("button", { name: "Copiar mensagem" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Mensagem copiada." })).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toContain("Olá, {{nome}}! Tudo bem? Faz um tempinho");

  await page.getByLabel("Preencher para um paciente (opcional)").fill("maria");
  await page.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Maria Silva/ }).click();
  const calma = mensagem(page, "Conseguiu avaliar com calma?");
  await expect(calma).toContainText("Olá, Maria! Tudo bem? Estou passando para saber se conseguiu avaliar com calma as informações sobre facetas de porcelana.");
  await calma.getByRole("button", { name: "Adaptar antes de copiar" }).click();
  const j = page.getByRole("dialog");
  await expect(j).toContainText("Para Maria Silva");
  await j.getByRole("textbox").fill("Olá, Maria! Conseguiu pensar com calma? Estou à disposição.");
  await j.getByRole("button", { name: "Copiar mensagem" }).click();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("Olá, Maria! Conseguiu pensar com calma? Estou à disposição.");
  await expect(j.getByRole("link", { name: "Abrir no WhatsApp" })).toHaveAttribute("href", /wa\.me\/5511900000001\?text=Ol%C3%A1%2C%20Maria/);
});

test("criar nova mensagem associada a um procedimento", async ({ page }) => {
  await entrar(page);
  await page.goto("/mensagens");
  await page.getByRole("button", { name: "Criar nova mensagem" }).click();
  const j = page.getByRole("dialog");
  await j.getByLabel("Situação", { exact: true }).selectOption({ label: "Paciente não fechou" });
  await j.getByLabel("Procedimento (opcional)").selectOption({ label: "Implantes" });
  await j.getByLabel("Nome da mensagem").fill("Implantes — retomar");
  await j.getByLabel("Texto", { exact: true }).fill("Olá, {{nome}}! Tudo bem? Pensando em você e no seu sorriso: se quiser retomar a conversa sobre {{apelido}}");
  await j.getByRole("button", { name: "Salvar mensagem" }).click();
  await expect(j.getByRole("alert")).toContainText("Variável desconhecida: {{apelido}}");
  await j.getByLabel("Texto", { exact: true }).fill("Olá, {{nome}}! Tudo bem? Pensando em você e no seu sorriso: se quiser retomar a conversa sobre ");
  await j.getByRole("group", { name: "Inserir variável" }).getByRole("button", { name: "Procedimento" }).click();
  await expect(j.getByLabel("Texto", { exact: true })).toHaveValue(/sobre \{\{procedimento\}\}$/);
  await expect(j.getByText("Olá, Maria! Tudo bem? Pensando em você e no seu sorriso: se quiser retomar a conversa sobre facetas de porcelana")).toBeVisible();
  await j.getByLabel(/Sugerir automaticamente nesta situação/).check();
  await j.getByRole("button", { name: "Salvar mensagem" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Mensagem criada." })).toBeVisible();
  const nova = secao(page, "Paciente não fechou").getByRole("listitem", { name: "Implantes — retomar" });
  await expect(nova).toContainText("Implantes");
  await expect(nova).toContainText("Sugerida");
});

test("editar mensagem", async ({ page }) => {
  await entrar(page);
  await page.goto("/mensagens");
  await mensagem(page, "Lembrete gentil").getByRole("button", { name: "Editar mensagem Lembrete gentil" }).click();
  const j = page.getByRole("dialog");
  await j.getByLabel("Texto", { exact: true }).fill("Olá, {{nome}}! Tudo bem? Um lembrete carinhoso do pagamento de {{valor}}, com vencimento em {{vencimento}}. Qualquer coisa, estou por aqui.");
  await j.getByRole("button", { name: "Salvar mensagem" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Mensagem atualizada." })).toBeVisible();
  await expect(mensagem(page, "Lembrete gentil")).toContainText("Um lembrete carinhoso do pagamento");
});

test("a tarefa sugere a mensagem certa e permite trocar e adaptar", async ({ page }) => {
  await entrar(page);
  // Pagamento atrasado (5 dias): cobrança amigável, já com valor e vencimento — e com o texto editado acima.
  await page.getByRole("article", { name: "Paulo Ribeiro — R$ 800,00" }).getByRole("button", { name: "Ver mensagem" }).click();
  let j = page.getByRole("dialog", { name: "Mensagem sugerida" });
  await expect(j).toContainText("Situação: Cobrança amigável · sugerida: “Lembrete gentil”");
  await expect(j.getByRole("textbox")).toHaveValue(/^Olá, Paulo! Tudo bem\? Um lembrete carinhoso do pagamento de R\$ 800,00, com vencimento em \d\d\/\d\d\./);
  await j.getByRole("button", { name: "Fechar", exact: true }).click();

  // Passou pela consulta: escolhe outra mensagem da mesma situação.
  await page.getByRole("article", { name: "Maria Silva" }).getByRole("button", { name: "Ver mensagem" }).click();
  j = page.getByRole("dialog", { name: "Mensagem sugerida" });
  await expect(j).toContainText("Recebeu o orçamento de R$ 14.000,00 na consulta há 7 dias");
  await expect(j).toContainText("Situação: Passou pela primeira consulta (pensando)");
  await j.getByLabel("Usar outra mensagem pronta").selectOption({ label: "Conseguiu avaliar com calma?" });
  await expect(j.getByRole("textbox")).toHaveValue(/^Olá, Maria! Tudo bem\? Estou passando para saber se conseguiu avaliar com calma as informações sobre facetas de porcelana\./);
  await j.getByRole("textbox").fill("Olá, Maria! Passando só para saber como você está.");
  await expect(j.getByRole("link", { name: "Abrir no WhatsApp" })).toHaveAttribute("href", /text=Ol%C3%A1%2C%20Maria!%20Passando/);
  await expect(j).toContainText("A mensagem nunca é enviada pelo sistema.");
});
