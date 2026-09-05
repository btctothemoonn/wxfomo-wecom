export async function copyText(value, environment = {}) {
  const text = String(value === undefined || value === null ? "" : value);
  const root = typeof globalThis === "object" ? globalThis : {};
  const navigatorObject = environment.navigator || root.navigator || {};
  const documentObject = environment.document || root.document || null;
  const secure = Object.prototype.hasOwnProperty.call(environment, "isSecureContext")
    ? environment.isSecureContext === true
    : root.isSecureContext === true;
  const promptFunction = environment.prompt || root.prompt;

  if (
    secure
    && navigatorObject.clipboard
    && typeof navigatorObject.clipboard.writeText === "function"
  ) {
    try {
      await navigatorObject.clipboard.writeText(text);
      return "clipboard";
    } catch (_error) {
      // A selected textarea below is the compatibility path for browsers that reject Clipboard API.
    }
  }

  if (
    documentObject
    && documentObject.body
    && typeof documentObject.createElement === "function"
    && typeof documentObject.execCommand === "function"
  ) {
    const previousFocus = documentObject.activeElement;
    const textarea = documentObject.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.setAttribute("aria-hidden", "true");
    textarea.style.position = "fixed";
    textarea.style.left = "-9999px";
    textarea.style.top = "0";
    textarea.style.opacity = "0";
    documentObject.body.appendChild(textarea);
    try {
      textarea.focus();
      textarea.select();
      if (documentObject.execCommand("copy")) {
        return "execCommand";
      }
    } catch (_error) {
      // Continue to the explicit manual-copy prompt.
    } finally {
      documentObject.body.removeChild(textarea);
      if (previousFocus && typeof previousFocus.focus === "function") {
        previousFocus.focus();
      }
    }
  }

  if (typeof promptFunction === "function") {
    promptFunction("请按 Ctrl+C 复制", text);
    return "manual";
  }
  return "failed";
}
