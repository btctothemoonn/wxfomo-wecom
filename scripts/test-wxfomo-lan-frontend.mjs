import assert from "assert";

import {
  ApiError,
  authenticate,
  fetchBootstrap,
  hasSessionToken,
  requestJson,
} from "../web/wxfomo-lan/api.mjs";
import { copyText } from "../web/wxfomo-lan/clipboard.mjs";
import * as frontendState from "../web/wxfomo-lan/state.mjs";
import {
  PRIORITY_PAGE,
  SourceLink,
  PUBLIC_SOURCE_HOSTS,
  WORKSPACE_PAGES,
  isCurrentMessageRequest,
  isCurrentReadOnlyRequest,
  readOnlyPageFromHash,
  renderAlerts,
  renderAutomations,
  renderMeme,
  renderPriority,
  renderRules,
  renderTrading,
} from "../web/wxfomo-lan/pages.mjs";

const {
  applyMessagePage,
  boundedRetryDelay,
  canLoadMessagePage,
  diagnosticsPrimaryFailurePayload,
  diagnosticsPayloadWithLiveBootstrap,
  isCurrentConnection,
  isRetriableReadOnlyPayload,
  isRetriableWorkspaceReason,
  invalidateListenerFreshness,
  listenerPresentation,
  mergeNewMessages,
  prepareMessageReload,
  retainMessageBootstrap,
  retainReadOnlyPayload,
  resetMessageSession,
  routeFromHash,
  runRecurringAttempt,
} = frontendState;

class FakeClassList {
  constructor(node) {
    this.node = node;
  }

  add(name) {
    const names = this.node.className ? this.node.className.split(/\s+/) : [];
    if (!names.includes(name)) {
      names.push(name);
      this.node.className = names.join(" ");
    }
  }
}

class FakeNode {
  constructor(tagName, ownerDocument) {
    this.tagName = String(tagName).toUpperCase();
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.attributes = {};
    this.className = "";
    this.classList = new FakeClassList(this);
    this._textContent = "";
    this.listeners = {};
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  append(...children) {
    for (const child of children) {
      this.appendChild(child);
    }
  }

  replaceChildren(...children) {
    this.children = [];
    this._textContent = "";
    this.append(...children);
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name)
      ? this.attributes[name]
      : null;
  }

  addEventListener(name, listener) {
    this.listeners[name] = listener;
  }

  querySelector(selector) {
    if (selector.startsWith(".")) {
      const className = selector.slice(1);
      return descendants(this).find(
        (node) => String(node.className).split(/\s+/).includes(className)
      ) || null;
    }
    if (selector === "button[type='submit']") {
      return descendants(this).find(
        (node) => node.tagName === "BUTTON" && node.type === "submit"
      ) || null;
    }
    return null;
  }

  focus() {}

  click() {
    if (this.listeners.click) {
      this.listeners.click({ preventDefault() {} });
    }
  }

  set textContent(value) {
    this._textContent = String(value);
    this.children = [];
  }

  get textContent() {
    return this._textContent + this.children.map((child) => child.textContent).join("");
  }
}

class FakeDocument {
  constructor() {
    this.nodesById = new Map();
    this.listeners = {};
    this.visibilityState = "visible";
  }

  createElement(tagName) {
    return new FakeNode(tagName, this);
  }

  createElementNS(_namespace, tagName) {
    return this.createElement(tagName);
  }

  createTextNode(text) {
    const node = new FakeNode("#text", this);
    node.textContent = text;
    return node;
  }

  getElementById(id) {
    if (!this.nodesById.has(id)) {
      this.nodesById.set(id, this.createElement("div"));
    }
    return this.nodesById.get(id);
  }

  addEventListener(name, listener) {
    this.listeners[name] = listener;
  }
}

function fakeRoot() {
  const document = new FakeDocument();
  return document.createElement("main");
}

function descendants(node) {
  const result = [];
  for (const child of node.children) {
    result.push(child, ...descendants(child));
  }
  return result;
}

function testWorkspaceRegistryHasExactReadOnlyCoverage() {
  assert.deepStrictEqual(
    WORKSPACE_PAGES.map((page) => page.id),
    [
      "meme", "market", "analyses", "rules", "trading", "automations",
      "sounds", "providers", "diagnostics",
    ]
  );
  for (const page of WORKSPACE_PAGES) {
    assert.strictEqual(typeof page.render, "function");
    assert.strictEqual(page.readOnly, true);
  }
}

function testUnavailablePagesUseCanonicalCopyAndNeverRenderWriteActions() {
  const renderers = [renderAlerts, ...WORKSPACE_PAGES.map((page) => page.render)];
  for (const render of renderers) {
    const root = fakeRoot();
    const cleanup = render({
      root,
      payload: { available: false, reason: "source_unavailable", items: [] },
      api: {},
    });
    assert.strictEqual(typeof cleanup, "function");
    assert.ok(root.textContent.includes("当前 Mac 后台尚未生成此类数据"));
    assert.strictEqual(
      descendants(root).filter(
        (node) => node.tagName === "BUTTON" && node.getAttribute("data-write-action") !== null
      ).length,
      0
    );
    cleanup();
  }
}

function testProviderPageDisplaysOnlyNamesBooleansAndFixedMask() {
  const providerPage = WORKSPACE_PAGES.find((page) => page.id === "providers");
  const root = fakeRoot();
  providerPage.render({
    root,
    payload: {
      available: true,
      aiConfigured: true,
      speechConfigured: false,
      providerNames: ["OpenAI Compatible"],
      tradingConfigured: false,
      secret: "NEVER_EXPOSE_THIS",
    },
    api: {},
  });
  assert.ok(root.textContent.includes("OpenAI Compatible"));
  assert.ok(root.textContent.includes("••••••••"));
  assert.ok(!root.textContent.includes("NEVER_EXPOSE_THIS"));
}

function testSourceLinkAcceptsOnlyHttpsAndUsesSafeRelationship() {
  const root = fakeRoot();
  const secure = SourceLink(root.ownerDocument, "公开来源", "https://dexscreener.com/base/0xsafe");
  const insecure = SourceLink(root.ownerDocument, "不安全来源", "http://dexscreener.com/base/0xsafe");
  assert.strictEqual(secure.tagName, "A");
  assert.strictEqual(secure.getAttribute("href"), "https://dexscreener.com/base/0xsafe");
  assert.strictEqual(secure.getAttribute("target"), "_blank");
  assert.strictEqual(secure.getAttribute("rel"), "noopener noreferrer");
  assert.notStrictEqual(insecure.tagName, "A");
  assert.strictEqual(insecure.textContent, "不安全来源");
  for (const unsafe of [
    "https://router/admin",
    "https://nas/private",
    "https://home.arpa/admin",
    "https://service.home.arpa/admin",
    "https://public.example/path",
    "https://example.invalid/path",
    "https://example.test/path",
    "https://name.example/path",
    "https://example.com/path",
    "https://example.net/path",
    "https://example.org/path",
    "https://sub.dexscreener.com/base/0xsafe",
    "https://dexscreener.com./base/0xsafe",
    "https://8.8.8.8/path",
    "https://user:password@dexscreener.com/private",
    "https://dexscreener.com:8443/private",
    "https://localhost/private",
    "https://127.0.0.1/private",
    "https://10.0.0.8/private",
    "https://169.254.10.8/private",
    "https://100.64.0.1/private",
    "https://198.51.100.8/private",
    "https://[::1]/private",
    "https://[::ffff:127.0.0.1]/private",
    "https://dexscreener.com/path?api_key=secret",
    "https://dexscreener.com/path?view=chart",
    "https://dexscreener.com/path?code=secret",
    "https://dexscreener.com/path?jwt=secret",
    "https://dexscreener.com/path?sig=secret",
    "https://dexscreener.com/path?x=Bearer%20secret",
    "https://dexscreener.com/path#fragment",
    "https://dexscreener.com/Authorization/Bearer-secret",
    "https://dexscreener.com/%E0%A4%A",
  ]) {
    assert.notStrictEqual(SourceLink(root.ownerDocument, "拒绝", unsafe).tagName, "A");
  }
  assert.strictEqual(
    SourceLink(root.ownerDocument, "公开来源", "https://www.geckoterminal.com/solana/pools/safe").tagName,
    "A"
  );
}

function testPublicSourceHostAllowlistMatchesTheDocumentedContract() {
  assert.deepStrictEqual(PUBLIC_SOURCE_HOSTS, [
    "arbiscan.io",
    "basescan.org",
    "birdeye.so",
    "bscscan.com",
    "dexscreener.com",
    "etherscan.io",
    "fomo.family",
    "geckoterminal.com",
    "gmgn.ai",
    "optimistic.etherscan.io",
    "polygonscan.com",
    "pump.fun",
    "snowtrace.io",
    "solscan.io",
    "www.birdeye.so",
    "www.geckoterminal.com",
  ]);
}

function testReadOnlyPageNavigationResolvesOnlyRegisteredHashes() {
  assert.strictEqual(readOnlyPageFromHash("#alerts").id, "alerts");
  assert.strictEqual(readOnlyPageFromHash("#priority"), PRIORITY_PAGE);
  for (const page of WORKSPACE_PAGES) {
    assert.strictEqual(readOnlyPageFromHash(`#${page.id}`), page);
  }
  assert.strictEqual(readOnlyPageFromHash("#inbox"), null);
  assert.strictEqual(readOnlyPageFromHash("#trading/execute"), null);
  assert.strictEqual(readOnlyPageFromHash("#unknown"), null);
}

function testPriorityPageIsSeparateReadOnlyRouteWithCanonicalUnavailableCopy() {
  assert.ok(!WORKSPACE_PAGES.includes(PRIORITY_PAGE));
  assert.strictEqual(PRIORITY_PAGE.endpoint, "/api/priority");
  const root = fakeRoot();
  renderPriority({
    root,
    payload: { available: false, reason: "source_unavailable", items: [] },
    api: {},
  });
  assert.ok(root.textContent.includes("重点捕捉"));
  assert.ok(root.textContent.includes("当前 Mac 后台尚未生成此类数据"));
  assert.strictEqual(
    descendants(root).filter((node) => node.getAttribute("data-write-action") !== null).length,
    0
  );
}

function testAvailablePagesIgnoreSecretsPathsAndWriteControls() {
  const payloads = {
    meme: { available: true, items: [{ symbol: "SAFE", network: "base" }] },
    market: { available: true, items: [{ symbol: "SAFE", network: "base" }] },
    analyses: { available: true, items: [{ jobId: "job-1", state: "succeeded" }] },
    rules: { available: true, items: [{ name: "规则", condition: {}, actions: [] }] },
    trading: { available: true, items: [{ symbol: "SAFE", state: "simulated" }] },
    automations: { available: true, items: [{ name: "观察规则", condition: {}, actions: [] }] },
    sounds: { available: true, aiConfigured: true, speechConfigured: false },
    providers: {
      available: true,
      aiConfigured: true,
      speechConfigured: false,
      tradingConfigured: false,
      providerNames: ["Safe Provider"],
      apiKey: "NEVER_EXPOSE_THIS",
    },
    diagnostics: {
      available: true,
      sources: { messages: { available: true }, workspace: { available: false } },
      databasePath: "/Users/private/workspace.sqlite3",
      retriableErrors: ["source_locked", "/Users/private/error"],
    },
  };
  const forbiddenLabels = /create|edit|retry|run|buy|sell|simulate|write|新建|编辑|重试|运行|买入|卖出|模拟|写入/i;
  for (const page of WORKSPACE_PAGES) {
    const root = fakeRoot();
    page.render({ root, payload: payloads[page.id], api: {} });
    const nodes = descendants(root);
    assert.strictEqual(
      nodes.filter((node) => node.getAttribute("data-write-action") !== null).length,
      0
    );
    assert.strictEqual(
      nodes.filter((node) => node.tagName === "BUTTON" && forbiddenLabels.test(node.textContent)).length,
      0
    );
    assert.ok(!root.textContent.includes("NEVER_EXPOSE_THIS"));
    assert.ok(!root.textContent.includes("/Users/private"));
  }

  const root = fakeRoot();
  renderAlerts({
    root,
    payload: {
      available: true,
      items: [{ title: "<img src=x onerror=alert(1)>", sourceEventIds: [] }],
    },
    api: {},
  });
  assert.ok(root.textContent.includes("<img src=x onerror=alert(1)>"));
  assert.strictEqual(descendants(root).filter((node) => node.tagName === "IMG").length, 0);
}

function testAlertTabsFilterPendingAndAllRecords() {
  const root = fakeRoot();
  renderAlerts({
    root,
    payload: {
      available: true,
      items: [
        { title: "待处理提醒", acknowledgedAt: null },
        { title: "已确认提醒", acknowledgedAt: "2026-09-02T00:00:00Z" },
      ],
    },
    api: {},
  });
  assert.ok(root.textContent.includes("待处理提醒"));
  assert.ok(!root.textContent.includes("已确认提醒"));
  const allTab = descendants(root).find(
    (node) => node.tagName === "BUTTON" && node.textContent === "全部 2"
  );
  allTab.click();
  assert.ok(root.textContent.includes("待处理提醒"));
  assert.ok(root.textContent.includes("已确认提醒"));
}

function testMarketChainTabsFilterPersistedRows() {
  const marketPage = WORKSPACE_PAGES.find((page) => page.id === "market");
  const root = fakeRoot();
  marketPage.render({
    root,
    payload: {
      available: true,
      items: [
        { symbol: "BASE", network: "base" },
        { symbol: "SOL", network: "sol" },
      ],
    },
    api: {},
  });
  const baseTab = descendants(root).find(
    (node) => node.tagName === "BUTTON" && node.textContent === "base"
  );
  baseTab.click();
  assert.ok(root.textContent.includes("BASE"));
  assert.ok(!root.textContent.includes("SOL"));
}

function testStaleReadOnlyRequestsCannotReplaceCurrentPage() {
  const pageA = WORKSPACE_PAGES[0];
  const pageB = WORKSPACE_PAGES[1];
  assert.strictEqual(isCurrentReadOnlyRequest(4, 5, pageA, pageB), false);
  assert.strictEqual(isCurrentReadOnlyRequest(5, 5, pageA, pageB), false);
  assert.strictEqual(isCurrentReadOnlyRequest(5, 5, pageB, pageB), true);
}

function testStaleMessageRequestsCannotReportErrorsOnAnotherGenerationOrWorkspace() {
  assert.strictEqual(isCurrentMessageRequest(4, 5, false), false);
  assert.strictEqual(isCurrentMessageRequest(5, 5, true), false);
  assert.strictEqual(isCurrentMessageRequest(5, 5, false), true);
}

function testDiagnosticsDoesNotEquateDatabaseReadabilityWithListenerActivity() {
  const diagnostics = WORKSPACE_PAGES.find((page) => page.id === "diagnostics");
  const root = fakeRoot();
  diagnostics.render({
    root,
    payload: {
      available: true,
      sources: {
        messages: { available: true },
        workspace: { available: false, reason: "source_unavailable" },
        configuration: { available: true },
      },
      listenerState: "unknown",
      retriableErrors: ["message_source_unavailable"],
    },
    api: {},
  });
  assert.ok(root.textContent.includes("后台未提供运行状态"));
  assert.ok(!root.textContent.includes("活动中"));
  assert.ok(root.textContent.includes("消息库暂不可读"));

  for (const [reason, expected] of [
    ["source_locked", "数据源临时锁定"],
    ["schema_incompatible", "数据源版本不兼容"],
    ["source_permission_denied", "数据源权限不足"],
    ["source_corrupt", "数据源已损坏"],
  ]) {
    const reasonRoot = fakeRoot();
    diagnostics.render({
      root: reasonRoot,
      payload: {
        available: true,
        sources: {
          messages: { available: true },
          workspace: { available: false, reason },
          configuration: { available: true },
        },
        listenerState: "unknown",
      },
      api: {},
    });
    assert.ok(reasonRoot.textContent.includes(expected), `${reason}: ${reasonRoot.textContent}`);
  }
}

function testDiagnosticsUsesLatestBootstrapListenerAndMessageSource() {
  assert.strictEqual(typeof diagnosticsPayloadWithLiveBootstrap, "function");
  const stale = {
    available: true,
    listenerState: "active",
    sources: {
      messages: { available: true, reason: null },
      workspace: { available: true, reason: null },
      configuration: { available: true, reason: null },
    },
    items: [],
  };

  const inactive = diagnosticsPayloadWithLiveBootstrap(stale, {
    listenerState: "inactive",
    messageSource: { available: true, listenerState: "inactive" },
  });
  assert.strictEqual(inactive.listenerState, "inactive");
  assert.deepStrictEqual(inactive.sources.messages, { available: true, reason: null });
  assert.deepStrictEqual(inactive.sources.workspace, { available: true, reason: null });

  const unavailable = diagnosticsPayloadWithLiveBootstrap(stale, {
    listenerState: "active",
    messageSource: { available: false, listenerState: "unknown" },
  });
  assert.strictEqual(unavailable.listenerState, "unknown");
  assert.deepStrictEqual(unavailable.sources.messages, {
    available: false,
    reason: "source_unavailable",
  });
  assert.strictEqual(stale.listenerState, "active");
  assert.deepStrictEqual(stale.sources.messages, { available: true, reason: null });
}

function testDiagnosticsRequiresFreshHeartbeatForActiveState() {
  const diagnostics = WORKSPACE_PAGES.find((page) => page.id === "diagnostics");
  const clock = { now: () => Date.parse("2026-09-03T00:00:06.000Z") };
  const stored = {
    available: true,
    listenerState: "active",
    sources: {
      messages: { available: true, reason: null },
      workspace: { available: true, reason: null },
      configuration: { available: true, reason: null },
    },
    items: [],
  };

  for (const heartbeatAt of [undefined, "2026-09-03T00:00:00.000Z"]) {
    const merged = diagnosticsPayloadWithLiveBootstrap(stored, {
      listenerState: "active",
      messageSource: {
        available: true,
        listenerState: "active",
        heartbeatAt,
      },
    }, clock);
    const root = fakeRoot();
    diagnostics.render({ root, payload: merged, api: {} });

    assert.strictEqual(merged.listenerState, "inactive");
    assert.ok(!root.textContent.includes("活动中"));
    assert.ok(root.textContent.includes("未活动"));
  }
}

async function testSkippedRecurringAttemptAlwaysReschedules() {
  let attempts = 0;
  let reschedules = 0;
  const ran = await runRecurringAttempt(
    () => false,
    async () => { attempts += 1; },
    () => { reschedules += 1; }
  );
  assert.strictEqual(ran, false);
  assert.strictEqual(attempts, 0);
  assert.strictEqual(reschedules, 1);
}

function testBootstrapFailureInvalidatesOnlyListenerFreshness() {
  const active = {
    readOnly: true,
    listenerState: "active",
    messageSource: {
      available: true,
      listenerState: "active",
      heartbeatAt: "2026-09-03T00:00:00Z",
    },
    groups: [{ name: "目标群", count: 3 }],
    counts: { inbox: 3 },
  };
  const invalidated = invalidateListenerFreshness(active);
  assert.strictEqual(invalidated.listenerState, "unknown");
  assert.strictEqual(invalidated.messageSource.listenerState, "unknown");
  assert.strictEqual(invalidated.messageSource.available, true);
  assert.deepStrictEqual(invalidated.groups, active.groups);
  assert.deepStrictEqual(invalidated.counts, active.counts);
  assert.strictEqual(active.listenerState, "active");
}

function testMessageReloadPreservesVisiblePageUntilReplacementSucceeds() {
  const oldMessages = [{ eventId: "old-visible", observedAt: "2026-09-03T00:00:00Z" }];
  const prepared = prepareMessageReload({
    messages: oldMessages,
    latestCursor: "old-latest",
    nextBefore: "old-before",
  });
  assert.strictEqual(prepared.messages, oldMessages);
  assert.strictEqual(prepared.latestCursor, null);
  assert.strictEqual(prepared.nextBefore, null);
  assert.strictEqual(prepared.pendingMessageReplace, true);

  const replacement = applyMessagePage(prepared, {
    items: [{ eventId: "new-scope", observedAt: "2026-09-03T00:00:01Z" }],
    latestCursor: "new-latest",
    nextBefore: "new-before",
  }, "replace");
  assert.deepStrictEqual(replacement.messages.map((item) => item.eventId), ["new-scope"]);
}

function testUnauthorizedResetAllowsAReplacementLoadAfterReconnect() {
  const staleRequestState = {
    loading: true,
    polling: true,
    pendingMessageReplace: true,
    messages: [{ eventId: "stale" }],
    latestCursor: "stale-latest",
    nextBefore: "stale-before",
  };
  const loggedOut = Object.assign({}, staleRequestState, resetMessageSession(), {
    authenticated: false,
    bootstrap: null,
  });
  assert.strictEqual(loggedOut.loading, false);
  assert.strictEqual(loggedOut.polling, false);
  assert.strictEqual(loggedOut.nextBefore, null);
  assert.strictEqual(loggedOut.pendingMessageReplace, false);

  const reconnected = Object.assign({}, loggedOut, {
    authenticated: true,
    bootstrap: { messageSource: { available: true } },
  });
  assert.strictEqual(canLoadMessagePage(reconnected), true);
}

function testAlertsRenderMatchedSafeSourceMessages() {
  const root = fakeRoot();
  const copied = [];
  renderAlerts({
    root,
    payload: {
      available: true,
      items: [{
        title: "来源提醒",
        sourceEventIds: ["event-a"],
        sourceMessages: [{
          eventId: "event-a",
          group: "安全群",
          sender: "阿甲",
          content: "真实来源正文",
          links: ["https://dexscreener.com/base/0xsafe"],
        }],
        tokenContext: {
          family: "evm",
          network: "base",
          address: "0xsafe",
          mentionCount: 3,
          groupNames: ["安全群", "观察群"],
        },
      }],
    },
    api: { copyText: (value) => copied.push(value) },
  });
  assert.ok(root.textContent.includes("安全群 · 阿甲"));
  assert.ok(root.textContent.includes("真实来源正文"));
  assert.ok(root.textContent.includes("base · 0xsafe"));
  assert.ok(root.textContent.includes("3 次提及 · 2 个群"));
  const link = descendants(root).find((node) => node.tagName === "A");
  assert.strictEqual(link.getAttribute("href"), "https://dexscreener.com/base/0xsafe");
  assert.strictEqual(link.getAttribute("rel"), "noopener noreferrer");
  const copyButtons = descendants(root).filter((node) => node.tagName === "BUTTON");
  assert.ok(copyButtons.some((node) => node.textContent.includes("复制地址")));
  assert.ok(copyButtons.some((node) => node.textContent.includes("复制公开链接")));
  for (const button of copyButtons) {
    button.click();
  }
  assert.ok(copied.includes("0xsafe"));
  assert.ok(copied.includes("https://dexscreener.com/base/0xsafe"));
}

function testMemeRendersPersistedMentionAndDistinctGroupHeat() {
  const root = fakeRoot();
  const copied = [];
  renderMeme({
    root,
    payload: {
      available: true,
      items: [{
        family: "evm",
        network: "base",
        address: "0xsafe",
        state: "watching",
        symbol: "SAFE",
        mentionCount: 3,
        groupNames: ["安全群", "观察群"],
      }],
    },
    api: { copyText: (value) => copied.push(value) },
  });
  assert.ok(root.textContent.includes("3 次提及 · 2 个群"));
  assert.ok(root.textContent.includes("持久化观察窗口"));
  assert.ok(root.textContent.includes("0xsafe"));
  const copy = descendants(root).find(
    (node) => node.tagName === "BUTTON" && node.textContent.includes("复制地址")
  );
  copy.click();
  assert.deepStrictEqual(copied, ["0xsafe"]);
  assert.ok(!root.textContent.includes("尚无聚合值"));
}

function testTradingRendersAndCopiesTokenAddress() {
  const root = fakeRoot();
  const copied = [];
  renderTrading({
    root,
    payload: {
      available: true,
      walletSafeStatus: "私钥未下发",
      items: [{
        symbol: "SAFE",
        tokenAddress: "0xtrade",
        state: "simulated",
        network: "base",
      }],
    },
    api: { copyText: (value) => copied.push(value) },
  });
  assert.ok(root.textContent.includes("0xtrade"));
  const copy = descendants(root).find(
    (node) => node.tagName === "BUTTON" && node.textContent.includes("复制地址")
  );
  copy.click();
  assert.deepStrictEqual(copied, ["0xtrade"]);
}

function testTradingAndAutomationCompositesPreserveSettingsAvailability() {
  assert.strictEqual(typeof frontendState.composeReadOnlyPagePayload, "function");
  assert.strictEqual(typeof frontendState.isRetriableReadOnlyPayload, "function");
  const lockedSettings = { available: false, reason: "source_locked" };
  const automationPayload = frontendState.composeReadOnlyPagePayload(
    "automations",
    { available: true, items: [{ name: "旧规则" }] },
    { available: true, items: [{ intentId: "intent-1" }] },
    lockedSettings
  );
  assert.deepStrictEqual(automationPayload.settingsDependency, lockedSettings);
  assert.strictEqual(automationPayload.configurationStatus, null);
  assert.deepStrictEqual(automationPayload.recentIntents, [{ intentId: "intent-1" }]);
  assert.strictEqual(frontendState.isRetriableReadOnlyPayload(automationPayload), true);

  const tradingPayload = frontendState.composeReadOnlyPagePayload(
    "trading",
    { available: true, items: [{ symbol: "SAFE" }] },
    null,
    { available: false, reason: "source_permission_denied" }
  );
  assert.deepStrictEqual(tradingPayload.settingsDependency, {
    available: false,
    reason: "source_permission_denied",
  });
  assert.strictEqual(tradingPayload.walletSafeStatus, null);
  assert.strictEqual(frontendState.isRetriableReadOnlyPayload(tradingPayload), false);

  const previous = {
    available: true,
    settingsDependency: { available: true, reason: null },
    configurationStatus: true,
    items: [{ name: "保留规则" }],
  };
  const retained = retainReadOnlyPayload(previous, automationPayload);
  assert.deepStrictEqual(retained.items, previous.items);
  assert.strictEqual(retained.configurationStatus, previous.configurationStatus);
  assert.deepStrictEqual(retained.settingsDependency, lockedSettings);
}

function testAutomationCompositePreservesUnavailableTradesDependency() {
  const reasonCases = [
    ["source_locked", "数据源临时锁定", true],
    ["schema_incompatible", "数据源版本不兼容", true],
    ["source_corrupt", "数据源已损坏", true],
    ["source_permission_denied", "数据源权限不足", false],
    ["source_unavailable", "数据源尚未生成", false],
  ];
  const previous = {
    available: true,
    settingsDependency: { available: true, reason: null },
    tradesDependency: { available: true, reason: null },
    configurationStatus: true,
    recentIntents: [{ intentId: "retained-intent" }],
    items: [{ name: "保留规则" }],
  };

  for (const [reason, label, retriable] of reasonCases) {
    const payload = frontendState.composeReadOnlyPagePayload(
      "automations",
      { available: true, items: [{ name: "替换规则" }] },
      { available: false, reason, items: [] },
      { available: true, reason: null, tradingConfigured: true }
    );
    assert.deepStrictEqual(payload.tradesDependency, { available: false, reason });
    assert.strictEqual(frontendState.isRetriableReadOnlyPayload(payload), retriable);
    const retained = retainReadOnlyPayload(previous, payload);
    if (retriable) {
      assert.deepStrictEqual(retained.items, previous.items);
      assert.deepStrictEqual(retained.recentIntents, previous.recentIntents);
      assert.deepStrictEqual(retained.tradesDependency, { available: false, reason });
    } else {
      assert.strictEqual(retained, payload);
    }

    const root = fakeRoot();
    renderAutomations({ root, payload, api: {} });
    assert.ok(root.textContent.includes(label), `${reason}: ${root.textContent}`);
    assert.ok(!root.textContent.includes("暂无最近意图"), `${reason}: ${root.textContent}`);
  }

  const available = frontendState.composeReadOnlyPagePayload(
    "automations",
    { available: true, items: [] },
    { available: true, reason: null, items: [{ intentId: "intent-available" }] },
    { available: true, reason: null, tradingConfigured: true }
  );
  assert.deepStrictEqual(available.tradesDependency, { available: true, reason: null });
  assert.deepStrictEqual(available.recentIntents, [{ intentId: "intent-available" }]);

  const previousEmpty = {
    ...previous,
    recentIntents: [],
  };
  const lockedAfterEmptySuccess = frontendState.composeReadOnlyPagePayload(
    "automations",
    { available: true, items: [{ name: "保留规则" }] },
    { available: false, reason: "source_locked", items: [] },
    { available: true, reason: null, tradingConfigured: true }
  );
  const retainedEmpty = retainReadOnlyPayload(previousEmpty, lockedAfterEmptySuccess);
  const retainedRoot = fakeRoot();
  renderAutomations({ root: retainedRoot, payload: retainedEmpty, api: {} });
  assert.deepStrictEqual(retainedEmpty.recentIntents, []);
  assert.deepStrictEqual(retainedEmpty.tradesDependency, {
    available: false,
    reason: "source_locked",
  });
  assert.ok(retainedRoot.textContent.includes("数据源临时锁定"));
  assert.ok(!retainedRoot.textContent.includes("暂无最近意图"));
}

function testDiagnosticsSupplementalMessagesDependencyControlsTruthAndRetry() {
  assert.strictEqual(typeof frontendState.composeDiagnosticsPagePayload, "function");
  const primary = {
    available: true,
    sources: {
      messages: { available: true, reason: null },
      workspace: { available: true, reason: null },
      configuration: { available: true, reason: null },
    },
    listenerState: "inactive",
    retriableErrors: [],
  };
  const successful = frontendState.composeDiagnosticsPagePayload(primary, {
    available: true,
    reason: null,
    items: [{ observedAt: "2026-09-03T01:02:03Z" }],
  });
  assert.deepStrictEqual(successful.messagesDependency, { available: true, reason: null });
  assert.strictEqual(successful.lastMessageAt, "2026-09-03T01:02:03Z");

  const previous = {
    ...successful,
    lastMessageAt: "2026-09-03T00:00:00Z",
  };
  for (const [reason, label] of [
    ["request_timeout", "请求超时"],
    ["source_locked", "数据源临时锁定"],
  ]) {
    const failed = frontendState.composeDiagnosticsPagePayload(primary, {
      available: false,
      reason,
      items: [],
    });
    assert.deepStrictEqual(failed.messagesDependency, { available: false, reason });
    assert.strictEqual(failed.lastMessageAt, null);
    assert.strictEqual(frontendState.isRetriableReadOnlyPayload(failed), true);
    const retained = retainReadOnlyPayload(previous, failed);
    assert.strictEqual(retained.lastMessageAt, previous.lastMessageAt);
    assert.deepStrictEqual(retained.messagesDependency, { available: false, reason });

    const root = fakeRoot();
    const diagnostics = WORKSPACE_PAGES.find((page) => page.id === "diagnostics");
    diagnostics.render({ root, payload: failed, api: {} });
    assert.ok(root.textContent.includes(label), `${reason}: ${root.textContent}`);
    assert.ok(!root.textContent.includes("尚无记录"), `${reason}: ${root.textContent}`);
  }

  const failedAfterEmptySuccess = frontendState.composeDiagnosticsPagePayload(primary, {
    available: false,
    reason: "request_timeout",
    items: [],
  });
  const retainedEmpty = retainReadOnlyPayload(
    { ...successful, lastMessageAt: null },
    failedAfterEmptySuccess
  );
  const retainedRoot = fakeRoot();
  const diagnostics = WORKSPACE_PAGES.find((page) => page.id === "diagnostics");
  diagnostics.render({ root: retainedRoot, payload: retainedEmpty, api: {} });
  assert.strictEqual(retainedEmpty.lastMessageAt, null);
  assert.deepStrictEqual(retainedEmpty.messagesDependency, {
    available: false,
    reason: "request_timeout",
  });
  assert.ok(retainedRoot.textContent.includes("请求超时"));
  assert.ok(!retainedRoot.textContent.includes("尚无记录"));

  const changedPrimary = {
    ...primary,
    listenerState: "active",
    sources: {
      ...primary.sources,
      workspace: { available: false, reason: "source_corrupt" },
    },
    healthGeneration: 2,
  };
  const changedWhileMessagesFail = frontendState.composeDiagnosticsPagePayload(
    changedPrimary,
    { available: false, reason: "message_source_unavailable", items: [] }
  );
  const retainedWithFreshPrimary = retainReadOnlyPayload(
    { ...previous, healthGeneration: 1 },
    changedWhileMessagesFail
  );
  assert.strictEqual(retainedWithFreshPrimary.lastMessageAt, previous.lastMessageAt);
  assert.strictEqual(retainedWithFreshPrimary.listenerState, "active");
  assert.strictEqual(retainedWithFreshPrimary.healthGeneration, 2);
  assert.deepStrictEqual(retainedWithFreshPrimary.sources.workspace, {
    available: false,
    reason: "source_corrupt",
  });
  assert.deepStrictEqual(retainedWithFreshPrimary.messagesDependency, {
    available: false,
    reason: "message_source_unavailable",
  });
}

function testDiagnosticsPrimaryFailurePayloadIsExplicitAndRetainsHistory() {
  const firstLoad = diagnosticsPrimaryFailurePayload(null, "network_error");
  assert.strictEqual(firstLoad.available, true);
  assert.strictEqual(firstLoad.reason, null);
  assert.strictEqual(firstLoad.lastMessageAt, null);
  assert.deepStrictEqual(firstLoad.messagesDependency, {
    available: false,
    reason: "network_error",
  });
  assert.strictEqual(isRetriableReadOnlyPayload(firstLoad), true);

  const previous = {
    available: true,
    reason: null,
    listenerState: "active",
    sources: {
      workspace: { available: false, reason: "source_corrupt" },
    },
    healthGeneration: 7,
    lastMessageAt: "2026-09-03T01:02:03Z",
    messagesDependency: { available: true, reason: null },
    retriableErrors: [],
  };
  const retained = diagnosticsPrimaryFailurePayload(previous, "request_timeout");
  assert.strictEqual(retained.available, true);
  assert.strictEqual(retained.listenerState, "active");
  assert.strictEqual(retained.sources, previous.sources);
  assert.strictEqual(retained.healthGeneration, 7);
  assert.strictEqual(retained.lastMessageAt, previous.lastMessageAt);
  assert.deepStrictEqual(retained.messagesDependency, {
    available: false,
    reason: "request_timeout",
  });
  assert.deepStrictEqual(retained.retriableErrors, []);
  assert.strictEqual(isRetriableReadOnlyPayload(retained), true);
}

function testTradingAndAutomationUiNeverCallUnavailableSettingsUnconfigured() {
  for (const [render, payload] of [
    [renderAutomations, {
      available: true,
      settingsDependency: { available: false, reason: "source_locked" },
      configurationStatus: null,
      items: [],
    }],
    [renderTrading, {
      available: true,
      settingsDependency: { available: false, reason: "source_locked" },
      walletSafeStatus: null,
      items: [],
    }],
  ]) {
    const root = fakeRoot();
    render({ root, payload, api: {} });
    assert.ok(root.textContent.includes("数据源临时锁定"));
    assert.ok(!root.textContent.includes("未配置"));
    assert.ok(!root.textContent.includes("交易配置未启用"));
  }
}

async function testAutomationCompositeRetainsPriorDependencyAndPayloadDuringLock() {
  const previousGlobals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const timers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#automations" },
    addEventListener() {},
    clearTimeout(id) {
      timers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      timers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("composite-retention-token", storage);
  let automationRequests = 0;
  let settingsRequests = 0;

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    const path = String(url).split("?")[0];
    let payload;
    if (path === "/api/bootstrap") {
      payload = {
        readOnly: true,
        listenerState: "inactive",
        messageSource: { available: true, listenerState: "inactive" },
        groups: [],
        counts: { inbox: 0 },
      };
    } else if (path === "/api/automations") {
      automationRequests += 1;
      payload = {
        available: true,
        items: [{ name: automationRequests === 1 ? "RETAINED_AUTOMATION" : "REPLACEMENT_AUTOMATION" }],
      };
    } else if (path === "/api/trades") {
      payload = { available: true, items: [] };
    } else if (path === "/api/settings/status") {
      settingsRequests += 1;
      payload = settingsRequests === 1
        ? { available: true, reason: null, tradingConfigured: true }
        : { available: false, reason: "source_locked" };
    } else {
      throw new Error(`unexpected request ${path}`);
    }
    return { ok: true, status: 200, json: async () => payload };
  };

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("composite-retention-test", String(Date.now()));
    await import(appUrl.href);
    for (let index = 0; index < 24; index += 1) {
      await Promise.resolve();
    }
    const appShell = document.getElementById("app-shell");
    assert.ok(appShell.textContent.includes("RETAINED_AUTOMATION"));
    assert.ok(appShell.textContent.includes("已配置"));

    document.visibilityState = "hidden";
    document.listeners.visibilitychange();
    document.visibilityState = "visible";
    document.listeners.visibilitychange();
    for (let index = 0; index < 24; index += 1) {
      await Promise.resolve();
    }

    assert.ok(settingsRequests >= 2);
    assert.ok(appShell.textContent.includes("RETAINED_AUTOMATION"));
    assert.ok(!appShell.textContent.includes("REPLACEMENT_AUTOMATION"));
    assert.ok(appShell.textContent.includes("数据源临时锁定"));
    assert.ok(!appShell.textContent.includes("未配置"));
    assert.ok(appShell.textContent.includes("依赖数据源暂不可读，保留已有内容后重试"));
    assert.ok(Array.from(timers.values()).some((timer) => timer.delay === 2000));

    const scheduled = Array.from(timers.values());
    timers.clear();
    for (const timer of scheduled) {
      if (timer.delay === 2000) {
        timer.callback();
      }
    }
    for (let index = 0; index < 24; index += 1) {
      await Promise.resolve();
    }
    assert.ok(settingsRequests >= 3);
    assert.ok(Array.from(timers.values()).some((timer) => timer.delay >= 4000));
  } finally {
    for (const [name, value] of Object.entries(previousGlobals)) {
      if (value === undefined) {
        delete globalThis[name];
      } else {
        globalThis[name] = value;
      }
    }
  }
}

async function testAutomationCompositeRetainsPriorStateAndBacksOffForTradesFailures() {
  const previousGlobals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const timers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#automations" },
    addEventListener() {},
    clearTimeout(id) {
      timers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      timers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("trades-dependency-retention-token", storage);
  let automationRequests = 0;
  let tradesRequests = 0;
  const tradesFailures = ["source_locked", "schema_incompatible", "source_corrupt"];

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    const path = String(url).split("?")[0];
    let payload;
    if (path === "/api/bootstrap") {
      payload = {
        readOnly: true,
        listenerState: "inactive",
        messageSource: { available: true, listenerState: "inactive" },
        groups: [],
        counts: { inbox: 0 },
      };
    } else if (path === "/api/automations") {
      automationRequests += 1;
      payload = {
        available: true,
        items: [{ name: automationRequests === 1 ? "RETAINED_TRADES_RULE" : "REPLACEMENT_TRADES_RULE" }],
      };
    } else if (path === "/api/trades") {
      tradesRequests += 1;
      payload = tradesRequests === 1
        ? { available: true, reason: null, items: [{ intentId: "RETAINED_TRADE_INTENT" }] }
        : {
            available: false,
            reason: tradesFailures[Math.min(tradesRequests - 2, tradesFailures.length - 1)],
            items: [],
          };
    } else if (path === "/api/settings/status") {
      payload = { available: true, reason: null, tradingConfigured: true };
    } else {
      throw new Error(`unexpected request ${path}`);
    }
    return { ok: true, status: 200, json: async () => payload };
  };

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("trades-dependency-retention-test", String(Date.now()));
    await import(appUrl.href);
    await flushMicrotasks();
    const appShell = document.getElementById("app-shell");
    assert.ok(appShell.textContent.includes("RETAINED_TRADES_RULE"));
    assert.ok(appShell.textContent.includes("RETAINED_TRADE_INTENT"));

    document.visibilityState = "hidden";
    document.listeners.visibilitychange();
    document.visibilityState = "visible";
    document.listeners.visibilitychange();
    await flushMicrotasks();

    assert.strictEqual(tradesRequests, 2);
    assert.ok(appShell.textContent.includes("RETAINED_TRADES_RULE"));
    assert.ok(appShell.textContent.includes("RETAINED_TRADE_INTENT"));
    assert.ok(!appShell.textContent.includes("REPLACEMENT_TRADES_RULE"));
    assert.ok(!appShell.textContent.includes("暂无最近意图"));
    assert.ok(appShell.textContent.includes("数据源临时锁定"));
    assert.ok(appShell.textContent.includes("保留已有内容后重试"));
    assert.ok(Array.from(timers.values()).some((timer) => timer.delay === 2000));

    for (const expected of [
      { minimumRequests: 3, retryDelay: 4000, reasonLabel: "数据源版本不兼容" },
      { minimumRequests: 4, retryDelay: 8000, reasonLabel: "数据源已损坏" },
    ]) {
      const scheduled = Array.from(timers.values());
      timers.clear();
      for (const timer of scheduled) {
        if (timer.delay === expected.retryDelay / 2 || timer.delay === 2000) {
          timer.callback();
        }
      }
      await flushMicrotasks();
      assert.ok(tradesRequests >= expected.minimumRequests);
      assert.ok(appShell.textContent.includes("RETAINED_TRADE_INTENT"));
      assert.ok(!appShell.textContent.includes("暂无最近意图"));
      assert.ok(appShell.textContent.includes(expected.reasonLabel));
      assert.ok(Array.from(timers.values()).some((timer) => timer.delay >= expected.retryDelay));
    }
  } finally {
    restoreGlobals(previousGlobals);
  }
}

async function testDiagnosticsSupplementalFailuresRetainPriorStateAndBackOff() {
  const previousGlobals = {
    AbortController: globalThis.AbortController,
    clearTimeout: globalThis.clearTimeout,
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    setTimeout: globalThis.setTimeout,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const requestTimers = new Map();
  const appTimers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#diagnostics" },
    addEventListener() {},
    clearTimeout(id) {
      appTimers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      appTimers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("diagnostics-dependency-retention-token", storage);
  let diagnosticsRequests = 0;
  let messageRequests = 0;

  globalThis.AbortController = undefined;
  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    const path = String(url).split("?")[0];
    if (path === "/api/bootstrap") {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          readOnly: true,
          listenerState: "inactive",
          messageSource: { available: true, listenerState: "inactive" },
          groups: [],
          counts: { inbox: 0 },
        }),
      };
    }
    if (path === "/api/diagnostics") {
      diagnosticsRequests += 1;
      return {
        ok: true,
        status: 200,
        json: async () => ({
          available: true,
          listenerState: "inactive",
          sources: {
            messages: { available: true, reason: null },
            workspace: diagnosticsRequests === 1
              ? { available: false, reason: "source_permission_denied" }
              : { available: false, reason: "source_corrupt" },
            configuration: { available: true, reason: null },
          },
          retriableErrors: [],
        }),
      };
    }
    if (path === "/api/messages") {
      messageRequests += 1;
      if (messageRequests === 1) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            items: [{ observedAt: "2026-09-03T01:02:03Z" }],
            latestCursor: "diagnostics-old",
            nextBefore: null,
          }),
        };
      }
      if (messageRequests === 2) {
        return new Promise(() => {});
      }
      return {
        ok: false,
        status: 503,
        json: async () => ({
          error: "message_source_unavailable",
          reason: "source_locked",
        }),
      };
    }
    throw new Error(`unexpected request ${path}`);
  };
  globalThis.setTimeout = (callback, delay) => {
    const id = nextTimer;
    nextTimer += 1;
    requestTimers.set(id, { callback, delay });
    return id;
  };
  globalThis.clearTimeout = (id) => requestTimers.delete(id);

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("diagnostics-dependency-retention-test", String(Date.now()));
    await import(appUrl.href);
    await flushMicrotasks();
    const appShell = document.getElementById("app-shell");
    assert.strictEqual(messageRequests, 1);
    assert.ok(appShell.textContent.includes("数据源权限不足"));
    assert.ok(!appShell.textContent.includes("尚无记录"));

    document.visibilityState = "hidden";
    document.listeners.visibilitychange();
    document.visibilityState = "visible";
    document.listeners.visibilitychange();
    await flushMicrotasks();
    assert.strictEqual(messageRequests, 2);
    assert.ok(requestTimers.size > 0, "the hung supplemental request must have a finite timeout");
    for (const timer of Array.from(requestTimers.values())) {
      timer.callback();
    }
    await flushMicrotasks(48);

    assert.ok(!appShell.textContent.includes("数据源权限不足"));
    assert.ok(appShell.textContent.includes("数据源已损坏"));
    assert.ok(!appShell.textContent.includes("尚无记录"));
    assert.ok(appShell.textContent.includes("请求超时"));
    assert.ok(appShell.textContent.includes("保留已有内容后重试"));
    assert.ok(Array.from(appTimers.values()).some((timer) => timer.delay === 2000));

    const scheduled = Array.from(appTimers.values());
    appTimers.clear();
    for (const timer of scheduled) {
      if (timer.delay === 2000) {
        timer.callback();
      }
    }
    await flushMicrotasks(48);
    assert.ok(messageRequests >= 3, "the 503 case must be reached by the bounded retry");
    assert.ok(!appShell.textContent.includes("数据源权限不足"));
    assert.ok(appShell.textContent.includes("数据源已损坏"));
    assert.ok(!appShell.textContent.includes("尚无记录"));
    assert.ok(appShell.textContent.includes("数据源临时锁定"));
    assert.ok(appShell.textContent.includes("依赖数据源暂不可读，保留已有内容后重试"));
    assert.ok(Array.from(appTimers.values()).some((timer) => timer.delay >= 4000));
  } finally {
    restoreGlobals(previousGlobals);
  }
}

async function testDiagnosticsFirstLoadNativeFetchRejectIsUnavailable() {
  const previousGlobals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const timers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#diagnostics" },
    addEventListener() {},
    clearTimeout(id) {
      timers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      timers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("diagnostics-native-reject-token", storage);

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    const path = String(url).split("?")[0];
    if (path === "/api/bootstrap") {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          readOnly: true,
          listenerState: "inactive",
          messageSource: { available: true, listenerState: "inactive" },
          groups: [],
          counts: { inbox: 0 },
        }),
      };
    }
    if (path === "/api/diagnostics") {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          available: true,
          listenerState: "inactive",
          sources: {
            messages: { available: true, reason: null },
            workspace: { available: false, reason: "source_corrupt" },
            configuration: { available: true, reason: null },
          },
          retriableErrors: [],
        }),
      };
    }
    if (path === "/api/messages") {
      throw new TypeError("Failed to fetch");
    }
    throw new Error(`unexpected request ${path}`);
  };

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("diagnostics-native-reject-test", String(Date.now()));
    await import(appUrl.href);
    await flushMicrotasks(48);
    const appShell = document.getElementById("app-shell");
    assert.ok(appShell.textContent.includes("数据源已损坏"));
    assert.ok(appShell.textContent.includes("消息库暂不可读"));
    assert.ok(!appShell.textContent.includes("尚无记录"));
    assert.ok(appShell.textContent.includes("保留已有内容后重试"));
    assert.ok(Array.from(timers.values()).some((timer) => timer.delay === 2000));
  } finally {
    restoreGlobals(previousGlobals);
  }
}

async function testDiagnosticsPrimaryFirstLoadFailuresAreExplicitAndRetry() {
  for (const scenario of [
    { name: "native-reject", label: "网络连接失败", timeout: false },
    { name: "timeout", label: "请求超时", timeout: true },
  ]) {
    const previousGlobals = {
      AbortController: globalThis.AbortController,
      clearTimeout: globalThis.clearTimeout,
      document: globalThis.document,
      fetch: globalThis.fetch,
      sessionStorage: globalThis.sessionStorage,
      setTimeout: globalThis.setTimeout,
      window: globalThis.window,
    };
    const document = new FakeDocument();
    const requestTimers = new Map();
    const appTimers = new Map();
    let nextTimer = 1;
    const window = {
      location: { hash: "#diagnostics" },
      addEventListener() {},
      clearTimeout(id) {
        appTimers.delete(id);
      },
      setTimeout(callback, delay) {
        const id = nextTimer;
        nextTimer += 1;
        appTimers.set(id, { callback, delay });
        return id;
      },
    };
    const storage = new MemoryStorage();
    authenticate(`diagnostics-primary-${scenario.name}-token`, storage);
    let diagnosticsRequests = 0;
    let messageRequests = 0;

    globalThis.AbortController = undefined;
    globalThis.document = document;
    globalThis.window = window;
    globalThis.sessionStorage = storage;
    globalThis.fetch = async (url) => {
      const path = String(url).split("?")[0];
      if (path === "/api/bootstrap") {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            readOnly: true,
            listenerState: "inactive",
            messageSource: { available: true, listenerState: "inactive" },
            groups: [],
            counts: { inbox: 0 },
          }),
        };
      }
      if (path === "/api/diagnostics") {
        diagnosticsRequests += 1;
        if (diagnosticsRequests === 1 || diagnosticsRequests === 3) {
          if (scenario.timeout) {
            return new Promise(() => {});
          }
          throw new TypeError("Failed to fetch primary diagnostics");
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({
            available: true,
            listenerState: "active",
            sources: {
              messages: { available: true, reason: null },
              workspace: { available: false, reason: "source_corrupt" },
              configuration: { available: true, reason: null },
            },
            retriableErrors: [],
          }),
        };
      }
      if (path === "/api/messages") {
        messageRequests += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            items: [{ observedAt: "2026-09-03T01:02:03Z" }],
            latestCursor: "round5-primary-recovery",
            nextBefore: null,
          }),
        };
      }
      throw new Error(`unexpected request ${path}`);
    };
    globalThis.setTimeout = (callback, delay) => {
      const id = nextTimer;
      nextTimer += 1;
      requestTimers.set(id, { callback, delay });
      return id;
    };
    globalThis.clearTimeout = (id) => requestTimers.delete(id);

    const finishPendingRequest = async () => {
      for (const timer of Array.from(requestTimers.values())) {
        timer.callback();
      }
      await flushMicrotasks(48);
    };

    try {
      const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
      appUrl.searchParams.set(
        `diagnostics-primary-${scenario.name}-test`,
        String(Date.now())
      );
      await import(appUrl.href);
      await flushMicrotasks(48);
      if (scenario.timeout) {
        assert.ok(requestTimers.size > 0, "primary diagnostics must have a finite timeout");
        await finishPendingRequest();
      }

      const appShell = document.getElementById("app-shell");
      assert.strictEqual(diagnosticsRequests, 1);
      assert.strictEqual(messageRequests, 0);
      assert.ok(appShell.textContent.includes(scenario.label), appShell.textContent);
      assert.ok(appShell.textContent.includes("最近消息"), appShell.textContent);
      assert.ok(
        !appShell.textContent.includes("当前 Mac 后台尚未生成此类数据"),
        appShell.textContent
      );
      assert.ok(!appShell.textContent.includes("尚无记录"), appShell.textContent);
      const firstRetries = Array.from(appTimers.entries()).filter(
        ([_id, timer]) => timer.delay === 2000
      );
      assert.ok(firstRetries.length > 0, "primary failure must schedule bounded retry");
      const retry = firstRetries[firstRetries.length - 1];
      appTimers.delete(retry[0]);
      retry[1].callback();
      await flushMicrotasks(48);

      assert.strictEqual(diagnosticsRequests, 2);
      assert.strictEqual(messageRequests, 1);
      assert.ok(appShell.textContent.includes("数据源已损坏"));
      assert.ok(!appShell.textContent.includes("尚无记录"));

      document.visibilityState = "hidden";
      document.listeners.visibilitychange();
      document.visibilityState = "visible";
      document.listeners.visibilitychange();
      await flushMicrotasks(48);
      if (scenario.timeout) {
        assert.ok(requestTimers.size > 0, "repeat primary failure must retain finite timeout");
        await finishPendingRequest();
      }

      assert.strictEqual(diagnosticsRequests, 3);
      assert.strictEqual(messageRequests, 1);
      assert.ok(appShell.textContent.includes("数据源已损坏"));
      assert.ok(appShell.textContent.includes(scenario.label));
      assert.ok(!appShell.textContent.includes("尚无记录"));
      assert.ok(appShell.textContent.includes("数据源暂不可读"));
      assert.ok(Array.from(appTimers.values()).some((timer) => timer.delay === 2000));
    } finally {
      restoreGlobals(previousGlobals);
    }
  }
}

function testRetryRetentionConnectionAndListenerPresentationContracts() {
  assert.deepStrictEqual(
    [0, 1, 2, 3, 4, 5].map((attempt) => boundedRetryDelay(attempt)),
    [2000, 4000, 8000, 16000, 30000, 30000]
  );
  assert.strictEqual(isRetriableWorkspaceReason("source_locked"), true);
  for (const reason of [
    "schema_incompatible", "source_permission_denied", "source_corrupt", "source_unavailable",
  ]) {
    assert.strictEqual(isRetriableWorkspaceReason(reason), false);
  }
  const previous = { available: true, items: [{ id: "old" }] };
  assert.strictEqual(
    retainReadOnlyPayload(previous, { available: false, reason: "source_locked", items: [] }),
    previous
  );
  const permanent = { available: false, reason: "source_corrupt", items: [] };
  assert.strictEqual(retainReadOnlyPayload(previous, permanent), permanent);
  assert.strictEqual(isCurrentConnection(4, 5), false);
  assert.strictEqual(isCurrentConnection(5, 5), true);

  const now = Date.parse("2026-09-03T00:00:05.000Z");
  const active = listenerPresentation({
    messageSource: {
      available: true,
      heartbeatAt: "2026-09-03T00:00:00.000Z",
    },
    listenerState: "active",
  }, { now: () => now });
  assert.ok(active.label.includes("活动"));
  const unknown = listenerPresentation({
    messageSource: { available: true },
    listenerState: "unknown",
  });
  assert.ok(unknown.label.includes("状态未知"));
  assert.ok(!unknown.label.includes("活动中"));
  assert.ok(!unknown.detail.includes("Mac 持续采集"));
  const inactive = listenerPresentation({
    messageSource: { available: true },
    listenerState: "inactive",
  });
  assert.ok(inactive.label.includes("未活动"));
}

function testUnavailableMessageBootstrapRetainsGroupsAndCountsAcrossRetries() {
  const previous = {
    readOnly: true,
    listenerState: "active",
    messageSource: {
      available: true,
      listenerState: "active",
      heartbeatAt: "2026-09-03T00:00:00Z",
    },
    groups: [{ name: "旧群", count: 7 }],
    counts: { inbox: 7 },
  };
  const unavailable = {
    readOnly: true,
    listenerState: "unknown",
    messageSource: {
      available: false,
      listenerState: "unknown",
      reason: "source_locked",
    },
    groups: [],
    counts: { inbox: 0 },
  };

  const firstRetry = retainMessageBootstrap(previous, unavailable);
  const secondRetry = retainMessageBootstrap(firstRetry, {
    ...unavailable,
    messageSource: {
      ...unavailable.messageSource,
      reason: "source_unavailable",
    },
  });

  assert.deepStrictEqual(firstRetry.groups, previous.groups);
  assert.deepStrictEqual(firstRetry.counts, previous.counts);
  assert.deepStrictEqual(secondRetry.groups, previous.groups);
  assert.deepStrictEqual(secondRetry.counts, previous.counts);
  assert.strictEqual(secondRetry.messageSource.available, false);
  assert.strictEqual(secondRetry.messageSource.reason, "source_unavailable");
  assert.strictEqual(secondRetry.listenerState, "unknown");
}

function testListenerPresentationRequiresAFreshValidHeartbeat() {
  const now = Date.parse("2026-09-03T00:00:05.000Z");
  const clock = { now: () => now };
  const bootstrap = {
    listenerState: "active",
    messageSource: {
      available: true,
      listenerState: "active",
      heartbeatAt: "2026-09-03T00:00:00.000Z",
    },
  };

  assert.strictEqual(listenerPresentation(bootstrap, clock).active, true);
  for (const heartbeatAt of [
    "2026-09-02T23:59:59.999Z",
    "not-a-timestamp",
    "",
    null,
    undefined,
  ]) {
    const presentation = listenerPresentation({
      ...bootstrap,
      messageSource: { ...bootstrap.messageSource, heartbeatAt },
    }, clock);
    assert.strictEqual(
      presentation.active,
      false,
      `heartbeat ${String(heartbeatAt)} must not be presented as active`
    );
  }
}

class MemoryStorage {
  constructor() {
    this.values = new Map();
  }

  getItem(key) {
    return this.values.has(key) ? this.values.get(key) : null;
  }

  setItem(key, value) {
    this.values.set(key, String(value));
  }

  removeItem(key) {
    this.values.delete(key);
  }
}

async function withTestWatchdog(promise, timeoutMs = 250) {
  let timeoutHandle = null;
  const watchdog = new Promise((_resolve, reject) => {
    timeoutHandle = setTimeout(
      () => reject(new Error("test_watchdog_elapsed")),
      timeoutMs
    );
  });
  try {
    return await Promise.race([promise, watchdog]);
  } finally {
    if (timeoutHandle !== null) {
      clearTimeout(timeoutHandle);
    }
  }
}

async function withNativeWatchdog(promise, nativeSetTimeout, nativeClearTimeout, timeoutMs = 250) {
  let timeoutHandle = null;
  const watchdog = new Promise((_resolve, reject) => {
    timeoutHandle = nativeSetTimeout(
      () => reject(new Error("test_watchdog_elapsed")),
      timeoutMs
    );
  });
  try {
    return await Promise.race([promise, watchdog]);
  } finally {
    if (timeoutHandle !== null) {
      nativeClearTimeout(timeoutHandle);
    }
  }
}

async function flushMicrotasks(count = 24) {
  for (let index = 0; index < count; index += 1) {
    await Promise.resolve();
  }
}

function restoreGlobals(previousGlobals) {
  for (const [name, value] of Object.entries(previousGlobals)) {
    if (value === undefined) {
      delete globalThis[name];
    } else {
      globalThis[name] = value;
    }
  }
}

async function testBootstrapTimeoutReleasesHungRequestsAndAbortsWhenSupported() {
  const storage = new MemoryStorage();
  authenticate("timeout-token", storage);

  await assert.rejects(
    withTestWatchdog(fetchBootstrap({
      storage,
      fetch: () => new Promise(() => {}),
      timeoutMs: 5,
      AbortController: null,
    })),
    (error) => error instanceof ApiError && error.code === "request_timeout"
  );

  let requestOptions = null;
  let controller = null;
  class TrackingAbortController {
    constructor() {
      this.signal = { aborted: false };
      controller = this;
    }

    abort() {
      this.signal.aborted = true;
    }
  }
  await assert.rejects(
    withTestWatchdog(fetchBootstrap({
      storage,
      fetch: (_url, options) => {
        requestOptions = options;
        return new Promise(() => {});
      },
      timeoutMs: 5,
      AbortController: TrackingAbortController,
    })),
    (error) => error instanceof ApiError && error.code === "request_timeout"
  );
  assert.strictEqual(requestOptions.signal, controller.signal);
  assert.strictEqual(controller.signal.aborted, true);
  assert.strictEqual(hasSessionToken(storage), true);
}

async function testEveryProductionApiPathHasFiniteDefaultTimeout() {
  const storage = new MemoryStorage();
  authenticate("default-timeout-token", storage);
  const nativeSetTimeout = globalThis.setTimeout;
  const nativeClearTimeout = globalThis.clearTimeout;
  const paths = Array.from(new Set([
    "/api/bootstrap",
    "/api/messages",
    ...WORKSPACE_PAGES.map((page) => page.endpoint),
    "/api/trades",
    "/api/settings/status",
  ]));

  try {
    for (const withAbortController of [false, true]) {
      for (const path of paths) {
        let observedDelay = null;
        let controller = null;
        class TrackingAbortController {
          constructor() {
            this.signal = { aborted: false };
            controller = this;
          }

          abort() {
            this.signal.aborted = true;
          }
        }
        globalThis.setTimeout = (callback, delay) => {
          observedDelay = delay;
          Promise.resolve().then(callback);
          return 1;
        };
        globalThis.clearTimeout = () => {};
        await assert.rejects(
          withNativeWatchdog(
            requestJson(path, {}, {
              storage,
              fetch: () => new Promise(() => {}),
              AbortController: withAbortController ? TrackingAbortController : null,
            }),
            nativeSetTimeout,
            nativeClearTimeout
          ),
          (error) => error instanceof ApiError && error.code === "request_timeout",
          `${path} must reject through its finite default timeout`
        );
        assert.ok(Number.isFinite(observedDelay) && observedDelay > 0 && observedDelay <= 30000);
        if (withAbortController) {
          assert.strictEqual(controller.signal.aborted, true);
        }
      }
    }
  } finally {
    globalThis.setTimeout = nativeSetTimeout;
    globalThis.clearTimeout = nativeClearTimeout;
  }
}

async function testHungBootstrapReturnsToLoginAfterDefaultTimeout() {
  const previousGlobals = {
    AbortController: globalThis.AbortController,
    clearTimeout: globalThis.clearTimeout,
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    setTimeout: globalThis.setTimeout,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const requestTimers = new Map();
  let nextRequestTimer = 1;
  const window = {
    location: { hash: "#inbox" },
    addEventListener() {},
    clearTimeout() {},
    setTimeout() { return 1; },
  };
  const storage = new MemoryStorage();
  authenticate("hung-bootstrap-token", storage);
  globalThis.AbortController = undefined;
  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = () => new Promise(() => {});
  globalThis.setTimeout = (callback, delay) => {
    const id = nextRequestTimer;
    nextRequestTimer += 1;
    requestTimers.set(id, { callback, delay });
    return id;
  };
  globalThis.clearTimeout = (id) => requestTimers.delete(id);

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("hung-bootstrap-test", String(Date.now()));
    await import(appUrl.href);
    await flushMicrotasks();
    assert.strictEqual(requestTimers.size, 1);
    const timeout = Array.from(requestTimers.values())[0];
    assert.ok(timeout.delay > 0 && timeout.delay <= 30000);
    timeout.callback();
    await flushMicrotasks();
    assert.strictEqual(document.getElementById("login-view").hidden, false);
    assert.strictEqual(document.getElementById("app-shell").hidden, true);
    assert.ok(document.getElementById("login-error").textContent.includes("无法连接"));
  } finally {
    restoreGlobals(previousGlobals);
  }
}

async function testHungMessagesReleaseLoadingAndPollingAfterDefaultTimeout() {
  const previousGlobals = {
    AbortController: globalThis.AbortController,
    clearTimeout: globalThis.clearTimeout,
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    setTimeout: globalThis.setTimeout,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const requestTimers = new Map();
  const appTimers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#inbox" },
    addEventListener() {},
    clearTimeout(id) { appTimers.delete(id); },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      appTimers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("hung-messages-token", storage);
  let messageRequests = 0;
  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    if (String(url).startsWith("/api/bootstrap")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          readOnly: true,
          listenerState: "inactive",
          messageSource: { available: true, listenerState: "inactive" },
          groups: [],
          counts: { inbox: 0 },
        }),
      };
    }
    messageRequests += 1;
    return new Promise(() => {});
  };
  globalThis.setTimeout = (callback, delay) => {
    const id = nextTimer;
    nextTimer += 1;
    requestTimers.set(id, { callback, delay });
    return id;
  };
  globalThis.clearTimeout = (id) => requestTimers.delete(id);

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("hung-messages-test", String(Date.now()));
    await import(appUrl.href);
    await flushMicrotasks();
    assert.strictEqual(messageRequests, 1);
    assert.ok(document.getElementById("app-shell").textContent.includes("正在读取消息"));
    for (const timer of Array.from(requestTimers.values())) {
      timer.callback();
    }
    await flushMicrotasks();
    const appShell = document.getElementById("app-shell");
    assert.ok(!appShell.textContent.includes("正在读取消息"));
    assert.ok(appShell.textContent.includes("刷新失败，保留现有内容"));

    const scheduled = Array.from(appTimers.values());
    appTimers.clear();
    for (const timer of scheduled) {
      if (timer.delay === 2000) {
        timer.callback();
      }
    }
    await flushMicrotasks();
    assert.ok(messageRequests >= 2, "polling must be released for the next message attempt");
    for (const timer of Array.from(requestTimers.values())) {
      timer.callback();
    }
    await flushMicrotasks();
    assert.ok(Array.from(appTimers.values()).some((timer) => timer.delay >= 4000));
  } finally {
    restoreGlobals(previousGlobals);
  }
}

async function testHungWorkspaceReleasesLoadingAndBacksOffAfterDefaultTimeout() {
  const previousGlobals = {
    AbortController: globalThis.AbortController,
    clearTimeout: globalThis.clearTimeout,
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    setTimeout: globalThis.setTimeout,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const requestTimers = new Map();
  const appTimers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#meme" },
    addEventListener() {},
    clearTimeout(id) { appTimers.delete(id); },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      appTimers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("hung-workspace-token", storage);
  let workspaceRequests = 0;
  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    if (String(url).startsWith("/api/bootstrap")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          readOnly: true,
          listenerState: "inactive",
          messageSource: { available: true, listenerState: "inactive" },
          groups: [],
          counts: { inbox: 0 },
        }),
      };
    }
    workspaceRequests += 1;
    return new Promise(() => {});
  };
  globalThis.setTimeout = (callback, delay) => {
    const id = nextTimer;
    nextTimer += 1;
    requestTimers.set(id, { callback, delay });
    return id;
  };
  globalThis.clearTimeout = (id) => requestTimers.delete(id);

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("hung-workspace-test", String(Date.now()));
    await import(appUrl.href);
    await flushMicrotasks();
    assert.strictEqual(workspaceRequests, 1);
    assert.ok(document.getElementById("app-shell").textContent.includes("正在读取 Mac 只读数据"));
    for (const timer of Array.from(requestTimers.values())) {
      timer.callback();
    }
    await flushMicrotasks();
    const appShell = document.getElementById("app-shell");
    assert.ok(!appShell.textContent.includes("正在读取 Mac 只读数据"));
    assert.ok(appShell.textContent.includes("数据源暂不可读"));
    const retries = Array.from(appTimers.values()).filter((timer) => timer.delay === 2000);
    assert.ok(retries.length > 0);
    for (const retry of retries) {
      retry.callback();
    }
    await flushMicrotasks();
    assert.ok(workspaceRequests >= 2, "workspace loading must be released for retry");
  } finally {
    restoreGlobals(previousGlobals);
  }
}

async function testVisibleTabInvalidatesListenerBeforeRenderAndRefresh() {
  const previousGlobals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const windowListeners = {};
  const timers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#inbox" },
    addEventListener(name, listener) {
      windowListeners[name] = listener;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      timers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("visibility-token", storage);
  const heartbeatAt = new Date(Date.now()).toISOString();
  let recovering = false;
  let refreshObservedStaleActive = false;

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    if (
      recovering
      && document.getElementById("app-shell").textContent.includes("监听器活动中")
    ) {
      refreshObservedStaleActive = true;
    }
    const payload = String(url).startsWith("/api/bootstrap")
      ? {
          readOnly: true,
          listenerState: "active",
          messageSource: {
            available: true,
            listenerState: "active",
            heartbeatAt,
          },
          groups: [],
          counts: { inbox: 0 },
        }
      : { items: [], latestCursor: null, nextBefore: null };
    return {
      ok: true,
      status: 200,
      json: async () => payload,
    };
  };

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("visibility-test", String(Date.now()));
    await import(appUrl.href);
    for (let index = 0; index < 12; index += 1) {
      await Promise.resolve();
    }

    const appShell = document.getElementById("app-shell");
    assert.ok(appShell.textContent.includes("监听器活动中"));
    document.visibilityState = "hidden";
    document.listeners.visibilitychange();

    document.visibilityState = "visible";
    recovering = true;
    document.listeners.visibilitychange();
    assert.ok(!appShell.textContent.includes("监听器活动中"));

    const scheduledAfterRecovery = Array.from(timers.values());
    timers.clear();
    for (const timer of scheduledAfterRecovery) {
      timer.callback();
    }
    for (let index = 0; index < 12; index += 1) {
      await Promise.resolve();
    }
    assert.strictEqual(refreshObservedStaleActive, false);
  } finally {
    for (const [name, value] of Object.entries(previousGlobals)) {
      if (value === undefined) {
        delete globalThis[name];
      } else {
        globalThis[name] = value;
      }
    }
  }
}

async function testActiveListenerExpiresThroughALocalPresentationTimer() {
  const previousGlobals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const timers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#inbox" },
    addEventListener() {},
    clearTimeout(id) {
      timers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      timers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("local-expiry-token", storage);
  const heartbeatAt = new Date(Date.now()).toISOString();

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => ({
    ok: true,
    status: 200,
    json: async () => String(url).startsWith("/api/bootstrap")
      ? {
          readOnly: true,
          listenerState: "active",
          messageSource: {
            available: true,
            listenerState: "active",
            heartbeatAt,
          },
          groups: [],
          counts: { inbox: 0 },
        }
      : { items: [], latestCursor: null, nextBefore: null },
  });

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("local-expiry-test", String(Date.now()));
    await import(appUrl.href);
    for (let index = 0; index < 16; index += 1) {
      await Promise.resolve();
    }

    const appShell = document.getElementById("app-shell");
    assert.ok(appShell.textContent.includes("监听器活动中"));
    const expiry = Array.from(timers.entries()).find(
      ([_id, timer]) => timer.delay >= 4500 && timer.delay <= 5100
    );
    assert.ok(expiry, "a fresh heartbeat must schedule its local TTL expiry");

    timers.delete(expiry[0]);
    expiry[1].callback();

    assert.ok(!appShell.textContent.includes("监听器活动中"));
    assert.ok(appShell.textContent.includes("监听状态未知"));
  } finally {
    for (const [name, value] of Object.entries(previousGlobals)) {
      if (value === undefined) {
        delete globalThis[name];
      } else {
        globalThis[name] = value;
      }
    }
  }
}

async function testUnavailableBootstrapKeepsVisibleMessagesAndUsesBackoff() {
  const previousGlobals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    sessionStorage: globalThis.sessionStorage,
    window: globalThis.window,
  };
  const document = new FakeDocument();
  const timers = new Map();
  let nextTimer = 1;
  const window = {
    location: { hash: "#inbox" },
    addEventListener() {},
    clearTimeout(id) {
      timers.delete(id);
    },
    setTimeout(callback, delay) {
      const id = nextTimer;
      nextTimer += 1;
      timers.set(id, { callback, delay });
      return id;
    },
  };
  const storage = new MemoryStorage();
  authenticate("retention-token", storage);
  let bootstrapRequests = 0;
  let messageRequests = 0;

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = storage;
  globalThis.fetch = async (url) => {
    if (String(url).startsWith("/api/bootstrap")) {
      bootstrapRequests += 1;
      if (bootstrapRequests === 1) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            readOnly: true,
            listenerState: "active",
            messageSource: {
              available: true,
              listenerState: "active",
              heartbeatAt: new Date(Date.now()).toISOString(),
            },
            groups: [{ name: "保留群", count: 7 }],
            counts: { inbox: 7 },
          }),
        };
      }
      return {
        ok: true,
        status: 200,
        json: async () => ({
          readOnly: true,
          listenerState: "unknown",
          messageSource: {
            available: false,
            listenerState: "unknown",
            reason: "source_locked",
          },
          groups: [],
          counts: { inbox: 0 },
        }),
      };
    }
    messageRequests += 1;
    return {
      ok: true,
      status: 200,
      json: async () => ({
        items: messageRequests === 1
          ? [{
              eventId: "retained-event",
              group: "保留群",
              sender: "保留用户",
              content: "RETAINED_MESSAGE_SENTINEL",
              messageType: "text",
              observedAt: new Date(Date.now()).toISOString(),
              sourceSequence: 1,
            }]
          : [],
        latestCursor: messageRequests === 1 ? "retained-cursor" : null,
        nextBefore: null,
      }),
    };
  };

  try {
    const appUrl = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    appUrl.searchParams.set("retention-test", String(Date.now()));
    await import(appUrl.href);
    for (let index = 0; index < 16; index += 1) {
      await Promise.resolve();
    }

    const appShell = document.getElementById("app-shell");
    assert.ok(appShell.textContent.includes("保留群"));
    assert.ok(appShell.textContent.includes("RETAINED_MESSAGE_SENTINEL"));

    const scheduled = Array.from(timers.values());
    timers.clear();
    for (const timer of scheduled) {
      timer.callback();
    }
    for (let index = 0; index < 24; index += 1) {
      await Promise.resolve();
    }

    assert.ok(bootstrapRequests >= 2);
    assert.ok(appShell.textContent.includes("保留群"));
    assert.ok(appShell.textContent.includes("RETAINED_MESSAGE_SENTINEL"));
    assert.ok(
      descendants(appShell).some(
        (node) => node.className === "nav-badge" && node.textContent === "7"
      )
    );
    assert.ok(appShell.textContent.includes("保留已有内容后退避重试"));
    assert.ok(Array.from(timers.values()).some((timer) => timer.delay >= 4000));
  } finally {
    for (const [name, value] of Object.entries(previousGlobals)) {
      if (value === undefined) {
        delete globalThis[name];
      } else {
        globalThis[name] = value;
      }
    }
  }
}

async function testStaleUnauthorizedRequestCannotClearNewToken() {
  const storage = new MemoryStorage();
  let resolveOld;
  const oldResponse = new Promise((resolve) => { resolveOld = resolve; });
  authenticate("old-token", storage);
  const pending = requestJson("/api/bootstrap", {}, {
    storage,
    fetch: () => oldResponse,
  });
  authenticate("new-token", storage);
  resolveOld({
    ok: false,
    status: 401,
    json: async () => ({ error: "unauthorized" }),
  });
  await assert.rejects(pending, (error) => error.status === 401);
  assert.strictEqual(hasSessionToken(storage), true);

  await assert.rejects(
    requestJson("/api/bootstrap", {}, {
      storage,
      fetch: async () => ({
        ok: false,
        status: 401,
        json: async () => ({ error: "unauthorized" }),
      }),
    }),
    (error) => error.status === 401
  );
  assert.strictEqual(hasSessionToken(storage), false);
}

async function testApiErrorPreservesCanonicalRedactedSourceReason() {
  const storage = new MemoryStorage();
  authenticate("reason-token", storage);

  await assert.rejects(
    requestJson("/api/messages", {}, {
      storage,
      fetch: async () => ({
        ok: false,
        status: 503,
        json: async () => ({
          error: "message_source_unavailable",
          reason: "source_locked",
        }),
      }),
    }),
    (error) => error instanceof ApiError
      && error.code === "message_source_unavailable"
      && error.reason === "source_locked"
  );
}

async function testClipboardUsesRawHttpFallbackAndManualFallback() {
  const appended = [];
  let selected = "";
  let promptValue = null;
  const document = {
    activeElement: { focus() {} },
    body: {
      appendChild(node) { appended.push(node); },
      removeChild(node) { appended.splice(appended.indexOf(node), 1); },
    },
    createElement() {
      return {
        setAttribute() {},
        focus() {},
        select() { selected = this.value; },
        style: {},
        value: "",
      };
    },
    execCommand(command) { return command === "copy"; },
  };
  assert.strictEqual(
    await copyText("0xraw-http", { document, isSecureContext: false }),
    "execCommand"
  );
  assert.strictEqual(selected, "0xraw-http");
  assert.strictEqual(appended.length, 0);

  document.execCommand = () => false;
  assert.strictEqual(
    await copyText("manual-value", {
      document,
      isSecureContext: false,
      prompt: (_label, value) => { promptValue = value; },
    }),
    "manual"
  );
  assert.strictEqual(promptValue, "manual-value");
}

function testRulesRenderCompleteSafeTask4ConditionAndActionContract() {
  const root = fakeRoot();
  renderRules({
    root,
    payload: {
      available: true,
      items: [{
        name: "Momentum",
        priority: 8,
        isEnabled: true,
        condition: {
          groups: ["安全群"],
          senders: ["阿甲"],
          includeKeywords: ["上涨"],
          excludeKeywords: ["广告"],
          includeKeywordMode: "all",
          regularExpressionCount: 2,
          regularExpressionMode: "any",
          messageTypes: ["text"],
          timeWindows: [{
            startMinuteOfDay: 60,
            endMinuteOfDay: 120,
            weekdays: [2, 4],
            timeZoneIdentifier: "Asia/Shanghai",
          }],
          caseSensitive: false,
        },
        actions: [
          { type: "local_alert", severity: "warning", title: "Safe alert" },
          { type: "enqueue_summary", configurationId: "provider-safe" },
          { type: "invoke_script", scriptId: "script-safe" },
        ],
        regularExpressions: ["NEVER_EXPOSE_REGEX"],
        arguments: ["NEVER_EXPOSE_ARGUMENT"],
      }],
    },
    api: {},
  });
  for (const expected of [
    "排除关键词", "广告", "关键词匹配模式", "all", "正则数量", "2",
    "正则匹配模式", "any", "01:00–02:00", "周2、4", "Asia/Shanghai",
    "warning", "provider-safe", "script-safe",
  ]) {
    assert.ok(root.textContent.includes(expected), expected);
  }
  assert.ok(!root.textContent.includes("NEVER_EXPOSE_REGEX"));
  assert.ok(!root.textContent.includes("NEVER_EXPOSE_ARGUMENT"));
}

function testAutomationsRenderCompleteSafeTask4ScopeAndRiskContract() {
  const root = fakeRoot();
  renderAutomations({
    root,
    payload: {
      available: true,
      configurationStatus: true,
      items: [{
        name: "Paper buy",
        isEnabled: true,
        condition: {
          allowedChains: ["base", "eth"],
          groups: ["安全群"],
          senders: ["阿甲"],
          aggregationWindowSeconds: 600,
          minimumMentions: 2,
          minimumDistinctGroups: 2,
          minimumMarketCapUSD: 500000,
          maximumMarketCapUSD: 20000000,
          minimumLiquidityUSD: 100000,
          minimumHolderCount: 100,
          maximumRugRatio: 0.1,
          requireSecurityData: true,
        },
        actions: [{
          type: "trade",
          inputAmountNative: 0.01,
          maximumSlippagePercent: 12,
          antiMEV: true,
          maximumTradesPerDay: 2,
          tokenCooldownSeconds: 86400,
          protectionOrders: [{
            id: "protection-1",
            kind: "stop_loss",
            triggerPercent: 50,
            sellPercent: 100,
          }],
        }],
      }],
    },
    api: {},
  });
  for (const expected of [
    "允许链", "base、eth", "群聊范围", "安全群", "发送者范围", "阿甲",
    "聚合窗口（秒）", "600", "最低提及数", "最低群数", "最低持有人数",
    "要求安全数据", "投入原生币", "Anti-MEV", "冷却（秒）", "86400",
    "保护单", "protection-1", "stop_loss", "触发 50%", "卖出 100%",
  ]) {
    assert.ok(root.textContent.includes(expected), expected);
  }
}

function testMergeSortsNewestFirstAndDeduplicatesAcrossBatches() {
  const merged = mergeNewMessages(
    [{ eventId: "b", observedAt: "2026-09-02T00:00:02Z" }],
    [
      { eventId: "a", observedAt: "2026-09-02T00:00:01Z" },
      { eventId: "b", observedAt: "2026-09-02T00:00:02Z" },
      { eventId: "c", observedAt: "2026-09-02T00:00:03Z" },
    ]
  );

  assert.deepStrictEqual(
    merged.map((item) => item.eventId),
    ["c", "b", "a"]
  );
}

function testMergeDeduplicatesIncomingBatchAndOrdersEqualTimestampsStably() {
  const merged = mergeNewMessages([], [
    { eventId: "event-b", observedAt: "2026-09-02T00:00:02Z" },
    { eventId: "event-a", observedAt: "2026-09-02T00:00:02Z" },
    { eventId: "event-b", observedAt: "2026-09-02T00:00:02Z" },
  ]);

  assert.deepStrictEqual(
    merged.map((item) => item.eventId),
    ["event-b", "event-a"]
  );
}

function testMergeMatchesServerBinaryOrderForEqualTimestamps() {
  const merged = mergeNewMessages([], [
    { eventId: "Z", observedAt: "2026-09-02T00:00:02Z" },
    { eventId: "a", observedAt: "2026-09-02T00:00:02Z" },
  ]);

  assert.deepStrictEqual(
    merged.map((item) => item.eventId),
    ["a", "Z"]
  );
}

function testRouteDecodesExactGroupName() {
  assert.deepStrictEqual(routeFromHash("#group/%E7%94%B2%E7%BE%A4"), {
    page: "group",
    group: "甲群",
  });
}

function testRouteDecodesEncodedSlashInsideExactGroupName() {
  assert.deepStrictEqual(
    routeFromHash("#group/%E9%A1%B9%E7%9B%AE%2F%E4%BA%A4%E6%98%93%E7%BE%A4"),
    { page: "group", group: "项目/交易群" }
  );
}

function testInvalidRoutesFallBackToInbox() {
  for (const hash of [
    "",
    "#",
    "#unknown",
    "#group",
    "#group/",
    "#group/%E0%A4%A",
    "#group/%E9%A1%B9%E7%9B%AE/%E4%BA%A4%E6%98%93%E7%BE%A4",
  ]) {
    assert.deepStrictEqual(routeFromHash(hash), { page: "inbox" });
  }
}

function testMessagePagesAdvanceOnlyWithOpaqueServerCursor() {
  assert.strictEqual(typeof applyMessagePage, "function");
  const initial = applyMessagePage(
    { messages: [], latestCursor: null, nextBefore: null },
    {
      items: [{ eventId: "a", observedAt: "2026-09-02T00:00:00.123Z" }],
      latestCursor: "exact-microsecond-cursor-a",
      nextBefore: "before-a",
    },
    "replace"
  );
  assert.strictEqual(initial.latestCursor, "exact-microsecond-cursor-a");
  assert.strictEqual(initial.nextBefore, "before-a");

  const older = applyMessagePage(
    initial,
    {
      items: [{ eventId: "old", observedAt: "2026-09-01T23:59:59Z" }],
      latestCursor: "older-page-cursor",
      nextBefore: "before-old",
    },
    "older"
  );
  assert.strictEqual(older.latestCursor, "exact-microsecond-cursor-a");
  assert.strictEqual(older.nextBefore, "before-old");

  const firstIncremental = applyMessagePage(
    older,
    {
      items: Array.from({ length: 100 }, (_unused, index) => ({
        eventId: `batch-one-${index}`,
        observedAt: "2026-09-02T00:00:01Z",
      })),
      latestCursor: "exact-cursor-after-100",
      nextBefore: "ignored-after-before",
    },
    "incremental"
  );
  assert.strictEqual(firstIncremental.latestCursor, "exact-cursor-after-100");
  assert.strictEqual(firstIncremental.nextBefore, "before-old");

  const secondIncremental = applyMessagePage(
    firstIncremental,
    {
      items: Array.from({ length: 105 }, (_unused, index) => ({
        eventId: `batch-two-${index}`,
        observedAt: "2026-09-02T00:00:02Z",
      })),
      latestCursor: "exact-cursor-after-205",
    },
    "incremental"
  );
  assert.strictEqual(secondIncremental.latestCursor, "exact-cursor-after-205");
  assert.strictEqual(secondIncremental.messages.length, 207);

  const legacyEmpty = applyMessagePage(secondIncremental, {}, "incremental");
  assert.strictEqual(legacyEmpty.latestCursor, "exact-cursor-after-205");
  assert.strictEqual(legacyEmpty.nextBefore, "before-old");
  assert.strictEqual(legacyEmpty.receivedCount, 0);
}

function testFirstPollAfterEmptyInitialEstablishesLiveAndOlderCursors() {
  const emptyInitial = applyMessagePage(
    { messages: [], latestCursor: null, nextBefore: null },
    { items: [], latestCursor: null, nextBefore: null },
    "replace"
  );
  const firstPoll = applyMessagePage(
    emptyInitial,
    {
      items: Array.from({ length: 100 }, (_unused, index) => ({
        eventId: `initial-burst-${index}`,
        observedAt: "2026-09-02T00:00:01Z",
      })),
      latestCursor: "initial-burst-latest",
      nextBefore: "initial-burst-oldest",
    },
    "incremental"
  );
  assert.strictEqual(firstPoll.latestCursor, "initial-burst-latest");
  assert.strictEqual(firstPoll.nextBefore, "initial-burst-oldest");

  const nextPoll = applyMessagePage(
    firstPoll,
    {
      items: [{ eventId: "newer", observedAt: "2026-09-02T00:00:02Z" }],
      latestCursor: "newer-latest",
      nextBefore: "must-not-replace-older-entry",
    },
    "incremental"
  );
  assert.strictEqual(nextPoll.latestCursor, "newer-latest");
  assert.strictEqual(nextPoll.nextBefore, "initial-burst-oldest");

  const olderPage = applyMessagePage(
    nextPoll,
    {
      items: [{ eventId: "older", observedAt: "2026-09-01T23:59:59Z" }],
      latestCursor: "older-page-latest",
      nextBefore: "older-page-oldest",
    },
    "older"
  );
  assert.strictEqual(olderPage.latestCursor, "newer-latest");
  assert.strictEqual(olderPage.nextBefore, "older-page-oldest");
}

testWorkspaceRegistryHasExactReadOnlyCoverage();
testUnavailablePagesUseCanonicalCopyAndNeverRenderWriteActions();
testProviderPageDisplaysOnlyNamesBooleansAndFixedMask();
testSourceLinkAcceptsOnlyHttpsAndUsesSafeRelationship();
testPublicSourceHostAllowlistMatchesTheDocumentedContract();
testReadOnlyPageNavigationResolvesOnlyRegisteredHashes();
testPriorityPageIsSeparateReadOnlyRouteWithCanonicalUnavailableCopy();
testAvailablePagesIgnoreSecretsPathsAndWriteControls();
testAlertTabsFilterPendingAndAllRecords();
testMarketChainTabsFilterPersistedRows();
testStaleReadOnlyRequestsCannotReplaceCurrentPage();
testStaleMessageRequestsCannotReportErrorsOnAnotherGenerationOrWorkspace();
testDiagnosticsDoesNotEquateDatabaseReadabilityWithListenerActivity();
testDiagnosticsUsesLatestBootstrapListenerAndMessageSource();
testDiagnosticsRequiresFreshHeartbeatForActiveState();
await testSkippedRecurringAttemptAlwaysReschedules();
testBootstrapFailureInvalidatesOnlyListenerFreshness();
testMessageReloadPreservesVisiblePageUntilReplacementSucceeds();
testUnauthorizedResetAllowsAReplacementLoadAfterReconnect();
testAlertsRenderMatchedSafeSourceMessages();
testMemeRendersPersistedMentionAndDistinctGroupHeat();
testTradingRendersAndCopiesTokenAddress();
testTradingAndAutomationCompositesPreserveSettingsAvailability();
testDiagnosticsSupplementalMessagesDependencyControlsTruthAndRetry();
testDiagnosticsPrimaryFailurePayloadIsExplicitAndRetainsHistory();
testAutomationCompositePreservesUnavailableTradesDependency();
testTradingAndAutomationUiNeverCallUnavailableSettingsUnconfigured();
testRetryRetentionConnectionAndListenerPresentationContracts();
testUnavailableMessageBootstrapRetainsGroupsAndCountsAcrossRetries();
testListenerPresentationRequiresAFreshValidHeartbeat();
testRulesRenderCompleteSafeTask4ConditionAndActionContract();
testAutomationsRenderCompleteSafeTask4ScopeAndRiskContract();
testMergeSortsNewestFirstAndDeduplicatesAcrossBatches();
testMergeDeduplicatesIncomingBatchAndOrdersEqualTimestampsStably();
testMergeMatchesServerBinaryOrderForEqualTimestamps();
testRouteDecodesExactGroupName();
testRouteDecodesEncodedSlashInsideExactGroupName();
testInvalidRoutesFallBackToInbox();
testMessagePagesAdvanceOnlyWithOpaqueServerCursor();
testFirstPollAfterEmptyInitialEstablishesLiveAndOlderCursors();
await testStaleUnauthorizedRequestCannotClearNewToken();
await testApiErrorPreservesCanonicalRedactedSourceReason();
await testBootstrapTimeoutReleasesHungRequestsAndAbortsWhenSupported();
await testEveryProductionApiPathHasFiniteDefaultTimeout();
await testHungBootstrapReturnsToLoginAfterDefaultTimeout();
await testHungMessagesReleaseLoadingAndPollingAfterDefaultTimeout();
await testHungWorkspaceReleasesLoadingAndBacksOffAfterDefaultTimeout();
await testAutomationCompositeRetainsPriorDependencyAndPayloadDuringLock();
await testAutomationCompositeRetainsPriorStateAndBacksOffForTradesFailures();
await testDiagnosticsSupplementalFailuresRetainPriorStateAndBackOff();
await testDiagnosticsFirstLoadNativeFetchRejectIsUnavailable();
await testDiagnosticsPrimaryFirstLoadFailuresAreExplicitAndRetry();
await testClipboardUsesRawHttpFallbackAndManualFallback();
await testVisibleTabInvalidatesListenerBeforeRenderAndRefresh();
await testActiveListenerExpiresThroughALocalPresentationTimer();
await testUnavailableBootstrapKeepsVisibleMessagesAndUsesBackoff();

console.log("PASS: wxFomo LAN frontend state");
