namespace RoomScanWeb {
  export type ProfessionalRole = "owner" | "admin" | "editor" | "viewer";
  export type ProfessionalMembership = Readonly<{ readonly memberID: string; readonly displayName: string; readonly role: ProfessionalRole; readonly state: "active" | "invited" | "suspended"; readonly current?: boolean }>;
  export type ProfessionalSession = Readonly<{
    readonly expiresAt: string;
    readonly membership: ProfessionalMembership;
    readonly subscription: Readonly<{ readonly plan: string; readonly status: string; readonly currentPeriodEnd?: string }>;
    readonly quota: Readonly<{ readonly policyVersion: number; readonly portalPeriod: string; readonly used: number; readonly reserved: number; readonly limit: number }>;
  }>;
  export type ProfessionalPropertyRoom = Readonly<{ readonly roomKey: string; readonly roomOrder: number; readonly projectID: string }>;
  export type ProfessionalProperty = Readonly<{ readonly propertyID: string; readonly title: string; readonly version: number; readonly roomCount: number; readonly rooms: readonly ProfessionalPropertyRoom[] }>;
  export type ProfessionalRoomCandidate = Readonly<{ readonly projectID: string; readonly title: string }>;
  export type ProfessionalPropertiesWorkspace = Readonly<{ readonly properties: readonly ProfessionalProperty[]; readonly roomCandidates: readonly ProfessionalRoomCandidate[] }>;
  export type ProfessionalPropertyUpsert = Readonly<{ readonly title: string; readonly rooms: readonly ProfessionalPropertyRoom[]; readonly propertyID?: string; readonly expectedVersion?: number; readonly createIdempotencyKey?: string }>;
  export type ProfessionalConcept = Readonly<{ readonly snapshotID: string; readonly assetID: string; readonly contentType: ApprovedAssetContentType; readonly byteCount: number; readonly publishedAt: string }>;
  export type ProfessionalSnapshot = Readonly<{ readonly allocationID: string; readonly status: "allocated" | "validation_pending" | "validating" | "published" | "rejected"; readonly kind: PresentationKind; readonly projectID: string; readonly sourceRevisionID: string; readonly propertyID?: string; readonly snapshotID?: string; readonly rejectionCode?: string; readonly createdAt: string; readonly updatedAt: string; readonly expiresAt: string }>;
  export type ProfessionalLink = Readonly<{ readonly linkID: string; readonly snapshotID: string; readonly generation: number; readonly state: "active" | "revoked"; readonly expiresAt: string; readonly pinRequired: boolean; readonly aiEnabled: boolean; readonly feedbackEnabled: boolean; readonly feedbackCount: number; readonly feedbackCountCapped: boolean; readonly latestFeedbackAction?: "comment" | "approve" | "request_changes"; readonly latestFeedbackAt?: string }>;
  export type ProfessionalFeedback = Readonly<{ readonly feedbackID: string; readonly linkID: string; readonly snapshotID: string; readonly action: "comment" | "approve" | "request_changes"; readonly comment?: string; readonly displayName: string; readonly occurredAt: string }>;
  export type ProfessionalAccessEvent = Readonly<{ readonly eventID: string; readonly linkID: string; readonly snapshotID: string; readonly action: string; readonly outcome: string; readonly occurredHour: string; readonly clientFamily: "desktop" | "mobile" | "tablet" | "unknown" }>;
  export type ProfessionalDownload = Readonly<{ readonly snapshotID: string; readonly assetID: string; readonly kind: PortalDownloadKind; readonly contentType: ApprovedAssetContentType; readonly byteCount: number }>;

  export interface ProfessionalClient {
    exchange(appBearer: string): Promise<ProfessionalSession>;
    requestEmailSignIn(email: string): Promise<Readonly<{ readonly status: "accepted"; readonly expiresAt?: string }>>;
    redeemEmailSignIn(transferCode: string): Promise<ProfessionalSession | Readonly<{ readonly pending: true }>>;
    listProperties(): Promise<ProfessionalPropertiesWorkspace>;
    upsertProperty(input: ProfessionalPropertyUpsert): Promise<Readonly<{ readonly status: "created" | "updated" | "existing"; readonly propertyID: string; readonly version: number; readonly roomCount: number }>>;
    listConcepts(projectID: string): Promise<readonly ProfessionalConcept[]>;
    listMembers(): Promise<readonly ProfessionalMembership[]>;
    listSnapshots(): Promise<readonly ProfessionalSnapshot[]>;
    listLinks(snapshotID?: string): Promise<readonly ProfessionalLink[]>;
    listFeedback(input: Readonly<{ readonly linkID: string } | { readonly snapshotID: string }>): Promise<readonly ProfessionalFeedback[]>;
    listAccessHistory(linkID?: string): Promise<readonly ProfessionalAccessEvent[]>;
    listDownloads(snapshotID: string): Promise<readonly ProfessionalDownload[]>;
    createLink(input: Readonly<{ readonly snapshotID: string; readonly expiresAt?: string; readonly pin?: string; readonly aiEnabled: boolean; readonly feedbackEnabled: boolean; readonly idempotencyKey: string }>): Promise<Readonly<{ readonly status: "created" | "existing"; readonly linkID: string; readonly generation: number; readonly expiresAt: string; readonly pinRequired: boolean; readonly shareURL?: string }>>;
    revokeLink(linkID: string, expectedGeneration: number): Promise<Readonly<{ readonly status: "revoked" | "already_revoked"; readonly linkID: string; readonly generation: number }>>;
    downloadAsset(assetID: string, expectedByteCount?: number): Promise<DownloadedPortalAsset>;
    logout(): Promise<void>;
    hasMutationAuthority(): boolean;
  }

  export function createProfessionalClient(input: Readonly<{ readonly fetch: Slice6Fetch; readonly requestID?: () => string | undefined }>): ProfessionalClient {
    if (input === null || typeof input !== "object" || typeof input.fetch !== "function") throw new WebServiceError("unavailable");
    const nextRequestID = input.requestID ?? professionalRandomID;
    let csrfToken: string | undefined;
    let pendingMagic: Readonly<{ readonly completionID: string; readonly verifier: string; readonly expiresAt: string }> | undefined;

    const exchange = async (suppliedBearer: string): Promise<ProfessionalSession> => {
      let bearer: string | undefined = validAppBearer(suppliedBearer) ? suppliedBearer : undefined;
      if (bearer === undefined) throw new WebServiceError("unavailable");
      try {
        const value = await professionalJSON(input.fetch, "/professional/session/exchange", undefined, Object.freeze({ authorization: `Bearer ${bearer}` }));
        const record = proRecord(value, ["csrfToken", "expiresAt", "membership", "quota", "subscription"], []);
        const parsed = parseProfessionalSession(record);
        csrfToken = proOpaque(record.csrfToken, 43, 43);
        return parsed;
      } finally { bearer = undefined; }
    };
    const read = async (path: ProfessionalJSONPath, body: unknown): Promise<unknown> => professionalJSON(input.fetch, path, body);
    const mutate = async (path: ProfessionalJSONPath, body?: unknown): Promise<unknown> => {
      const csrf = csrfToken;
      if (csrf === undefined) throw new WebServiceError("unavailable");
      return professionalJSON(input.fetch, path, body, Object.freeze({ "x-roomscan-csrf": csrf }));
    };

    return Object.freeze({
      exchange,
      requestEmailSignIn: async (email: string): Promise<Readonly<{ readonly status: "accepted"; readonly expiresAt?: string }>> => {
        if (!professionalEmail(email)) throw new WebServiceError("unavailable");
        const verifier = randomOpaqueSecret();
        const challenge = await s256Challenge(verifier);
        const record = proRecord(await professionalJSON(input.fetch, "/auth/magic-link/request", Object.freeze({ email, purpose: "sign-in", codeChallenge: challenge })), ["accepted"], ["completionId", "expiresAt"]);
        if (record.accepted !== true) throw new WebServiceError("invalid_response");
        pendingMagic = undefined;
        if (record.completionId === undefined && record.expiresAt === undefined) return Object.freeze({ status: "accepted" as const });
        if (record.completionId === undefined || record.expiresAt === undefined) throw new WebServiceError("invalid_response");
        const completionID = proOpaque(record.completionId, 43, 43);
        const expiresAt = proTimestamp(record.expiresAt);
        pendingMagic = Object.freeze({ completionID, verifier, expiresAt });
        return Object.freeze({ status: "accepted" as const, expiresAt });
      },
      redeemEmailSignIn: async (inputCode: string): Promise<ProfessionalSession | Readonly<{ readonly pending: true }>> => {
        const current = pendingMagic;
        if (current === undefined || Date.parse(current.expiresAt) <= Date.now()) { pendingMagic = undefined; throw new WebServiceError("unavailable"); }
        const transferCode = inputCode.toUpperCase().replace(/[\s-]/gu, "");
        if (!/^[0-9A-HJKMNP-TV-Z]{8}$/u.test(transferCode)) throw new WebServiceError("unavailable");
        const value = await professionalJSON(input.fetch, "/auth/magic-link/completion/redeem", Object.freeze({ completionId: current.completionID, codeVerifier: current.verifier, purpose: "sign-in", transferCode }));
        const plain = proPlainRecord(value);
        if (plain.pending === true && Object.keys(plain).length === 1) return Object.freeze({ pending: true as const });
        const record = proRecord(value, ["principalCanonicalId", "familyPublicId", "accessToken", "refreshToken", "accessExpiresAt"], []);
        proText(record.principalCanonicalId, 1, 128); proText(record.familyPublicId, 16, 128); proTimestamp(record.accessExpiresAt);
        let accessToken = validAppBearerValue(record.accessToken);
        let refreshToken = validAppBearerValue(record.refreshToken);
        if (accessToken === undefined || refreshToken === undefined || accessToken === refreshToken) throw new WebServiceError("invalid_response");
        pendingMagic = undefined;
        try { return await exchange(accessToken); }
        finally { accessToken = undefined; refreshToken = undefined; }
      },
      listProperties: async (): Promise<ProfessionalPropertiesWorkspace> => parsePropertiesWorkspace(await read("/professional/properties/list", Object.freeze({ limit: 20 }))),
      upsertProperty: async (input: ProfessionalPropertyUpsert) => {
        const request = propertyUpsertRequest(input);
        const record = proRecord(await mutate("/professional/properties/upsert", request), ["status", "propertyID", "version", "roomCount"], []);
        return Object.freeze({ status: proEnum(record.status, ["created", "updated", "existing"] as const), propertyID: proID(record.propertyID, "prop_"), version: proInteger(record.version, 1), roomCount: proInteger(record.roomCount, 0, 64) });
      },
      listConcepts: async (projectID: string): Promise<readonly ProfessionalConcept[]> => parseItems(await read("/professional/concepts/list", Object.freeze({ projectID: proID(projectID, "prj_"), limit: 20 })), parseConcept, 20),
      listMembers: async (): Promise<readonly ProfessionalMembership[]> => parseItems(await read("/professional/members/list", Object.freeze({ limit: 100 })), (value) => parseMembership(value, true), 100),
      listSnapshots: async (): Promise<readonly ProfessionalSnapshot[]> => parseItems(await read("/publications/snapshots/list", Object.freeze({ limit: 100 })), parseSnapshot, 100),
      listLinks: async (snapshotID?: string): Promise<readonly ProfessionalLink[]> => parseItems(await read("/publications/links/list", Object.freeze({ ...(snapshotID === undefined ? {} : { snapshotID: proID(snapshotID, "snp_") }), limit: 100 })), parseLink, 100),
      listFeedback: async (scope: Readonly<{ readonly linkID: string } | { readonly snapshotID: string }>): Promise<readonly ProfessionalFeedback[]> => parseItems(await read("/publications/feedback/list", Object.freeze({ ...("linkID" in scope ? { linkID: proID(scope.linkID, "lnk_") } : { snapshotID: proID(scope.snapshotID, "snp_") }), limit: 20 })), parseFeedback, 20),
      listAccessHistory: async (linkID?: string): Promise<readonly ProfessionalAccessEvent[]> => parseItems(await read("/publications/access-history/list", Object.freeze({ ...(linkID === undefined ? {} : { linkID: proID(linkID, "lnk_") }), limit: 100 })), parseAccessEvent, 100),
      listDownloads: async (snapshotID: string): Promise<readonly ProfessionalDownload[]> => parseItems(await read("/publications/downloads/list", Object.freeze({ snapshotID: proID(snapshotID, "snp_") })), parseDownload, 100),
      createLink: async (request: Readonly<{ readonly snapshotID: string; readonly expiresAt?: string; readonly pin?: string; readonly aiEnabled: boolean; readonly feedbackEnabled: boolean; readonly idempotencyKey: string }>) => {
        const record = proRecord(await mutate("/publications/links/create", Object.freeze({ snapshotID: proID(request.snapshotID, "snp_"), ...(request.expiresAt === undefined ? {} : { expiresAt: proTimestamp(request.expiresAt) }), ...(request.pin === undefined ? {} : { pin: proPIN(request.pin) }), aiPolicy: request.aiEnabled ? "enabled" : "disabled", feedbackPolicy: request.feedbackEnabled ? "enabled" : "disabled", idempotencyKey: proOpaque(request.idempotencyKey, 16, 128) })), ["status", "linkID", "generation", "expiresAt", "pinRequired"], ["shareURL"]);
        const shareURL = record.shareURL === undefined ? undefined : proShareURL(record.shareURL);
        return Object.freeze({ status: proEnum(record.status, ["created", "existing"] as const), linkID: proID(record.linkID, "lnk_"), generation: proInteger(record.generation, 1), expiresAt: proTimestamp(record.expiresAt), pinRequired: proBoolean(record.pinRequired), ...(shareURL === undefined ? {} : { shareURL }) });
      },
      revokeLink: async (linkID: string, expectedGeneration: number) => {
        const record = proRecord(await mutate("/publications/links/revoke", Object.freeze({ linkID: proID(linkID, "lnk_"), expectedGeneration: proInteger(expectedGeneration, 1) })), ["status", "linkID", "generation"], []);
        return Object.freeze({ status: proEnum(record.status, ["revoked", "already_revoked"] as const), linkID: proID(record.linkID, "lnk_"), generation: proInteger(record.generation, 1) });
      },
      downloadAsset: async (assetID: string, expectedByteCount?: number): Promise<DownloadedPortalAsset> => professionalAsset(input.fetch, nextRequestID, proID(assetID, "ast_"), expectedByteCount),
      logout: async (): Promise<void> => {
        try { const record = proRecord(await mutate("/professional/session/logout"), ["revoked"], []); if (record.revoked !== true) throw new WebServiceError("invalid_response"); }
        finally { csrfToken = undefined; pendingMagic = undefined; }
      },
      hasMutationAuthority: (): boolean => csrfToken !== undefined,
    });
  }

  type ProfessionalJSONPath = "/auth/magic-link/request" | "/auth/magic-link/completion/redeem" | "/professional/session/exchange" | "/professional/session/logout" | "/professional/properties/list" | "/professional/properties/upsert" | "/professional/concepts/list" | "/professional/members/list" | "/publications/snapshots/list" | "/publications/links/create" | "/publications/links/revoke" | "/publications/links/list" | "/publications/feedback/list" | "/publications/access-history/list" | "/publications/downloads/list";
  async function professionalJSON(fetchImpl: Slice6Fetch, path: ProfessionalJSONPath, body?: unknown, extraHeaders: Readonly<Record<string, string>> = Object.freeze({})): Promise<unknown> {
    let response: Response;
    try { response = await fetchImpl(path, Object.freeze({ method: "POST", credentials: "include", cache: "no-store", referrerPolicy: "no-referrer", headers: Object.freeze({ ...(body === undefined ? {} : { "content-type": "application/json" }), ...extraHeaders }), ...(body === undefined ? {} : { body: canonicalJSON(body) }) })); }
    catch { throw new WebServiceError("unavailable"); }
    if (!(response instanceof Response) || !response.ok || response.headers.get("content-type") !== "application/json") throw new WebServiceError("unavailable");
    let source: string; try { source = await response.text(); } catch { throw new WebServiceError("invalid_response"); }
    if (source.length < 2 || source.length > 262_144) throw new WebServiceError("invalid_response");
    try { return JSON.parse(source); } catch { throw new WebServiceError("invalid_response"); }
  }

  async function professionalAsset(fetchImpl: Slice6Fetch, nextRequestID: () => string | undefined, assetID: string, expectedByteCount?: number): Promise<DownloadedPortalAsset> {
    if (expectedByteCount !== undefined && (!Number.isSafeInteger(expectedByteCount) || expectedByteCount < 1 || expectedByteCount > 536_870_912)) throw new WebServiceError("invalid_asset");
    const chunks: BlobPart[] = []; let offset = 0; let total: number | undefined; let contentType: ApprovedAssetContentType | undefined;
    while (total === undefined || offset < total) {
      const requestID = nextRequestID(); if (requestID === undefined || !/^[A-Za-z0-9_-]{16,128}$/u.test(requestID)) throw new WebServiceError("invalid_asset");
      const remaining = total === undefined ? expectedByteCount : total - offset; const byteCount = remaining === undefined ? 1 : Math.min(4_194_304, remaining);
      let response: Response;
      try { response = await fetchImpl("/publications/assets/read", Object.freeze({ method: "POST", credentials: "include", cache: "no-store", referrerPolicy: "no-referrer", headers: Object.freeze({ "content-type": "application/json" }), body: canonicalJSON({ assetID, offset, byteCount, requestID }) })); }
      catch { throw new WebServiceError("unavailable"); }
      if (!(response instanceof Response) || !response.ok || response.headers.get("cache-control") !== "no-store" || response.headers.get("accept-ranges") !== "bytes") throw new WebServiceError("invalid_asset");
      const match = /^bytes ([0-9]+)-([0-9]+)\/([0-9]+)$/u.exec(response.headers.get("content-range") ?? "");
      if (match?.[1] === undefined || match[2] === undefined || match[3] === undefined) throw new WebServiceError("invalid_asset");
      const start = Number(match[1]); const end = Number(match[2]); const responseTotal = Number(match[3]);
      if (start !== offset || end - start + 1 !== byteCount || !Number.isSafeInteger(responseTotal) || responseTotal < 1 || responseTotal > 536_870_912 || end >= responseTotal || (total !== undefined && total !== responseTotal) || (expectedByteCount !== undefined && expectedByteCount !== responseTotal)) throw new WebServiceError("invalid_asset");
      const nextType = proContentType(response.headers.get("content-type")); if (contentType !== undefined && contentType !== nextType) throw new WebServiceError("invalid_asset"); contentType = nextType;
      const bytes = new Uint8Array(await response.arrayBuffer()); if (bytes.byteLength !== byteCount) throw new WebServiceError("invalid_asset"); chunks.push(bytes); total = responseTotal; offset = end + 1;
      if (chunks.length > 129) throw new WebServiceError("invalid_asset");
    }
    if (total === undefined || contentType === undefined || offset !== total) throw new WebServiceError("invalid_asset");
    return Object.freeze({ blob: new Blob(chunks, { type: contentType }), contentType, byteCount: total });
  }

  function parseProfessionalSession(record: Readonly<Record<string, unknown>>): ProfessionalSession {
    const subscription = proRecord(record.subscription, ["plan", "status"], ["currentPeriodEnd"]); const quota = proRecord(record.quota, ["policyVersion", "portalPeriod", "used", "reserved", "limit"], []);
    const currentPeriodEnd = subscription.currentPeriodEnd === undefined ? undefined : proTimestamp(subscription.currentPeriodEnd);
    return Object.freeze({ expiresAt: proTimestamp(record.expiresAt), membership: parseMembership(record.membership, false), subscription: Object.freeze({ plan: proText(subscription.plan, 1, 80), status: proText(subscription.status, 1, 80), ...(currentPeriodEnd === undefined ? {} : { currentPeriodEnd }) }), quota: Object.freeze({ policyVersion: proInteger(quota.policyVersion, 1), portalPeriod: proText(quota.portalPeriod, 1, 128), used: proInteger(quota.used, 0), reserved: proInteger(quota.reserved, 0), limit: proInteger(quota.limit, 0) }) });
  }
  function parseMembership(value: unknown, includeCurrent: boolean): ProfessionalMembership { const record = proRecord(value, ["memberID", "displayName", "role", "state", ...(includeCurrent ? ["current"] : [])], []); return Object.freeze({ memberID: proMemberID(record.memberID), displayName: proText(record.displayName, 4, 80), role: proEnum(record.role, ["owner", "admin", "editor", "viewer"] as const), state: proEnum(record.state, ["active", "invited", "suspended"] as const), ...(includeCurrent ? { current: proBoolean(record.current) } : {}) }); }
  function parsePropertiesWorkspace(value: unknown): ProfessionalPropertiesWorkspace {
    const record = proRecord(value, ["items", "roomCandidates"], []);
    const properties = Object.freeze(proArray(record.items, 20).map(parseProperty));
    const roomCandidates = Object.freeze(proArray(record.roomCandidates, 100).map(parseRoomCandidate));
    if (new Set(roomCandidates.map((candidate) => candidate.projectID)).size !== roomCandidates.length) throw new WebServiceError("invalid_response");
    return Object.freeze({ properties, roomCandidates });
  }
  function parseProperty(value: unknown): ProfessionalProperty { const record = proRecord(value, ["propertyID", "title", "version", "roomCount", "rooms"], []); const rooms = orderedPropertyRooms(record.rooms); const roomCount = proInteger(record.roomCount, 0, 64); if (roomCount !== rooms.length) throw new WebServiceError("invalid_response"); return Object.freeze({ propertyID: proID(record.propertyID, "prop_"), title: proText(record.title, 1, 180), version: proInteger(record.version, 1), roomCount, rooms }); }
  function parseRoomCandidate(value: unknown): ProfessionalRoomCandidate { const record = proRecord(value, ["projectID", "title"], []); return Object.freeze({ projectID: proID(record.projectID, "prj_"), title: proText(record.title, 1, 180) }); }
  function orderedPropertyRooms(value: unknown): readonly ProfessionalPropertyRoom[] {
    const rooms = proArray(value, 64).map((candidate) => {
      const room = proRecord(candidate, ["roomKey", "roomOrder", "projectID"], []);
      return Object.freeze({ roomKey: proIdentifier(room.roomKey), roomOrder: proInteger(room.roomOrder, 1, 64), projectID: proID(room.projectID, "prj_") });
    });
    if (new Set(rooms.map((room) => room.roomKey)).size !== rooms.length || new Set(rooms.map((room) => room.projectID)).size !== rooms.length) throw new WebServiceError("invalid_response");
    const ordered = rooms.slice().sort((left, right) => left.roomOrder - right.roomOrder);
    if (ordered.some((room, index) => room.roomOrder !== index + 1)) throw new WebServiceError("invalid_response");
    return Object.freeze(ordered);
  }
  function propertyUpsertRequest(value: ProfessionalPropertyUpsert): Readonly<Record<string, unknown>> {
    const record = proRecord(value, ["title", "rooms"], ["propertyID", "expectedVersion", "createIdempotencyKey"]);
    const title = proText(record.title, 1, 180);
    const rooms = orderedPropertyRooms(record.rooms);
    const propertyID = record.propertyID === undefined ? undefined : proID(record.propertyID, "prop_");
    const expectedVersion = record.expectedVersion === undefined ? undefined : proInteger(record.expectedVersion, 1);
    const createIdempotencyKey = record.createIdempotencyKey === undefined ? undefined : proOpaque(record.createIdempotencyKey, 16, 128);
    if ((propertyID === undefined) !== (expectedVersion === undefined) || (propertyID === undefined && createIdempotencyKey === undefined) || (propertyID !== undefined && createIdempotencyKey !== undefined)) throw new WebServiceError("invalid_response");
    return Object.freeze({ title, rooms, ...(propertyID === undefined ? { createIdempotencyKey: createIdempotencyKey! } : { propertyID, expectedVersion: expectedVersion! }) });
  }
  function parseConcept(value: unknown): ProfessionalConcept { const record = proRecord(value, ["snapshotID", "assetID", "contentType", "byteCount", "publishedAt"], []); return Object.freeze({ snapshotID: proID(record.snapshotID, "snp_"), assetID: proID(record.assetID, "ast_"), contentType: proContentType(record.contentType), byteCount: proInteger(record.byteCount, 1, 32_000_000), publishedAt: proTimestamp(record.publishedAt) }); }
  function parseSnapshot(value: unknown): ProfessionalSnapshot { const record = proRecord(value, ["allocationID", "status", "kind", "projectID", "sourceRevisionID", "createdAt", "updatedAt", "expiresAt"], ["propertyID", "snapshotID", "rejectionCode"]); return Object.freeze({ allocationID: proID(record.allocationID, "pua_"), status: proEnum(record.status, ["allocated", "validation_pending", "validating", "published", "rejected"] as const), kind: proEnum(record.kind, ["room", "property"] as const), projectID: proID(record.projectID, "prj_"), sourceRevisionID: proID(record.sourceRevisionID, "rev_"), ...(record.propertyID === undefined ? {} : { propertyID: proID(record.propertyID, "prop_") }), ...(record.snapshotID === undefined ? {} : { snapshotID: proID(record.snapshotID, "snp_") }), ...(record.rejectionCode === undefined ? {} : { rejectionCode: proText(record.rejectionCode, 1, 64) }), createdAt: proTimestamp(record.createdAt), updatedAt: proTimestamp(record.updatedAt), expiresAt: proTimestamp(record.expiresAt) }); }
  function parseLink(value: unknown): ProfessionalLink { const record = proRecord(value, ["linkID", "snapshotID", "generation", "state", "expiresAt", "pinRequired", "aiEnabled", "feedbackEnabled", "feedbackCount", "feedbackCountCapped"], ["latestFeedbackAction", "latestFeedbackAt"]); if ((record.latestFeedbackAction === undefined) !== (record.latestFeedbackAt === undefined)) throw new WebServiceError("invalid_response"); return Object.freeze({ linkID: proID(record.linkID, "lnk_"), snapshotID: proID(record.snapshotID, "snp_"), generation: proInteger(record.generation, 1), state: proEnum(record.state, ["active", "revoked"] as const), expiresAt: proTimestamp(record.expiresAt), pinRequired: proBoolean(record.pinRequired), aiEnabled: proBoolean(record.aiEnabled), feedbackEnabled: proBoolean(record.feedbackEnabled), feedbackCount: proInteger(record.feedbackCount, 0, 10_000), feedbackCountCapped: proBoolean(record.feedbackCountCapped), ...(record.latestFeedbackAction === undefined ? {} : { latestFeedbackAction: proEnum(record.latestFeedbackAction, ["comment", "approve", "request_changes"] as const), latestFeedbackAt: proTimestamp(record.latestFeedbackAt) }) }); }
  function parseFeedback(value: unknown): ProfessionalFeedback { const record = proRecord(value, ["feedbackID", "linkID", "snapshotID", "action", "displayName", "occurredAt"], ["comment"]); return Object.freeze({ feedbackID: proText(record.feedbackID, 1, 80), linkID: proID(record.linkID, "lnk_"), snapshotID: proID(record.snapshotID, "snp_"), action: proEnum(record.action, ["comment", "approve", "request_changes"] as const), ...(record.comment === undefined ? {} : { comment: proText(record.comment, 1, 4_000) }), displayName: proText(record.displayName, 1, 120), occurredAt: proTimestamp(record.occurredAt) }); }
  function parseAccessEvent(value: unknown): ProfessionalAccessEvent { const record = proRecord(value, ["eventID", "linkID", "snapshotID", "action", "outcome", "occurredHour", "clientFamily"], []); return Object.freeze({ eventID: proText(record.eventID, 1, 80), linkID: proID(record.linkID, "lnk_"), snapshotID: proID(record.snapshotID, "snp_"), action: proText(record.action, 1, 32), outcome: proText(record.outcome, 1, 32), occurredHour: proTimestamp(record.occurredHour), clientFamily: proEnum(record.clientFamily, ["desktop", "mobile", "tablet", "unknown"] as const) }); }
  function parseDownload(value: unknown): ProfessionalDownload { const record = proRecord(value, ["snapshotID", "assetID", "kind", "contentType", "byteCount"], []); return Object.freeze({ snapshotID: proID(record.snapshotID, "snp_"), assetID: proID(record.assetID, "ast_"), kind: proEnum(record.kind, ["floor_plan_pdf", "gallery_zip", "ai_ready_package"] as const), contentType: proContentType(record.contentType), byteCount: proInteger(record.byteCount, 1, 536_870_912) }); }
  function parseItems<T>(value: unknown, parser: (candidate: unknown) => T, maximum: number): readonly T[] { const record = proRecord(value, ["items"], []); return Object.freeze(proArray(record.items, maximum).map(parser)); }

  function proPlainRecord(value: unknown): Readonly<Record<string, unknown>> { if (value === null || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype) throw new WebServiceError("invalid_response"); return value as Readonly<Record<string, unknown>>; }
  function proRecord(value: unknown, required: readonly string[], optional: readonly string[]): Readonly<Record<string, unknown>> { const record = proPlainRecord(value); const allowed = new Set([...required, ...optional]); if (Object.keys(record).some((key) => !allowed.has(key)) || required.some((key) => !(key in record))) throw new WebServiceError("invalid_response"); return record; }
  function proArray(value: unknown, maximum: number): readonly unknown[] { if (!Array.isArray(value) || value.length > maximum) throw new WebServiceError("invalid_response"); return value; }
  function proText(value: unknown, minimum: number, maximum: number): string { if (typeof value !== "string" || Array.from(value).length < minimum || Array.from(value).length > maximum || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw new WebServiceError("invalid_response"); return value; }
  function proIdentifier(value: unknown): string { const result = proText(value, 1, 128); if (!/^[A-Za-z0-9_.-]+$/u.test(result)) throw new WebServiceError("invalid_response"); return result; }
  function proID(value: unknown, prefix: string): string { const result = proText(value, 20, 132); if (!result.startsWith(prefix) || !/^[A-Za-z0-9_-]+$/u.test(result)) throw new WebServiceError("invalid_response"); return result; }
  function proMemberID(value: unknown): string { const result = proText(value, 68, 68); if (!/^mem_[0-9a-f]{64}$/u.test(result)) throw new WebServiceError("invalid_response"); return result; }
  function proOpaque(value: unknown, minimum: number, maximum: number): string { const result = proText(value, minimum, maximum); if (!/^[A-Za-z0-9_-]+$/u.test(result)) throw new WebServiceError("invalid_response"); return result; }
  function proTimestamp(value: unknown): string { const result = proText(value, 20, 30); const date = new Date(result); if (!Number.isSafeInteger(date.getTime()) || date.toISOString() !== result) throw new WebServiceError("invalid_response"); return result; }
  function proInteger(value: unknown, minimum: number, maximum = Number.MAX_SAFE_INTEGER): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw new WebServiceError("invalid_response"); return value; }
  function proBoolean(value: unknown): boolean { if (typeof value !== "boolean") throw new WebServiceError("invalid_response"); return value; }
  function proEnum<T extends readonly string[]>(value: unknown, allowed: T): T[number] { if (typeof value !== "string" || !allowed.includes(value)) throw new WebServiceError("invalid_response"); return value as T[number]; }
  function proContentType(value: unknown): ApprovedAssetContentType { return proEnum(value, ["application/json", "image/png", "image/jpeg", "application/pdf", "application/zip"] as const); }
  function proPIN(value: unknown): string { if (typeof value !== "string" || !/^[0-9]{6}$/u.test(value)) throw new WebServiceError("invalid_response"); return value; }
  function proShareURL(value: unknown): string { const result = proText(value, 1, 2_048); try { const url = new URL(result); if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || !/^#[A-Za-z0-9_-]{43}$/u.test(url.hash)) throw new Error(); return result; } catch { throw new WebServiceError("invalid_response"); } }
  function validAppBearer(value: string): boolean { return /^[A-Za-z0-9._~-]{32,4096}$/u.test(value); }
  function validAppBearerValue(value: unknown): string | undefined { return typeof value === "string" && validAppBearer(value) ? value : undefined; }
  function professionalEmail(value: string): boolean { return typeof value === "string" && value.length >= 3 && value.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value); }
  function professionalRandomID(): string | undefined { try { const bytes = new Uint8Array(16); crypto.getRandomValues(bytes); return toBase64URL(bytes); } catch { return undefined; } }
  function randomOpaqueSecret(): string { const bytes = new Uint8Array(32); crypto.getRandomValues(bytes); return toBase64URL(bytes); }
  async function s256Challenge(verifier: string): Promise<string> { const bytes = new TextEncoder().encode(verifier); const digest = await crypto.subtle.digest("SHA-256", bytes); return toBase64URL(new Uint8Array(digest)); }
}
