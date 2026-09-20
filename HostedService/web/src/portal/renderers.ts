namespace RoomScanWeb {
  export type PortalOrientationState = Readonly<{
    readonly epoch: number;
    readonly initialView: InitialView;
    readonly yaw: number;
    readonly pitch: number;
  }>;

  export interface PortalViewModel {
    currentRoom(): PublishedRoom;
    selectRoom(roomKey: string): void;
    rotate(yawDelta: number, pitchDelta: number): void;
    orientation(): PortalOrientationState;
    setComparison(value: number): void;
    comparison(): number;
    downloads(): readonly PortalDownloadKind[];
  }

  export function createPortalViewModel(
    presentation: PublishedPresentation,
    livePolicy: Readonly<{ readonly feedbackEnabled: boolean; readonly aiReadyPackageEnabled: boolean }>,
  ): PortalViewModel {
    if (presentation === null || typeof presentation !== "object" || !Array.isArray(presentation.rooms) || presentation.rooms.length < 1
      || livePolicy === null || typeof livePolicy !== "object" || typeof livePolicy.feedbackEnabled !== "boolean" || typeof livePolicy.aiReadyPackageEnabled !== "boolean") {
      throw new WebContractError("invalid_presentation");
    }
    let roomIndex = 0;
    let epoch = 1;
    let yaw = 0;
    let pitch = 0;
    let comparison = 0.5;
    const room = (): PublishedRoom => {
      const value = presentation.rooms[roomIndex];
      if (value === undefined) throw new WebContractError("invalid_presentation");
      return value;
    };
    const resetRoomState = (): void => { epoch += 1; yaw = 0; pitch = 0; comparison = 0.5; };
    return Object.freeze({
      currentRoom: room,
      selectRoom: (roomKey: string): void => {
        const next = presentation.rooms.findIndex((candidate) => candidate.roomKey === roomKey);
        if (next < 0) throw new WebContractError("invalid_presentation");
        if (next !== roomIndex) { roomIndex = next; resetRoomState(); }
      },
      rotate: (yawDelta: number, pitchDelta: number): void => {
        if (!Number.isFinite(yawDelta) || !Number.isFinite(pitchDelta)) throw new WebContractError("invalid_geometry");
        yaw = normalizeRadians(yaw + yawDelta);
        pitch = clamp(pitch + pitchDelta, -1.2, 1.2);
      },
      orientation: (): PortalOrientationState => Object.freeze({ epoch, initialView: room().orientation.initialView, yaw, pitch }),
      setComparison: (value: number): void => {
        if (!Number.isFinite(value)) throw new WebContractError("invalid_presentation");
        comparison = clamp(value, 0, 1);
      },
      comparison: (): number => comparison,
      downloads: (): readonly PortalDownloadKind[] => Object.freeze([
        ...(presentation.downloads.floorPlanPDF ? ["floor_plan_pdf" as const] : []),
        ...(presentation.downloads.galleryZIP ? ["gallery_zip" as const] : []),
        ...(presentation.downloads.aiReadyPackageAssetID !== undefined && livePolicy.aiReadyPackageEnabled ? ["ai_ready_package" as const] : []),
      ]),
    });
  }

  export function comparisonKeyStep(value: number, key: string): number {
    if (!Number.isFinite(value)) throw new WebContractError("invalid_presentation");
    if (key === "Home") return 0;
    if (key === "End") return 1;
    if (key === "ArrowLeft" || key === "ArrowDown") return roundedComparison(value - 0.05);
    if (key === "ArrowRight" || key === "ArrowUp") return roundedComparison(value + 0.05);
    return clamp(value, 0, 1);
  }

  export function drawFloorPlan(
    context: CanvasRenderingContext2D,
    room: PublishedRoom,
    viewport: Readonly<{ readonly width: number; readonly height: number; readonly highContrast: boolean }>,
  ): void {
    requireCanvasInput(context, viewport);
    const width = viewport.width;
    const height = viewport.height;
    const inset = Math.max(24, Math.min(width, height) * 0.08);
    const drawingWidth = width - inset * 2;
    const drawingHeight = height - inset * 2;
    context.clearRect(0, 0, width, height);
    context.fillStyle = viewport.highContrast ? "#ffffff" : "#f4efe4";
    context.fillRect(0, 0, width, height);
    context.font = "600 13px ui-monospace, monospace";
    context.lineWidth = viewport.highContrast ? 4 : 2;
    for (const element of room.semanticLayout.elements) {
      const x = inset + element.x * drawingWidth;
      const y = inset + element.y * drawingHeight;
      const elementWidth = Math.max(2, element.width * drawingWidth);
      const elementHeight = Math.max(2, element.height * drawingHeight);
      const colors = floorColors(element.kind, viewport.highContrast);
      context.fillStyle = colors.fill;
      context.strokeStyle = colors.stroke;
      context.fillRect(x, y, elementWidth, elementHeight);
      context.strokeRect(x, y, elementWidth, elementHeight);
      context.fillStyle = viewport.highContrast ? "#000000" : "#173b42";
      context.fillText(element.label, Math.max(8, x), Math.max(16, y - 6));
    }
  }

  export function drawOrientation(
    context: CanvasRenderingContext2D,
    geometry: WebGeometry,
    viewport: Readonly<{ readonly yaw: number; readonly pitch: number; readonly width: number; readonly height: number; readonly highContrast: boolean }>,
  ): void {
    requireCanvasInput(context, viewport);
    if (!Number.isFinite(viewport.yaw) || !Number.isFinite(viewport.pitch) || geometry.vertices.length < 3 || geometry.triangles.length < 1) throw new WebContractError("invalid_geometry");
    const width = viewport.width;
    const height = viewport.height;
    const projected = geometry.vertices.map((vertex) => projectVertex(vertex, viewport.yaw, viewport.pitch, width, height));
    context.clearRect(0, 0, width, height);
    context.fillStyle = viewport.highContrast ? "#000000" : "#173b42";
    context.fillRect(0, 0, width, height);
    context.strokeStyle = viewport.highContrast ? "#ffffff" : "#d7e7df";
    context.lineWidth = viewport.highContrast ? 3 : 1.5;
    const maximumTriangles = Math.min(geometry.triangles.length, 50_000);
    for (let index = 0; index < maximumTriangles; index += 1) {
      const triangle = geometry.triangles[index];
      if (triangle === undefined) continue;
      const a = projected[triangle.a]; const b = projected[triangle.b]; const c = projected[triangle.c];
      if (a === undefined || b === undefined || c === undefined) throw new WebContractError("invalid_geometry");
      context.beginPath();
      context.moveTo(a.x, a.y);
      context.lineTo(b.x, b.y);
      context.lineTo(c.x, c.y);
      context.closePath();
      context.stroke();
    }
  }

  function projectVertex(vertex: WebGeometry["vertices"][number], yaw: number, pitch: number, width: number, height: number): Readonly<{ readonly x: number; readonly y: number }> {
    const cosYaw = Math.cos(yaw); const sinYaw = Math.sin(yaw);
    const yawX = vertex.x * cosYaw - vertex.z * sinYaw;
    const yawZ = vertex.x * sinYaw + vertex.z * cosYaw;
    const cosPitch = Math.cos(pitch); const sinPitch = Math.sin(pitch);
    const pitchY = vertex.y * cosPitch - yawZ * sinPitch;
    const pitchZ = vertex.y * sinPitch + yawZ * cosPitch;
    const perspective = 1 / Math.max(0.4, 3.2 + pitchZ);
    const scale = Math.min(width, height) * 0.62;
    return Object.freeze({ x: width / 2 + yawX * scale * perspective, y: height / 2 - pitchY * scale * perspective });
  }

  function floorColors(kind: PublishedLayoutKind, highContrast: boolean): Readonly<{ readonly fill: string; readonly stroke: string }> {
    if (highContrast) return Object.freeze({ fill: kind === "floor" ? "#ffffff" : "#000000", stroke: kind === "floor" ? "#000000" : "#ffffff" });
    if (kind === "floor") return Object.freeze({ fill: "#e6ddca", stroke: "#315e65" });
    if (kind === "door" || kind === "opening") return Object.freeze({ fill: "#c36f42", stroke: "#713a23" });
    if (kind === "window") return Object.freeze({ fill: "#a6cfda", stroke: "#315e65" });
    if (kind === "wall") return Object.freeze({ fill: "#173b42", stroke: "#0c252b" });
    return Object.freeze({ fill: "#c7bcaa", stroke: "#61584c" });
  }

  function requireCanvasInput(context: CanvasRenderingContext2D, viewport: Readonly<{ readonly width: number; readonly height: number }>): void {
    if (context === null || typeof context !== "object" || !Number.isSafeInteger(viewport.width) || !Number.isSafeInteger(viewport.height)
      || viewport.width < 1 || viewport.width > 4_096 || viewport.height < 1 || viewport.height > 4_096) throw new WebContractError("invalid_geometry");
  }
  function normalizeRadians(value: number): number { const turn = Math.PI * 2; return ((value + Math.PI) % turn + turn) % turn - Math.PI; }
  function roundedComparison(value: number): number { return Math.round(clamp(value, 0, 1) * 100) / 100; }
  function clamp(value: number, minimum: number, maximum: number): number { return Math.min(maximum, Math.max(minimum, value)); }
}
