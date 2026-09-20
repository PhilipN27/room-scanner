import { fileURLToPath } from "node:url";

import { test, expect } from "@playwright/test";
import { LINK_SECRET, resetFixture, assertStoredContentIsInert, assertAccessibleSurface, assertNoHorizontalOverflowAtLargeText } from "./helpers.mjs";

const screenshot = fileURLToPath(new URL("../screenshots/portal-mobile-fallback.png", import.meta.url));

test.beforeEach(async ({ request }) => resetFixture(request));

test("mobile portal presents bounded static fallback with responsive navigation and accessible controls", async ({ page }) => {
  await page.goto(`/p?fallback=1#${LINK_SECRET}`);
  await expect(page.getByRole("heading", { level: 1, name: /Aster House/u })).toBeVisible();
  await expect(page.getByTestId("canvas-fallback")).toBeVisible();
  await expect(page.getByTestId("orientation-fallback")).toBeVisible();
  await expect(page.getByTestId("orientation-canvas")).toHaveCount(0);
  await expect(page.locator(".floor-plan-panel img")).toBeVisible();
  await expect(page.getByTestId("comparison-range")).toBeVisible();
  await expect(page.getByTestId("downloads-panel")).toBeVisible();
  await assertStoredContentIsInert(page);
  await assertAccessibleSurface(page);
  await assertNoHorizontalOverflowAtLargeText(page);
  await page.screenshot({ path: screenshot, fullPage: true });
});
