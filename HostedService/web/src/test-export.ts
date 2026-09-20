namespace RoomScanWeb {
  const testSurface = Object.freeze({
    capturePortalLink,
    canonicalOpaqueSecret,
    portalContinuationPath,
    fromBase64URL,
    toBase64URL,
    parsePresentation,
    parseWebGeometry,
    parsePortalSnapshot,
    canonicalJSON,
    parseCanonicalJSON,
    INDEPENDENT_ROOM_NOTICE,
    createServiceClient,
    createProfessionalClient,
    safeElement,
    replaceSafeText,
    safeText,
    safeHref,
    createBlobURLRegistry,
    createPortalViewModel,
    drawFloorPlan,
    drawOrientation,
    comparisonKeyStep,
    PROFESSIONAL_SECTIONS,
  });
  (globalThis as { RoomScanWeb?: unknown }).RoomScanWeb = testSurface;
}
