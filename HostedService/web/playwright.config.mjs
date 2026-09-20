const baseURL = process.env.ROOMSCAN_WEB_BASE_URL ?? "http://127.0.0.1:4173";

export default {
  testDir: "./e2e",
  outputDir: "./test-results/artifacts",
  timeout: 30_000,
  expect: { timeout: 8_000 },
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: [["line"], ["json", { outputFile: "test-results/results.json" }]],
  use: {
    baseURL,
    browserName: "chromium",
    headless: true,
    ignoreHTTPSErrors: false,
    reducedMotion: "reduce",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [
    {
      name: "desktop-chromium",
      testMatch: /.*\.desktop\.spec\.mjs/u,
      use: { viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 },
    },
    {
      name: "mobile-chromium",
      testMatch: /.*\.mobile\.spec\.mjs/u,
      use: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, isMobile: true, hasTouch: true },
    },
  ],
};
