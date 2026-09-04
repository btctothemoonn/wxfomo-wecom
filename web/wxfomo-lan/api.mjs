const TOKEN_KEY = "wxfomo-lan-access-token";
const REQUEST_TIMEOUT_MS = 5000;

function browserStorage(storage) {
  if (storage) {
    return storage;
  }
  return globalThis.sessionStorage;
}

export class ApiError extends Error {
  constructor(status, code, reason = null) {
    super(code || `HTTP ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.code = code || "request_failed";
    this.reason = typeof reason === "string" && reason ? reason : null;
  }
}

export function authenticate(token, storage) {
  const value = String(token || "").trim();
  if (!value) {
    throw new Error("token_required");
  }
  browserStorage(storage).setItem(TOKEN_KEY, value);
}

export function hasSessionToken(storage) {
  return Boolean(browserStorage(storage).getItem(TOKEN_KEY));
}

export function clearSessionToken(expectedToken, storage) {
  const target = browserStorage(storage);
  if (expectedToken !== undefined && target.getItem(TOKEN_KEY) !== expectedToken) {
    return false;
  }
  target.removeItem(TOKEN_KEY);
  return true;
}

function apiUrl(path, parameters) {
  if (!path.startsWith("/api/") || path.includes("#")) {
    throw new Error("invalid_api_path");
  }
  const query = new URLSearchParams();
  for (const [name, value] of Object.entries(parameters || {})) {
    if (value !== undefined && value !== null && value !== "") {
      query.set(name, String(value));
    }
  }
  const suffix = query.toString();
  return suffix ? `${path}?${suffix}` : path;
}

export async function requestJson(path, parameters = {}, environment = {}) {
  const storage = browserStorage(environment.storage);
  const token = storage.getItem(TOKEN_KEY);
  if (!token) {
    throw new ApiError(401, "unauthorized");
  }
  const fetchFunction = environment.fetch || globalThis.fetch;
  const configuredTimeoutMs = Number(environment.timeoutMs);
  const timeoutMs = Number.isFinite(configuredTimeoutMs) && configuredTimeoutMs > 0
    ? configuredTimeoutMs
    : REQUEST_TIMEOUT_MS;
  const AbortControllerClass = Object.prototype.hasOwnProperty.call(
    environment,
    "AbortController"
  )
    ? environment.AbortController
    : globalThis.AbortController;
  const controller = typeof AbortControllerClass === "function"
    ? new AbortControllerClass()
    : null;
  const requestOptions = {
    method: "GET",
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${token}`,
    },
  };
  if (controller) {
    requestOptions.signal = controller.signal;
  }

  const operation = async () => {
    const response = await fetchFunction(apiUrl(path, parameters), requestOptions);
    let payload = {};
    try {
      payload = await response.json();
    } catch (_error) {
      payload = {};
    }
    if (!response.ok) {
      if (response.status === 401) {
        clearSessionToken(token, storage);
      }
      throw new ApiError(response.status, payload.error, payload.reason);
    }
    return payload;
  };
  let timeoutHandle = null;
  const timeout = new Promise((_resolve, reject) => {
    timeoutHandle = globalThis.setTimeout(() => {
      if (controller) {
        controller.abort();
      }
      reject(new ApiError(0, "request_timeout"));
    }, timeoutMs);
  });
  try {
    return await Promise.race([operation(), timeout]);
  } finally {
    if (timeoutHandle !== null) {
      globalThis.clearTimeout(timeoutHandle);
    }
  }
}

export function fetchBootstrap(environment = {}) {
  const timeoutMs = Number(environment.timeoutMs);
  return requestJson("/api/bootstrap", {}, {
    ...environment,
    timeoutMs: Number.isFinite(timeoutMs) && timeoutMs > 0
      ? timeoutMs
      : REQUEST_TIMEOUT_MS,
  });
}

export function fetchMessages(parameters) {
  return requestJson("/api/messages", parameters);
}
