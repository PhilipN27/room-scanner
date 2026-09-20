namespace RoomScanWeb {
  export type PortalLinkCapture = Readonly<{
    consume(): string | undefined;
  }>;

  export function capturePortalLink(input: Readonly<{
    href: string;
    replace: (path: "/p") => void;
  }>): PortalLinkCapture {
    const url = new URL(input.href);
    const fragment = url.hash.startsWith("#") ? url.hash.slice(1) : "";
    let secret = canonicalOpaqueSecret(fragment) ? fragment : undefined;
    input.replace("/p");
    return Object.freeze({
      consume: (): string | undefined => {
        const value = secret;
        secret = undefined;
        return value;
      },
    });
  }

  export function canonicalOpaqueSecret(value: string): boolean {
    if (!/^[A-Za-z0-9_-]{43}$/u.test(value)) return false;
    try {
      const bytes = fromBase64URL(value);
      return bytes.byteLength === 32 && toBase64URL(bytes) === value;
    } catch {
      return false;
    }
  }

  export function portalContinuationPath(forceFallback: boolean, pendingPIN: boolean): "/p" | "/p?fallback=1" | "/p?pin=1" | "/p?fallback=1&pin=1" {
    if (forceFallback && pendingPIN) return "/p?fallback=1&pin=1";
    if (forceFallback) return "/p?fallback=1";
    if (pendingPIN) return "/p?pin=1";
    return "/p";
  }

  export function fromBase64URL(value: string): Uint8Array {
    const padded = value.replace(/-/gu, "+").replace(/_/gu, "/") + "=".repeat((4 - value.length % 4) % 4);
    const decoded = atob(padded);
    const bytes = new Uint8Array(decoded.length);
    for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded.charCodeAt(index);
    return bytes;
  }

  export function toBase64URL(bytes: Uint8Array): string {
    let text = "";
    for (const byte of bytes) text += String.fromCharCode(byte);
    return btoa(text).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
  }
}
