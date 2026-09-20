namespace RoomScanWeb {
  export class WebBlobError extends Error {
    constructor() {
      super("invalid_blob");
      this.name = "WebBlobError";
    }
  }

  export type BlobURLHost = Readonly<{
    createObjectURL(blob: Blob): string;
    revokeObjectURL(url: string): void;
  }>;
  export interface BlobURLRegistry {
    createImageURL(asset: DownloadedPortalAsset): string;
    createDownloadURL(asset: DownloadedPortalAsset): string;
    resetForRoom(): void;
    resetForDenial(): void;
    resetForError(): void;
    completeDownload(url: string): void;
    dispose(): void;
    has(url: string): boolean;
  }

  export function createBlobURLRegistry(host: BlobURLHost = URL): BlobURLRegistry {
    if (host === null || (typeof host !== "object" && typeof host !== "function") || typeof host.createObjectURL !== "function" || typeof host.revokeObjectURL !== "function") throw new WebBlobError();
    const active = new Set<string>();
    let closed = false;
    const create = (asset: DownloadedPortalAsset, allowed: readonly ApprovedAssetContentType[]): string => {
      if (closed || !validAsset(asset) || !allowed.includes(asset.contentType)) throw new WebBlobError();
      let value: string;
      try { value = host.createObjectURL(asset.blob); } catch { throw new WebBlobError(); }
      if (typeof value !== "string" || !value.startsWith("blob:")) {
        try { if (typeof value === "string") host.revokeObjectURL(value); } catch { /* no secondary leak path */ }
        throw new WebBlobError();
      }
      active.add(value);
      return value;
    };
    const revoke = (value: string): void => {
      if (!active.delete(value)) return;
      try { host.revokeObjectURL(value); } catch { /* continue cleanup of every other URL */ }
    };
    const clear = (): void => { for (const value of [...active]) revoke(value); };
    const close = (): void => { clear(); closed = true; };
    return Object.freeze({
      createImageURL: (asset: DownloadedPortalAsset) => create(asset, ["image/png", "image/jpeg"] as const),
      createDownloadURL: (asset: DownloadedPortalAsset) => create(asset, ["application/pdf", "application/zip"] as const),
      resetForRoom: clear,
      resetForDenial: close,
      resetForError: close,
      completeDownload: (value: string) => revoke(value),
      dispose: close,
      has: (value: string) => active.has(value),
    });
  }

  function validAsset(value: unknown): value is DownloadedPortalAsset {
    if (value === null || typeof value !== "object") return false;
    const asset = value as Partial<DownloadedPortalAsset>;
    return asset.blob instanceof Blob && typeof asset.contentType === "string" && Number.isSafeInteger(asset.byteCount) && asset.byteCount === asset.blob.size && asset.byteCount > 0;
  }
}
