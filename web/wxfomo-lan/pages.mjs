const UNAVAILABLE_MESSAGE = "当前 Mac 后台尚未生成此类数据";

export const PUBLIC_SOURCE_HOSTS = Object.freeze([
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

const PUBLIC_SOURCE_HOST_SET = new Set(PUBLIC_SOURCE_HOSTS);

const dateFormatter = new Intl.DateTimeFormat("zh-CN", {
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

function element(document, tagName, className, text) {
  const node = document.createElement(tagName);
  if (className) {
    node.className = className;
  }
  if (text !== undefined && text !== null) {
    node.textContent = String(text);
  }
  return node;
}

function items(payload) {
  return payload && Array.isArray(payload.items) ? payload.items : [];
}

function object(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function booleanLabel(value) {
  return value === true ? "已配置" : "未配置";
}

function statusKind(value) {
  if (["critical", "failed", "rejected", "cancelled", "unprotected_position"].includes(value)) {
    return "danger";
  }
  if (["warning", "retry_wait", "pending", "running", "detected"].includes(value)) {
    return "warning";
  }
  if (["succeeded", "confirmed", "eligible", "simulated", "watching"].includes(value)) {
    return "ready";
  }
  return "neutral";
}

function formatDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "时间未知" : dateFormatter.format(date);
}

function formatMoney(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return "—";
  }
  return new Intl.NumberFormat("zh-CN", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: value < 1 ? 6 : 2,
  }).format(value);
}

function formatValue(value) {
  if (value === true) {
    return "是";
  }
  if (value === false) {
    return "否";
  }
  if (Array.isArray(value)) {
    return value.map((item) => String(item)).join("、") || "—";
  }
  if (value === undefined || value === null || value === "") {
    return "—";
  }
  return String(value);
}

function cleanup() {}

export function WorkspacePage(document, title, subtitle) {
  const page = element(document, "section", "workspace-page");
  const header = element(document, "header", "workspace-page-header");
  const heading = element(document, "div", "workspace-page-heading");
  heading.appendChild(element(document, "h1", "page-title", title));
  heading.appendChild(element(document, "p", "page-subtitle", subtitle));
  header.appendChild(heading);
  header.appendChild(StatusPill(document, "浏览器只读", "ready"));
  page.appendChild(header);
  const content = element(document, "div", "workspace-page-content");
  page.appendChild(content);
  return { node: page, content };
}

export function MetricCard(document, label, value, detail) {
  const card = element(document, "article", "metric-card");
  card.appendChild(element(document, "p", "metric-label", label));
  card.appendChild(element(document, "p", "metric-value", formatValue(value)));
  if (detail) {
    card.appendChild(element(document, "p", "metric-detail", detail));
  }
  return card;
}

export function StatusPill(document, label, kind) {
  return element(document, "span", `status-pill ${kind || "neutral"}`, label);
}

export function EmptyState(document, message) {
  const wrapper = element(document, "div", "workspace-empty-state");
  wrapper.appendChild(element(document, "p", "empty-state-title", message || UNAVAILABLE_MESSAGE));
  return wrapper;
}

export function ReadonlyControl(document, label, value) {
  const row = element(document, "div", "readonly-control");
  row.setAttribute("data-readonly-control", "true");
  row.appendChild(element(document, "span", "readonly-control-label", label));
  row.appendChild(element(document, "span", "readonly-control-value", formatValue(value)));
  return row;
}

export function publicSourceURL(href) {
  let url;
  try {
    url = new URL(String(href));
  } catch (_error) {
    return null;
  }
  if (url.search || url.hash) {
    return null;
  }
  const hostname = url.hostname.toLowerCase();
  let credentialTail;
  try {
    credentialTail = decodeURIComponent(
      `${url.pathname}?${url.searchParams.toString()}#${url.hash}`
    ).toLowerCase();
  } catch (_error) {
    return null;
  }
  const credentialMarkers = [
    "authorization", "bearer-", "api_key", "apikey", "access_token", "password",
    "passwd", "secret=", "session=", "signature=",
  ];
  if (
    url.protocol !== "https:"
    || url.port && url.port !== "443"
    || url.username
    || url.password
    || !PUBLIC_SOURCE_HOST_SET.has(hostname)
    || credentialMarkers.some((marker) => credentialTail.includes(marker))
  ) {
    return null;
  }
  return url;
}

export function SourceLink(document, label, href) {
  const url = publicSourceURL(href);
  if (!url) {
    return element(document, "span", "source-link unavailable", label);
  }
  const link = element(document, "a", "source-link", label);
  link.setAttribute("href", url.href);
  link.setAttribute("target", "_blank");
  link.setAttribute("rel", "noopener noreferrer");
  return link;
}

function CopyControl(document, label, value, api) {
  const button = element(document, "button", "copy-control", label);
  button.type = "button";
  button.setAttribute("data-local-copy", "true");
  button.addEventListener("click", async () => {
    const copy = api && typeof api.copyText === "function" ? api.copyText : null;
    if (!copy) {
      return;
    }
    const result = await copy(String(value));
    button.textContent = ["clipboard", "execCommand"].includes(result) || result === undefined
      ? "已复制"
      : "请手动复制";
  });
  return button;
}

function AddressControl(document, address, api) {
  const wrapper = element(document, "div", "address-control");
  wrapper.appendChild(element(document, "code", "address-value", address));
  wrapper.appendChild(CopyControl(document, "复制地址", address, api));
  return wrapper;
}

export function sourceReasonLabel(reason) {
  const labels = {
    source_locked: "数据源临时锁定",
    schema_incompatible: "数据源版本不兼容",
    source_permission_denied: "数据源权限不足",
    source_corrupt: "数据源已损坏",
    source_unavailable: "数据源尚未生成",
    request_timeout: "请求超时",
    network_error: "网络连接失败",
    message_source_unavailable: "消息库暂不可读",
  };
  return labels[reason] || "数据源不可用";
}

export function JsonFindingList(document, findings) {
  const list = element(document, "ul", "finding-list");
  for (const finding of Array.isArray(findings) ? findings : []) {
    const safeFinding = object(finding);
    const item = element(document, "li", "finding-item");
    const meta = element(document, "div", "finding-meta");
    if (safeFinding.category) {
      meta.appendChild(StatusPill(document, safeFinding.category, statusKind(safeFinding.category)));
    }
    if (safeFinding.epistemicStatus) {
      meta.appendChild(element(document, "span", "finding-state", safeFinding.epistemicStatus));
    }
    item.appendChild(meta);
    item.appendChild(element(document, "p", "finding-text", safeFinding.text || "未提供结论正文"));
    if (Array.isArray(safeFinding.sourceReferences) && safeFinding.sourceReferences.length) {
      item.appendChild(
        element(document, "p", "source-reference", `来源 ${safeFinding.sourceReferences.join(" · ")}`)
      );
    }
    list.appendChild(item);
  }
  return list;
}

function begin(root, title, subtitle, payload) {
  const document = root.ownerDocument;
  root.replaceChildren();
  const page = WorkspacePage(document, title, subtitle);
  root.appendChild(page.node);
  if (!payload || payload.available === false) {
    page.content.appendChild(EmptyState(document, UNAVAILABLE_MESSAGE));
    if (payload && payload.reason) {
      page.content.appendChild(
        element(document, "p", "workspace-source-reason", sourceReasonLabel(payload.reason))
      );
    }
    return { document, content: page.content, unavailable: true };
  }
  return { document, content: page.content, unavailable: false };
}

function section(document, title, copy) {
  const wrapper = element(document, "section", "workspace-section");
  wrapper.appendChild(element(document, "h2", "workspace-section-title", title));
  if (copy) {
    wrapper.appendChild(element(document, "p", "workspace-section-copy", copy));
  }
  return wrapper;
}

function keyValueGrid(document, values) {
  const grid = element(document, "dl", "key-value-grid");
  for (const value of values) {
    const pair = element(document, "div", "key-value-pair");
    pair.appendChild(element(document, "dt", "key-value-label", value[0]));
    pair.appendChild(element(document, "dd", "key-value-value", formatValue(value[1])));
    grid.appendChild(pair);
  }
  return grid;
}

function appendEmptyIfNeeded(document, content, collection, copy) {
  if (!collection.length) {
    content.appendChild(EmptyState(document, copy || "暂无记录"));
    return true;
  }
  return false;
}

export function renderAlerts({ root, payload, api }) {
  void api;
  const page = begin(root, "提醒中心", "规则命中与跨群地址出现的待处理信息", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const allItems = items(payload);
  const toolbar = element(document, "div", "workspace-toolbar");
  const pending = allItems.filter((item) => !item.acknowledgedAt);
  const tabs = element(document, "div", "readonly-tabs");
  const tabButtons = [];
  const listHost = element(document, "div", "record-list-host");

  function draw(filter) {
    const collection = filter === "pending" ? pending : allItems;
    listHost.replaceChildren();
    for (const entry of tabButtons) {
      entry.button.className = entry.filter === filter ? "readonly-tab active" : "readonly-tab";
    }
    if (!collection.length) {
      listHost.appendChild(EmptyState(document, filter === "pending" ? "没有待处理提醒" : "还没有提醒"));
      return;
    }
    const list = element(document, "ol", "record-list alert-list");
    for (const item of collection) {
      const card = element(document, "li", "record-card alert-card");
      const header = element(document, "div", "record-card-header");
      header.appendChild(StatusPill(document, item.severity || "information", statusKind(item.severity)));
      header.appendChild(element(document, "h2", "record-title", item.title || "未命名提醒"));
      header.appendChild(element(document, "time", "record-time", formatDate(item.updatedAt)));
      card.appendChild(header);
      if (item.body) {
        card.appendChild(element(document, "p", "record-body", item.body));
      }
      card.appendChild(
        keyValueGrid(document, [
          ["出现次数", item.occurrenceCount],
          ["规则", item.ruleId],
          ["状态", item.acknowledgedAt ? "已确认" : "待处理"],
        ])
      );
      if (Array.isArray(item.sourceEventIds) && item.sourceEventIds.length) {
        card.appendChild(
          element(document, "p", "source-reference", `来源消息 ${item.sourceEventIds.join(" · ")}`)
        );
      }
      const context = object(item.tokenContext);
      if (context.address) {
        card.appendChild(
          keyValueGrid(document, [
            ["地址上下文", `${formatValue(context.network || context.family)} · ${context.address}`],
            ["跨群热度", `${formatValue(context.mentionCount)} 次提及 · ${Array.isArray(context.groupNames) ? context.groupNames.length : 0} 个群`],
            ["出现群聊", context.groupNames],
          ])
        );
        card.appendChild(AddressControl(document, context.address, api));
      }
      if (Array.isArray(item.sourceMessages) && item.sourceMessages.length) {
        const sources = element(document, "ol", "source-message-list");
        for (const message of item.sourceMessages) {
          const source = element(document, "li", "source-message");
          source.appendChild(
            element(
              document,
              "p",
              "source-message-meta",
              `${formatValue(message.group)} · ${formatValue(message.sender)}`
            )
          );
          source.appendChild(element(document, "p", "source-message-body", message.content));
          if (Array.isArray(message.links) && message.links.length) {
            const links = element(document, "div", "source-links");
            for (const href of message.links) {
              const safeURL = publicSourceURL(href);
              links.appendChild(SourceLink(document, "打开公开来源", href));
              if (safeURL) {
                links.appendChild(
                  element(document, "code", "source-url-value", safeURL.href)
                );
                links.appendChild(
                  CopyControl(document, "复制公开链接", safeURL.href, api)
                );
              }
            }
            source.appendChild(links);
          }
          sources.appendChild(source);
        }
        card.appendChild(sources);
      }
      list.appendChild(card);
    }
    listHost.appendChild(list);
  }

  for (const tab of [["待处理", pending.length, "pending"], ["全部", allItems.length, "all"]]) {
    const button = element(document, "button", "readonly-tab", `${tab[0]} ${tab[1]}`);
    button.type = "button";
    button.setAttribute("data-readonly-filter", tab[0]);
    button.addEventListener("click", () => draw(tab[2]));
    tabButtons.push({ button, filter: tab[2] });
    tabs.appendChild(button);
  }
  toolbar.appendChild(tabs);
  page.content.appendChild(toolbar);
  page.content.appendChild(listHost);
  draw("pending");
  return cleanup;
}

export function renderAnalyses({ root, payload, api }) {
  void api;
  const page = begin(root, "分析记录", "已生成任务、总结与可追溯来源", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const collection = items(payload);
  if (appendEmptyIfNeeded(document, page.content, collection, "还没有分析记录")) {
    return cleanup;
  }
  const split = element(document, "div", "analysis-layout");
  const jobs = section(document, "任务", `${collection.length} 条只读记录`);
  const jobList = element(document, "ol", "analysis-job-list");
  for (const item of collection) {
    const job = element(document, "li", "analysis-job");
    job.appendChild(StatusPill(document, item.state || "unknown", statusKind(item.state)));
    job.appendChild(element(document, "p", "analysis-job-mode", item.mode || "分析任务"));
    job.appendChild(
      element(document, "p", "analysis-job-meta", `尝试 ${formatValue(item.attempt)}/${formatValue(item.maximumAttempts)}`)
    );
    job.appendChild(element(document, "time", "record-time", formatDate(item.updatedAt)));
    jobList.appendChild(job);
  }
  jobs.appendChild(jobList);
  split.appendChild(jobs);

  const details = section(document, "分析结果", "摘要、主题、发现与来源引用");
  for (const item of collection) {
    if (!item.summary && !Array.isArray(item.topics) && !Array.isArray(item.findings)) {
      continue;
    }
    const result = element(document, "article", "analysis-result");
    result.appendChild(element(document, "h3", "record-title", item.summary || item.mode || "分析结果"));
    if (item.summary) {
      result.appendChild(element(document, "p", "record-body", item.summary));
    }
    for (const topic of Array.isArray(item.topics) ? item.topics : []) {
      const topicCard = element(document, "section", "topic-card");
      topicCard.appendChild(element(document, "h4", "topic-title", topic.title || "主题"));
      if (topic.summary) {
        topicCard.appendChild(element(document, "p", "record-body", topic.summary));
      }
      if (Array.isArray(topic.sourceReferences) && topic.sourceReferences.length) {
        topicCard.appendChild(
          element(document, "p", "source-reference", `来源 ${topic.sourceReferences.join(" · ")}`)
        );
      }
      result.appendChild(topicCard);
    }
    if (Array.isArray(item.findings) && item.findings.length) {
      result.appendChild(JsonFindingList(document, item.findings));
    }
    if (Array.isArray(item.sourceReferences) && item.sourceReferences.length) {
      result.appendChild(
        element(document, "p", "source-reference", `总结来源 ${item.sourceReferences.join(" · ")}`)
      );
    }
    details.appendChild(result);
  }
  split.appendChild(details);
  page.content.appendChild(split);
  return cleanup;
}

export function renderMeme({ root, payload, api }) {
  const page = begin(root, "Meme 观察", "观察池中的跨群信号与已记录链上行情", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const collection = items(payload);
  if (appendEmptyIfNeeded(document, page.content, collection, "观察池暂无记录")) {
    return cleanup;
  }
  const grid = element(document, "div", "watch-grid");
  for (const item of collection) {
    const card = element(document, "article", "watch-card");
    const header = element(document, "div", "record-card-header");
    header.appendChild(element(document, "h2", "record-title", item.symbol || item.name || "未命名代币"));
    header.appendChild(StatusPill(document, item.network || item.family || "未知网络", "neutral"));
    if (item.isPinned) {
      header.appendChild(StatusPill(document, "置顶", "ready"));
    }
    card.appendChild(header);
    if (item.name) {
      card.appendChild(element(document, "p", "record-body", item.name));
    }
    const metrics = element(document, "div", "metric-grid compact");
    metrics.appendChild(MetricCard(document, "价格", formatMoney(item.priceUsd)));
    metrics.appendChild(MetricCard(document, "市值", formatMoney(item.marketCapUsd)));
    metrics.appendChild(MetricCard(document, "流动性", formatMoney(item.liquidityUsd)));
    card.appendChild(metrics);
    card.appendChild(
      keyValueGrid(document, [
        ["群聊热度", `${formatValue(item.mentionCount)} 次提及 · ${Array.isArray(item.groupNames) ? item.groupNames.length : 0} 个群`],
        ["数据窗口", "持久化观察窗口"],
        ["出现群聊", item.groupNames],
        ["最近出现", formatDate(item.latestSeenAt)],
        ["观察状态", item.state],
      ])
    );
    if (item.address) {
      card.appendChild(AddressControl(document, item.address, api));
    }
    grid.appendChild(card);
  }
  page.content.appendChild(grid);
  return cleanup;
}

export function renderMarket({ root, payload, api }) {
  void api;
  const page = begin(root, "市场趋势", "Mac 后台已持久化的多链趋势记录", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const collection = items(payload);
  const tabs = element(document, "div", "workspace-toolbar chain-tabs");
  const chains = ["全部", ...new Set(collection.map((item) => item.network).filter(Boolean))];
  const tabButtons = [];
  const table = element(document, "div", "trend-table");

  function draw(chain) {
    const displayed = chain === "全部"
      ? collection
      : collection.filter((item) => item.network === chain);
    table.replaceChildren();
    for (const entry of tabButtons) {
      entry.button.className = entry.chain === chain ? "readonly-tab active" : "readonly-tab";
    }
    if (!displayed.length) {
      table.appendChild(EmptyState(document, "暂无市场趋势记录"));
      return;
    }
    for (const item of displayed) {
      const row = element(document, "article", "trend-row");
      row.appendChild(element(document, "strong", "trend-symbol", item.symbol || item.name || "—"));
      row.appendChild(StatusPill(document, item.network || "未知网络", "neutral"));
      row.appendChild(element(document, "span", "trend-value", formatMoney(item.priceUsd)));
      row.appendChild(element(document, "span", "trend-value", formatMoney(item.marketCapUsd)));
      row.appendChild(element(document, "span", "trend-value", formatMoney(item.liquidityUsd)));
      row.appendChild(element(document, "time", "record-time", formatDate(item.capturedAt)));
      table.appendChild(row);
    }
  }

  for (const chain of chains) {
    const tab = element(document, "button", "readonly-tab", chain);
    tab.type = "button";
    tab.setAttribute("data-readonly-filter", chain);
    tab.addEventListener("click", () => draw(chain));
    tabButtons.push({ button: tab, chain });
    tabs.appendChild(tab);
  }
  page.content.appendChild(tabs);
  page.content.appendChild(table);
  draw("全部");
  return cleanup;
}

function conditionSummary(document, condition) {
  const safe = object(condition);
  const wrapper = element(document, "div", "condition-summary");
  wrapper.appendChild(keyValueGrid(document, [
    ["群聊", safe.groups],
    ["发送者", safe.senders],
    ["包含关键词", safe.includeKeywords],
    ["排除关键词", safe.excludeKeywords],
    ["关键词匹配模式", safe.includeKeywordMode],
    ["正则数量", safe.regularExpressionCount],
    ["正则匹配模式", safe.regularExpressionMode],
    ["消息类型", safe.messageTypes],
    ["大小写敏感", safe.caseSensitive],
  ]));
  const windows = Array.isArray(safe.timeWindows) ? safe.timeWindows : [];
  if (windows.length) {
    const list = element(document, "ul", "time-window-list");
    for (const rawWindow of windows) {
      const window = object(rawWindow);
      const clock = (minute) => {
        const numeric = Number(minute);
        if (!Number.isFinite(numeric)) {
          return "—";
        }
        const hours = String(Math.floor(numeric / 60)).padStart(2, "0");
        const minutes = String(numeric % 60).padStart(2, "0");
        return `${hours}:${minutes}`;
      };
      list.appendChild(
        element(
          document,
          "li",
          "time-window-item",
          `${clock(window.startMinuteOfDay)}–${clock(window.endMinuteOfDay)} · 周${formatValue(window.weekdays)} · ${formatValue(window.timeZoneIdentifier)}`
        )
      );
    }
    wrapper.appendChild(list);
  }
  return wrapper;
}

function actionSummary(document, actions) {
  const list = element(document, "ul", "action-list");
  for (const action of Array.isArray(actions) ? actions : []) {
    const safe = object(action);
    const item = element(document, "li", "action-item");
    item.appendChild(StatusPill(document, safe.type || "action", "neutral"));
    if (safe.title) {
      item.appendChild(element(document, "span", "action-title", safe.title));
    }
    if (safe.tag) {
      item.appendChild(element(document, "span", "action-title", safe.tag));
    }
    for (const detail of [
      ["级别", safe.severity],
      ["配置", safe.configurationId],
      ["脚本", safe.scriptId],
    ]) {
      if (detail[1] !== undefined && detail[1] !== null && detail[1] !== "") {
        item.appendChild(element(document, "span", "action-title", `${detail[0]} ${detail[1]}`));
      }
    }
    list.appendChild(item);
  }
  return list;
}

export function renderRules({ root, payload, api }) {
  void api;
  const page = begin(root, "监控规则", "确定性筛选、优先级与只读动作摘要", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const collection = items(payload);
  if (appendEmptyIfNeeded(document, page.content, collection, "还没有监控规则")) {
    return cleanup;
  }
  const list = element(document, "div", "record-list");
  for (const item of collection) {
    const card = element(document, "article", "record-card rule-card");
    const header = element(document, "div", "record-card-header");
    header.appendChild(element(document, "h2", "record-title", item.name || item.ruleId || "未命名规则"));
    header.appendChild(StatusPill(document, item.isEnabled ? "已启用" : "已停用", item.isEnabled ? "ready" : "neutral"));
    header.appendChild(StatusPill(document, `优先级 ${formatValue(item.priority)}`, "neutral"));
    card.appendChild(header);
    if (item.description) {
      card.appendChild(element(document, "p", "record-body", item.description));
    }
    card.appendChild(element(document, "h3", "record-subtitle", "条件"));
    card.appendChild(conditionSummary(document, item.condition));
    card.appendChild(element(document, "h3", "record-subtitle", "动作"));
    card.appendChild(actionSummary(document, item.actions));
    list.appendChild(card);
  }
  page.content.appendChild(list);
  return cleanup;
}

export function renderTrading({ root, payload, api }) {
  const page = begin(root, "交易工作台", "钱包安全状态、交易意图与历史记录", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const summary = element(document, "div", "metric-grid");
  const settingsDependency = object(payload.settingsDependency);
  const walletSafeStatus = settingsDependency.available === false
    ? sourceReasonLabel(settingsDependency.reason)
    : payload.walletSafeStatus || "签名材料不会发送到浏览器";
  summary.appendChild(
    MetricCard(document, "钱包安全", walletSafeStatus, "仅显示后台记录状态")
  );
  summary.appendChild(MetricCard(document, "交易记录", items(payload).length));
  page.content.appendChild(summary);
  const collection = items(payload);
  if (appendEmptyIfNeeded(document, page.content, collection, "还没有交易记录")) {
    return cleanup;
  }
  const records = section(document, "交易意图与历史", "只显示 Mac 后台已记录状态");
  for (const item of collection) {
    const card = element(document, "article", "record-card trade-card");
    const header = element(document, "div", "record-card-header");
    header.appendChild(element(document, "h3", "record-title", item.symbol || item.tokenName || item.intentId || "交易意图"));
    header.appendChild(StatusPill(document, item.state || "unknown", statusKind(item.state)));
    header.appendChild(element(document, "time", "record-time", formatDate(item.updatedAt)));
    card.appendChild(header);
    card.appendChild(
      keyValueGrid(document, [
        ["网络", item.network || item.chain],
        ["预计金额", formatMoney(item.estimatedSpendUsd)],
        ["原因", item.reason],
        ["风险比率", object(item.riskSummary).rugRatio],
      ])
    );
    if (item.tokenAddress) {
      card.appendChild(AddressControl(document, item.tokenAddress, api));
    }
    records.appendChild(card);
  }
  page.content.appendChild(records);
  return cleanup;
}

function automationRiskValues(item) {
  const condition = object(item.condition);
  const action = Array.isArray(item.actions) && item.actions.length ? object(item.actions[0]) : {};
  return [
    ["允许链", condition.allowedChains],
    ["群聊范围", condition.groups],
    ["发送者范围", condition.senders],
    ["聚合窗口（秒）", condition.aggregationWindowSeconds],
    ["最低提及数", condition.minimumMentions],
    ["最低群数", condition.minimumDistinctGroups],
    ["最低市值", formatMoney(condition.minimumMarketCapUSD)],
    ["最高市值", formatMoney(condition.maximumMarketCapUSD)],
    ["最低流动性", formatMoney(condition.minimumLiquidityUSD)],
    ["最低持有人数", condition.minimumHolderCount],
    ["最大风险比", condition.maximumRugRatio],
    ["要求安全数据", condition.requireSecurityData],
    ["投入原生币", action.inputAmountNative],
    ["Anti-MEV", action.antiMEV],
    ["每日上限", action.maximumTradesPerDay],
    ["最大滑点", action.maximumSlippagePercent],
    ["冷却（秒）", action.tokenCooldownSeconds],
  ];
}

export function renderAutomations({ root, payload, api }) {
  void api;
  const page = begin(root, "自动化交易", "配置状态、规则、风控与最近意图状态", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const settingsDependency = object(payload.settingsDependency);
  const configurationStatus = settingsDependency.available === false
    ? sourceReasonLabel(settingsDependency.reason)
    : payload.configurationStatus === true
      ? "已配置"
      : "未配置";
  page.content.appendChild(
    MetricCard(
      document,
      "自动化配置",
      configurationStatus,
      "浏览器不会执行规则或模拟交易"
    )
  );
  const collection = items(payload);
  const rules = section(document, "规则与风控", `${collection.length} 条只读规则`);
  if (!collection.length) {
    rules.appendChild(EmptyState(document, "还没有自动化规则"));
  }
  for (const item of collection) {
    const card = element(document, "article", "record-card automation-card");
    const header = element(document, "div", "record-card-header");
    header.appendChild(element(document, "h3", "record-title", item.name || item.ruleId || "自动化规则"));
    header.appendChild(StatusPill(document, item.isEnabled ? "已启用" : "已停用", item.isEnabled ? "ready" : "neutral"));
    card.appendChild(header);
    card.appendChild(keyValueGrid(document, automationRiskValues(item)));
    const action = Array.isArray(item.actions) && item.actions.length ? object(item.actions[0]) : {};
    const orders = Array.isArray(action.protectionOrders) ? action.protectionOrders : [];
    if (orders.length) {
      card.appendChild(element(document, "h4", "record-subtitle", "保护单"));
      const orderList = element(document, "ul", "action-list");
      for (const rawOrder of orders) {
        const order = object(rawOrder);
        orderList.appendChild(
          element(
            document,
            "li",
            "action-item",
            `${formatValue(order.id)} · ${formatValue(order.kind)} · 触发 ${formatValue(order.triggerPercent)}% · 卖出 ${formatValue(order.sellPercent)}%`
          )
        );
      }
      card.appendChild(orderList);
    }
    rules.appendChild(card);
  }
  page.content.appendChild(rules);
  const recent = section(document, "最近意图状态", "仅展示已落库记录");
  const tradesDependency = object(payload.tradesDependency);
  const recentIntents = Array.isArray(payload.recentIntents) ? payload.recentIntents : [];
  if (tradesDependency.available === false) {
    recent.appendChild(EmptyState(document, sourceReasonLabel(tradesDependency.reason)));
  } else if (!recentIntents.length) {
    recent.appendChild(EmptyState(document, "暂无最近意图"));
  }
  for (const intent of recentIntents.slice(0, 8)) {
    const row = element(document, "div", "intent-row");
    row.appendChild(element(document, "span", "intent-name", intent.symbol || intent.intentId || "交易意图"));
    row.appendChild(StatusPill(document, intent.state || "unknown", statusKind(intent.state)));
    row.appendChild(element(document, "time", "record-time", formatDate(intent.updatedAt)));
    recent.appendChild(row);
  }
  page.content.appendChild(recent);
  return cleanup;
}

export function renderSounds({ root, payload, api }) {
  void api;
  const page = begin(root, "声音与提醒", "仅显示 Mac 后台配置状态", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const grid = element(document, "div", "metric-grid");
  grid.appendChild(MetricCard(document, "语音服务", booleanLabel(payload.speechConfigured)));
  grid.appendChild(MetricCard(document, "AI 摘要服务", booleanLabel(payload.aiConfigured)));
  page.content.appendChild(grid);
  page.content.appendChild(
    ReadonlyControl(document, "声音规则", "请在 Mac wxFomo 中查看和修改")
  );
  return cleanup;
}

export function renderProviders({ root, payload, api }) {
  void api;
  const page = begin(root, "配置中心", "只显示服务名称与配置状态，不传输凭据", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const providers = Array.isArray(payload.providerNames) ? payload.providerNames : [];
  const checklist = section(document, "首次使用检查", "Windows 端只显示布尔结果");
  checklist.appendChild(ReadonlyControl(document, "AI 模型服务", booleanLabel(payload.aiConfigured)));
  checklist.appendChild(ReadonlyControl(document, "语音服务", booleanLabel(payload.speechConfigured)));
  checklist.appendChild(ReadonlyControl(document, "交易服务", booleanLabel(payload.tradingConfigured)));
  page.content.appendChild(checklist);

  const providerSection = section(document, "AI 模型服务", `${providers.length} 个已知显示名称`);
  if (!providers.length) {
    providerSection.appendChild(EmptyState(document, "还没有 AI 模型服务"));
  }
  for (const name of providers) {
    const card = element(document, "article", "provider-card");
    card.appendChild(element(document, "h3", "record-title", name));
    card.appendChild(StatusPill(document, payload.aiConfigured ? "已配置" : "未配置", payload.aiConfigured ? "ready" : "neutral"));
    card.appendChild(ReadonlyControl(document, "API Key", "••••••••"));
    providerSection.appendChild(card);
  }
  page.content.appendChild(providerSection);
  const speech = section(document, "真人语音 / TTS", "仅显示服务是否已配置");
  speech.appendChild(ReadonlyControl(document, "语音 Key", "••••••••"));
  speech.appendChild(StatusPill(document, payload.speechConfigured ? "已配置" : "未配置", payload.speechConfigured ? "ready" : "neutral"));
  page.content.appendChild(speech);
  return cleanup;
}

function sourceStatus(payload, name) {
  const sources = object(payload.sources);
  const source = object(sources[name]);
  return source.available === true ? "可读取" : sourceReasonLabel(source.reason);
}

function safeRetriableErrors(value) {
  const labels = {
    source_locked: "数据源临时锁定",
    source_unavailable: "数据源暂不可用",
    message_source_unavailable: "消息库暂不可读",
  };
  const result = [];
  for (const code of Array.isArray(value) ? value : []) {
    if (Object.prototype.hasOwnProperty.call(labels, code)) {
      result.push(labels[code]);
    }
  }
  return result;
}

function listenerStateLabel(value) {
  if (value === "active") {
    return "活动中";
  }
  if (value === "inactive") {
    return "未活动";
  }
  return "后台未提供运行状态";
}

export function renderDiagnostics({ root, payload, api }) {
  void api;
  const page = begin(root, "运行诊断", "采集链路、存储与已知覆盖边界", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const rows = section(document, "只读数据源", "不会显示完整本地路径");
  rows.appendChild(ReadonlyControl(document, "消息数据库", sourceStatus(payload, "messages")));
  rows.appendChild(ReadonlyControl(document, "工作区数据库（可选）", sourceStatus(payload, "workspace")));
  rows.appendChild(ReadonlyControl(document, "配置摘要", sourceStatus(payload, "configuration")));
  rows.appendChild(ReadonlyControl(document, "监听活动", listenerStateLabel(payload.listenerState)));
  const messagesDependency = object(payload.messagesDependency);
  const lastMessageStatus = messagesDependency.available === false
    ? sourceReasonLabel(messagesDependency.reason)
    : payload.lastMessageAt
      ? formatDate(payload.lastMessageAt)
      : "尚无记录";
  rows.appendChild(ReadonlyControl(document, "最近消息", lastMessageStatus));
  rows.appendChild(ReadonlyControl(document, "API 模式", "GET / HEAD 只读"));
  page.content.appendChild(rows);

  const errors = safeRetriableErrors(payload.retriableErrors);
  const errorSection = section(document, "可重试错误", errors.length ? `${errors.length} 项` : "无");
  for (const error of errors) {
    errorSection.appendChild(StatusPill(document, error, "warning"));
  }
  page.content.appendChild(errorSection);
  page.content.appendChild(
    element(
      document,
      "p",
      "diagnostic-note",
      "wxFomo 只能展示系统实际投递并成功解码的通知，不能推导企业微信群消息完整率。"
    )
  );
  return cleanup;
}

export function renderPriority({ root, payload, api }) {
  void api;
  const page = begin(root, "重点捕捉", "已标记的重点消息只读列表", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const collection = items(payload);
  if (appendEmptyIfNeeded(document, page.content, collection, "还没有重点消息")) {
    return cleanup;
  }
  const list = element(document, "ol", "record-list priority-list");
  for (const item of collection) {
    const card = element(document, "li", "record-card priority-card");
    card.appendChild(element(document, "h2", "record-title", item.content || "重点消息"));
    card.appendChild(
      keyValueGrid(document, [
        ["群聊", item.group],
        ["发送者", item.sender],
        ["时间", formatDate(item.observedAt)],
      ])
    );
    list.appendChild(card);
  }
  page.content.appendChild(list);
  return cleanup;
}

export const WORKSPACE_PAGES = Object.freeze([
  { id: "meme", label: "Meme 观察", icon: "pulse", endpoint: "/api/meme", render: renderMeme, readOnly: true },
  { id: "market", label: "市场趋势", icon: "chart", endpoint: "/api/market", render: renderMarket, readOnly: true },
  { id: "analyses", label: "分析记录", icon: "analysis", endpoint: "/api/analyses", render: renderAnalyses, readOnly: true },
  { id: "rules", label: "监控规则", icon: "rules", endpoint: "/api/rules", render: renderRules, readOnly: true },
  { id: "trading", label: "交易工作台", icon: "trade", endpoint: "/api/trades", render: renderTrading, readOnly: true },
  { id: "automations", label: "自动化交易", icon: "automation", endpoint: "/api/automations", render: renderAutomations, readOnly: true },
  { id: "sounds", label: "声音与提醒", icon: "sound", endpoint: "/api/settings/status", render: renderSounds, readOnly: true },
  { id: "providers", label: "配置中心", icon: "settings", endpoint: "/api/settings/status", render: renderProviders, readOnly: true },
  { id: "diagnostics", label: "运行诊断", icon: "diagnostics", endpoint: "/api/diagnostics", render: renderDiagnostics, readOnly: true },
]);

export const ALERT_PAGE = Object.freeze({
  id: "alerts",
  label: "提醒中心",
  icon: "bell",
  endpoint: "/api/alerts",
  render: renderAlerts,
  readOnly: true,
});

export const PRIORITY_PAGE = Object.freeze({
  id: "priority",
  label: "重点捕捉",
  icon: "target",
  endpoint: "/api/priority",
  render: renderPriority,
  readOnly: true,
});

export function readOnlyPageFromHash(hash) {
  if (hash === "#alerts") {
    return ALERT_PAGE;
  }
  if (hash === "#priority") {
    return PRIORITY_PAGE;
  }
  for (const page of WORKSPACE_PAGES) {
    if (hash === `#${page.id}`) {
      return page;
    }
  }
  return null;
}

export function isCurrentReadOnlyRequest(
  requestGeneration,
  currentGeneration,
  requestPage,
  currentPage
) {
  return requestGeneration === currentGeneration && requestPage === currentPage;
}

export function isCurrentMessageRequest(
  requestGeneration,
  currentGeneration,
  hasReadOnlyPage
) {
  return requestGeneration === currentGeneration && !hasReadOnlyPage;
}
