import { fileURLToPath } from "node:url";

import { test, expect } from "@playwright/test";
import { resetFixture, assertAccessibleSurface, assertNoHorizontalOverflowAtLargeText } from "./helpers.mjs";

const screenshot = fileURLToPath(new URL("../screenshots/professional-mobile.png", import.meta.url));
const curationScreenshot = fileURLToPath(new URL("../screenshots/professional-curation-mobile.png", import.meta.url));
const FIRST_PUBLISHED_SNAPSHOT_ID = `snp_${"s".repeat(16)}`;
const SECOND_PUBLISHED_SNAPSHOT_ID = `snp_${"t".repeat(16)}`;
const PENDING_SNAPSHOT_ID = `snp_${"q".repeat(16)}`;
const REJECTED_SNAPSHOT_ID = `snp_${"r".repeat(16)}`;

test.beforeEach(async ({ request }) => resetFixture(request));

test("mobile professional workspace reflows its bounded navigation and presents signed-in room curation controls", async ({ page, context }) => {
  await context.addCookies([
    { name: "roomscan_professional", value: "active", url: "http://127.0.0.1:4173/professional" },
    { name: "roomscan_professional", value: "active", url: "http://127.0.0.1:4173/publications" },
  ]);
  await page.goto("/p?workspace=1");
  await expect(page.getByRole("heading", { level: 1, name: "Professional" })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Professional workspace" }).getByRole("button")).toHaveCount(8);
  const snapshotSelect = page.getByLabel("Published snapshot");
  await expect(snapshotSelect).toHaveValue(FIRST_PUBLISHED_SNAPSHOT_ID);
  expect(await snapshotSelect.locator("option").evaluateAll((options) => options.map((option) => option.value))).toEqual([FIRST_PUBLISHED_SNAPSHOT_ID, SECOND_PUBLISHED_SNAPSHOT_ID]);
  expect(await snapshotSelect.locator("option").evaluateAll((options) => options.map((option) => option.value))).not.toContain(PENDING_SNAPSHOT_ID);
  expect(await snapshotSelect.locator("option").evaluateAll((options) => options.map((option) => option.value))).not.toContain(REJECTED_SNAPSHOT_ID);
  await expect(page.getByText("Read-only resumed session")).toBeVisible();
  await assertAccessibleSurface(page);
  await assertNoHorizontalOverflowAtLargeText(page);
  await page.screenshot({ path: screenshot, fullPage: true });

  await context.clearCookies();
  await page.goto("/p?workspace=1");
  await page.getByLabel("Professional email").fill("owner@example.test");
  await page.getByRole("button", { name: "Email a sign-in link" }).click();
  await page.getByLabel("Eight-character transfer code").fill("23456789");
  await page.getByRole("button", { name: "Open workspace" }).click();
  await expect(page.getByText("Owner workspace")).toBeVisible();
  await page.getByRole("button", { name: "Create property curation" }).click();
  const curation = page.getByTestId("property-curation-form");
  await curation.getByLabel("Property title").fill("Mobile room draft");
  await curation.getByLabel(/^Living room/u).check();
  await curation.getByLabel(/^Unpublished long draft room/u).check();
  await expect(curation.getByTestId("property-room-order").getByRole("button", { name: "Move Unpublished long draft room earlier" })).toBeVisible();
  await page.screenshot({ path: curationScreenshot, fullPage: true });
});
