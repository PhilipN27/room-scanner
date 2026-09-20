namespace RoomScanWeb {
  export const PROFESSIONAL_SECTIONS = Object.freeze(["properties", "concepts", "feedback", "links", "roles", "billing", "access-history", "downloads"] as const);
  export type ProfessionalSection = typeof PROFESSIONAL_SECTIONS[number];
  type PublishedProfessionalSnapshot = ProfessionalSnapshot & Readonly<{ readonly snapshotID: string }>;
  type ProfessionalWorkspaceCache = { properties: ProfessionalPropertiesWorkspace; snapshots: readonly ProfessionalSnapshot[]; selectedPublishedSnapshotID: string | undefined };
  type ProfessionalRenderedSection = Readonly<{ readonly content: HTMLElement; readonly properties?: ProfessionalPropertiesWorkspace }>;
  class StaleProfessionalRender extends Error {}

  export async function bootProfessionalApplication(input: Readonly<{ readonly document: Document; readonly root: HTMLElement; readonly client: ProfessionalClient }>): Promise<void> {
    const blobs = createBlobURLRegistry();
    window.addEventListener("pagehide", () => blobs.dispose(), { once: true });
    professionalLoading(input.document, input.root);
    try {
      const [properties, snapshots] = await Promise.all([input.client.listProperties(), input.client.listSnapshots()]);
      await renderProfessionalWorkspace(input, blobs, undefined, properties, snapshots);
    } catch {
      renderProfessionalSignIn(input, blobs);
    }
  }

  function renderProfessionalSignIn(input: Readonly<{ readonly document: Document; readonly root: HTMLElement; readonly client: ProfessionalClient }>, blobs: BlobURLRegistry): void {
    blobs.resetForRoom();
    const document = input.document;
    const card = safeElement(document, "section", { attributes: { class: "gate-card professional-signin", "aria-labelledby": "professional-signin-title" } });
    const status = safeElement(document, "p", { text: "Use the verified email attached to your professional account.", attributes: { class: "inline-status", role: "status", "aria-live": "polite" } });
    const emailForm = safeElement(document, "form", { attributes: { class: "professional-auth-form" } });
    const emailLabel = safeElement(document, "label", { text: "Professional email", attributes: { for: "professional-email" } });
    const email = safeElement(document, "input", { attributes: { id: "professional-email", type: "email", autocomplete: "email", maxlength: "320" } }) as HTMLInputElement;
    const request = safeElement(document, "button", { text: "Email a sign-in link", attributes: { type: "submit", class: "primary-action" } });
    emailForm.append(emailLabel, email, request);
    const codeForm = safeElement(document, "form", { attributes: { class: "professional-auth-form hidden", "aria-hidden": "true" } });
    const codeLabel = safeElement(document, "label", { text: "Eight-character transfer code", attributes: { for: "professional-transfer-code" } });
    const code = safeElement(document, "input", { attributes: { id: "professional-transfer-code", type: "text", autocomplete: "one-time-code", maxlength: "10", inputmode: "text" } }) as HTMLInputElement;
    const redeem = safeElement(document, "button", { text: "Open workspace", attributes: { type: "submit", class: "primary-action" } }); codeForm.append(codeLabel, code, redeem);
    emailForm.addEventListener("submit", (event) => {
      event.preventDefault(); request.setAttribute("disabled", "true");
      void input.client.requestEmailSignIn(email.value).then(() => {
        email.value = ""; codeForm.classList.remove("hidden"); codeForm.setAttribute("aria-hidden", "false"); replaceSafeText(document, status, "Check your email, confirm in the first-party page, then enter the transfer code shown there."); code.focus();
      }).catch(() => replaceSafeText(document, status, "Sign-in is unavailable. No account details were disclosed.")).finally(() => request.removeAttribute("disabled"));
    });
    codeForm.addEventListener("submit", (event) => {
      event.preventDefault(); let transfer: string | undefined = code.value; code.value = ""; redeem.setAttribute("disabled", "true");
      void input.client.redeemEmailSignIn(transfer).then(async (result) => {
        transfer = undefined;
        if ("pending" in result) { replaceSafeText(document, status, "Confirmation is still pending. Confirm the email link, then retry the transfer code."); return; }
        const [properties, snapshots] = await Promise.all([input.client.listProperties(), input.client.listSnapshots()]);
        await renderProfessionalWorkspace(input, blobs, result, properties, snapshots);
      }).catch(() => { transfer = undefined; replaceSafeText(document, status, "The transfer code or sign-in request is unavailable."); }).finally(() => redeem.removeAttribute("disabled"));
    });
    card.append(
      safeElement(document, "p", { text: "ROOMSCANSTUDIO / PROFESSIONAL", attributes: { class: "eyebrow" } }),
      safeElement(document, "h1", { text: "Published work, without the editing surface", attributes: { id: "professional-signin-title" } }),
      safeElement(document, "p", { text: "Organize properties, review concepts and client feedback, manage links, and inspect billing and access history. Capture and spatial editing stay in the iOS app." }),
      status, emailForm, codeForm,
      safeElement(document, "a", { text: "Open a client presentation instead", attributes: { href: "/p", class: "secondary-action" } }),
      safeElement(document, "p", { text: "RoomScanStudio", attributes: { class: "attribution" } }),
    );
    input.root.replaceChildren(card); email.focus();
  }

  async function renderProfessionalWorkspace(
    input: Readonly<{ readonly document: Document; readonly root: HTMLElement; readonly client: ProfessionalClient }>,
    blobs: BlobURLRegistry,
    session: ProfessionalSession | undefined,
    initialProperties: ProfessionalPropertiesWorkspace,
    initialSnapshots: readonly ProfessionalSnapshot[],
  ): Promise<void> {
    const document = input.document;
    const shell = safeElement(document, "div", { attributes: { class: "professional-shell" } });
    const sidebar = safeElement(document, "aside", { attributes: { class: "professional-sidebar" } });
    const brand = safeElement(document, "div", { attributes: { class: "professional-brand" } });
    brand.append(safeElement(document, "p", { text: "ROOMSCANSTUDIO", attributes: { class: "eyebrow" } }), safeElement(document, "h1", { text: "Professional" }), safeElement(document, "p", { text: session === undefined ? "Read-only resumed session" : `${roleLabel(session.membership.role)} workspace`, attributes: { class: "session-label" } }));
    const nav = safeElement(document, "nav", { attributes: { class: "professional-nav", "aria-label": "Professional workspace" } });
    const content = safeElement(document, "main", { attributes: { id: "professional-content", class: "professional-content", tabindex: "-1" } });
    const status = safeElement(document, "p", { text: "", attributes: { class: "workspace-status", role: "status", "aria-live": "polite" } });
    const cached: ProfessionalWorkspaceCache = { properties: initialProperties, snapshots: initialSnapshots, selectedPublishedSnapshotID: firstPublishedSnapshotID(initialSnapshots) };
    let activeSection: ProfessionalSection = "properties";
    let renderGeneration = 0;
    const select = async (section: ProfessionalSection): Promise<void> => {
      const generation = ++renderGeneration;
      activeSection = section;
      blobs.resetForRoom(); updateProfessionalNavigation(nav, section); replaceSafeText(document, status, `Loading ${sectionLabel(section)}…`);
      try {
        const rendered = await renderProfessionalSection(document, input.client, blobs, session, cached, section, () => generation === renderGeneration);
        if (generation !== renderGeneration) return;
        if (rendered.properties !== undefined) cached.properties = rendered.properties;
        content.replaceChildren(rendered.content); replaceSafeText(document, status, `${sectionLabel(section)} loaded.`); content.focus();
      } catch (error) {
        if (generation !== renderGeneration || error instanceof StaleProfessionalRender) return;
        blobs.resetForError(); content.replaceChildren(professionalUnavailable(document)); replaceSafeText(document, status, `${sectionLabel(section)} is unavailable.`);
      }
    };
    for (const section of PROFESSIONAL_SECTIONS) {
      const button = safeElement(document, "button", { text: sectionLabel(section), attributes: { type: "button", class: "professional-nav-item", "data-section": section } });
      button.addEventListener("click", () => { void select(section); }); nav.append(button);
    }
    sidebar.append(brand, nav);
    if (input.client.hasMutationAuthority()) {
      const logout = safeElement(document, "button", { text: "Sign out", attributes: { type: "button", class: "signout-button" } });
      logout.addEventListener("click", () => { logout.setAttribute("disabled", "true"); void input.client.logout().finally(() => renderProfessionalSignIn(input, blobs)); }); sidebar.append(logout);
    } else sidebar.append(safeElement(document, "p", { text: "Reauthenticate to create properties, links, or revoke access.", attributes: { class: "reauth-note" } }));
    const mainWrap = safeElement(document, "div", { attributes: { class: "professional-main" } });
    const masthead = safeElement(document, "header", { attributes: { class: "professional-masthead" } });
    masthead.append(
      safeElement(document, "p", { text: "Lightweight browser workspace", attributes: { class: "eyebrow" } }),
      safeElement(document, "h2", { text: "Published presentations" }),
      safeElement(document, "p", { text: "No capture, semantic editing, spatial editing, or live project truth mutation is available here." }),
      publishedSnapshotSelect(document, cached, () => { void select(activeSection); }),
    );
    mainWrap.append(masthead, status, content, safeElement(document, "footer", { text: "Professional web by RoomScanStudio", attributes: { class: "professional-footer attribution" } })); shell.append(sidebar, mainWrap); input.root.replaceChildren(shell);
    await select("properties");
  }

  async function renderProfessionalSection(document: Document, client: ProfessionalClient, blobs: BlobURLRegistry, session: ProfessionalSession | undefined, cached: ProfessionalWorkspaceCache, section: ProfessionalSection, isCurrent: () => boolean): Promise<ProfessionalRenderedSection> {
    if (section === "properties") {
      const properties = await client.listProperties(); ensureCurrentProfessionalRender(isCurrent);
      return Object.freeze({ content: propertiesSection(document, client, properties, cached), properties });
    }
    const published = selectedPublishedSnapshot(cached);
    if (section === "concepts") return Object.freeze({ content: await conceptsSection(document, client, blobs, published, isCurrent) });
    if (section === "feedback") {
      const feedback = published?.snapshotID === undefined ? Object.freeze([]) : await client.listFeedback({ snapshotID: published.snapshotID });
      ensureCurrentProfessionalRender(isCurrent);
      return Object.freeze({ content: feedbackSection(document, feedback) });
    }
    if (section === "links") return Object.freeze({ content: await linksSection(document, client, published, isCurrent) });
    if (section === "roles") { const members = await client.listMembers(); ensureCurrentProfessionalRender(isCurrent); return Object.freeze({ content: rolesSection(document, members) }); }
    if (section === "billing") { ensureCurrentProfessionalRender(isCurrent); return Object.freeze({ content: billingSection(document, session) }); }
    if (section === "access-history") { const events = await client.listAccessHistory(); ensureCurrentProfessionalRender(isCurrent); return Object.freeze({ content: accessSection(document, events) }); }
    return Object.freeze({ content: await downloadsSection(document, client, blobs, published?.snapshotID, isCurrent) });
  }

  function propertiesSection(document: Document, client: ProfessionalClient, workspace: ProfessionalPropertiesWorkspace, cached: ProfessionalWorkspaceCache): HTMLElement {
    const section = professionalSection(document, "Properties", "Showing the first page of up to 20 properties. Curate bounded draft room membership from available synced rooms. This browser does not expose geometry, capture, or full spatial editing.");
    const list = safeElement(document, "div", { attributes: { class: "professional-list", "data-testid": "professional-properties" } });
    const editor = safeElement(document, "div", { attributes: { class: "property-curation-editor" } });
    const refresh = async (): Promise<void> => {
      const properties = await client.listProperties();
      if (!section.isConnected) return;
      cached.properties = properties; section.replaceWith(propertiesSection(document, client, properties, cached));
    };
    const openEditor = (property: ProfessionalProperty | undefined): void => editor.replaceChildren(propertyCurationEditor(document, client, property, workspace.roomCandidates, refresh));
    if (workspace.properties.length === 0) list.append(emptyProfessional(document, "No properties have been organized yet."));
    for (const property of workspace.properties) {
      const item = professionalItem(document, property.title, `${property.roomCount} independent room${property.roomCount === 1 ? "" : "s"} · version ${property.version}`);
      const rooms = safeElement(document, "ul", { attributes: { class: "compact-list" } }); for (const room of property.rooms) rooms.append(safeElement(document, "li", { text: `${room.roomOrder}. ${room.roomKey}` })); item.append(rooms);
      const unavailable = unavailablePropertyRooms(property, workspace.roomCandidates);
      if (unavailable.length > 0) item.append(safeElement(document, "p", { text: "This property includes a room unavailable from the current synced inventory. Writes are disabled until it is available again.", attributes: { class: "property-unavailable", role: "status" } }));
      else if (client.hasMutationAuthority()) { const edit = safeElement(document, "button", { text: "Edit rooms", attributes: { type: "button" } }); edit.addEventListener("click", () => openEditor(property)); item.append(edit); }
      list.append(item);
    }
    section.append(list);
    if (client.hasMutationAuthority()) {
      const create = safeElement(document, "button", { text: "Create property curation", attributes: { type: "button", class: "primary-action" } });
      create.addEventListener("click", () => openEditor(undefined));
      section.append(create);
    }
    section.append(editor);
    return section;
  }

  function propertyCurationEditor(document: Document, client: ProfessionalClient, property: ProfessionalProperty | undefined, candidates: readonly ProfessionalRoomCandidate[], onSaved: () => Promise<void>): HTMLElement {
    const form = safeElement(document, "form", { attributes: { class: "inline-create property-curation-form", "data-testid": "property-curation-form" } });
    const titleID = "property-curation-title";
    const titleLabel = safeElement(document, "label", { text: "Property title", attributes: { for: titleID } });
    const title = safeElement(document, "input", { attributes: { id: titleID, type: "text", maxlength: "180" } }) as HTMLInputElement;
    title.required = true;
    title.value = property?.title ?? "";
    const candidatesHeading = safeElement(document, "h3", { text: "Available synced rooms" });
    const candidateCopy = safeElement(document, "p", { text: "Up to 100 safe workspace records are available here; choose up to 64 rooms. Room membership remains a draft; published snapshots verify their current source when finalized.", attributes: { class: "section-intro" } });
    const candidateList = safeElement(document, "div", { attributes: { class: "room-candidate-list" } });
    const orderHeading = safeElement(document, "h3", { text: "Room order" });
    const order = safeElement(document, "ol", { attributes: { class: "room-order-list", "data-testid": "property-room-order" } });
    const status = safeElement(document, "p", { text: "", attributes: { class: "inline-status", role: "status", "aria-live": "polite" } });
    const submit = safeElement(document, "button", { text: property === undefined ? "Create property with 0 rooms" : "Save room order", attributes: { type: "submit", class: "primary-action" } }) as HTMLButtonElement;
    const candidateByProject = new Map(candidates.map((candidate) => [candidate.projectID, candidate]));
    const unavailable = property === undefined ? Object.freeze([]) : unavailablePropertyRooms(property, candidates);
    let selected: ProfessionalPropertyRoom[] = property === undefined ? [] : property.rooms.map((room) => ({ ...room }));
    let createDraft: Readonly<{ readonly fingerprint: string; readonly key: string }> | undefined;
    const candidateInputs: Array<readonly [ProfessionalRoomCandidate, HTMLInputElement]> = [];
    const normalizedRooms = (): readonly ProfessionalPropertyRoom[] => Object.freeze(selected.map((room, index) => Object.freeze({ ...room, roomOrder: index + 1 })));
    const submitIsBlocked = (): boolean => unavailable.length > 0 || (property === undefined && selected.length === 0);
    const createKeyForDraft = (rooms: readonly ProfessionalPropertyRoom[]): string => {
      const fingerprint = JSON.stringify({ title: title.value, rooms: rooms.map((room) => [room.projectID, room.roomKey, room.roomOrder]) });
      if (createDraft?.fingerprint !== fingerprint) createDraft = Object.freeze({ fingerprint, key: professionalID("property") });
      return createDraft.key;
    };
    const updateCandidateAvailability = (): void => {
      const atCapacity = selected.length >= 64;
      for (const [candidate, input] of candidateInputs) input.disabled = unavailable.length > 0 || (!selected.some((room) => room.projectID === candidate.projectID) && atCapacity);
    };
    const renderOrder = (): void => {
      order.replaceChildren();
      for (const [index, room] of normalizedRooms().entries()) {
        const label = candidateByProject.get(room.projectID)?.title ?? room.roomKey;
        const row = safeElement(document, "li", { text: `${index + 1}. ${label}` });
        const actions = safeElement(document, "span", { attributes: { class: "room-order-actions" } });
        const earlier = safeElement(document, "button", { text: "Earlier", attributes: { type: "button", "aria-label": `Move ${label} earlier` } }) as HTMLButtonElement;
        const later = safeElement(document, "button", { text: "Later", attributes: { type: "button", "aria-label": `Move ${label} later` } }) as HTMLButtonElement;
        earlier.disabled = index === 0 || unavailable.length > 0;
        later.disabled = index === selected.length - 1 || unavailable.length > 0;
        earlier.addEventListener("click", () => { if (index === 0) return; [selected[index - 1], selected[index]] = [selected[index]!, selected[index - 1]!]; renderOrder(); });
        later.addEventListener("click", () => { if (index === selected.length - 1) return; [selected[index], selected[index + 1]] = [selected[index + 1]!, selected[index]!]; renderOrder(); });
        actions.append(earlier, later); row.append(actions); order.append(row);
      }
      submit.disabled = submitIsBlocked();
      replaceSafeText(document, submit, property === undefined ? `Create property with ${selected.length} room${selected.length === 1 ? "" : "s"}` : "Save room order");
      updateCandidateAvailability();
      replaceSafeText(document, status, unavailable.length > 0 ? "This existing curation includes a room that is no longer available. Writes fail closed until the server lists it again." : property === undefined && selected.length === 0 ? "Choose at least one available synced room before creating a property." : selected.length >= 64 ? "You can select up to 64 rooms. Remove a selected room before adding another." : "The server checks workspace eligibility and the exact property version when this draft is saved.");
    };
    if (candidates.length === 0) candidateList.append(emptyProfessional(document, "No current synced rooms are available for curation."));
    for (const [index, candidate] of candidates.entries()) {
      const inputID = `property-room-candidate-${index}`;
      const label = safeElement(document, "label", { text: `${candidate.title} · ${shortID(candidate.projectID)}`, attributes: { class: "checkbox-line", for: inputID } });
      const input = safeElement(document, "input", { attributes: { id: inputID, type: "checkbox" } }) as HTMLInputElement;
      input.checked = selected.some((room) => room.projectID === candidate.projectID);
      input.disabled = unavailable.length > 0;
      input.addEventListener("change", () => {
        if (input.checked) {
          if (selected.length >= 64) { input.checked = false; renderOrder(); return; }
          if (!selected.some((room) => room.projectID === candidate.projectID)) selected = [...selected, { roomKey: candidateRoomKey(candidate.projectID), roomOrder: selected.length + 1, projectID: candidate.projectID }];
        }
        else selected = selected.filter((room) => room.projectID !== candidate.projectID);
        renderOrder();
      });
      candidateInputs.push([candidate, input]); label.prepend(input); candidateList.append(label);
    }
    form.append(
      safeElement(document, "h3", { text: property === undefined ? "Create property curation" : "Edit room curation" }),
      titleLabel, title, candidatesHeading, candidateCopy, candidateList, orderHeading, order, submit, status,
    );
    title.addEventListener("input", renderOrder);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      submit.setAttribute("disabled", "true");
      const rooms = normalizedRooms();
      const request: ProfessionalPropertyUpsert = property === undefined
        ? { title: title.value, rooms, createIdempotencyKey: createKeyForDraft(rooms) }
        : { title: title.value, rooms, propertyID: property.propertyID, expectedVersion: property.version };
      void client.upsertProperty(request).then(onSaved).catch(() => {
        if (!form.isConnected) return;
        submit.disabled = submitIsBlocked();
        replaceSafeText(document, status, property === undefined ? "Property creation is unavailable." : "Property update is unavailable; refresh before retrying.");
      });
    });
    renderOrder();
    return form;
  }

  async function conceptsSection(document: Document, client: ProfessionalClient, blobs: BlobURLRegistry, selected: PublishedProfessionalSnapshot | undefined, isCurrent: () => boolean): Promise<HTMLElement> {
    const section = professionalSection(document, "Concepts", "Review only approved concept derivatives. Full concept editing stays native.");
    const projectID = selected?.projectID; const snapshotID = selected?.snapshotID;
    if (projectID === undefined || snapshotID === undefined) { section.append(emptyProfessional(document, "No published project is selected for concept review.")); return section; }
    const concepts = (await client.listConcepts(projectID)).filter((concept) => concept.snapshotID === snapshotID);
    ensureCurrentProfessionalRender(isCurrent);
    const staged: Array<Readonly<{ readonly concept: ProfessionalConcept; readonly asset?: DownloadedPortalAsset }>> = [];
    for (const concept of concepts) {
      if (concept.contentType !== "image/png" && concept.contentType !== "image/jpeg") { staged.push(Object.freeze({ concept })); continue; }
      try {
        const asset = await client.downloadAsset(concept.assetID, concept.byteCount);
        ensureCurrentProfessionalRender(isCurrent); staged.push(Object.freeze({ concept, asset }));
      } catch {
        ensureCurrentProfessionalRender(isCurrent); staged.push(Object.freeze({ concept }));
      }
    }
    ensureCurrentProfessionalRender(isCurrent);
    const list = safeElement(document, "div", { attributes: { class: "concept-review-grid", "data-testid": "professional-concepts" } });
    if (staged.length === 0) list.append(emptyProfessional(document, "No approved concept derivatives are available."));
    for (const { concept, asset } of staged) {
      const card = professionalItem(document, "Approved concept", `${formatProfessionalDate(concept.publishedAt)} · ${formatBytes(concept.byteCount)}`);
      if (asset !== undefined) {
        const source = blobs.createImageURL(asset); const image = safeElement(document, "img", { attributes: { alt: "Approved published concept", class: "professional-concept-image" } }) as HTMLImageElement;
        if (!source.startsWith("blob:")) throw new WebBlobError(); image.setAttribute("src", source); card.prepend(image);
      } else if (concept.contentType === "image/png" || concept.contentType === "image/jpeg") card.append(safeElement(document, "p", { text: "Concept preview unavailable." }));
      list.append(card);
    }
    section.append(list); return section;
  }

  function feedbackSection(document: Document, feedback: readonly ProfessionalFeedback[]): HTMLElement {
    const section = professionalSection(document, "Feedback", "Immutable verified client records scoped to one link and snapshot."); const list = safeElement(document, "div", { attributes: { class: "professional-list", "data-testid": "professional-feedback" } });
    if (feedback.length === 0) list.append(emptyProfessional(document, "No verified feedback has been recorded."));
    for (const item of feedback) { const card = professionalItem(document, feedbackAction(item.action), `${item.displayName} · ${formatProfessionalDate(item.occurredAt)}`); if (item.comment !== undefined) card.append(safeElement(document, "p", { text: item.comment, attributes: { class: "feedback-quote" } })); card.append(safeElement(document, "p", { text: `Snapshot ${shortID(item.snapshotID)} · link ${shortID(item.linkID)}`, attributes: { class: "fact-line" } })); list.append(card); }
    section.append(list); return section;
  }

  async function linksSection(document: Document, client: ProfessionalClient, selected: PublishedProfessionalSnapshot | undefined, isCurrent: () => boolean): Promise<HTMLElement> {
    const section = professionalSection(document, "Links", "Create, inspect, and immediately revoke high-entropy portal links."); const links = await client.listLinks(); ensureCurrentProfessionalRender(isCurrent); const list = safeElement(document, "div", { attributes: { class: "professional-list", "data-testid": "professional-links" } });
    if (links.length === 0) list.append(emptyProfessional(document, "No portal links exist."));
    for (const link of links) {
      const card = professionalItem(document, link.state === "active" ? "Active client link" : "Revoked client link", `Expires ${formatProfessionalDate(link.expiresAt)} · generation ${link.generation}`);
      card.append(safeElement(document, "p", { text: `${link.pinRequired ? "PIN required" : "No PIN"} · AI package ${link.aiEnabled ? "enabled" : "disabled"} · feedback ${link.feedbackEnabled ? "enabled" : "disabled"}`, attributes: { class: "fact-line" } }), safeElement(document, "p", { text: `${link.feedbackCount}${link.feedbackCountCapped ? "+" : ""} feedback record${link.feedbackCount === 1 ? "" : "s"}` }));
      if (link.state === "active" && client.hasMutationAuthority()) { const revoke = safeElement(document, "button", { text: "Revoke now", attributes: { type: "button", class: "danger-action" } }); revoke.addEventListener("click", () => { revoke.setAttribute("disabled", "true"); void client.revokeLink(link.linkID, link.generation).then(() => { replaceSafeText(document, revoke, "Revoked"); }).catch(() => { replaceSafeText(document, revoke, "Revocation unavailable"); revoke.removeAttribute("disabled"); }); }); card.append(revoke); }
      list.append(card);
    }
    section.append(list);
    if (selected?.snapshotID !== undefined && client.hasMutationAuthority()) section.append(createLinkForm(document, client, selected.snapshotID));
    return section;
  }

  function createLinkForm(document: Document, client: ProfessionalClient, snapshotID: string): HTMLElement {
    const form = safeElement(document, "form", { attributes: { class: "link-create-form" } }); const heading = safeElement(document, "h3", { text: "Create a 30-day link" }); const pinLabel = safeElement(document, "label", { text: "Optional six-digit PIN", attributes: { for: "new-link-pin" } }); const pin = safeElement(document, "input", { attributes: { id: "new-link-pin", type: "password", inputmode: "numeric", autocomplete: "off", maxlength: "6" } }) as HTMLInputElement;
    const aiLabel = checkbox(document, "new-link-ai", "Enable AI Room Package download"); const feedbackLabel = checkbox(document, "new-link-feedback", "Enable verified feedback"); const ai = aiLabel.querySelector("input") as HTMLInputElement; const feedback = feedbackLabel.querySelector("input") as HTMLInputElement; feedback.checked = true;
    const submit = safeElement(document, "button", { text: "Create protected link", attributes: { type: "submit", class: "primary-action" } }); const status = safeElement(document, "p", { text: "The bearer is shown once and is never placed in browser history.", attributes: { class: "inline-status", role: "status", "aria-live": "polite" } });
    form.append(heading, pinLabel, pin, aiLabel, feedbackLabel, submit, status);
    form.addEventListener("submit", (event) => { event.preventDefault(); let pinProbe: string | undefined = pin.value.length === 0 ? undefined : pin.value; pin.value = ""; submit.setAttribute("disabled", "true"); void client.createLink({ snapshotID, ...(pinProbe === undefined ? {} : { pin: pinProbe }), aiEnabled: ai.checked, feedbackEnabled: feedback.checked, idempotencyKey: professionalID("link") }).then((result) => { pinProbe = undefined; if (result.shareURL === undefined) { replaceSafeText(document, status, "Link exists. Reset it to issue a fresh bearer if needed."); return; } showShareLink(document, status, result.shareURL); }).catch(() => { pinProbe = undefined; replaceSafeText(document, status, "Link creation is unavailable."); }).finally(() => submit.removeAttribute("disabled")); }); return form;
  }

  function showShareLink(document: Document, status: HTMLElement, rawShareURL: string): void {
    let shareURL: string | undefined = rawShareURL; const wrap = safeElement(document, "div", { attributes: { class: "share-link-once" } }); const label = safeElement(document, "label", { text: "One-time share link", attributes: { for: "new-share-link" } }); const value = safeElement(document, "input", { attributes: { id: "new-share-link", type: "text", "aria-label": "One-time share link" } }) as HTMLInputElement; value.readOnly = true; value.value = shareURL; const copy = safeElement(document, "button", { text: "Copy and hide", attributes: { type: "button" } });
    copy.addEventListener("click", () => { const current = shareURL; if (current === undefined) return; void navigator.clipboard.writeText(current).then(() => { shareURL = undefined; value.value = ""; wrap.replaceChildren(safeElement(document, "p", { text: "Copied. The bearer is no longer displayed." })); }).catch(() => { value.focus(); value.select(); replaceSafeText(document, copy, "Select and copy manually"); }); }); wrap.append(label, value, copy); status.replaceChildren(wrap);
  }

  function rolesSection(document: Document, members: readonly ProfessionalMembership[]): HTMLElement { const section = professionalSection(document, "Roles", "Role visibility follows the existing server action matrix. Membership mutation is not added in this slice."); const list = safeElement(document, "div", { attributes: { class: "professional-list", "data-testid": "professional-roles" } }); if (members.length === 0) list.append(emptyProfessional(document, "No visible workspace members.")); for (const member of members) list.append(professionalItem(document, `${roleLabel(member.role)}${member.current ? " · current" : ""}`, `${member.displayName} · ${member.state}`)); section.append(list); return section; }
  function billingSection(document: Document, session: ProfessionalSession | undefined): HTMLElement { const section = professionalSection(document, "Billing", "Current entitlement and portal-traffic quota only. Production pricing and checkout are outside Slice 6."); if (session === undefined) { section.append(emptyProfessional(document, "Reauthenticate to view the current billing summary.")); return section; } const facts = safeElement(document, "dl", { attributes: { class: "billing-facts" } }); for (const [term, detail] of [["Plan", session.subscription.plan], ["Status", session.subscription.status], ["Portal period", session.quota.portalPeriod], ["Used", formatBytes(session.quota.used)], ["Reserved", formatBytes(session.quota.reserved)], ["Limit", formatBytes(session.quota.limit)]] as const) facts.append(safeElement(document, "dt", { text: term }), safeElement(document, "dd", { text: detail })); section.append(facts); return section; }
  function accessSection(document: Document, events: readonly ProfessionalAccessEvent[]): HTMLElement { const section = professionalSection(document, "Access history", "Privacy-conscious hourly events; no raw IP address, user agent, email, or bearer is shown."); const list = safeElement(document, "div", { attributes: { class: "professional-list", "data-testid": "professional-access-history" } }); if (events.length === 0) list.append(emptyProfessional(document, "No access events are visible.")); for (const event of events) list.append(professionalItem(document, `${event.action} · ${event.outcome}`, `${formatProfessionalDate(event.occurredHour)} · ${event.clientFamily}`)); section.append(list); return section; }
  async function downloadsSection(document: Document, client: ProfessionalClient, blobs: BlobURLRegistry, snapshotID: string | undefined, isCurrent: () => boolean): Promise<HTMLElement> { const section = professionalSection(document, "Downloads", "Download only active approved derivatives through revocation-aware bounded requests."); if (snapshotID === undefined) { section.append(emptyProfessional(document, "No published snapshot has downloads.")); return section; } const downloads = await client.listDownloads(snapshotID); ensureCurrentProfessionalRender(isCurrent); const list = safeElement(document, "div", { attributes: { class: "professional-list", "data-testid": "professional-downloads" } }); if (downloads.length === 0) list.append(emptyProfessional(document, "No downloads are enabled.")); for (const download of downloads) { const item = professionalItem(document, downloadKindLabel(download.kind), `${formatBytes(download.byteCount)} · ${download.contentType}`); const button = safeElement(document, "button", { text: "Download", attributes: { type: "button" } }) as HTMLButtonElement; button.addEventListener("click", () => { button.disabled = true; void client.downloadAsset(download.assetID, download.byteCount).then((asset) => { if (!isCurrent()) return; const source = blobs.createDownloadURL(asset); const anchor = safeElement(document, "a", { text: "Download", attributes: { download: professionalDownloadName(download.kind) } }) as HTMLAnchorElement; if (!source.startsWith("blob:")) throw new WebBlobError(); anchor.setAttribute("href", source); anchor.click(); window.setTimeout(() => blobs.completeDownload(source), 0); }).catch(() => { if (isCurrent()) blobs.resetForError(); }).finally(() => { button.disabled = false; }); }); item.append(button); list.append(item); } section.append(list); return section; }

  function publishedSnapshots(snapshots: readonly ProfessionalSnapshot[]): readonly PublishedProfessionalSnapshot[] { return Object.freeze(snapshots.filter((snapshot): snapshot is PublishedProfessionalSnapshot => snapshot.status === "published" && snapshot.snapshotID !== undefined)); }
  function ensureCurrentProfessionalRender(isCurrent: () => boolean): void { if (!isCurrent()) throw new StaleProfessionalRender(); }
  function firstPublishedSnapshotID(snapshots: readonly ProfessionalSnapshot[]): string | undefined { return publishedSnapshots(snapshots)[0]?.snapshotID; }
  function selectedPublishedSnapshot(cached: ProfessionalWorkspaceCache): PublishedProfessionalSnapshot | undefined {
    const options = publishedSnapshots(cached.snapshots);
    const selected = options.find((snapshot) => snapshot.snapshotID === cached.selectedPublishedSnapshotID) ?? options[0];
    cached.selectedPublishedSnapshotID = selected?.snapshotID;
    return selected;
  }
  function publishedSnapshotSelect(document: Document, cached: ProfessionalWorkspaceCache, onChange: () => void): HTMLElement {
    const options = publishedSnapshots(cached.snapshots);
    const wrap = safeElement(document, "div", { attributes: { class: "published-snapshot-select" } });
    if (options.length === 0) { wrap.append(safeElement(document, "p", { text: "No published snapshot is available for browser review.", attributes: { class: "inline-status" } })); return wrap; }
    const id = "professional-published-snapshot";
    const label = safeElement(document, "label", { text: "Published snapshot", attributes: { for: id } });
    const select = safeElement(document, "select", { attributes: { id, "data-testid": "professional-snapshot-select" } }) as HTMLSelectElement;
    for (const snapshot of options) select.append(safeElement(document, "option", { text: `Published ${snapshot.kind} · ${shortID(snapshot.projectID)} · ${formatProfessionalDate(snapshot.updatedAt)} · ${shortID(snapshot.snapshotID)}`, attributes: { value: snapshot.snapshotID } }));
    select.value = selectedPublishedSnapshot(cached)?.snapshotID ?? "";
    select.addEventListener("change", () => { cached.selectedPublishedSnapshotID = select.value; onChange(); });
    wrap.append(label, select); return wrap;
  }
  function unavailablePropertyRooms(property: ProfessionalProperty, candidates: readonly ProfessionalRoomCandidate[]): readonly ProfessionalPropertyRoom[] { const available = new Set(candidates.map((candidate) => candidate.projectID)); return Object.freeze(property.rooms.filter((room) => !available.has(room.projectID))); }
  function candidateRoomKey(projectID: string): string {
    const roomKey = projectID.slice("prj_".length);
    if (!/^[A-Za-z0-9_-]{16,128}$/u.test(roomKey)) throw new WebServiceError("invalid_response");
    return roomKey;
  }

  function professionalSection(document: Document, title: string, intro: string): HTMLElement { const section = safeElement(document, "section", { attributes: { class: "professional-section" } }); section.append(safeElement(document, "h2", { text: title }), safeElement(document, "p", { text: intro, attributes: { class: "section-intro" } })); return section; }
  function professionalItem(document: Document, title: string, meta: string): HTMLElement { const item = safeElement(document, "article", { attributes: { class: "professional-item" } }); item.append(safeElement(document, "h3", { text: title }), safeElement(document, "p", { text: meta, attributes: { class: "fact-line" } })); return item; }
  function emptyProfessional(document: Document, message: string): HTMLElement { return safeElement(document, "p", { text: message, attributes: { class: "professional-empty" } }); }
  function professionalUnavailable(document: Document): HTMLElement { return professionalItem(document, "Section unavailable", "The session, role, publication flag, or service may no longer authorize this request."); }
  function professionalLoading(document: Document, root: HTMLElement): void { const card = safeElement(document, "section", { attributes: { class: "gate-card loading-card", role: "status" } }); card.append(safeElement(document, "p", { text: "ROOMSCANSTUDIO / PROFESSIONAL", attributes: { class: "eyebrow" } }), safeElement(document, "h1", { text: "Checking the browser session…" }), safeElement(document, "div", { attributes: { class: "loading-rule", "aria-hidden": "true" } })); root.replaceChildren(card); }
  function updateProfessionalNavigation(nav: HTMLElement, section: ProfessionalSection): void { for (const button of nav.querySelectorAll<HTMLButtonElement>("button[data-section]")) button.setAttribute("aria-current", button.dataset.section === section ? "page" : "false"); }
  function checkbox(document: Document, id: string, text: string): HTMLElement { const label = safeElement(document, "label", { attributes: { class: "checkbox-line", for: id } }); const input = safeElement(document, "input", { attributes: { id, type: "checkbox" } }) as HTMLInputElement; label.append(input, document.createTextNode(safeText(text, 180))); return label; }
  function sectionLabel(value: ProfessionalSection): string { return value === "access-history" ? "Access history" : `${value[0]?.toUpperCase() ?? ""}${value.slice(1)}`; }
  function roleLabel(value: ProfessionalRole): string { return `${value[0]?.toUpperCase() ?? ""}${value.slice(1)}`; }
  function feedbackAction(value: ProfessionalFeedback["action"]): string { return value === "request_changes" ? "Request changes" : value === "approve" ? "Approved" : "Comment"; }
  function formatProfessionalDate(value: string): string { return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)); }
  function formatBytes(value: number): string { if (value < 1_024) return `${value} B`; if (value < 1_048_576) return `${(value / 1_024).toFixed(1)} KB`; return `${(value / 1_048_576).toFixed(1)} MB`; }
  function shortID(value: string): string { return value.length <= 16 ? value : `${value.slice(0, 12)}…`; }
  function professionalID(label: string): string { const bytes = new Uint8Array(16); crypto.getRandomValues(bytes); return `${label}-${toBase64URL(bytes)}`.replace(/-/gu, "_"); }
  function downloadKindLabel(value: PortalDownloadKind): string { return value === "floor_plan_pdf" ? "Floor-plan PDF" : value === "gallery_zip" ? "Gallery ZIP" : "AI Room Package"; }
  function professionalDownloadName(value: PortalDownloadKind): string { return value === "floor_plan_pdf" ? "roomscan-floor-plan.pdf" : value === "gallery_zip" ? "roomscan-gallery.zip" : "roomscan-ai-package.zip"; }
}
