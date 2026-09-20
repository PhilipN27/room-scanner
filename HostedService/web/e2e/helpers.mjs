import { expect } from "@playwright/test";

export const LINK_SECRET = "A".repeat(43);
export const PIN_LINK_SECRET = "Q".repeat(43);
export const FEEDBACK_CODE = `${"C".repeat(43)}.${"D".repeat(43)}`;
export const STORED_CANARY_MARKER = "window.__roomscanStoredCanary=1";

export async function resetFixture(request) {
  const response = await request.post("/__control/reset");
  expect(response.ok()).toBe(true);
}

export async function waitForPortal(page) {
  await expect(page.getByRole("heading", { level: 1, name: /Aster House/u })).toBeVisible();
  await expect(page.getByTestId("floor-plan-canvas")).toBeVisible();
  await expect(page.getByTestId("orientation-canvas")).toBeVisible();
  await expect(page.locator("[data-testid='gallery-panel'] img").first()).toBeVisible();
}

export async function assertStoredContentIsInert(page) {
  await expect(page.locator('img[src="x"],svg[onload],[onerror]')).toHaveCount(0);
  expect(await page.evaluate(() => globalThis.__roomscanStoredCanary)).toBeUndefined();
  await expect(page.getByText(STORED_CANARY_MARKER, { exact: false }).first()).toBeVisible();
}

export async function assertAccessibleSurface(page) {
  const audit = await page.evaluate(() => {
    const ids = [...document.querySelectorAll("[id]")].map((node) => node.id);
    const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
    const visible = (node) => {
      const style = getComputedStyle(node); const box = node.getBoundingClientRect();
      return style.visibility !== "hidden" && style.display !== "none" && box.width > 0 && box.height > 0;
    };
    const controls = [...document.querySelectorAll("button,input,select,textarea")].filter(visible);
    const unnamed = controls.filter((node) => {
      if (node instanceof HTMLButtonElement) return (node.textContent ?? "").trim().length === 0 && !node.getAttribute("aria-label");
      const label = node.id.length === 0 ? null : document.querySelector(`label[for="${CSS.escape(node.id)}"]`);
      return label === null && !node.getAttribute("aria-label");
    }).map((node) => node.outerHTML.slice(0, 120));
    const smallTargets = controls.filter((node) => {
      const box = node.getBoundingClientRect(); return box.width < 44 || box.height < 44;
    }).map((node) => `${node.tagName}:${node.getAttribute("aria-label") ?? node.textContent ?? node.id}`);
    const missingAlt = [...document.querySelectorAll("img")].filter((image) => !image.hasAttribute("alt")).length;
    const headingLevels = [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")].filter(visible).map((heading) => Number(heading.tagName.slice(1)));
    const headingJumps = headingLevels.filter((level, index) => index > 0 && level > (headingLevels[index - 1] ?? level) + 1);
    return {
      duplicates,
      unnamed,
      smallTargets,
      missingAlt,
      headingJumps,
      horizontalOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    };
  });
  expect(audit.duplicates).toEqual([]);
  expect(audit.unnamed).toEqual([]);
  expect(audit.smallTargets).toEqual([]);
  expect(audit.missingAlt).toBe(0);
  expect(audit.headingJumps).toEqual([]);
  expect(audit.horizontalOverflow).toBeLessThanOrEqual(1);
}

export async function assertNoHorizontalOverflowAtLargeText(page) {
  await page.evaluate(() => { document.documentElement.style.fontSize = "200%"; });
  await page.waitForTimeout(50);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
  await page.evaluate(() => { document.documentElement.style.fontSize = ""; });
}
