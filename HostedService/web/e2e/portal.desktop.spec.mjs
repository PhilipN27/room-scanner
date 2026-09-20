import { fileURLToPath } from "node:url";

import { test, expect } from "@playwright/test";
import { LINK_SECRET, PIN_LINK_SECRET, FEEDBACK_CODE, resetFixture, waitForPortal, assertStoredContentIsInert, assertAccessibleSurface, assertNoHorizontalOverflowAtLargeText } from "./helpers.mjs";

const screenshot = fileURLToPath(new URL("../screenshots/portal-desktop.png", import.meta.url));

test.beforeEach(async ({ request }) => resetFixture(request));

test("interactive property portal covers floor plan, orientation, comparison, navigation, downloads, feedback, accessibility, and token confinement", async ({ page, request }) => {
  const observed = [];
  const consoleErrors = [];
  page.on("request", (candidate) => observed.push({ url: candidate.url(), headers: candidate.headers(), body: candidate.postData() ?? "" }));
  page.on("console", (message) => { if (message.type() === "error") consoleErrors.push(message.text()); });
  await page.goto(`/p#${LINK_SECRET}`);
  await waitForPortal(page);

  expect(page.url()).toMatch(/\/p$/u);
  expect(await page.evaluate(() => ({ hash: location.hash, referrer: document.referrer, state: JSON.stringify(history.state), local: JSON.stringify(localStorage), session: JSON.stringify(sessionStorage), performance: performance.getEntries().map((entry) => entry.name) }))).toEqual(expect.objectContaining({ hash: "", referrer: "", state: "null", local: "{}", session: "{}" }));
  await expect(page.getByTestId("independent-room-notice")).toContainText("do not share coordinates, alignment, connectivity, or reconstruction");
  await expect(page.getByTestId("room-navigation").getByRole("button")).toHaveCount(2);
  await expect(page.getByRole("heading", { name: "Published dimensions" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Quality notes" })).toBeVisible();
  await expect(page.getByTestId("comparison-panel")).toBeVisible();
  await expect(page.getByTestId("roomscan-attribution")).toBeVisible();
  await assertStoredContentIsInert(page);

  const orientation = page.getByTestId("orientation-canvas");
  const before = await orientation.evaluate((canvas) => canvas.toDataURL());
  await orientation.focus();
  await page.keyboard.press("ArrowRight");
  const after = await orientation.evaluate((canvas) => canvas.toDataURL());
  expect(after).not.toBe(before);
  const comparison = page.getByTestId("comparison-range");
  await comparison.focus();
  await page.keyboard.press("End");
  await expect(comparison).toHaveValue("100");
  await page.keyboard.press("Home");
  await expect(comparison).toHaveValue("0");

  const rooms = page.getByTestId("room-navigation").getByRole("button");
  await rooms.nth(1).click();
  await expect(page.locator(".room-heading h2")).not.toContainText("West parlour");
  await expect(page.getByTestId("comparison-range")).toHaveValue("50");
  await expect(page.getByTestId("orientation-canvas")).toBeVisible();

  const downloadEvent = page.waitForEvent("download");
  await page.getByRole("button", { name: "Floor-plan PDF" }).click();
  expect((await downloadEvent).suggestedFilename()).toBe("roomscan-floor-plan.pdf");

  await page.getByLabel("Email for verification").fill("client@example.test");
  await page.getByRole("button", { name: "Send verification" }).click();
  await page.getByLabel("Verification code").fill(FEEDBACK_CODE);
  await page.getByRole("button", { name: "Verify", exact: true }).click();
  await page.getByLabel("Feedback action").selectOption("request_changes");
  await page.getByLabel("Comment", { exact: true }).fill("Please revisit the daylight concept.");
  await page.getByRole("button", { name: "Record feedback" }).click();
  await expect(page.getByTestId("feedback-panel").getByRole("status")).toContainText("did not alter the room or concept");

  await page.screenshot({ path: screenshot, fullPage: true });
  await assertAccessibleSurface(page);
  await assertNoHorizontalOverflowAtLargeText(page);
  await page.evaluate((secret) => window.dispatchEvent(new ErrorEvent("error", { message: secret })), LINK_SECRET);
  await page.waitForTimeout(100);

  for (const entry of observed) {
    expect(entry.url).not.toContain(LINK_SECRET);
    expect(entry.body).not.toContain(LINK_SECRET);
    expect(entry.headers.referer ?? "").not.toContain(LINK_SECRET);
    if ((entry.headers.authorization ?? "").includes(LINK_SECRET)) expect(new URL(entry.url).pathname).toBe("/portal/link/exchange");
  }
  const browserState = await page.evaluate(() => `${location.href}\n${document.referrer}\n${JSON.stringify(history.state)}\n${performance.getEntries().map((entry) => entry.name).join("\n")}\n${JSON.stringify(localStorage)}\n${JSON.stringify(sessionStorage)}`);
  expect(browserState).not.toContain(LINK_SECRET);
  const report = await (await request.get("/__control/report")).json();
  expect(report.rawTokenFields).toBe(false);
  expect(report.feedbackCount).toBe(1);
  expect(report.requests.some((entry) => entry.queryHasCanary || entry.refererHasCanary || entry.bodyHasCanary)).toBe(false);
  expect(report.requests.filter((entry) => entry.feedbackCodeExpected)).toEqual([expect.objectContaining({ path: "/portal/feedback/verification/consume", feedbackCodeOutsideConsume: false })]);
  expect(report.requests.some((entry) => entry.feedbackCodeOutsideConsume)).toBe(false);
  expect(report.requests.filter((entry) => entry.authorizationKind === "portal_link")).toEqual([expect.objectContaining({ path: "/portal/link/exchange", authorizationExpected: true })]);
  expect(report.requests.some((entry) => entry.path.includes("analytics") || entry.path.includes("crash"))).toBe(false);
  expect(consoleErrors).toEqual([]);
});

test("PIN gate fails closed, clears each probe, and opens only on the correct value", async ({ page }) => {
  await page.goto(`/p#${PIN_LINK_SECRET}`);
  await expect(page.getByRole("heading", { name: "PIN required" })).toBeVisible();
  const input = page.getByLabel("Six-digit PIN");
  await input.fill("000000");
  await page.getByRole("button", { name: "Open presentation" }).click();
  await expect(input).toHaveValue("");
  await expect(page.getByRole("status")).toContainText("PIN or link is unavailable");
  await input.fill("123456");
  await page.getByRole("button", { name: "Open presentation" }).click();
  await waitForPortal(page);
});

test("an already active session and protected asset fail immediately after revocation", async ({ page, request }) => {
  await page.goto(`/p#${LINK_SECRET}`);
  await waitForPortal(page);
  expect((await request.post("/__control/revoke")).ok()).toBe(true);
  await page.getByTestId("room-navigation").getByRole("button").nth(1).click();
  await expect(page.getByRole("heading", { name: "Presentation unavailable" })).toBeVisible();
  await expect(page.locator("img[src^='blob:']")).toHaveCount(0);
});
