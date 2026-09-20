namespace RoomScanWeb {
  export class WebDOMError extends Error {
    constructor() {
      super("invalid_dom");
      this.name = "WebDOMError";
    }
  }
  export type SafeDocument = Pick<Document, "createElement" | "createTextNode">;
  export type SafeElementOptions = Readonly<{ readonly text?: string; readonly attributes?: Readonly<Record<string, string>> }>;

  const SAFE_TAGS = new Set([
    "a", "article", "aside", "button", "canvas", "dd", "div", "dl", "dt", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "header", "img", "input", "label", "li", "main", "nav", "ol", "option", "p", "section", "select", "span", "strong", "textarea", "ul",
  ]);

  export function safeElement(document: SafeDocument, tag: string, options: SafeElementOptions = Object.freeze({})): HTMLElement {
    if (document === null || typeof document !== "object" || typeof document.createElement !== "function" || typeof document.createTextNode !== "function" || !SAFE_TAGS.has(tag)) throw new WebDOMError();
    const element = document.createElement(tag);
    for (const [name, value] of Object.entries(options.attributes ?? {})) setSafeAttribute(element, name, value);
    if (options.text !== undefined) element.append(document.createTextNode(safeText(options.text, 4_000)));
    return element;
  }

  export function replaceSafeText(document: SafeDocument, element: Element, value: string): void {
    if (document === null || typeof document !== "object" || typeof document.createTextNode !== "function" || element === null || typeof element !== "object" || typeof element.replaceChildren !== "function") throw new WebDOMError();
    element.replaceChildren(document.createTextNode(safeText(value, 4_000)));
  }

  export function safeText(value: string, maximum = 4_000): string {
    if (typeof value !== "string" || !Number.isSafeInteger(maximum) || maximum < 1 || scalarLength(value) > maximum || hasUnpairedSurrogateForDOM(value) || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw new WebDOMError();
    return value;
  }

  export function safeHref(value: string): string {
    if (typeof value !== "string" || value.length < 1 || value.length > 2_048 || hasUnpairedSurrogateForDOM(value)) throw new WebDOMError();
    if (/^#[A-Za-z][A-Za-z0-9_-]{0,127}$/u.test(value) || value === "/p" || value === "/p?workspace=1") return value;
    if (value.startsWith("tel:")) {
      if (!/^tel:\+?[0-9() -]{3,40}$/u.test(value)) throw new WebDOMError();
      return value;
    }
    try {
      const parsed = new URL(value);
      if (parsed.protocol !== "https:" || parsed.username !== "" || parsed.password !== "") throw new Error();
      return parsed.toString();
    } catch {
      throw new WebDOMError();
    }
  }

  function setSafeAttribute(element: HTMLElement, name: string, value: string): void {
    if (typeof name !== "string" || typeof value !== "string" || value.length > 4_000 || /^on/iu.test(name) || name === "style" || name === "src") throw new WebDOMError();
    if (name === "href") { element.setAttribute(name, safeHref(value)); return; }
    if (name === "class") {
      if (!/^[A-Za-z0-9_ -]{1,256}$/u.test(value)) throw new WebDOMError();
      element.setAttribute(name, value); return;
    }
    if (name === "id" || name === "role" || name === "type" || name === "name" || name === "value" || name === "for" || name === "title" || name === "alt" || name === "download" || name === "tabindex" || name === "min" || name === "max" || name === "step" || name === "placeholder" || name === "autocomplete" || name === "inputmode" || name === "maxlength" || /^aria-[a-z-]{1,64}$/u.test(name) || /^data-[a-z0-9-]{1,64}$/u.test(name)) {
      element.setAttribute(name, safeText(value, 4_000)); return;
    }
    throw new WebDOMError();
  }

  function scalarLength(value: string): number { return Array.from(value).length; }
  function hasUnpairedSurrogateForDOM(value: string): boolean {
    for (let index = 0; index < value.length; index += 1) {
      const unit = value.charCodeAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const next = value.charCodeAt(index + 1);
        if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
        index += 1;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) return true;
    }
    return false;
  }
}
