const INBOX_ROUTE = Object.freeze({ page: "inbox" });
const LISTENER_HEARTBEAT_TTL_MS = 5000;
const LISTENER_HEARTBEAT_FUTURE_TOLERANCE_MS = 1000;

export function boundedRetryDelay(attempt, base = 2000, cap = 30000) {
  const normalizedAttempt = Math.max(0, Math.floor(Number(attempt) || 0));
  return Math.min(cap, base * Math.pow(2, normalizedAttempt));
}

export function isRetriableWorkspaceReason(reason) {
  return reason === "source_locked";
}

function isRetriableTradesReason(reason) {
  return ["source_locked", "schema_incompatible", "source_corrupt"].includes(reason);
}

function unavailableDependency(payload, predicate) {
  return Boolean(
    payload
    && typeof payload === "object"
    && payload.available === false
    && predicate(payload.reason)
  );
}

export function isRetriableReadOnlyPayload(payload) {
  if (!payload || typeof payload !== "object") {
    return false;
  }
  const settingsDependency = payload.settingsDependency;
  const tradesDependency = payload.tradesDependency;
  const messagesDependency = payload.messagesDependency;
  return isRetriableWorkspaceReason(payload.reason)
    || unavailableDependency(settingsDependency, isRetriableWorkspaceReason)
    || unavailableDependency(tradesDependency, isRetriableTradesReason)
    || unavailableDependency(messagesDependency, () => true);
}

function normalizedDependency(payload) {
  const source = payload && typeof payload === "object" ? payload : {};
  const available = source.available === true;
  return {
    available,
    reason: available
      ? null
      : typeof source.reason === "string" && source.reason
        ? source.reason
        : "source_unavailable",
  };
}

export function composeReadOnlyPagePayload(pageId, primary, related, settings) {
  const source = primary && typeof primary === "object" ? primary : {};
  const settingsPayload = settings && typeof settings === "object" ? settings : {};
  const settingsAvailable = settingsPayload.available === true;
  const settingsDependency = {
    available: settingsAvailable,
    reason: settingsAvailable
      ? null
      : typeof settingsPayload.reason === "string" && settingsPayload.reason
        ? settingsPayload.reason
        : "source_unavailable",
  };
  if (pageId === "automations") {
    const relatedPayload = related && typeof related === "object" ? related : {};
    const tradesDependency = normalizedDependency(relatedPayload);
    return {
      ...source,
      recentIntents: Array.isArray(relatedPayload.items) ? relatedPayload.items : [],
      configurationStatus: settingsAvailable
        ? settingsPayload.tradingConfigured === true
        : null,
      settingsDependency,
      tradesDependency,
    };
  }
  if (pageId === "trading") {
    return {
      ...source,
      walletSafeStatus: settingsAvailable
        ? settingsPayload.tradingConfigured
          ? "交易配置存在 · 私钥未下发"
          : "交易配置未启用 · 私钥未下发"
        : null,
      settingsDependency,
    };
  }
  throw new Error("unsupported_composite_page");
}

export function composeDiagnosticsPagePayload(primary, messages) {
  const source = primary && typeof primary === "object" ? primary : {};
  const messagesPayload = messages && typeof messages === "object" ? messages : {};
  const messagesDependency = normalizedDependency(messagesPayload);
  const latestMessage = messagesDependency.available && Array.isArray(messagesPayload.items)
    ? messagesPayload.items[0]
    : null;
  const retriableErrors = Array.isArray(source.retriableErrors)
    ? source.retriableErrors.slice()
    : [];
  if (
    !messagesDependency.available
    && !retriableErrors.includes("message_source_unavailable")
  ) {
    retriableErrors.push("message_source_unavailable");
  }
  return {
    ...source,
    listenerState: ["active", "inactive"].includes(source.listenerState)
      ? source.listenerState
      : "unknown",
    lastMessageAt: latestMessage ? latestMessage.observedAt : null,
    messagesDependency,
    retriableErrors,
  };
}

export function diagnosticsPrimaryFailurePayload(previous, reason) {
  const normalizedReason = typeof reason === "string" && reason
    ? reason
    : "source_unavailable";
  const messagesDependency = {
    available: false,
    reason: normalizedReason,
  };
  if (previous && previous.available === true) {
    return {
      ...previous,
      messagesDependency,
    };
  }
  return {
    // A primary transport failure is still a renderable diagnostics snapshot:
    // live bootstrap owns the listener/message-source rows, while the missing
    // supplemental request is represented by messagesDependency below.
    available: true,
    reason: null,
    items: [],
    sources: {
      workspace: { available: false, reason: normalizedReason },
      configuration: { available: false, reason: normalizedReason },
    },
    listenerState: "unknown",
    lastMessageAt: null,
    messagesDependency,
    retriableErrors: [],
  };
}

export function retainReadOnlyPayload(previous, next) {
  if (
    previous
    && previous.available === true
    && next
    && isRetriableReadOnlyPayload(next)
  ) {
    if (
      next.messagesDependency
      && next.messagesDependency.available === false
    ) {
      const retained = { ...next };
      if (Object.prototype.hasOwnProperty.call(previous, "lastMessageAt")) {
        retained.lastMessageAt = previous.lastMessageAt;
      }
      return retained;
    }
    let retained = previous;
    for (const dependency of [
      "settingsDependency",
      "tradesDependency",
      "messagesDependency",
    ]) {
      if (Object.prototype.hasOwnProperty.call(next, dependency)) {
        if (retained === previous) {
          retained = { ...previous };
        }
        retained[dependency] = next[dependency];
      }
    }
    return retained;
  }
  return next;
}

export function isCurrentConnection(requestGeneration, currentGeneration) {
  return requestGeneration === currentGeneration;
}

function listenerHeartbeatTiming(source, clock) {
  if (typeof source.heartbeatAt !== "string" || !source.heartbeatAt) {
    return null;
  }
  const heartbeatAt = Date.parse(source.heartbeatAt);
  const now = Number(clock.now());
  if (!Number.isFinite(heartbeatAt) || !Number.isFinite(now)) {
    return null;
  }
  const age = now - heartbeatAt;
  if (
    age < -LISTENER_HEARTBEAT_FUTURE_TOLERANCE_MS
    || age > LISTENER_HEARTBEAT_TTL_MS
  ) {
    return null;
  }
  return { remaining: LISTENER_HEARTBEAT_TTL_MS - age };
}

function listenerHeartbeatIsFresh(source, clock) {
  return listenerHeartbeatTiming(source, clock) !== null;
}

function verifiedListenerState(bootstrap, clock) {
  const source = bootstrap && bootstrap.messageSource ? bootstrap.messageSource : {};
  const state = bootstrap && bootstrap.listenerState
    ? bootstrap.listenerState
    : source.listenerState;
  if (source.available !== true) {
    return "unknown";
  }
  if (state === "active") {
    return listenerHeartbeatIsFresh(source, clock) ? "active" : "inactive";
  }
  return state === "inactive" ? "inactive" : "unknown";
}

export function listenerFreshnessExpiryDelay(bootstrap, clock = Date) {
  const source = bootstrap && bootstrap.messageSource ? bootstrap.messageSource : {};
  const state = bootstrap && bootstrap.listenerState
    ? bootstrap.listenerState
    : source.listenerState;
  if (source.available !== true || state !== "active") {
    return null;
  }
  const timing = listenerHeartbeatTiming(source, clock);
  return timing === null ? null : Math.max(1, Math.ceil(timing.remaining) + 1);
}

export function listenerPresentation(bootstrap, clock = Date) {
  const source = bootstrap && bootstrap.messageSource ? bootstrap.messageSource : {};
  const state = verifiedListenerState(bootstrap, clock);
  if (source.available !== true) {
    return {
      active: false,
      kind: "error",
      label: "消息库不可用",
      detail: "页面会安全重试连接",
    };
  }
  if (state === "active") {
    return {
      active: true,
      kind: "ready",
      label: "监听器活动中",
      detail: "Mac 监听器心跳正常",
    };
  }
  if (state === "inactive" || state === "active") {
    return {
      active: false,
      kind: "warning",
      label: "监听器未活动",
      detail: "消息库可读，但未收到新鲜心跳",
    };
  }
  return {
    active: false,
    kind: "neutral",
    label: "监听状态未知",
    detail: "消息库可读；页面只读刷新",
  };
}

export function invalidateListenerFreshness(bootstrap) {
  if (!bootstrap || typeof bootstrap !== "object") {
    return bootstrap;
  }
  const source = bootstrap.messageSource && typeof bootstrap.messageSource === "object"
    ? bootstrap.messageSource
    : {};
  return {
    ...bootstrap,
    listenerState: "unknown",
    messageSource: {
      ...source,
      listenerState: "unknown",
    },
  };
}

export function retainMessageBootstrap(previous, next) {
  if (
    !previous
    || typeof previous !== "object"
    || !next
    || typeof next !== "object"
    || !next.messageSource
    || next.messageSource.available !== false
  ) {
    return next;
  }
  const previousCounts = previous.counts
    && typeof previous.counts === "object"
    && !Array.isArray(previous.counts)
    ? previous.counts
    : next.counts;
  return {
    ...next,
    listenerState: "unknown",
    messageSource: {
      ...next.messageSource,
      listenerState: "unknown",
    },
    groups: Array.isArray(previous.groups) ? previous.groups : next.groups,
    counts: previousCounts,
  };
}

export function diagnosticsPayloadWithLiveBootstrap(payload, bootstrap, clock = Date) {
  if (
    !bootstrap
    || typeof bootstrap !== "object"
    || !bootstrap.messageSource
    || typeof bootstrap.messageSource !== "object"
  ) {
    return payload;
  }
  const current = payload && typeof payload === "object" && !Array.isArray(payload)
    ? payload
    : {};
  const currentSources = current.sources
    && typeof current.sources === "object"
    && !Array.isArray(current.sources)
    ? current.sources
    : {};
  const source = bootstrap.messageSource;
  const available = source.available === true;
  const listenerState = verifiedListenerState(bootstrap, clock);
  const reason = available
    ? null
    : typeof source.reason === "string" && source.reason
      ? source.reason
      : "source_unavailable";
  return {
    ...current,
    listenerState,
    sources: {
      ...currentSources,
      messages: {
        available,
        reason,
      },
    },
  };
}

export async function runRecurringAttempt(shouldRun, attempt, reschedule) {
  try {
    if (!shouldRun()) {
      return false;
    }
    await attempt();
    return true;
  } finally {
    reschedule();
  }
}

function compareMessagesNewestFirst(left, right) {
  const leftTime = Date.parse(left.observedAt);
  const rightTime = Date.parse(right.observedAt);
  if (leftTime !== rightTime) {
    return rightTime - leftTime;
  }
  const leftEventId = String(left.eventId);
  const rightEventId = String(right.eventId);
  if (leftEventId === rightEventId) {
    return 0;
  }
  return leftEventId < rightEventId ? 1 : -1;
}

export function mergeNewMessages(existing, incoming) {
  const byEventId = new Map();
  for (const message of existing) {
    byEventId.set(message.eventId, message);
  }
  for (const message of incoming) {
    byEventId.set(message.eventId, message);
  }
  return Array.from(byEventId.values()).sort(compareMessagesNewestFirst);
}

function opaqueCursor(value) {
  return typeof value === "string" && value ? value : null;
}

export function prepareMessageReload(current) {
  const state = current || {};
  return {
    messages: Array.isArray(state.messages) ? state.messages : [],
    latestCursor: null,
    nextBefore: null,
    pendingMessageReplace: true,
  };
}

export function resetMessageSession() {
  return {
    messages: [],
    latestCursor: null,
    nextBefore: null,
    loading: false,
    polling: false,
    pendingMessageReplace: false,
  };
}

export function canLoadMessagePage(state) {
  return Boolean(
    state
    && !state.loading
    && state.authenticated
    && state.bootstrap
    && state.bootstrap.messageSource
    && state.bootstrap.messageSource.available === true
  );
}

export function applyMessagePage(current, payload, mode) {
  if (!["replace", "older", "incremental"].includes(mode)) {
    throw new Error("invalid_message_page_mode");
  }
  const previous = current || {};
  const response = payload && typeof payload === "object" ? payload : {};
  const existing = Array.isArray(previous.messages) ? previous.messages : [];
  const incoming = Array.isArray(response.items) ? response.items : [];
  const messages =
    mode === "replace"
      ? mergeNewMessages([], incoming)
      : mergeNewMessages(existing, incoming);

  const responseLatestCursor = opaqueCursor(response.latestCursor);
  let latestCursor = opaqueCursor(previous.latestCursor);
  const hadLatestCursor = latestCursor !== null;
  if (mode === "replace") {
    latestCursor = responseLatestCursor;
  } else if (mode === "incremental" || latestCursor === null) {
    latestCursor = responseLatestCursor || latestCursor;
  }

  let nextBefore = opaqueCursor(previous.nextBefore);
  if (mode === "replace") {
    nextBefore = opaqueCursor(response.nextBefore);
  } else if (
    mode === "older" &&
    Object.prototype.hasOwnProperty.call(response, "nextBefore")
  ) {
    nextBefore = opaqueCursor(response.nextBefore);
  } else if (
    mode === "incremental" &&
    !hadLatestCursor &&
    nextBefore === null &&
    responseLatestCursor !== null
  ) {
    nextBefore = opaqueCursor(response.nextBefore);
  }

  return {
    messages,
    latestCursor,
    nextBefore,
    receivedCount: incoming.length,
  };
}

export function routeFromHash(hash) {
  if (hash === "" || hash === "#" || hash === "#inbox") {
    return { ...INBOX_ROUTE };
  }
  const match = /^#group\/([^/]+)$/.exec(hash);
  if (!match) {
    return { ...INBOX_ROUTE };
  }
  try {
    const group = decodeURIComponent(match[1]);
    if (!group) {
      return { ...INBOX_ROUTE };
    }
    return { page: "group", group };
  } catch (_error) {
    return { ...INBOX_ROUTE };
  }
}
