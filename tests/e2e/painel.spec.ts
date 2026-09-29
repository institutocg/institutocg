import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

async function entrar(page: Page, email: string) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Entrar" }).click();
}

const cartao = (page: Page, nome: string) => page.getByRole("article", { name: nome });
const bloco = (page: Page, titulo: string) => page.getByRole("region", { name: titulo });

function daquiA(dias: number) {
  const d = new Date(Date.now() + dias * 86_400_000);
  return d.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" }); // AAAA-MM-DD
}

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

test("sem login, o painel leva para a tela de entrada", async ({ page }) => {
  await page.goto("/hoje");
  await expect(page).toHaveURL(/\/login$/);
  await expect(page.getByText("Modo de desenvolvimento")).toBeVisible();
});

test("login sem acesso liberado mostra o aviso", async ({ page }) => {
  await entrar(page, "semacesso@teste.local");
  await expect(page).toHaveURL(/\/sem-acesso$/);
  await expect(page.getByRole("heading", { name: "Seu acesso ainda não foi liberado" })).toBeVisible();
});

test("clínica sem tarefas: estado 'Tudo em dia'", async ({ page }) => {
  await entrar(page, "vazia@teste.local");
  await expect(page.getByText("Tudo em dia", { exact: true })).toBeVisible();
  await expect(page.getByText("Tudo em dia por aqui. Nenhuma ação pendente.")).toBeVisible();
  await expect(page.getByText("Nada programado para os próximos 7 dias.")).toBeVisible();
  await expect(page.getByRole("article")).toHaveCount(0);
});

test("painel completo: atrasadas, urgente, importante, rotina e próximos dias", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await expect(page.getByRole("heading", { name: "O que eu tenho que fazer hoje?" })).toBeVisible();
  await expect(page.getByText(/Hoje você tem 9 ações: 3 atrasadas, 2 urgentes, 2 importantes e 2 de rotina\./)).toBeVisible();

  await expect(bloco(page, "Atrasadas").getByRole("article")).toHaveCount(3);
  await expect(bloco(page, "Urgente").getByRole("article")).toHaveCount(2);
  await expect(bloco(page, "Importante").getByRole("article")).toHaveCount(2);
  await expect(bloco(page, "Rotina").getByRole("article")).toHaveCount(2);
  await expect(bloco(page, "Próximos dias").getByRole("article")).toHaveCount(2);

  // Exemplo 1: Maria — orçamento enviado
  const maria = cartao(page, "Maria Silva");
  await expect(maria.getByText("Facetas de porcelana")).toBeVisible();
  await expect(maria.getByText("Orçamento de R$ 14.000,00 enviado há 7 dias")).toBeVisible();
  await expect(maria.getByText("Ação recomendada")).toBeVisible();
  await expect(maria.getByText("Fazer follow-up hoje", { exact: false })).toBeVisible();
  for (const b of ["Ver mensagem", "Registrar contato", "Concluir"]) {
    await expect(maria.getByRole("button", { name: b })).toBeVisible();
  }
  await expect(maria.getByRole("link", { name: "Abrir paciente" })).toBeVisible();

  // Exemplo 2: desmarcou — sem "Concluir" (precisa registrar o resultado)
  const carla = cartao(page, "Carla Mendes");
  await expect(carla.getByText(/Desmarcou a consulta/)).toBeVisible();
  await expect(carla.getByText("Entrar em contato para entender se deseja remarcar.")).toBeVisible();
  await expect(carla.getByRole("button", { name: "Concluir" })).toHaveCount(0);

  // Exemplo 3: pagamento previsto hoje
  const ana = cartao(page, "Ana Costa — R$ 2.700,00");
  await expect(ana.getByText("Pagamento previsto hoje")).toBeVisible();
  await expect(ana.getByText("Facetas/lentes em resina")).toBeVisible();
  await expect(ana.getByRole("link", { name: "Ver negociação" })).toBeVisible();
  await expect(ana.getByRole("button", { name: "Marcar como pago" })).toBeVisible();

  // Pagamento atrasado
  const paulo = cartao(page, "Paulo Ribeiro — R$ 800,00");
  await expect(paulo.getByText("Pagamento em atraso há 5 dias")).toBeVisible();
  await expect(bloco(page, "Atrasadas").getByText("Atrasada há 5 dias")).toBeVisible();
});

test("ver mensagem sugerida: texto editável e link do WhatsApp", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await cartao(page, "Maria Silva").getByRole("button", { name: "Ver mensagem" }).click();
  const janela = page.getByRole("dialog", { name: "Mensagem sugerida" });
  await expect(janela).toBeVisible();
  const texto = janela.getByRole("textbox");
  await expect(texto).toHaveValue(/Olá, Maria!.*facetas de porcelana/);
  await texto.fill("Olá, Maria! Posso ajudar?");
  await expect(janela.getByRole("link", { name: "Abrir no WhatsApp" })).toHaveAttribute(
    "href",
    "https://wa.me/5511900000001?text=Ol%C3%A1%2C%20Maria!%20Posso%20ajudar%3F",
  );
  await janela.getByRole("button", { name: "Fechar", exact: true }).click();
  await expect(janela).toBeHidden();
});

test("concluir: a tarefa sai de hoje e o próximo follow-up é criado sozinho", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await cartao(page, "Maria Silva").getByRole("button", { name: "Concluir" }).click();
  await expect(page.getByRole("status")).toContainText("Tarefa concluída. Próxima ação: Retornar Maria sobre facetas de porcelana");
  await expect(bloco(page, "Importante").getByRole("article", { name: "Maria Silva" })).toHaveCount(0);
  await expect(bloco(page, "Próximos dias").getByRole("article", { name: "Maria Silva" })).toBeVisible();
});

test("registrar contato: validações e 'agendou' cria a confirmação", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await cartao(page, "Beatriz Almeida").getByRole("button", { name: "Registrar contato" }).click();
  const janela = page.getByRole("dialog", { name: "Registrar contato" });
  await janela.getByRole("button", { name: "Salvar" }).click();
  await expect(janela.getByRole("alert")).toHaveText("Escolha o que aconteceu.");

  await janela.getByRole("radio", { name: "Agendou horário" }).click();
  await janela.getByRole("button", { name: "Salvar" }).click();
  await expect(janela.getByRole("alert")).toHaveText("Informe a data e o horário.");

  await janela.getByLabel("Data e horário").fill(`${daquiA(10)}T10:00`);
  await janela.getByLabel("Observação (opcional)").fill("Prefere manhã");
  await janela.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("status")).toContainText("Contato registrado. Próxima ação: Confirmar a avaliação de Beatriz");
  await expect(bloco(page, "Urgente").getByRole("article", { name: "Beatriz Almeida" })).toHaveCount(0);
});

test("não fechou exige motivo e encerra a tarefa", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await cartao(page, "Carla Mendes").getByRole("button", { name: "Registrar contato" }).click();
  const janela = page.getByRole("dialog", { name: "Registrar contato" });
  await janela.getByRole("radio", { name: "Não fechou" }).click();
  await janela.getByRole("button", { name: "Salvar" }).click();
  await expect(janela.getByRole("alert")).toHaveText("Escolha o motivo.");
  await janela.getByRole("combobox").selectOption({ label: "Valor alto (voltar a falar em 30 dias)" });
  await janela.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("status")).toContainText("Retomar conversa com Carla");
  await expect(cartao(page, "Carla Mendes")).toHaveCount(0);
});

test("marcar como pago remove o lembrete", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await cartao(page, "Ana Costa — R$ 2.700,00").getByRole("button", { name: "Marcar como pago" }).click();
  const janela = page.getByRole("dialog", { name: "Confirmar pagamento" });
  await expect(janela.getByText("Registrar o recebimento de R$ 2.700,00", { exact: false })).toBeVisible();
  await janela.getByRole("button", { name: "Confirmar pagamento" }).click();
  await expect(page.getByRole("status")).toContainText("Pagamento registrado.");
  await expect(cartao(page, "Ana Costa — R$ 2.700,00")).toHaveCount(0);
});

test("pagamento atrasado: combinou pagar em outra data", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  const paulo = cartao(page, "Paulo Ribeiro — R$ 800,00");
  await paulo.getByRole("button", { name: "Registrar contato" }).click();
  const janela = page.getByRole("dialog", { name: "Registrar contato" });
  await expect(janela.getByRole("radio")).toHaveCount(3 + 3); // canais + opções de pagamento
  await janela.getByRole("radio", { name: "Combinou pagar em outra data" }).click();
  await janela.getByLabel("Data combinada").fill(daquiA(3));
  await janela.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("status")).toContainText("Contato registrado.");
  await expect(bloco(page, "Atrasadas").getByRole("article", { name: "Paulo Ribeiro — R$ 800,00" })).toHaveCount(0);
  await expect(bloco(page, "Próximos dias").getByRole("article", { name: "Paulo Ribeiro — R$ 800,00" })).toBeVisible();
});

test("erro: concluir uma tarefa que já foi concluída em outra tela", async ({ browser }) => {
  const a = await browser.newPage();
  const b = await browser.newPage();
  await entrar(a, "secretaria@institutocg.local");
  await entrar(b, "dona@institutocg.local");
  await cartao(a, "Sofia Martins").getByRole("button", { name: "Concluir" }).click();
  await expect(a.getByRole("status")).toContainText("Tarefa concluída.");
  await cartao(b, "Sofia Martins").getByRole("button", { name: "Concluir" }).click();
  await expect(b.getByRole("alert").filter({ hasText: "Esta tarefa já foi concluída." })).toBeVisible();
  await a.close();
  await b.close();
});

test("abrir paciente mostra a ficha com o histórico", async ({ page }) => {
  await entrar(page, "secretaria@institutocg.local");
  await cartao(page, "Marcos Tavares").getByRole("link", { name: "Abrir paciente" }).click();
  await expect(page.getByRole("heading", { name: "Marcos Tavares", level: 1 })).toBeVisible();
  await expect(page.getByRole("region", { name: "Interesse" }).getByText("Periodontia")).toBeVisible();
  await expect(page.getByRole("region", { name: "Funil" }).locator('[aria-current="step"]')).toHaveText("Orçamento apresentado");
  await expect(page.getByRole("region", { name: "Histórico" }).getByText("Etapa: Avaliação realizada → Orçamento apresentado")).toBeVisible();
  await page.getByRole("navigation", { name: "Menu principal" }).getByRole("link", { name: "Hoje" }).click();
  await expect(page).toHaveURL(/\/hoje$/);
});

test("celular: tudo cabe na tela, sem rolagem lateral", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page, "dona@institutocg.local");
  await expect(page.getByRole("heading", { name: "O que eu tenho que fazer hoje?" })).toBeVisible();
  const cabe = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(cabe).toBe(true);
});
