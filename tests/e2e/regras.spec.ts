import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page, email: string) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

const menu = (page: Page) => page.getByRole("navigation", { name: "Menu principal" });
const regra = (page: Page, nome: string) => page.getByRole("listitem", { name: nome, exact: true });

test("secretária consulta as regras, mas não altera", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await menu(page).getByRole("link", { name: "Configurações" }).click();
  await expect(page.getByRole("heading", { name: "Configurações", level: 1 })).toBeVisible();
  await expect(page.getByText("Somente a administradora altera as regras.")).toBeVisible();
  await expect(regra(page, "Paciente desmarcou")).toContainText(
    "Ação no dia seguinte; sem resposta, mais 2 tentativas (após 3 e 4 dias). Depois disso, vai para “Sem resposta”.",
  );
  await expect(regra(page, "Parou de responder")).toContainText("vai para “Reativação”, com novo contato em 60 dias");
  await expect(page.getByRole("button", { name: /Editar regra/ })).toHaveCount(0);
});

test("administradora edita uma regra e a mensagem sugerida", async ({ page }) => {
  await entrar(page, "dona@institutocg.local");
  await page.goto("/configuracoes");
  await regra(page, "Paciente desmarcou").getByRole("button", { name: "Editar regra Paciente desmarcou" }).click();
  const j = page.getByRole("dialog");
  await j.getByLabel("Quando (dias depois)").fill("2");
  await j.getByLabel("Se não responder, tentar de novo após (dias)").fill("3, 4, 5, 6, 7, 8");
  await j.getByRole("button", { name: "Salvar regra" }).click();
  await expect(j.getByRole("alert")).toHaveText("No máximo 5 tentativas extras — evite insistir.");

  await j.getByLabel("Se não responder, tentar de novo após (dias)").fill("5");
  await j.getByLabel("Se continuar sem resposta").selectOption({ label: "Pedir para você decidir o próximo passo" });
  await expect(j.getByText("Ação em 2 dias; sem resposta, mais 1 tentativa (após 5 dias). Depois disso, você decide o próximo passo.")).toBeVisible();
  await j.getByLabel("Mensagem sugerida (WhatsApp)").fill("Oi, {primeiro_nome}! Vamos encontrar um novo horário para você?");
  await j.getByRole("button", { name: "Salvar regra" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Regra salva." })).toBeVisible();

  const card = regra(page, "Paciente desmarcou");
  await expect(card).toContainText("Ação em 2 dias; sem resposta, mais 1 tentativa (após 5 dias).");
  await card.getByText("Ver mensagem sugerida").click();
  await expect(card).toContainText("Oi, Maria! Vamos encontrar um novo horário para você?");

  // A regra editada vale para a próxima desmarcação.
  await page.goto("/funil");
  await page.getByRole("button", { name: "Mover Rafael Gomes" }).click();
  await page.getByRole("dialog").getByLabel("Etapa").selectOption({ label: "Desmarcou" });
  await expect(page.getByRole("dialog").getByText(/Regra “Paciente desmarcou”: ação em 2 dias/)).toBeVisible();
});

test("administradora desliga uma regra", async ({ page }) => {
  await entrar(page, "dona@institutocg.local");
  await page.goto("/configuracoes");
  await regra(page, "Compareceu à avaliação").getByRole("button", { name: /Editar regra/ }).click();
  await page.getByRole("dialog").getByLabel("Regra ligada (criar a tarefa automaticamente)").uncheck();
  await page.getByRole("dialog").getByRole("button", { name: "Salvar regra" }).click();
  await expect(regra(page, "Compareceu à avaliação")).toContainText("Desligada: nenhuma tarefa automática nesta situação.");
});

test("campanha de reativação: prévia, lista editável e contatos distribuídos", async ({ page }) => {
  await entrar(page, "dona@institutocg.local");
  await menu(page).getByRole("link", { name: "Campanhas" }).click();
  await expect(page.getByText("Nenhuma campanha ainda.")).toBeVisible();
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  const lista = page.getByRole("list", { name: "Pessoas da campanha" });
  await expect(lista.getByRole("checkbox")).toHaveCount(2); // Paulo (pagamento em atraso) fica de fora
  await expect(lista).toContainText("Gabriela Rocha");
  await expect(lista).toContainText("Heitor Campos");

  await page.getByLabel("Só quem aceitou comunicações").check();
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  await expect(lista.getByRole("checkbox")).toHaveCount(1);
  await page.getByLabel("Só quem aceitou comunicações").uncheck();
  await page.getByRole("button", { name: "Ver quem entra" }).click();
  await lista.getByRole("checkbox").last().uncheck();
  await expect(page.getByText("1 de 2 pessoas selecionadas")).toBeVisible();

  await page.getByLabel("Nome da campanha").fill("Sorriso em dia");
  await expect(page.getByText(/Prévia · Olá, Maria! Tudo bem\? Sentimos sua falta/)).toBeVisible();
  await page.getByRole("button", { name: "Criar campanha" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Campanha criada: 1 contato programado" })).toBeVisible();

  const campanha = page.getByRole("listitem", { name: "Sorriso em dia" });
  await expect(campanha).toContainText("Em andamento");
  await expect(campanha.getByRole("definition").first()).toHaveText("1");

  await menu(page).getByRole("link", { name: "Hoje" }).click();
  const card = page.getByRole("article").filter({ hasText: "Sorriso em dia" });
  await expect(card).toContainText("Enviar a mensagem da campanha, com um convite pessoal.");
  await card.getByRole("button", { name: "Registrar contato" }).click();
  const j = page.getByRole("dialog", { name: "Registrar contato" });
  await j.getByRole("radio", { name: "Respondeu com interesse" }).click();
  await j.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Contato registrado." })).toBeVisible();

  await page.goto("/campanhas");
  await expect(page.getByRole("listitem", { name: "Sorriso em dia" })).toContainText("1 (100%)");
});

test("secretária vê as campanhas, mas não cria", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await page.goto("/campanhas");
  await expect(page.getByText("Somente a administradora cria campanhas.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Ver quem entra" })).toHaveCount(0);
  await expect(page.getByRole("listitem", { name: "Sorriso em dia" })).toBeVisible();
});

test("fechou → concluir tratamento agenda o convite de retorno", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await page.goto("/contatos?q=ana costa");
  await page.getByRole("link", { name: /Ana Costa/ }).click();
  const naClinica = page.getByRole("region", { name: "Na clínica" });
  await naClinica.getByRole("button", { name: "Concluir tratamento" }).click();
  await expect(naClinica.getByText("O convite para a revisão fica programado para daqui a 6 meses.", { exact: false })).toBeVisible();
  await naClinica.getByRole("button", { name: "Confirmar" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Tratamento concluído." })).toContainText("convite para a revisão");
  await expect(naClinica.getByText("Convite de retorno")).toBeVisible();
  await expect(naClinica.getByRole("button", { name: "Concluir tratamento" })).toHaveCount(0);
});

test("celular: configurações e campanhas cabem na tela", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page, "dona@institutocg.local");
  for (const url of ["/configuracoes", "/campanhas"]) {
    await page.goto(url);
    const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(sobra).toBeLessThanOrEqual(0);
  }
});
