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
  renderAnalyses,
  renderPriority,
  renderRules,
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
  normalizeReadOnlyPayload,
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

  querySelectorAll(selector) {
    if (selector.startsWith("[") && selector.endsWith("]")) {
      return descendants(this).filter(node => node.getAttribute(selector.slice(1, -1)) !== null);
    }
    return descendants(this).filter(node => node.tagName === selector.toUpperCase());
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
      "analyses", "rules", "providers", "diagnostics",
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

function testProviderPageDisplaysOnlyKnownModelConfigurationState() {
  const providerPage = WORKSPACE_PAGES.find((page) => page.id === "providers");
  const root = fakeRoot();
  providerPage.render({
    root,
    payload: {
      available: true,
      aiConfigured: true,
      speechConfigured: false,
      providerNames: ["UNTRUSTED_PROVIDER_NAME"],
      model: "deepseek-v4-flash",
      tradingConfigured: false,
      secret: "NEVER_EXPOSE_THIS",
      credentialRevision: "NEVER_EXPOSE_REVISION",
    },
    api: {},
  });
  assert.ok(root.textContent.includes("deepseek-v4-flash"));
  assert.ok(!root.textContent.includes("MiniMax-M2.7"));
  assert.ok(root.textContent.includes("已配置"));
  assert.ok(!root.textContent.includes("UNTRUSTED_PROVIDER_NAME"));
  assert.ok(!root.textContent.includes("NEVER_EXPOSE_THIS"));
  assert.ok(!root.textContent.includes("NEVER_EXPOSE_REVISION"));
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

function testRuleAnnotationsRenderWithoutWriteControls() {
  const root = fakeRoot();
  renderPriority({
    root,
    payload: { available: true, items: [{
      content: "rug 加仓", group: "甲群", sender: "阿甲",
      observedAt: "2026-09-04T00:00:00Z", tags: ["高风险", "资金信号"],
      priority: 50, severity: "critical",
    }] },
    api: {},
  });
  assert.ok(root.textContent.includes("高风险"));
  assert.ok(root.textContent.includes("优先级 50"));
  assert.strictEqual(descendants(root).filter((node) => node.attributes["data-write-action"]).length, 0);
}

function testAnalysisReportsRenderCadenceWindowsSourcesAndReadOnlyStates() {
  const root = fakeRoot();
  renderAnalyses({
    root,
    payload: { available: true, items: [{
      jobId: "job-1", cadence: "two_hour", state: "credential_required",
      windowStart: "2026-09-04T00:00:00Z", windowEnd: "2026-09-04T02:00:00Z",
      attempt: 1, maximumAttempts: 3, nextAttemptAt: "2026-09-04T02:05:00Z",
      summary: "两小时总结", summarySourceMessageIDs: ["event-a"],
      topics: [{ title: "主题", summary: "主题摘要", sourceMessageIDs: ["event-a"] }],
      findings: [{ category: "risk", epistemicStatus: "fact", text: "风险发现", sourceMessageIDs: ["event-a"] }],
      cryptoAddresses: [{ address: "0xCA", contextSummary: "CA 上下文", epistemicStatus: "inference", sourceMessageIDs: ["event-a"] }],
      crossGroupCA: { sourcesComplete: false, total: 2, items: [{
        address: "0xCA", network: "base", groupNames: ["甲群", "乙群"], groupCount: 2,
        mentionCount: 3, uniqueStatementCount: 2, duplicateCount: 1, speakerCount: 2,
        speakers: ["阿甲", "阿乙"], summary: "CA 上下文", sourceMessageIDs: ["event-a"],
      }, { address: "0xUNKNOWN", network: "unknown", groupCount: 1, mentionCount: 1,
        uniqueStatementCount: 1, duplicateCount: 0, sourceMessageIDs: ["event-a"] }] },
      sourceMessages: [{ eventId: "event-a", group: "甲群", sender: "阿甲", content: "完整来源正文",
        relaySender: "搬运机器人", originalContent: "阿甲: <img src=x onerror=alert(1)>完整来源正文" }],
    }, {
      jobId: "job-2", cadence: "six_hour", state: "retry_wait",
      windowStart: "2026-09-04T00:00:00Z", windowEnd: "2026-09-04T06:00:00Z",
    }, {
      jobId: "job-3", cadence: "daily", state: "succeeded",
      windowStart: "2026-09-03T00:00:00Z", windowEnd: "2026-09-04T00:00:00Z",
    }] },
    api: {},
  });
  for (const expected of [
    "2 小时", "6 小时", "24 小时", "需要配置凭据",
    "主题", "风险发现", "0xCA", "完整来源正文", "查看原文",
    "经 搬运机器人 转发", "阿甲: <img src=x onerror=alert(1)>完整来源正文",
    "跨群 CA", "2 群", "3 条提及", "2 条去重发言", "1 条重复传播", "甲群、乙群",
    "链待确认，暂不跨群合并", "部分原文不可用", "未生成单独的 AI 摘要",
  ]) {
    assert.ok(root.textContent.includes(expected), expected);
  }
  assert.strictEqual(descendants(root).filter((node) => node.attributes["data-write-action"]).length, 0);
  assert.strictEqual(descendants(root).filter((node) => node.tagName === "IMG").length, 0);
  assert.ok(descendants(root).some((node) => node.tagName === "DETAILS"));
}

function testBriefingSwitchesOneReportAtATimeAndKeepsHistorySelection() {
  const root = fakeRoot();
  const viewState = {};
  const report = (jobId, cadence, hour, summary, state = "succeeded") => ({
    jobId, cadence, summary, state,
    windowStart: "2026-09-04T00:00:00Z", windowEnd: `2026-09-04T${hour}:00:00Z`,
  });
  const old = report("older", "two_hour", "02", "较早简报正文");
  const latest = report("latest", "two_hour", "04", "最新简报正文");
  const six = report("six", "six_hour", "06", "六小时简报正文");
  const payload = { available: true, items: [old, six, latest] };
  const draw = () => renderAnalyses({root, payload, api: {}, viewState});
  draw();
  assert.ok(root.textContent.includes("最新简报正文"));
  assert.ok(!root.textContent.includes("较早简报正文"), "old reports must not all expand");
  assert.ok(!root.textContent.includes("六小时简报正文"));
  const cadence = label => descendants(root).find(n => n.tagName === "BUTTON" && n.textContent === label);
  cadence("6 小时").click();
  assert.ok(root.textContent.includes("六小时简报正文"));
  cadence("24 小时").click();
  assert.ok(root.textContent.includes("暂无"));
  assert.ok(!root.textContent.includes("六小时简报正文"), "empty periods must not retain a different period's report");
  cadence("2 小时").click();
  const history = descendants(root).find(n => n.tagName === "SELECT");
  assert.ok(history, "historical reports must remain selectable");
  history.value = "older";
  history.listeners.change({ target: history });
  assert.ok(root.textContent.includes("较早简报正文"));
  payload.items.push(report("newer", "two_hour", "08", "后来生成的正文"));
  draw();
  assert.ok(root.textContent.includes("较早简报正文"), "refresh must keep an explicitly selected report");
  assert.ok(!root.textContent.includes("后来生成的正文"));
  assert.strictEqual(descendants(root).filter(n => n.tagName === "ARTICLE" && n.className.includes("analysis-result")).length, 1);
}

function testStructuredBriefingRendersSixSectionsAndBusinessFallback() {
  const root = fakeRoot();
  const address = `0x${"aB".repeat(20)}`;
  const note = text => ({text, source_message_ids: ["e1"]});
  const report = {
    jobId: "v2", cadence: "two_hour", state: "succeeded", summary: "摘要",
    windowStart: "2026-09-06T00:00:00Z", windowEnd: "2026-09-06T02:00:00Z",
    scope: {groupNames: ["甲群"], frozenCount: 100, analyzedCount: 100, readableCount: 99,
      missingCount: 1, displayedSourceCount: 99, timeZone: "Asia/Shanghai",
      dataCutoff: "2026-09-06T01:59:00Z", completeChatHistory: false},
    sourceMessages: [{eventId: "e1", referenceId: "M0001", group: "甲群", sender: "阿甲",
      observedAt: "2026-09-06T01:00:00Z", content: `阿甲说买入 ${address}`}],
    briefing: {version: 2, kind: "market", quick_read: {focus: note("据甲自述已买入"), news: note("消息待核实"), risk: note("存在分歧")},
      projects: [{name: "Test / TEST / 测试币", chain: "未确认", summary: "据甲自述买入",
        catalysts: "未提供", latest: "乙随后质疑", risks: "质疑并非事实",
        data: [{value: "100", unit: "USD", source: "甲自述", recorded_at: "未提供", kind: "个人预测", source_message_ids: ["e1"]}],
        addresses: [{address, chain: "未确认", source_message_ids: ["e1"]}], source_message_ids: ["e1"]}],
      events: [{event: "<img src=x onerror=alert(1)>", asset: "Test", nature: "推测", impact: "待核实", pending: "缺依据", source_message_ids: ["e1"]}],
      gaps: [note("图片未读取")], business: {progress: [], notices: [], blockers: [], tasks: []}}
  };
  renderAnalyses({root, api: {}, payload: {available: true, items: [report]}});
  for (const text of ["本期范围", "10秒速读", "重点标的与大盘", "消息面与风险", "CA索引", "来源与缺口",
    "实际分析 100 条", "1 条原文", "M0001", "阿甲", "甲群", "采集时间", "Asia/Shanghai", address,
    "个人预测", "USD", "完整群聊", "未进行外部核验"]) {
    assert.ok(root.textContent.includes(text), text);
  }
  assert.ok(root.querySelector(".briefing-columns"));
  assert.strictEqual(descendants(root).filter(n => n.tagName === "IMG").length, 0);
  assert.ok(descendants(root).filter(n => n.className === "briefing-sources").every(n => !n.open));
  report.briefing.kind = "business";
  report.briefing.projects = []; report.briefing.events = [];
  report.briefing.business.tasks = [{...note("补充文档"), owner: "未提供", deadline: "未提供"}];
  renderAnalyses({root, api: {}, payload: {available: true, items: [report]}});
  for (const text of ["关键进展", "重要通知", "风险阻塞", "待办清单", "负责人：未提供", "截止时间：未提供"]) {
    assert.ok(root.textContent.includes(text), text);
  }
  assert.ok(!root.textContent.includes("重点标的与大盘"));
}

function testBriefingKeepsSourcesCollapsedAndUsesChineseRiskLabels() {
  const root = fakeRoot();
  const id = "internal-event-id-that-must-not-clutter-the-report";
  renderAnalyses({ root, api: {}, payload: { available: true, items: [{
    jobId: "safe", cadence: "two_hour", state: "succeeded", summary: "一段总述",
    summarySourceMessageIDs: [id, "missing-event"],
    topics: [{title: "<img src=x onerror=alert(1)>", summary: "话题详情", sourceMessageIDs: [id]}],
    findings: [
      {category: "risk", epistemicStatus: "fact", text: "资金风险", sourceMessageIDs: [id]},
      {category: "disagreement", epistemicStatus: "inference", text: "观点有分歧", sourceMessageIDs: [id]},
      {category: "open_question", epistemicStatus: "uncertain", text: "有待核实", sourceMessageIDs: [id]},
      {category: "key_claim", epistemicStatus: "fact", text: "补充陈述", sourceMessageIDs: [id]},
    ],
    sourceMessages: [{eventId: id, group: "实际群", sender: "实际昵称", content: "可核对的原文"}],
  }] } });
  assert.ok(!root.textContent.includes(id), "internal source IDs must not appear as body copy");
  assert.ok(!root.textContent.includes("missing-event"));
  for (const text of ["本期速览", "重点话题", "风险与分歧", "群内陈述", "推测", "待核实", "实际昵称", "可核对的原文", "原文暂不可用"]) {
    assert.ok(root.textContent.includes(text), text);
  }
  const risks = root.querySelector(".briefing-risks");
  assert.ok(risks.textContent.includes("资金风险") && risks.textContent.includes("观点有分歧"));
  assert.ok(!risks.textContent.includes("补充陈述"));
  assert.strictEqual(descendants(root).filter(n => n.tagName === "IMG").length, 0);
  const disclosures = descendants(root).filter(n => n.tagName === "DETAILS");
  assert.ok(disclosures.length);
  assert.ok(disclosures.every(n => !n.open), "details must start collapsed");
}

function testBriefingDoesNotHideFailedLatestJobBehindAnOlderSuccess() {
  const root = fakeRoot();
  renderAnalyses({root, api: {}, payload: {available: true, items: [{
    jobId: "failure", cadence: "two_hour", state: "failed", windowEnd: "2026-09-04T04:00:00Z",
    attempt: 3, maximumAttempts: 3,
  }, {jobId: "success", cadence: "two_hour", state: "succeeded", summary: "此前成功的总结",
    windowEnd: "2026-09-04T02:00:00Z"}]}});
  assert.ok(root.textContent.includes("执行失败") && root.textContent.includes("此前成功的总结"));
  const history = descendants(root).find(n => n.tagName === "SELECT");
  assert.ok(history);
  history.value = "failure"; history.listeners.change({target: history});
  assert.ok(!root.textContent.includes("此前成功的总结"));
  assert.ok(root.textContent.includes("尚无总结正文"));
}

function testBriefingCollapsesExtraCAsWithoutLosingReferences() {
  const root = fakeRoot();
  const cards = Array.from({length: 6}, (_, index) => ({
    address: `CA-${index}`, network: "solana", groupCount: 2,
    summary: `讨论摘要-${index}`, sourceMessageIDs: [`ca-event-${index}`],
  }));
  renderAnalyses({root, api: {}, payload: {available: true, items: [{
    jobId: "many-ca", cadence: "two_hour", state: "succeeded", summary: "CA 简报",
    crossGroupCA: {items: cards, sourcesComplete: true, total: 6},
    sourceMessages: cards.map((_, index) => ({eventId: `ca-event-${index}`, group: "群", sender: "昵称", content: `原文-${index}`})),
  }]}});
  const panel = root.querySelector(".briefing-ca");
  assert.strictEqual(panel.children.filter(n => n.className === "briefing-ca-card").length, 5);
  const more = panel.querySelector(".briefing-more");
  assert.ok(more && !more.open);
  assert.ok(more.textContent.includes("CA-5") && more.textContent.includes("原文-5"));
}

function testBriefingSelectsShanghaiEndDateWithinThreeDays() {
  const root = fakeRoot();
  const viewState = {};
  const report = (id, end) => ({jobId: id, summary: `正文-${id}`, cadence: "two_hour", state: "succeeded",
    windowStart: "2026-09-02T00:00:00Z", windowEnd: end});
  const payload = {available: true, dateRange: {minDate: "2026-09-04", maxDate: "2026-09-06", timeZone: "Asia/Shanghai", dateBasis: "windowEnd"},
    items: [report("before", "2026-09-03T15:59:59Z"), report("oldest", "2026-09-03T16:00:00Z"),
      report("yesterday", "2026-09-05T15:59:59Z"), report("today", "2026-09-05T16:00:00Z"),
      report("future", "2026-09-06T16:00:00Z")]};
  const draw = () => renderAnalyses({root, payload, api: {}, viewState});
  draw();
  assert.ok(root.textContent.includes("正文-today"));
  assert.ok(!root.textContent.includes("正文-future"));
  const picker = () => descendants(root).find(n => n.tagName === "INPUT" && n.type === "date");
  assert.ok(picker(), "reports must be selectable by calendar date");
  assert.strictEqual(picker().min, "2026-09-04");
  assert.strictEqual(picker().max, "2026-09-06");
  picker().value = "2026-09-05"; picker().listeners.change();
  assert.ok(root.textContent.includes("正文-yesterday"));
  assert.ok(!root.textContent.includes("正文-today"));
  descendants(root).find(n => n.tagName === "BUTTON" && n.textContent === "6 小时").click();
  assert.ok(root.textContent.includes("暂无"));
  assert.strictEqual(picker().value, "2026-09-05");
  descendants(root).find(n => n.tagName === "BUTTON" && n.textContent === "2 小时").click();
  payload.items.push(report("newer", "2026-09-06T10:00:00Z"));
  draw();
  assert.ok(root.textContent.includes("正文-yesterday"), "background refresh must preserve the date filter");
  picker().value = "2026-09-04"; picker().listeners.change();
  assert.ok(root.textContent.includes("正文-oldest"), "date filtering uses window end, not start");
  payload.dateRange = {...payload.dateRange, minDate: "2026-09-05", maxDate: "2026-09-07"};
  draw();
  assert.ok(!root.textContent.includes("正文-oldest"), "expired selections cannot retain reports outside the new window");
  picker().value = "2026-09-02"; picker().listeners.change();
  assert.ok(!root.textContent.includes("正文-before"));
}

function testAnalysisPayloadNormalizesLegacySummarySources() {
  const payload = normalizeReadOnlyPayload("analyses", {
    available: true,
    items: [{ summary: "旧摘要", sourceReferences: ["legacy-event"] }],
  });
  assert.deepStrictEqual(payload.items[0].summarySourceMessageIDs, ["legacy-event"]);
}

function testCAUnresolvedSourcesAreNotReportedAsMissingAI() {
  const root = fakeRoot();
  renderAnalyses({root, api: {}, payload: {available: true, items: [{jobId: "one", summary: "已有报告",
    crossGroupCA: {sourcesComplete: true, total: 1, items: [{address: "0xCA", network: "unknown",
      summaryUnavailableReason: "unresolved_sources", sourceMessageIDs: []}]}}]}});
  assert.ok(root.textContent.includes("引用暂不能唯一关联"));
  assert.ok(!root.textContent.includes("未生成单独的 AI 摘要"));
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
      sources: { messages: { available: true }, analysis: { available: false } },
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
        analysis: { available: false, reason: "source_unavailable" },
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
          analysis: { available: false, reason },
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
      analysis: { available: true, reason: null },
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
  assert.deepStrictEqual(inactive.sources.analysis, { available: true, reason: null });

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
      analysis: { available: true, reason: null },
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

function testDiagnosticsSupplementalMessagesDependencyControlsTruthAndRetry() {
  assert.strictEqual(typeof frontendState.composeDiagnosticsPagePayload, "function");
  const primary = {
    available: true,
    sources: {
      messages: { available: true, reason: null },
      analysis: { available: true, reason: null },
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
      analysis: { available: false, reason: "source_corrupt" },
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
  assert.deepStrictEqual(retainedWithFreshPrimary.sources.analysis, {
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
      analysis: { available: false, reason: "source_corrupt" },
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
            analysis: diagnosticsRequests === 1
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
            analysis: { available: false, reason: "source_corrupt" },
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
              analysis: { available: false, reason: "source_corrupt" },
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
    location: { hash: "#analyses" },
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

async function testSummaryRefreshPreservesOpenSourcesAndLoadsNewReports() {
  const previous = { document: globalThis.document, window: globalThis.window,
    sessionStorage: globalThis.sessionStorage, fetch: globalThis.fetch };
  const doc = new FakeDocument();
  const timers = new Map();
  let timerId = 0;
  let reads = 0;
  let updated = false;
  globalThis.document = doc;
  globalThis.window = { location: { hash: "#analyses" }, addEventListener() {},
    setTimeout(fn, delay) { timers.set(++timerId, { fn, delay }); return timerId; },
    clearTimeout(id) { timers.delete(id); } };
  globalThis.sessionStorage = new MemoryStorage();
  authenticate("offline-summary-refresh", globalThis.sessionStorage);
  globalThis.fetch = async (url) => {
    const bootstrap = String(url).startsWith("/api/bootstrap");
    if (!bootstrap) reads += 1;
    return { ok: true, status: 200, json: async () => bootstrap ? {
      readOnly: true, listenerState: "inactive", messageSource: { available: true, listenerState: "inactive" },
      groups: [], counts: { inbox: 1 },
    } : { available: true, items: [{ jobId: "job-1", cadence: "two_hour", state: "succeeded",
      summary: updated ? "新总结" : "旧总结",
      sourceMessages: [{ eventId: "e1", group: "g", sender: "s", content: "离线原文" }] },
      {jobId: "history", cadence: "six_hour", state: "succeeded", summary: "正在阅读的历史简报"}] } };
  };
  try {
    const url = new URL("../web/wxfomo-lan/app.mjs", import.meta.url);
    url.searchParams.set("summary-refresh-test", String(Date.now()));
    await import(url.href);
    await flushMicrotasks(50);
    const shell = doc.getElementById("app-shell");
    const before = descendants(shell).find(node => node.tagName === "DETAILS");
    before.open = true;
    shell.querySelector(".workspace-page-content").scrollTop = 180;
    const heartbeat = [...timers.entries()].find(([, timer]) => timer.delay === 2000);
    assert.ok(heartbeat);
    timers.delete(heartbeat[0]); heartbeat[1].fn();
    await flushMicrotasks(50);
    assert.strictEqual(descendants(shell).find(node => node.tagName === "DETAILS"), before,
      "heartbeat must not replace summary DOM");
    const refresh = [...timers.entries()].find(([, timer]) => timer.delay > 2000);
    assert.ok(refresh, "successful summary pages must refresh without a tab switch");
    updated = true;
    timers.delete(refresh[0]); refresh[1].fn();
    await flushMicrotasks(50);
    assert.strictEqual(reads, 2);
    assert.ok(shell.textContent.includes("新总结"));
    assert.strictEqual(descendants(shell).find(node => node.tagName === "DETAILS").open, true,
      "new reports must preserve open source disclosures");
    assert.strictEqual(shell.querySelector(".workspace-page-content").scrollTop, 180);
    descendants(shell).find(n => n.tagName === "BUTTON" && n.textContent === "6 小时").click();
    const nextRefresh = [...timers.entries()].find(([, timer]) => timer.delay === 30000);
    updated = false;
    timers.delete(nextRefresh[0]); nextRefresh[1].fn();
    await flushMicrotasks(50);
    assert.ok(shell.textContent.includes("正在阅读的历史简报"), "app rerenders must preserve the selected cadence");
    assert.ok(!shell.textContent.includes("旧总结"));
    doc.visibilityState = "hidden"; doc.listeners.visibilitychange();
    assert.strictEqual(timers.size, 0, "hidden tabs stop polling");
  } finally { restoreGlobals(previous); }
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

async function testInboxRuleBadgesKeepAllTagsAccessibleWithoutWriteControls() {
  const previous = {
    document: globalThis.document,
    window: globalThis.window,
    sessionStorage: globalThis.sessionStorage,
  };
  const document = new FakeDocument();
  globalThis.document = document;
  globalThis.window = {
    location: { hash: "#inbox" },
    addEventListener() {},
    setTimeout() { return 1; },
    clearTimeout() {},
  };
  globalThis.sessionStorage = new MemoryStorage();
  try {
    const { MessageRuleBadges } = await import("../web/wxfomo-lan/app.mjs?rule-badges-test");
    const badges = MessageRuleBadges(document, {
      tags: ["高风险", "资金信号", "合约", "流动性"],
      priority: 50,
      severity: "critical",
    });
    assert.ok(badges.textContent.includes("严重性 严重"));
    assert.ok(badges.textContent.includes("优先级 50"));
    assert.ok(badges.textContent.includes("+1"));
    assert.strictEqual(badges.getAttribute("role"), "group");
    assert.ok(badges.getAttribute("aria-label").includes("高风险、资金信号、合约、流动性"));
    assert.strictEqual(descendants(badges).filter((node) => node.attributes["data-write-action"]).length, 0);
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) {
        delete globalThis[name];
      } else {
        globalThis[name] = value;
      }
    }
  }
}

async function testWorkbenchRuleBadgesKeepOverflowTagsInNamedGroup() {
  const { RuleAnnotationBadges } = await import("../web/wxfomo-lan/pages.mjs?workbench-rule-badges-test");
  const badges = RuleAnnotationBadges(fakeRoot().ownerDocument, {
    tags: ["高风险", "资金信号", "合约", "流动性"],
    priority: 50,
    severity: "critical",
  });
  assert.ok(badges.textContent.includes("+1"));
  assert.strictEqual(badges.getAttribute("role"), "group");
  assert.ok(badges.getAttribute("aria-label").includes("高风险、资金信号、合约、流动性"));
  assert.strictEqual(descendants(badges).filter((node) => node.attributes["data-write-action"]).length, 0);
}

testWorkspaceRegistryHasExactReadOnlyCoverage();
testUnavailablePagesUseCanonicalCopyAndNeverRenderWriteActions();
testProviderPageDisplaysOnlyKnownModelConfigurationState();
testSourceLinkAcceptsOnlyHttpsAndUsesSafeRelationship();
testPublicSourceHostAllowlistMatchesTheDocumentedContract();
testReadOnlyPageNavigationResolvesOnlyRegisteredHashes();
testPriorityPageIsSeparateReadOnlyRouteWithCanonicalUnavailableCopy();
testRuleAnnotationsRenderWithoutWriteControls();
testBriefingSwitchesOneReportAtATimeAndKeepsHistorySelection();
testBriefingKeepsSourcesCollapsedAndUsesChineseRiskLabels();
testStructuredBriefingRendersSixSectionsAndBusinessFallback();
testBriefingDoesNotHideFailedLatestJobBehindAnOlderSuccess();
testBriefingCollapsesExtraCAsWithoutLosingReferences();
testBriefingSelectsShanghaiEndDateWithinThreeDays();
testAnalysisReportsRenderCadenceWindowsSourcesAndReadOnlyStates();
testAnalysisPayloadNormalizesLegacySummarySources();
testCAUnresolvedSourcesAreNotReportedAsMissingAI();
testAvailablePagesIgnoreSecretsPathsAndWriteControls();
testAlertTabsFilterPendingAndAllRecords();
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
testDiagnosticsSupplementalMessagesDependencyControlsTruthAndRetry();
testDiagnosticsPrimaryFailurePayloadIsExplicitAndRetainsHistory();
testRetryRetentionConnectionAndListenerPresentationContracts();
testUnavailableMessageBootstrapRetainsGroupsAndCountsAcrossRetries();
testListenerPresentationRequiresAFreshValidHeartbeat();
testRulesRenderCompleteSafeTask4ConditionAndActionContract();
testMergeSortsNewestFirstAndDeduplicatesAcrossBatches();
testMergeDeduplicatesIncomingBatchAndOrdersEqualTimestampsStably();
testMergeMatchesServerBinaryOrderForEqualTimestamps();
testRouteDecodesExactGroupName();
testRouteDecodesEncodedSlashInsideExactGroupName();
testInvalidRoutesFallBackToInbox();
testMessagePagesAdvanceOnlyWithOpaqueServerCursor();
testFirstPollAfterEmptyInitialEstablishesLiveAndOlderCursors();
await testInboxRuleBadgesKeepAllTagsAccessibleWithoutWriteControls();
await testWorkbenchRuleBadgesKeepOverflowTagsInNamedGroup();
await testStaleUnauthorizedRequestCannotClearNewToken();
await testApiErrorPreservesCanonicalRedactedSourceReason();
await testBootstrapTimeoutReleasesHungRequestsAndAbortsWhenSupported();
await testEveryProductionApiPathHasFiniteDefaultTimeout();
await testHungBootstrapReturnsToLoginAfterDefaultTimeout();
await testHungMessagesReleaseLoadingAndPollingAfterDefaultTimeout();
await testHungWorkspaceReleasesLoadingAndBacksOffAfterDefaultTimeout();
await testDiagnosticsSupplementalFailuresRetainPriorStateAndBackOff();
await testDiagnosticsFirstLoadNativeFetchRejectIsUnavailable();
await testDiagnosticsPrimaryFirstLoadFailuresAreExplicitAndRetry();
await testClipboardUsesRawHttpFallbackAndManualFallback();
await testVisibleTabInvalidatesListenerBeforeRenderAndRefresh();
await testSummaryRefreshPreservesOpenSourcesAndLoadsNewReports();
await testActiveListenerExpiresThroughALocalPresentationTimer();
await testUnavailableBootstrapKeepsVisibleMessagesAndUsesBackoff();

console.log("PASS: wxFomo LAN frontend state");
