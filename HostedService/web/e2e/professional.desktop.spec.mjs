import { fileURLToPath } from "node:url";

import { test, expect } from "@playwright/test";
import { resetFixture, assertStoredContentIsInert, assertAccessibleSurface, assertNoHorizontalOverflowAtLargeText } from "./helpers.mjs";

const screenshot = fileURLToPath(new URL("../screenshots/professional-desktop.png", import.meta.url));
const FIRST_PUBLISHED_SNAPSHOT_ID = `snp_${"s".repeat(16)}`;
const SECOND_PUBLISHED_SNAPSHOT_ID = `snp_${"t".repeat(16)}`;
const PENDING_SNAPSHOT_ID = `snp_${"q".repeat(16)}`;
const REJECTED_SNAPSHOT_ID = `snp_${"r".repeat(16)}`;
const FIRST_PROJECT_ID = `prj_${"p".repeat(16)}`;
const SECOND_PROJECT_ID = `prj_${"u".repeat(16)}`;
const UNPUBLISHED_PROJECT_ID = `prj_${"x".repeat(128)}`;

test.beforeEach(async ({ request }) => resetFixture(request));

test("verified professional sign-in exposes exactly the eight bounded flows and keeps stored content inert", async ({ page }) => {
  await page.goto("/p?workspace=1");
  await expect(page.getByRole("heading", { name: "Published work, without the editing surface" })).toBeVisible();
  await page.getByLabel("Professional email").fill("owner@example.test");
  await page.getByRole("button", { name: "Email a sign-in link" }).click();
  await page.getByLabel("Eight-character transfer code").fill("23456789");
  await page.getByRole("button", { name: "Open workspace" }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Professional" })).toBeVisible();
  const nav = page.getByRole("navigation", { name: "Professional workspace" });
  await expect(nav.getByRole("button")).toHaveText(["Properties", "Concepts", "Feedback", "Links", "Roles", "Billing", "Access history", "Downloads"]);
  const snapshotSelect = page.getByLabel("Published snapshot");
  await expect(snapshotSelect).toHaveValue(FIRST_PUBLISHED_SNAPSHOT_ID);
  expect(await snapshotSelect.locator("option").evaluateAll((options) => options.map((option) => option.value))).toEqual([FIRST_PUBLISHED_SNAPSHOT_ID, SECOND_PUBLISHED_SNAPSHOT_ID]);
  expect(await snapshotSelect.locator("option").evaluateAll((options) => options.map((option) => option.value))).not.toContain(PENDING_SNAPSHOT_ID);
  expect(await snapshotSelect.locator("option").evaluateAll((options) => options.map((option) => option.value))).not.toContain(REJECTED_SNAPSHOT_ID);
  await expect(page.getByTestId("professional-properties")).toContainText("window.__roomscanStoredCanary=1");
  await expect(page.getByText("unavailable from the current synced inventory")).toBeVisible();
  await page.getByRole("button", { name: "Create property curation" }).click();
  await page.getByLabel("Property title").fill("Two room draft");
  await page.getByLabel(/^Living room/u).check();
  await page.getByLabel(/^Unpublished long draft room/u).check();
  await page.getByRole("button", { name: "Move Unpublished long draft room earlier" }).click();
  await page.getByRole("button", { name: "Create property with 2 rooms" }).click();
  await expect(page.getByTestId("professional-properties")).toContainText("Two room draft");
  await page.getByTestId("professional-properties").getByRole("button", { name: "Edit rooms" }).first().click();
  await page.getByRole("button", { name: "Move Kitchen earlier" }).click();
  await page.getByRole("button", { name: "Save room order" }).click();
  await expect(page.getByTestId("property-curation-form")).toHaveCount(0);
  await expect(page.getByTestId("professional-properties")).toContainText("Aster Portfolio");
  await assertStoredContentIsInert(page);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: screenshot, fullPage: true });

  await nav.getByRole("button", { name: "Concepts" }).click();
  await expect(page.getByText("Loading Concepts…")).toBeVisible();
  await snapshotSelect.selectOption(SECOND_PUBLISHED_SNAPSHOT_ID);
  const selectedConcepts = page.getByTestId("professional-concepts").getByRole("img", { name: "Approved published concept" });
  await expect(selectedConcepts).toHaveCount(1);
  await page.waitForTimeout(450);
  await expect(selectedConcepts).toHaveCount(1);
  await nav.getByRole("button", { name: "Feedback" }).click();
  await expect(page.getByTestId("professional-feedback")).toContainText("Second published snapshot feedback");
  await assertStoredContentIsInert(page);
  await nav.getByRole("button", { name: "Links" }).click();
  await page.getByLabel("Optional six-digit PIN").fill("654321");
  await page.getByLabel("Enable AI Room Package download").check();
  await page.getByRole("button", { name: "Create protected link" }).click();
  const oneTimeShare = page.getByLabel("One-time share link");
  await expect(oneTimeShare).toHaveValue(/^https:\/\/portal\.roomscanstudio\.test\/p#[A-Za-z0-9_-]{43}$/u);
  expect(page.url()).not.toContain("#");
  await expect(page.getByLabel("Optional six-digit PIN")).toHaveValue("");
  await page.getByRole("button", { name: "Revoke now" }).click();
  await expect(page.getByRole("button", { name: "Revoked" })).toBeVisible();
  await nav.getByRole("button", { name: "Roles" }).click();
  await expect(page.getByTestId("professional-roles")).toContainText("Owner");
  await nav.getByRole("button", { name: "Billing" }).click();
  await expect(page.getByText("Portal period", { exact: true })).toBeVisible();
  await nav.getByRole("button", { name: "Access history" }).click();
  await expect(page.getByTestId("professional-access-history")).toContainText("desktop");
  await nav.getByRole("button", { name: "Downloads" }).click();
  await expect(page.getByTestId("professional-downloads").getByRole("button", { name: "Download" })).toHaveCount(2);
  const report = await (await page.request.get("/__control/report")).json();
  expect(report.publishedSnapshotRequests).toEqual({
    conceptProjectIDs: [FIRST_PROJECT_ID, SECOND_PROJECT_ID],
    feedbackSnapshotIDs: [SECOND_PUBLISHED_SNAPSHOT_ID],
    downloadSnapshotIDs: [SECOND_PUBLISHED_SNAPSHOT_ID],
    linkSnapshotIDs: [SECOND_PUBLISHED_SNAPSHOT_ID],
  });
  expect(report.propertyUpserts.slice(0, 2)).toMatchObject([
    {
      operation: "create",
      expectedVersion: null,
      propertyID: null,
      rooms: [
        { projectID: UNPUBLISHED_PROJECT_ID, roomKey: "x".repeat(128), roomOrder: 1 },
        { projectID: FIRST_PROJECT_ID, roomKey: "p".repeat(16), roomOrder: 2 },
      ],
    },
    {
      operation: "update",
      expectedVersion: 3,
      propertyID: `prop_${"q".repeat(16)}`,
      rooms: [
        { projectID: SECOND_PROJECT_ID, roomKey: "room-kitchen", roomOrder: 1 },
        { projectID: FIRST_PROJECT_ID, roomKey: "room-living", roomOrder: 2 },
      ],
    },
  ]);
  await assertAccessibleSurface(page);
  await assertNoHorizontalOverflowAtLargeText(page);
  await nav.getByRole("button", { name: "Properties", exact: true }).click();
  await page.getByRole("button", { name: "Create property curation" }).click();
  const retryForm = page.getByTestId("property-curation-form");
  await retryForm.getByLabel("Property title").fill("Retry-safe draft");
  await retryForm.getByLabel(/^Kitchen/u).check();
  await retryForm.getByRole("button", { name: "Create property with 1 room" }).click();
  await expect(retryForm.getByRole("status")).toHaveText("Property creation is unavailable.");
  await expect(retryForm.getByRole("button", { name: "Create property with 1 room" })).toBeEnabled();
  await retryForm.getByRole("button", { name: "Create property with 1 room" }).click();
  await expect(page.getByTestId("professional-properties")).toContainText("Retry-safe draft");
  await page.getByRole("button", { name: "Create property curation" }).click();
  const rotatingForm = page.getByTestId("property-curation-form");
  await rotatingForm.getByLabel("Property title").fill("Rotate key draft");
  await rotatingForm.getByLabel(/^Kitchen/u).check();
  await rotatingForm.getByRole("button", { name: "Create property with 1 room" }).click();
  await expect(rotatingForm.getByRole("status")).toHaveText("Property creation is unavailable.");
  await rotatingForm.getByLabel("Property title").fill("Rotate key revised");
  await rotatingForm.getByRole("button", { name: "Create property with 1 room" }).click();
  await expect(page.getByTestId("professional-properties")).toContainText("Rotate key revised");
  await page.getByRole("button", { name: "Create property curation" }).click();
  const boundedForm = page.getByTestId("property-curation-form");
  for (let index = 1; index <= 64; index += 1) await boundedForm.getByLabel(`Bounded candidate ${String(index).padStart(2, "0")}`).check();
  await expect(boundedForm.getByRole("status")).toHaveText("You can select up to 64 rooms. Remove a selected room before adding another.");
  await expect(boundedForm.getByLabel("Bounded candidate 65")).toBeDisabled();
  const finalReport = await (await page.request.get("/__control/report")).json();
  const retryRequests = finalReport.propertyUpserts.filter((entry) => entry.title === "Retry-safe draft");
  expect(retryRequests).toHaveLength(2);
  expect(retryRequests[0].createIdempotencyKey).toBe(retryRequests[1].createIdempotencyKey);
  const rotatedRequests = finalReport.propertyUpserts.filter((entry) => entry.title === "Rotate key draft" || entry.title === "Rotate key revised");
  expect(rotatedRequests).toHaveLength(2);
  expect(rotatedRequests[0].createIdempotencyKey).not.toBe(rotatedRequests[1].createIdempotencyKey);
  await expect(page.getByText(/capture, semantic editing, spatial editing/u)).toBeVisible();
  await expect(page.getByRole("button", { name: /capture|spatial edit/u })).toHaveCount(0);
});
