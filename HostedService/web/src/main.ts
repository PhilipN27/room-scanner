namespace RoomScanWeb {
  function startPublishedWeb(): void {
    const root = document.getElementById("roomscan-portal");
    if (!(root instanceof HTMLElement)) return;
    const href = window.location.href;
    const url = new URL(href);
    const hasFragment = url.hash.length > 1;
    const forceFallback = url.searchParams.get("fallback") === "1";
    const navigateAfterExchange = (status: "active" | "pin_required" | "unavailable"): void => {
      window.location.replace(portalContinuationPath(forceFallback, status === "pin_required"));
    };
    if (hasFragment) {
      const linkCapture = capturePortalLink({ href, replace: (path) => window.history.replaceState(null, "", path) });
      const client = createServiceClient({ fetch: (path, init) => window.fetch(path, init) });
      void bootPortalApplication({ document, root, client, linkCapture, allowSessionResume: false, forceFallback, pendingPIN: false, navigateAfterExchange });
      return;
    }
    if (url.searchParams.get("workspace") === "1") {
      const client = createProfessionalClient({ fetch: (path, init) => window.fetch(path, init) });
      void bootProfessionalApplication({ document, root, client });
      return;
    }
    const client = createServiceClient({ fetch: (path, init) => window.fetch(path, init) });
    const pendingPIN = url.searchParams.get("pin") === "1";
    void bootPortalApplication({ document, root, client, allowSessionResume: !pendingPIN, forceFallback, pendingPIN, navigateAfterExchange });
  }

  startPublishedWeb();
}
