import { expect, test, type Page } from "@playwright/test";
import { recriarBanco } from "./banco";

test.describe.configure({ mode: "serial" });
test.beforeAll(recriarBanco);

async function entrar(page: Page, email = "secretaria@institutocg.local") {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByRole("button", { name: "Entrar" }).click();
  await page.waitForURL(/\/hoje$/);
}

/** Daqui a N dias, avançando para segunda se cair no fim de semana. */
function diaUtil(dias: number) {
  const fmt = (d: Date) => d.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
  let d = new Date(Date.now() + dias * 86_400_000);
  while ([0, 6].includes(new Date(`${fmt(d)}T12:00:00Z`).getUTCDay())) d = new Date(d.getTime() + 86_400_000);
  return fmt(d);
}

const menu = (page: Page) => page.getByRole("navigation", { name: "Menu principal" });
const aRecuperar = (page: Page) => page.getByRole("list", { name: "A recuperar" });
const janela = (page: Page) => page.getByRole("dialog");

test("a agenda mostra a semana e quem precisa ser recuperado", async ({ page }) => {
  await entrar(page);
  await expect(menu(page).getByLabel("1 a recuperar")).toBeVisible();
  await menu(page).getByRole("link", { name: /Agenda/ }).click();
  await expect(page.getByRole("heading", { name: "Agenda", level: 1 })).toBeVisible();

  const carla = aRecuperar(page).getByRole("listitem", { name: "Carla Mendes" });
  await expect(carla).toContainText("Desmarcou a avaliação de");
  await expect(carla).toContainText("Motivo: trabalho");
  await expect(carla).toContainText("→ Entrar em contato com Carla para remarcar");
  await carla.getByText("Ver mensagem de remarcação").click();
  await expect(carla).toContainText("Vi que você precisou desmarcar a avaliação do dia");
  await expect(carla.getByRole("link", { name: "WhatsApp com mensagem" })).toHaveAttribute("href", /wa\.me\/5511900000003\?text=/);

  await expect(page.getByRole("button", { name: "14:30 Rafael Gomes" })).toContainText("Agendado");
  await expect(page.getByRole("button", { name: "10:00 Carla Mendes" })).toContainText("A recuperar");
});

test("nova consulta: paciente cadastrado, procedimento, data, horário, profissional e status", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await page.getByRole("button", { name: "Nova consulta" }).click();
  const j = janela(page);
  await j.getByLabel("Paciente").fill("beat");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Beatriz Almeida/ }).click();
  await expect(j.getByText("Beatriz Almeida")).toBeVisible();
  await expect(j.getByLabel("Procedimento")).toHaveValue(/.+/); // interesse já preenchido
  await j.getByLabel("Data").fill(diaUtil(6));
  await j.getByLabel("Horário").fill("10:00");
  await expect(j.getByLabel("Dentista")).toHaveValue(/.+/);
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Consulta marcada para" })).toContainText(
    "Próxima ação: Confirmar a avaliação de Beatriz",
  );

  // Mesmo horário: conflito, com opção de encaixe.
  await page.getByRole("button", { name: "Nova consulta" }).click();
  await j.getByLabel("Paciente").fill("fernanda");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Fernanda Lopes/ }).click();
  await j.getByLabel("Data").fill(diaUtil(6));
  await j.getByLabel("Horário").fill("10:30");
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(j.getByRole("alert")).toContainText("Horário ocupado: Beatriz Almeida às 10:00");
  await j.getByLabel("Marcar como encaixe mesmo assim").check();
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Consulta marcada" }).last()).toBeVisible();
});

test("nova consulta: paciente ainda não cadastrado e horário fora do atendimento", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await page.getByRole("button", { name: "Nova consulta" }).click();
  const j = janela(page);
  await j.getByLabel("Paciente").fill("Olívia");
  await j.getByRole("button", { name: "Paciente ainda não cadastrado" }).click();
  await expect(j.getByLabel("Nome completo")).toHaveValue("Olívia");
  await j.getByLabel("Nome completo").fill("Olívia Ramos");
  await j.getByLabel("WhatsApp").fill("(11) 98888-7777");
  await j.getByLabel("Data").fill(diaUtil(7));
  await j.getByLabel("Horário").fill("18:30");
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(j.getByRole("alert")).toHaveText("Fora do horário de atendimento (08h às 19h).");
  await j.getByLabel("Horário").fill("15:00");
  await j.getByLabel("Status").selectOption("confirmado");
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Paciente cadastrado." })).toBeVisible();
  await page.goto("/contatos?q=olivia");
  await expect(page.getByRole("link", { name: /Olívia Ramos/ })).toBeVisible();
});

test("desmarcou: registra, muda o status, cria a recuperação com mensagem e mostra no painel", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await page.getByRole("button", { name: "14:30 Rafael Gomes" }).click();
  const j = janela(page);
  await j.getByRole("button", { name: "Desmarcou" }).click();
  await j.getByRole("button", { name: "Registrar desmarcação" }).click();
  await expect(j.getByRole("alert")).toHaveText("Escolha o motivo.");
  await j.getByLabel("Motivo").selectOption({ label: "Trabalho" });
  await j.getByLabel("Observação (opcional)").fill("Viagem a trabalho");
  await j.getByRole("button", { name: "Registrar desmarcação" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Desmarcação registrada." })).toContainText(
    "Recuperação: Entrar em contato com Rafael para remarcar",
  );
  await expect(page.getByRole("button", { name: "14:30 Rafael Gomes" })).toContainText("Desmarcou");
  await expect(aRecuperar(page).getByRole("listitem", { name: "Rafael Gomes" })).toContainText("Motivo: trabalho · Viagem a trabalho");
  await expect(menu(page).getByLabel("2 a recuperar")).toBeVisible();

  // O painel "O que eu tenho que fazer hoje" mostra a recuperação na data definida (dia seguinte).
  await menu(page).getByRole("link", { name: "Hoje" }).click();
  const rafael = page.getByRole("region", { name: "Próximos dias" }).getByRole("article", { name: "Rafael Gomes" });
  await expect(rafael).toContainText("Entrar em contato com Rafael para remarcar");
  await rafael.getByRole("button", { name: "Editar ação" }).click();
  await expect(janela(page).getByRole("button", { name: "Não fazer esta ação" })).toHaveCount(0);
  await expect(janela(page).getByText("Recuperação de consulta: não pode ser descartada.")).toBeVisible();

  // A ficha mostra o evento no histórico.
  await page.goto("/contatos?q=rafael");
  await page.getByRole("link", { name: /Rafael Gomes/ }).click();
  await expect(page.getByRole("region", { name: "Histórico" })).toContainText("motivo: trabalho — Viagem a trabalho");
});

test("remarcou: atualiza a agenda e encerra a recuperação", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  await aRecuperar(page).getByRole("listitem", { name: "Carla Mendes" }).getByRole("button", { name: "Remarcar" }).click();
  const j = janela(page);
  await j.getByLabel("Data").fill(diaUtil(8));
  await j.getByLabel("Horário").fill("11:00");
  await j.getByRole("button", { name: "Remarcar", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Remarcado para" })).toContainText("A tarefa antiga foi encerrada.");
  await expect(aRecuperar(page).getByRole("listitem", { name: "Carla Mendes" })).toHaveCount(0);
  await expect(page.getByText(/Últimos 30 dias: 1 de 2 desmarcações\/faltas recuperadas/)).toBeVisible();

  await menu(page).getByRole("link", { name: "Hoje" }).click();
  await expect(page.getByRole("article", { name: "Carla Mendes" }).filter({ hasText: "para remarcar" })).toHaveCount(0);
});

test("faltou e cancelado: ações específicas de recuperação", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  const ana = page.getByRole("button", { name: "11:00 Ana Costa" });
  test.skip((await ana.count()) === 0 || diaUtil(0) !== new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" }),
    "hoje não é dia de atendimento");
  await ana.click();
  await janela(page).getByRole("button", { name: "Faltou" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Falta registrada." })).toContainText("Entrar em contato com Ana para remarcar");
  await expect(aRecuperar(page).getByRole("listitem", { name: "Ana Costa" })).toContainText("Faltou ao procedimento de");

  await page.getByRole("button", { name: "16:00 Luiza Prado" }).click();
  await janela(page).getByRole("button", { name: "Cancelar (clínica)" }).click();
  await janela(page).getByRole("button", { name: "Cancelar consulta" }).click();
  await expect(janela(page).getByRole("alert")).toHaveText("Informe o motivo do cancelamento.");
  await janela(page).getByLabel("Motivo do cancelamento").fill("Doutora em congresso");
  await janela(page).getByRole("button", { name: "Cancelar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Consulta cancelada." })).toContainText("Remarcar o horário de Luiza");
  const luiza = aRecuperar(page).getByRole("listitem", { name: "Luiza Prado" });
  await luiza.getByText("Ver mensagem de remarcação").click();
  await expect(luiza).toContainText("pedimos desculpas pelo transtorno");
});

test("ficha do paciente: agendar consulta abre a agenda com o paciente escolhido", async ({ page }) => {
  await entrar(page);
  await page.goto("/contatos?q=joao");
  await page.getByRole("link", { name: /João Lima/ }).click();
  await page.getByRole("link", { name: "Agendar consulta" }).click();
  await expect(page).toHaveURL(/\/agenda\?novo=/);
  await expect(janela(page).getByText("João Lima")).toBeVisible();
  await expect(janela(page).getByRole("button", { name: "Trocar paciente" })).toBeVisible();
});

test("dentistas: escolher na consulta e filtrar a agenda", async ({ page }) => {
  await entrar(page);
  await page.goto("/agenda");
  const filtro = page.getByRole("navigation", { name: "Filtrar por dentista" });
  for (const nome of ["Todas as dentistas", "Dra. Cristina", "Dra. Paula Reis", "Dra. Lívia Moraes"]) {
    await expect(filtro.getByRole("link", { name: nome })).toBeVisible();
  }
  await page.getByRole("button", { name: "Nova consulta" }).click();
  const j = janela(page);
  await j.getByLabel("Paciente").fill("marcos");
  await j.getByRole("list", { name: "Pacientes encontrados" }).getByRole("button", { name: /Marcos Tavares/ }).click();
  await j.getByLabel("Data").fill(diaUtil(6));
  await j.getByLabel("Horário").fill("10:00"); // mesmo horário da Beatriz, mas com outra dentista
  await j.getByLabel("Dentista").selectOption({ label: "Dra. Lívia Moraes" });
  await j.getByRole("button", { name: "Marcar consulta" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Consulta marcada" }).last()).toBeVisible();

  await page.goto(`/agenda?semana=${diaUtil(6)}`);
  await page.getByRole("navigation", { name: "Filtrar por dentista" }).getByRole("link", { name: "Dra. Lívia Moraes" }).click();
  await expect(page.getByRole("button", { name: "10:00 Marcos Tavares" })).toBeVisible();
  await expect(page.getByRole("button", { name: "10:00 Beatriz Almeida" })).toHaveCount(0);
  await page.getByRole("navigation", { name: "Filtrar por dentista" }).getByRole("link", { name: "Todas as dentistas" }).click();
  await expect(page.getByRole("button", { name: "10:00 Beatriz Almeida" })).toContainText("Dra. Cristina");
  await expect(page.getByRole("button", { name: "10:00 Marcos Tavares" })).toContainText("Dra. Lívia Moraes");
});

test("configurações: a administradora inclui dentistas; a secretária só consulta", async ({ page }) => {
  await entrar(page, "dona@institutocg.local");
  await page.goto("/configuracoes");
  const lista = page.getByRole("list", { name: "Dentistas" });
  await expect(lista.getByRole("listitem")).toHaveCount(3);
  await page.getByRole("button", { name: "Incluir dentista" }).click();
  const nova = lista.getByRole("listitem", { name: "Nova dentista" });
  await nova.getByLabel("Nome").fill("Dra. Sara Nunes");
  await nova.getByRole("button", { name: "Incluir" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Dentista incluída." })).toBeVisible();
  await expect(lista.getByRole("listitem", { name: "Dra. Sara Nunes" })).toBeVisible();

  // Desativar quem tem consultas futuras é bloqueado.
  const lívia = lista.getByRole("listitem", { name: "Dra. Lívia Moraes" });
  await lívia.getByLabel("Atende").uncheck();
  await lívia.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Remarque antes de desativar." })).toBeVisible();

  await page.context().clearCookies();
  await entrar(page);
  await page.goto("/configuracoes");
  await expect(page.getByRole("button", { name: "Incluir dentista" })).toHaveCount(0);
  await expect(page.getByRole("list", { name: "Dentistas" }).getByLabel("Nome").first()).toBeDisabled();
});

test("celular: agenda cabe na tela", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar(page);
  await page.goto("/agenda");
  const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(sobra).toBeLessThanOrEqual(0);
  await expect(page.getByRole("heading", { name: /Pacientes a recuperar/ })).toBeVisible();
});
