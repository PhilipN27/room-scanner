namespace RoomScanWeb {
  export type PortalApplicationInput = Readonly<{
    readonly document: Document;
    readonly root: HTMLElement;
    readonly client: Slice6ServiceClient;
    readonly linkCapture?: PortalLinkCapture;
    readonly allowSessionResume: boolean;
    readonly forceFallback: boolean;
    readonly pendingPIN: boolean;
    readonly navigateAfterExchange: (status: "active" | "pin_required" | "unavailable") => void;
  }>;

  export async function bootPortalApplication(input: PortalApplicationInput): Promise<void> {
    const blobs = createBlobURLRegistry();
    const cleanup = (): void => blobs.dispose();
    window.addEventListener("pagehide", cleanup, { once: true });
    let secret = input.linkCapture?.consume();
    const startedWithLink = secret !== undefined;
    try {
      loading(input.document, input.root, "Opening the published presentation…");
      if (secret !== undefined) {
        const exchange = await input.client.exchangePortalLink(secret);
        secret = undefined;
        input.navigateAfterExchange(exchange.status);
        return;
      } else if (input.pendingPIN) {
        if (await requestPIN(input.document, input.root, input.client)) input.navigateAfterExchange("active");
        else denied(input.document, input.root, blobs);
        return;
      } else if (!input.allowSessionResume) {
        denied(input.document, input.root, blobs); return;
      }
      await renderPublishedPresentation(input, blobs);
    } catch {
      secret = undefined;
      if (startedWithLink) { input.navigateAfterExchange("unavailable"); return; }
      denied(input.document, input.root, blobs);
    }
  }

  async function renderPublishedPresentation(input: PortalApplicationInput, blobs: BlobURLRegistry): Promise<void> {
    const snapshot = await input.client.portalSnapshot();
    const presentationAsset = await input.client.downloadPortalAsset({ assetID: snapshot.presentation.assetID, expectedByteCount: snapshot.presentation.byteCount });
    if (presentationAsset.contentType !== "application/json") throw new WebServiceError("invalid_asset");
    const presentationSource = await boundedBlobText(presentationAsset.blob, snapshot.presentation.byteCount);
    const presentation = parsePresentation(parseCanonicalJSON(presentationSource));
    verifyPresentationNavigation(snapshot, presentation);
    const model = createPortalViewModel(presentation, snapshot);
    const document = input.document;

    const skip = safeElement(document, "a", { text: "Skip to presentation", attributes: { class: "skip-link", href: "#presentation-content" } });
    const shell = safeElement(document, "div", { attributes: { class: `portal-shell accent-${presentation.branding.accent}` } });
    const header = portalHeader(document, presentation, input.client, blobs);
    const roomNavigation = portalRoomNavigation(document, presentation, model, async () => {
      blobs.resetForRoom();
      await renderRoom();
    });
    const notice = presentation.independentRoomNotice === undefined ? undefined : safeElement(document, "aside", { text: presentation.independentRoomNotice, attributes: { class: "coordinate-notice", role: "note", "data-testid": "independent-room-notice" } });
    const content = safeElement(document, "section", { attributes: { id: "presentation-content", class: "presentation-content", tabindex: "-1" } });
    const footer = safeElement(document, "footer", { attributes: { class: "portal-footer" } });
    footer.append(
      safeElement(document, "p", { text: "Published with RoomScanStudio", attributes: { class: "attribution", "data-testid": "roomscan-attribution" } }),
      safeElement(document, "p", { text: "Illustrative presentation. Dimensions and concepts should be independently verified before purchase, fabrication, or construction." }),
    );
    shell.append(header);
    if (roomNavigation !== undefined) shell.append(roomNavigation);
    if (notice !== undefined) shell.append(notice);
    shell.append(content, footer);
    input.root.replaceChildren(skip, shell);

    const renderRoom = async (): Promise<void> => {
      const renderEpoch = model.orientation().epoch;
      const room = model.currentRoom();
      const roomHeader = safeElement(document, "header", { attributes: { class: "room-heading" } });
      roomHeader.append(
        safeElement(document, "p", { text: presentation.kind === "property" ? "Independent room" : "Published room", attributes: { class: "eyebrow" } }),
        safeElement(document, "h2", { text: room.displayName }),
        safeElement(document, "p", { text: `Orientation reference: ${orientationLabel(room.orientation.initialView)}. No survey-grade fit or construction claim is made.`, attributes: { class: "room-disclaimer" } }),
      );
      const visualGrid = safeElement(document, "div", { attributes: { class: "visual-grid" } });
      const facts = roomFacts(document, room);
      const comparison = comparisonPanel(document, input.client, blobs, model, room, renderEpoch);
      const gallery = galleryPanel(document, input.client, blobs, model, room, renderEpoch);
      const downloads = downloadPanel(document, input.client, blobs, model.downloads());
      const feedback = snapshot.feedbackEnabled ? feedbackPanel(document, input.client) : safeElement(document, "section", { attributes: { class: "folio-card muted-card", "aria-label": "Feedback unavailable" }, text: "Feedback is not enabled for this link." });
      content.replaceChildren(roomHeader, visualGrid, facts, comparison, gallery, downloads, feedback);
      try {
        visualGrid.append(
          await floorPlanPanel(document, input.client, blobs, model, room, renderEpoch, input.forceFallback),
          await orientationPanel(document, input.client, model, room, renderEpoch, input.forceFallback),
        );
      } catch {
        if (model.orientation().epoch !== renderEpoch) return;
        denied(document, input.root, blobs);
      }
    };
    await renderRoom();
  }

  function portalHeader(document: Document, presentation: PublishedPresentation, client: Slice6ServiceClient, blobs: BlobURLRegistry): HTMLElement {
    const header = safeElement(document, "header", { attributes: { class: "portal-header" } });
    const identity = safeElement(document, "div", { attributes: { class: "brand-lockup" } });
    const words = safeElement(document, "div");
    words.append(
      safeElement(document, "p", { text: presentation.branding.businessName, attributes: { class: "business-name", "data-testid": "business-name" } }),
      safeElement(document, "h1", { text: presentation.title }),
    );
    identity.append(words);
    header.append(identity, contactBlock(document, presentation.branding));
    if (presentation.branding.logoAssetID !== undefined) {
      void portalImage(document, client, blobs, presentation.branding.logoAssetID, `${presentation.branding.businessName} logo`).then((logo) => {
        logo.classList.add("brand-logo"); identity.prepend(logo);
      }).catch(() => { /* optional logo failure does not hide the approved presentation */ });
    }
    return header;
  }

  function contactBlock(document: Document, branding: PublishedBranding): HTMLElement {
    const block = safeElement(document, "div", { attributes: { class: "contact-block", "aria-label": "Business contact" } });
    if (branding.contact.phone !== undefined) block.append(safeElement(document, "a", { text: branding.contact.phone, attributes: { href: `tel:${branding.contact.phone}` } }));
    if (branding.contact.website !== undefined) block.append(safeElement(document, "a", { text: "Visit business website", attributes: { href: branding.contact.website } }));
    return block;
  }

  function portalRoomNavigation(document: Document, presentation: PublishedPresentation, model: PortalViewModel, rerender: () => Promise<void>): HTMLElement | undefined {
    if (presentation.kind !== "property") return undefined;
    const nav = safeElement(document, "nav", { attributes: { class: "room-navigation", "aria-label": "Property rooms", "data-testid": "room-navigation" } });
    for (const room of presentation.rooms) {
      const button = safeElement(document, "button", { text: room.displayName, attributes: { type: "button", class: "room-tab", "data-room-key": room.roomKey } });
      button.addEventListener("click", () => { model.selectRoom(room.roomKey); updateSelectedRoom(nav, room.roomKey); void rerender(); });
      nav.append(button);
    }
    updateSelectedRoom(nav, presentation.rooms[0]?.roomKey ?? "");
    return nav;
  }

  function updateSelectedRoom(nav: HTMLElement, roomKey: string): void {
    for (const candidate of nav.querySelectorAll<HTMLButtonElement>("button[data-room-key]")) {
      const selected = candidate.dataset.roomKey === roomKey;
      candidate.setAttribute("aria-current", selected ? "page" : "false");
    }
  }

  async function floorPlanPanel(document: Document, client: Slice6ServiceClient, blobs: BlobURLRegistry, model: PortalViewModel, room: PublishedRoom, epoch: number, forceFallback: boolean): Promise<HTMLElement> {
    const panel = folioPanel(document, "Floor plan", "Responsive semantic plan with published dimensions.", "floor-plan-panel");
    if (!forceFallback) {
      const canvas = safeElement(document, "canvas", { attributes: { role: "img", "aria-label": `Floor plan for ${room.displayName}`, class: "plan-canvas", "data-testid": "floor-plan-canvas" } }) as HTMLCanvasElement;
      canvas.width = 960; canvas.height = 620;
      const context = canvas.getContext("2d");
      if (context !== null) {
        drawFloorPlan(context, room, { width: canvas.width, height: canvas.height, highContrast: highContrast() });
        panel.append(canvas); return panel;
      }
    }
    const fallback = await portalImage(document, client, blobs, room.assets.floorPlanAssetID, `Static floor plan for ${room.displayName}`);
    if (model.orientation().epoch !== epoch) return panel;
    fallback.classList.add("fallback-image");
    panel.append(safeElement(document, "p", { text: "Interactive Canvas is unavailable. Showing the approved static floor-plan fallback.", attributes: { class: "fallback-note", "data-testid": "canvas-fallback" } }), fallback);
    return panel;
  }

  async function orientationPanel(document: Document, client: Slice6ServiceClient, model: PortalViewModel, room: PublishedRoom, epoch: number, forceFallback: boolean): Promise<HTMLElement> {
    const panel = folioPanel(document, "3D & orientation", "Drag, swipe, or use arrow keys. The view resets when rooms change.", "orientation-panel");
    if (forceFallback) {
      panel.append(safeElement(document, "p", { text: "Interactive 3D is unavailable in fallback mode. Use the approved gallery and PDF below.", attributes: { class: "fallback-note", "data-testid": "orientation-fallback" } }));
      return panel;
    }
    const asset = await client.downloadPortalAsset({ assetID: room.assets.webGeometryAssetID });
    if (asset.contentType !== "application/json" || model.orientation().epoch !== epoch) throw new WebServiceError("invalid_asset");
    const geometry = parseWebGeometry(parseCanonicalJSON(await boundedBlobText(asset.blob, asset.byteCount)));
    const canvas = safeElement(document, "canvas", { attributes: { role: "img", tabindex: "0", "aria-label": `Interactive orientation view for ${room.displayName}`, class: "orientation-canvas", "data-testid": "orientation-canvas" } }) as HTMLCanvasElement;
    canvas.width = 960; canvas.height = 620;
    const context = canvas.getContext("2d");
    if (context === null) { panel.append(safeElement(document, "p", { text: "Interactive 3D is unavailable. Use the approved gallery and PDF below.", attributes: { class: "fallback-note" } })); return panel; }
    const redraw = (): void => { const state = model.orientation(); if (state.epoch === epoch) drawOrientation(context, geometry, { yaw: state.yaw + initialYaw(state.initialView), pitch: state.pitch + initialPitch(state.initialView), width: canvas.width, height: canvas.height, highContrast: highContrast() }); };
    redraw();
    let pointer: Readonly<{ readonly id: number; readonly x: number; readonly y: number }> | undefined;
    canvas.addEventListener("pointerdown", (event) => { pointer = Object.freeze({ id: event.pointerId, x: event.clientX, y: event.clientY }); canvas.setPointerCapture(event.pointerId); });
    canvas.addEventListener("pointermove", (event) => { if (pointer?.id !== event.pointerId) return; model.rotate((event.clientX - pointer.x) / 180, (event.clientY - pointer.y) / 180); pointer = Object.freeze({ id: event.pointerId, x: event.clientX, y: event.clientY }); redraw(); });
    canvas.addEventListener("pointerup", () => { pointer = undefined; });
    canvas.addEventListener("keydown", (event) => { const delta = orientationKey(event.key); if (delta === undefined) return; event.preventDefault(); model.rotate(delta.yaw, delta.pitch); redraw(); });
    const controls = safeElement(document, "div", { attributes: { class: "orientation-controls", "aria-label": "Orientation controls" } });
    for (const [label, yaw, pitch] of [["Rotate left", -0.2, 0], ["Tilt up", 0, -0.15], ["Tilt down", 0, 0.15], ["Rotate right", 0.2, 0]] as const) {
      const button = safeElement(document, "button", { text: label, attributes: { type: "button" } });
      button.addEventListener("click", () => { model.rotate(yaw, pitch); redraw(); }); controls.append(button);
    }
    panel.append(canvas, controls); return panel;
  }

  function roomFacts(document: Document, room: PublishedRoom): HTMLElement {
    const grid = safeElement(document, "div", { attributes: { class: "fact-grid" } });
    const dimensions = folioPanel(document, "Published dimensions", "Measurements are informative, not survey-grade.", "dimensions-panel");
    const list = safeElement(document, "dl", { attributes: { class: "dimension-list" } });
    for (const dimension of room.dimensions) list.append(safeElement(document, "dt", { text: dimension.label }), safeElement(document, "dd", { text: `${formatMeters(dimension.meters)} m` }));
    dimensions.append(list);
    const warnings = folioPanel(document, "Quality notes", "Review these limitations with the published material.", "warnings-panel");
    const warningList = safeElement(document, "ul", { attributes: { class: "warning-list" } });
    if (room.qualityWarnings.length === 0) warningList.append(safeElement(document, "li", { text: "No additional quality warnings were published." }));
    for (const warning of room.qualityWarnings) {
      const item = safeElement(document, "li", { attributes: { class: `warning-${warning.severity}` } });
      item.append(safeElement(document, "strong", { text: warningLabel(warning.severity) }), safeElement(document, "p", { text: warning.message })); warningList.append(item);
    }
    warnings.append(warningList); grid.append(dimensions, warnings); return grid;
  }

  function comparisonPanel(document: Document, client: Slice6ServiceClient, blobs: BlobURLRegistry, model: PortalViewModel, room: PublishedRoom, epoch: number): HTMLElement {
    const panel = folioPanel(document, "Original & concept", "Concepts are illustrative references and do not replace the authoritative original.", "comparison-panel");
    panel.setAttribute("data-testid", "comparison-panel");
    const comparison = room.comparisons[0];
    if (comparison === undefined) { panel.append(safeElement(document, "p", { text: "No concept comparison was approved for this room.", attributes: { class: "empty-note" } })); return panel; }
    panel.append(safeElement(document, "h3", { text: comparison.label }), safeElement(document, "p", { text: comparison.disclaimer, attributes: { class: "concept-disclaimer" } }));
    const stage = safeElement(document, "div", { attributes: { class: "comparison-stage", "aria-label": `${comparison.label} comparison` } });
    const conceptLayer = safeElement(document, "div", { attributes: { class: "concept-layer" } });
    const rangeLabel = safeElement(document, "label", { text: "Reveal concept", attributes: { for: "comparison-range" } });
    const range = safeElement(document, "input", { attributes: { id: "comparison-range", type: "range", min: "0", max: "100", step: "5", value: "50", "aria-label": "Original and concept comparison", "data-testid": "comparison-range" } }) as HTMLInputElement;
    const update = (value: number): void => { model.setComparison(value); range.value = String(Math.round(model.comparison() * 100)); conceptLayer.style.width = `${Math.round(model.comparison() * 100)}%`; };
    range.addEventListener("input", () => update(Number(range.value) / 100));
    range.addEventListener("keydown", (event) => { const next = comparisonKeyStep(model.comparison(), event.key); if (next === model.comparison()) return; event.preventDefault(); update(next); });
    update(0.5); panel.append(stage, rangeLabel, range);
    void Promise.all([
      portalImage(document, client, blobs, comparison.originalAssetID, `Original ${room.displayName}`),
      portalImage(document, client, blobs, comparison.conceptAssetID, `${comparison.label} concept`),
    ]).then(([original, concept]) => {
      if (model.orientation().epoch !== epoch) return;
      original.classList.add("comparison-image", "original-image"); concept.classList.add("comparison-image", "concept-image"); conceptLayer.append(concept); stage.append(original, conceptLayer);
    }).catch(() => { if (model.orientation().epoch === epoch) panel.append(safeElement(document, "p", { text: "The comparison is temporarily unavailable.", attributes: { class: "fallback-note" } })); });
    return panel;
  }

  function galleryPanel(document: Document, client: Slice6ServiceClient, blobs: BlobURLRegistry, model: PortalViewModel, room: PublishedRoom, epoch: number): HTMLElement {
    const panel = folioPanel(document, "Approved gallery", "Only images selected for this immutable snapshot appear here.", "gallery-panel");
    panel.setAttribute("data-testid", "gallery-panel");
    const grid = safeElement(document, "div", { attributes: { class: "gallery-grid" } }); panel.append(grid);
    if (room.assets.selectedImageAssetIDs.length === 0) { grid.append(safeElement(document, "p", { text: "No gallery images were selected." })); return panel; }
    for (const [index, assetID] of room.assets.selectedImageAssetIDs.entries()) {
      void portalImage(document, client, blobs, assetID, `${room.displayName} approved view ${index + 1}`).then((image) => { if (model.orientation().epoch === epoch) grid.append(image); }).catch(() => { /* a missing optional image remains an unavailable gallery item */ });
    }
    return panel;
  }

  function downloadPanel(document: Document, client: Slice6ServiceClient, blobs: BlobURLRegistry, downloads: readonly PortalDownloadKind[]): HTMLElement {
    const panel = folioPanel(document, "Downloads & fallback", "Each protected file is reauthorized in bounded chunks.", "downloads-panel");
    panel.setAttribute("data-testid", "downloads-panel");
    const actions = safeElement(document, "div", { attributes: { class: "download-actions" } });
    if (downloads.length === 0) actions.append(safeElement(document, "p", { text: "No downloads are enabled for this link." }));
    for (const kind of downloads) {
      const button = safeElement(document, "button", { text: downloadLabel(kind), attributes: { type: "button", class: kind === "ai_ready_package" ? "secondary-action" : "download-action", "data-download-kind": kind } });
      button.addEventListener("click", () => { void triggerPortalDownload(document, client, blobs, button as HTMLButtonElement, kind); }); actions.append(button);
    }
    panel.append(actions); return panel;
  }

  function feedbackPanel(document: Document, client: Slice6ServiceClient): HTMLElement {
    const panel = folioPanel(document, "Verified feedback", "Comments, approval, and change requests append an audited record; they cannot edit room truth.", "feedback-panel");
    panel.setAttribute("data-testid", "feedback-panel");
    const status = safeElement(document, "p", { text: "Verify an email address to leave feedback.", attributes: { class: "inline-status", role: "status", "aria-live": "polite" } });
    const emailForm = safeElement(document, "form", { attributes: { class: "feedback-form" } });
    const emailLabel = safeElement(document, "label", { text: "Email for verification", attributes: { for: "feedback-email" } });
    const email = safeElement(document, "input", { attributes: { id: "feedback-email", type: "email", name: "email", autocomplete: "email", maxlength: "320" } }) as HTMLInputElement;
    const send = safeElement(document, "button", { text: "Send verification", attributes: { type: "submit" } }); emailForm.append(emailLabel, email, send);
    const codeForm = safeElement(document, "form", { attributes: { class: "feedback-form hidden", "aria-hidden": "true" } });
    const codeLabel = safeElement(document, "label", { text: "Verification code", attributes: { for: "feedback-code" } });
    const code = safeElement(document, "input", { attributes: { id: "feedback-code", type: "text", name: "code", autocomplete: "one-time-code", maxlength: "87" } }) as HTMLInputElement;
    const verify = safeElement(document, "button", { text: "Verify", attributes: { type: "submit" } }); codeForm.append(codeLabel, code, verify);
    const actionForm = safeElement(document, "form", { attributes: { class: "feedback-form hidden", "aria-hidden": "true" } });
    const actionLabel = safeElement(document, "label", { text: "Feedback action", attributes: { for: "feedback-action" } });
    const action = safeElement(document, "select", { attributes: { id: "feedback-action", name: "action" } }) as HTMLSelectElement;
    for (const [value, label] of [["comment", "Comment"], ["approve", "Approve"], ["request_changes", "Request changes"]] as const) action.append(safeElement(document, "option", { text: label, attributes: { value } }));
    const commentLabel = safeElement(document, "label", { text: "Comment", attributes: { for: "feedback-comment" } });
    const comment = safeElement(document, "textarea", { attributes: { id: "feedback-comment", name: "comment", maxlength: "4000" } }) as HTMLTextAreaElement;
    const record = safeElement(document, "button", { text: "Record feedback", attributes: { type: "submit", class: "primary-action" } }); actionForm.append(actionLabel, action, commentLabel, comment, record);
    emailForm.addEventListener("submit", (event) => { event.preventDefault(); send.setAttribute("disabled", "true"); void client.requestFeedbackVerification(email.value).then(() => { email.value = ""; codeForm.classList.remove("hidden"); codeForm.setAttribute("aria-hidden", "false"); replaceSafeText(document, status, "Check your email, then enter the one-time verification code."); code.focus(); }).catch(() => replaceSafeText(document, status, "Feedback verification is unavailable for this link.")).finally(() => send.removeAttribute("disabled")); });
    codeForm.addEventListener("submit", (event) => { event.preventDefault(); const probe = code.value; code.value = ""; verify.setAttribute("disabled", "true"); void client.consumeFeedbackVerification(probe).then((result) => { if (result.status !== "verified") { replaceSafeText(document, status, "The code or link is unavailable. Request a new code if permitted."); return; } actionForm.classList.remove("hidden"); actionForm.setAttribute("aria-hidden", "false"); replaceSafeText(document, status, "Verified. Choose one immutable feedback action."); action.focus(); }).catch(() => replaceSafeText(document, status, "The code or link is unavailable. Request a new code if permitted.")).finally(() => verify.removeAttribute("disabled")); });
    actionForm.addEventListener("submit", (event) => { event.preventDefault(); record.setAttribute("disabled", "true"); const message = comment.value.trim(); void client.createFeedback(action.value as "comment" | "approve" | "request_changes", message.length === 0 ? undefined : message).then((result) => { comment.value = ""; actionForm.classList.add("hidden"); actionForm.setAttribute("aria-hidden", "true"); replaceSafeText(document, status, `${result.displayName} feedback was recorded. It did not alter the room or concept.`); }).catch(() => replaceSafeText(document, status, "Feedback is unavailable. The presentation may have been revoked.")).finally(() => record.removeAttribute("disabled")); });
    panel.append(status, emailForm, codeForm, actionForm); return panel;
  }

  async function requestPIN(document: Document, root: HTMLElement, client: Slice6ServiceClient): Promise<boolean> {
    const card = safeElement(document, "section", { attributes: { class: "gate-card", "aria-labelledby": "pin-title" } });
    const title = safeElement(document, "h1", { text: "PIN required", attributes: { id: "pin-title" } });
    const explanation = safeElement(document, "p", { text: "Enter the six-digit PIN supplied by the publisher. The PIN is a second gate, not encryption." });
    const status = safeElement(document, "p", { text: "", attributes: { role: "status", "aria-live": "polite" } });
    const form = safeElement(document, "form", { attributes: { class: "pin-form" } });
    const label = safeElement(document, "label", { text: "Six-digit PIN", attributes: { for: "portal-pin" } });
    const pin = safeElement(document, "input", { attributes: { id: "portal-pin", name: "pin", type: "password", inputmode: "numeric", autocomplete: "off", maxlength: "6" } }) as HTMLInputElement;
    const submit = safeElement(document, "button", { text: "Open presentation", attributes: { type: "submit", class: "primary-action" } }); form.append(label, pin, submit); card.append(title, explanation, form, status); root.replaceChildren(card); pin.focus();
    return new Promise<boolean>((resolve) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault(); let probe: string | undefined = pin.value; pin.value = ""; submit.setAttribute("disabled", "true");
        void client.verifyPIN(probe).then((result) => { probe = undefined; if (result.status === "active") resolve(true); else { replaceSafeText(document, status, "The PIN or link is unavailable. Try again later."); submit.removeAttribute("disabled"); pin.focus(); } }).catch(() => { probe = undefined; replaceSafeText(document, status, "The PIN or link is unavailable. Try again later."); submit.removeAttribute("disabled"); pin.focus(); });
      });
    });
  }

  async function portalImage(document: Document, client: Slice6ServiceClient, blobs: BlobURLRegistry, assetID: string, alt: string): Promise<HTMLImageElement> {
    try {
      const asset = await client.downloadPortalAsset({ assetID });
      if (asset.contentType !== "image/png" && asset.contentType !== "image/jpeg") throw new WebServiceError("invalid_asset");
      const source = blobs.createImageURL(asset); const image = safeElement(document, "img", { attributes: { alt: safeText(alt, 500), class: "published-image" } }) as HTMLImageElement;
      if (!source.startsWith("blob:")) throw new WebBlobError(); image.setAttribute("src", source); return image;
    } catch { blobs.resetForError(); throw new WebServiceError("unavailable"); }
  }

  async function triggerPortalDownload(document: Document, client: Slice6ServiceClient, blobs: BlobURLRegistry, button: HTMLButtonElement, kind: PortalDownloadKind): Promise<void> {
    button.disabled = true;
    try {
      const asset = await client.downloadPortalAsset({ downloadKind: kind }); const source = blobs.createDownloadURL(asset);
      const anchor = safeElement(document, "a", { text: "Download", attributes: { download: downloadFilename(kind) } }) as HTMLAnchorElement;
      if (!source.startsWith("blob:")) throw new WebBlobError(); anchor.setAttribute("href", source); anchor.click(); window.setTimeout(() => blobs.completeDownload(source), 0);
    } catch { blobs.resetForError(); replaceSafeText(document, button, "Unavailable"); }
    finally { button.disabled = false; }
  }

  function folioPanel(document: Document, title: string, description: string, className: string): HTMLElement { const panel = safeElement(document, "section", { attributes: { class: `folio-card ${className}` } }); panel.append(safeElement(document, "h2", { text: title }), safeElement(document, "p", { text: description, attributes: { class: "section-intro" } })); return panel; }
  function loading(document: Document, root: HTMLElement, message: string): void { const card = safeElement(document, "section", { attributes: { class: "gate-card loading-card", role: "status" } }); card.append(safeElement(document, "p", { text: "ROOMSCANSTUDIO / PUBLISHED", attributes: { class: "eyebrow" } }), safeElement(document, "h1", { text: message }), safeElement(document, "div", { attributes: { class: "loading-rule", "aria-hidden": "true" } })); root.replaceChildren(card); }
  function denied(document: Document, root: HTMLElement, blobs: BlobURLRegistry): void { blobs.resetForDenial(); const card = safeElement(document, "section", { attributes: { class: "gate-card denial-card", role: "alert" } }); card.append(safeElement(document, "p", { text: "ROOMSCANSTUDIO / PUBLISHED", attributes: { class: "eyebrow" } }), safeElement(document, "h1", { text: "Presentation unavailable" }), safeElement(document, "p", { text: "This link may be expired, revoked, disabled, or temporarily unavailable. Ask the publisher for a current link." }), safeElement(document, "a", { text: "Professional workspace", attributes: { href: "/p?workspace=1", class: "secondary-action" } }), safeElement(document, "p", { text: "Published with RoomScanStudio", attributes: { class: "attribution" } })); root.replaceChildren(card); }
  function verifyPresentationNavigation(snapshot: PortalSnapshotResponse, presentation: PublishedPresentation): void { if (snapshot.kind !== presentation.kind) throw new WebContractError("invalid_response"); if (snapshot.kind === "property") { if (snapshot.rooms.length !== presentation.rooms.length || snapshot.rooms.some((room, index) => room.roomKey !== presentation.rooms[index]?.roomKey || room.roomOrder !== index + 1)) throw new WebContractError("invalid_response"); } }
  async function boundedBlobText(blob: Blob, expectedBytes: number): Promise<string> { if (blob.size !== expectedBytes || expectedBytes < 1 || expectedBytes > 8_388_608) throw new WebServiceError("invalid_asset"); const source = await blob.text(); if (new TextEncoder().encode(source).byteLength !== expectedBytes) throw new WebServiceError("invalid_asset"); return source; }
  function highContrast(): boolean { return typeof window.matchMedia === "function" && window.matchMedia("(prefers-contrast: more)").matches; }
  function orientationLabel(value: InitialView): string { return value === "topDown" ? "top down" : value; }
  function initialYaw(value: InitialView): number { return value === "wall" ? Math.PI / 2 : value === "corner" ? Math.PI / 4 : 0; }
  function initialPitch(value: InitialView): number { return value === "topDown" ? -1.05 : value === "corner" ? -0.25 : 0; }
  function orientationKey(key: string): Readonly<{ readonly yaw: number; readonly pitch: number }> | undefined { if (key === "ArrowLeft") return Object.freeze({ yaw: -0.15, pitch: 0 }); if (key === "ArrowRight") return Object.freeze({ yaw: 0.15, pitch: 0 }); if (key === "ArrowUp") return Object.freeze({ yaw: 0, pitch: -0.12 }); if (key === "ArrowDown") return Object.freeze({ yaw: 0, pitch: 0.12 }); return undefined; }
  function formatMeters(value: number): string { return value.toFixed(value < 10 ? 2 : 1).replace(/(\.[0-9]*?)0+$/u, "$1").replace(/\.$/u, ""); }
  function warningLabel(value: QualitySeverity): string { return value === "advisory" ? "Advisory" : value === "reviewRecommended" ? "Review recommended" : "Insufficient evidence"; }
  function downloadLabel(value: PortalDownloadKind): string { return value === "floor_plan_pdf" ? "Floor-plan PDF" : value === "gallery_zip" ? "Gallery ZIP" : "AI Room Package"; }
  function downloadFilename(value: PortalDownloadKind): string { return value === "floor_plan_pdf" ? "roomscan-floor-plan.pdf" : value === "gallery_zip" ? "roomscan-gallery.zip" : "roomscan-ai-package.zip"; }
}
