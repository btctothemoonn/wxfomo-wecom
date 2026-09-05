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
  timeZone: "Asia/Shanghai",
  year: "numeric",
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

function stringList(value) {
  return Array.isArray(value)
    ? value.filter((item) => typeof item === "string" && item.trim())
    : [];
}

function analysisSourceIDs(value) {
  const current = stringList(value && value.sourceMessageIDs);
  if (current.length) {
    return current;
  }
  return stringList(value && value.sourceReferences);
}

function analysisCadenceLabel(value) {
  return {
    two_hour: "2 小时",
    six_hour: "6 小时",
    daily: "24 小时",
  }[value] || "周期未知";
}

function analysisStateLabel(value) {
  return {
    queued: "等待执行",
    pending: "等待执行",
    running: "正在分析",
    retry_wait: "等待重试",
    credential_required: "需要配置凭据",
    succeeded: "已完成",
    failed: "执行失败",
    cancelled: "已取消",
    skipped_empty: "窗口无消息",
  }[value] || "状态未知";
}

function analysisWindowLabel(item) {
  const start = item && typeof item.windowStart === "string" ? item.windowStart : null;
  const end = item && typeof item.windowEnd === "string" ? item.windowEnd : null;
  if (!start || !end || Number.isNaN(Date.parse(start)) || Number.isNaN(Date.parse(end))) {
    return "窗口未知";
  }
  return `${formatDate(start)} 至 ${formatDate(end)}`;
}

function analysisEndDate(item) {
  const timestamp = Date.parse(item.windowEnd);
  return Number.isFinite(timestamp) ? new Date(timestamp + 8 * 3600000).toISOString().slice(0, 10) : "";
}

function severityLabel(value) {
  return value === "critical" ? "严重" : value === "warning" ? "警告" : "信息";
}

export function RuleAnnotationBadges(document, item) {
  const source = object(item);
  const tags = stringList(source.tags);
  const priority = Number.isInteger(source.priority) && source.priority >= 0
    ? source.priority
    : null;
  const severity = source.severity === "critical" || source.severity === "warning"
    ? source.severity
    : null;
  if (!tags.length && priority === null && !severity) {
    return null;
  }
  const badges = element(document, "div", "message-rule-badges");
  badges.setAttribute("role", "group");
  const labels = [];
  if (severity) {
    const label = `严重性 ${severityLabel(severity)}`;
    badges.appendChild(element(document, "span", `rule-tag severity-${severity}`, label));
    labels.push(label);
  }
  if (priority !== null) {
    const label = `优先级 ${priority}`;
    badges.appendChild(element(document, "span", "rule-tag", label));
    labels.push(label);
  }
  const visible = tags.slice(0, 3);
  for (const tag of visible) {
    badges.appendChild(element(document, "span", "rule-tag", tag));
  }
  if (tags.length > visible.length) {
    badges.appendChild(element(document, "span", "rule-tag rule-tag-overflow", `+${tags.length - visible.length}`));
  }
  if (tags.length) {
    labels.push(`规则标签 ${tags.join("、")}`);
  }
  badges.setAttribute("aria-label", labels.join("；"));
  return badges;
}

export function RelayProvenance(document, message, scope = "") {
  if (typeof message.relaySender !== "string" || typeof message.originalContent !== "string") {
    return null;
  }
  const details = element(document, "details", "relay-provenance");
  details.setAttribute("data-disclosure-key", `${scope}/relay/${message.eventId || ""}`);
  details.appendChild(element(document, "summary", "", `经 ${message.relaySender || "未知转发者"} 转发 · 查看原文`));
  details.appendChild(element(document, "p", "relay-original", message.originalContent));
  return details;
}

function AnalysisSourceList(document, messages, scope = "") {
  const collection = Array.isArray(messages) ? messages : [];
  if (!collection.length) {
    return null;
  }
  const list = element(document, "ol", "analysis-source-list");
  for (const rawMessage of collection) {
    const message = object(rawMessage);
    if (typeof message.content !== "string" || !message.content) {
      continue;
    }
    const item = element(document, "li", "source-message");
    item.appendChild(element(
      document,
      "p",
      "source-message-meta",
      `${message.referenceId ? `[${message.referenceId}] ` : ""}${formatValue(message.group)} · ${formatValue(message.sender)} · 采集时间 ${message.observedAt ? formatDate(message.observedAt) : "未提供"}（北京时间）`
    ));
    item.appendChild(element(document, "p", "source-message-body", message.content));
    const provenance = RelayProvenance(document, message, scope);
    if (provenance) item.appendChild(provenance);
    const badges = RuleAnnotationBadges(document, message);
    if (badges) {
      item.appendChild(badges);
    }
    list.appendChild(item);
  }
  return list.children.length ? list : null;
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

function ReportSources(document, report, ids, key, label = "查看原文") {
  const wanted = new Set(stringList(ids));
  if (!wanted.size) return null;
  const messages = (report.sourceMessages || []).filter(message => wanted.has(message.eventId));
  const found = new Set(messages.map(message => message.eventId));
  const disclosure = element(document, "details", "briefing-sources");
  disclosure.setAttribute("data-disclosure-key", `${report.jobId || "legacy"}/${key}`);
  const refs = messages.map(message => message.referenceId).filter(Boolean);
  disclosure.appendChild(element(document, "summary", "", `${label}（${wanted.size} 条引用）${refs.length ? ` · ${refs.join(" / ")}` : ""}`));
  const list = AnalysisSourceList(document, messages, `${report.jobId || "legacy"}/${key}`);
  if (list) disclosure.appendChild(list);
  if (found.size < wanted.size) {
    disclosure.appendChild(element(document, "p", "briefing-note", `${wanted.size - found.size} 条引用的原文暂不可用，不能据此补全内容。`));
  }
  return disclosure;
}

export function JsonFindingList(document, findings, report = {}, scope = "findings") {
  const list = element(document, "ul", "finding-list");
  const categories = {key_claim: "主要观点", action_item: "待办事项", deadline: "时间节点",
    risk: "风险提醒", opportunity: "潜在线索", disagreement: "观点分歧", open_question: "待确认问题"};
  const statuses = {fact: "群内陈述", inference: "推测", uncertain: "待核实"};
  for (const [index, finding] of (Array.isArray(findings) ? findings : []).entries()) {
    const safeFinding = object(finding);
    const item = element(document, "li", "finding-item");
    const meta = element(document, "div", "finding-meta");
    if (safeFinding.category) {
      meta.appendChild(StatusPill(document, categories[safeFinding.category] || "其他观点",
        safeFinding.category === "risk" ? "warning" : "neutral"));
    }
    if (safeFinding.epistemicStatus) {
      meta.appendChild(element(document, "span", "finding-state", statuses[safeFinding.epistemicStatus] || "待核实"));
    }
    item.appendChild(meta);
    item.appendChild(element(document, "p", "finding-text", safeFinding.text || "未提供结论正文"));
    const sources = ReportSources(document, report, analysisSourceIDs(safeFinding), `${scope}/${index}`);
    if (sources) item.appendChild(sources);
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
      header.appendChild(StatusPill(document, `严重性 ${severityLabel(item.severity)}`, statusKind(item.severity)));
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
          const provenance = RelayProvenance(document, message);
          if (provenance) source.appendChild(provenance);
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

function CrossCACards(document, report, api) {
  const data = object(report.crossGroupCA);
  const cards = Array.isArray(data.items) ? data.items
    : (Array.isArray(report.cryptoAddresses) ? report.cryptoAddresses.map(card => ({
      ...card, summary: card.contextSummary, sourceMessageIDs: analysisSourceIDs(card),
    })) : []);
  if (!cards.length && data.sourcesComplete !== false) return null;
  const panel = section(document, "跨群 CA", "先看讨论摘要；展开后核对传播统计与原文。链信息未做链上验证。");
  panel.className += " briefing-ca";
  if (data.sourcesComplete === false) {
    panel.appendChild(element(document, "p", "briefing-notice", "部分原文不可用，以下统计可能不完整。"));
  }
  const more = element(document, "details", "briefing-more");
  more.setAttribute("data-disclosure-key", `${report.jobId}/more-ca`);
  more.appendChild(element(document, "summary", "", `展开其余 ${Math.max(0, cards.length - 5)} 个 CA`));
  for (const [index, raw] of cards.entries()) {
    const card = object(raw);
    if (typeof card.address !== "string" || !card.address) continue;
    const entry = element(document, "section", "briefing-ca-card");
    const meta = element(document, "div", "briefing-meta");
    const networks = {unknown: "链待确认", ethereum: "以太坊", solana: "Solana", base: "Base", bsc: "BSC",
      arbitrum: "Arbitrum", polygon: "Polygon", optimism: "Optimism", avalanche: "Avalanche"};
    meta.appendChild(StatusPill(document, networks[card.network] || "链未标注", "neutral"));
    if (card.groupCount !== undefined) {
      meta.appendChild(element(document, "span", "", `${formatValue(card.groupCount)} 群讨论`));
    }
    entry.appendChild(meta);
    entry.appendChild(AddressControl(document, card.address, api));
    entry.appendChild(element(document, "p", "record-body", card.summary || (
      card.summaryUnavailableReason === "unresolved_sources"
        ? "已有 AI 引用暂不能唯一关联到此 CA，保留原文供核对。"
        : "本次报告未生成单独的 AI 摘要，可查看下方原文。")));
    const scope = JSON.stringify([report.jobId, card.address, card.network, card.groupNames]);
    const disclosure = element(document, "details", "briefing-sources");
    disclosure.setAttribute("data-disclosure-key", `ca/${scope}`);
    disclosure.appendChild(element(document, "summary", "", "查看传播统计与原文"));
    if (card.network === "unknown") {
      disclosure.appendChild(element(document, "p", "briefing-note", "链待确认，暂不跨群合并"));
    }
    if (card.mentionCount !== undefined) {
      disclosure.appendChild(element(document, "p", "briefing-note",
        `${formatValue(card.mentionCount)} 条提及 · ${formatValue(card.uniqueStatementCount)} 条去重发言 · ${formatValue(card.duplicateCount)} 条重复传播`));
      disclosure.appendChild(element(document, "p", "briefing-note", `涉及群：${formatValue(card.groupNames)}`));
    }
    if (Array.isArray(card.speakers) && card.speakers.length) {
      disclosure.appendChild(element(document, "p", "briefing-note", `发言昵称：${formatValue(card.speakers)}（同名不代表同一人）`));
    }
    const sources = ReportSources(document, report, card.sourceMessageIDs, `ca-sources/${scope}`, "查看原文示例");
    if (sources) disclosure.appendChild(sources);
    entry.appendChild(disclosure);
    (index < 5 ? panel : more).appendChild(entry);
  }
  if (cards.length > 5) panel.appendChild(more);
  panel.appendChild(element(document, "p", "briefing-note", `本报告收录 ${cards.length}/${formatValue(data.total === undefined ? cards.length : data.total)} 个 CA；重复传播不等于独立认可，也不构成投资建议。`));
  return panel;
}

function StructuredBriefing(document, report, api) {
  const content = element(document, "div", "structured-briefing");
  const data = report.briefing;
  const scope = object(report.scope);
  const source = (parent, ids, key) => {
    const disclosure = ReportSources(document, report, ids, `v2/${key}`, "原文来源");
    if (disclosure) parent.appendChild(disclosure);
  };
  const line = (parent, label, value) => {
    const row = element(document, "p", "briefing-field");
    row.appendChild(element(document, "strong", "", `${label}：`));
    row.appendChild(element(document, "span", "", value || "未提供"));
    parent.appendChild(row);
  };
  const note = (parent, item, key) => {
    parent.appendChild(element(document, "p", "record-body", item.text));
    source(parent, item.source_message_ids, key);
  };
  const range = section(document, "本期范围");
  range.className += " briefing-scope";
  line(range, "本期有记录的群", stringList(scope.groupNames).join("、") || "未提供");
  line(range, "起止时间", `${analysisWindowLabel(report)} · Asia/Shanghai（北京时间）`);
  line(range, "数据截止时间", scope.dataCutoff ? formatDate(scope.dataCutoff) : "未提供");
  range.appendChild(element(document, "p", "briefing-note", `实际分析 ${Number.isInteger(scope.analyzedCount) ? scope.analyzedCount : "未提供"} 条通知记录；不等于完整群聊，未捕获的消息数量未知。`));
  content.appendChild(range);

  if (data.kind === "market") {
    const quick = section(document, "10秒速读");
    const grid = element(document, "div", "briefing-quick-grid");
    for (const [key, label] of [["focus", "重点标的／大盘"], ["news", "消息面"], ["risk", "风险提醒"]]) {
      const card = element(document, "div", "briefing-quick-card");
      card.appendChild(element(document, "h3", "", label));
      note(card, data.quick_read[key], `quick/${key}`);
      grid.appendChild(card);
    }
    quick.appendChild(grid);
    content.appendChild(quick);
    const columns = element(document, "div", "briefing-columns");
    const projects = section(document, "重点标的与大盘");
    for (const [index, project] of data.projects.entries()) {
      const card = element(document, "article", "briefing-project");
      card.appendChild(element(document, "h3", "", project.name));
      line(card, "公链／归属", `${project.chain}（群内标注，未经外部核验）`);
      for (const [key, label] of [["summary", "核心摘要"], ["catalysts", "催化与讨论逻辑"], ["latest", "最新动态"], ["risks", "风险与分歧"]]) {
        line(card, label, project[key]);
      }
      if (!project.data.length) line(card, "数据快照", "未提供");
      for (const [i, snapshot] of project.data.entries()) {
        line(card, "数据快照", `${snapshot.value} ${snapshot.unit} · ${snapshot.kind} · 来源：${snapshot.source} · 原文记录时间：${snapshot.recorded_at}（不是当前行情）`);
        source(card, snapshot.source_message_ids, `project/${index}/data/${i}`);
      }
      if (!project.addresses.length) line(card, "完整CA", "未提供");
      for (const address of project.addresses) card.appendChild(AddressControl(document, address.address, api));
      source(card, project.source_message_ids, `project/${index}`);
      projects.appendChild(card);
    }
    if (!data.projects.length) projects.appendChild(EmptyState(document, "无有效标的或大盘信息"));
    columns.appendChild(projects);
    const side = element(document, "aside", "briefing-sidebar");
    const events = section(document, "消息面与风险");
    for (const [index, item] of data.events.entries()) {
      const card = element(document, "article", "briefing-event");
      card.appendChild(element(document, "h3", "", item.event));
      for (const [key, label] of [["asset", "涉及标的"], ["nature", "消息性质"], ["impact", "潜在影响"], ["pending", "待核实事项"]]) line(card, label, item[key]);
      source(card, item.source_message_ids, `event/${index}`);
      events.appendChild(card);
    }
    if (!data.events.length) events.appendChild(EmptyState(document, "无有效消息面或风险信息"));
    side.appendChild(events);
    const addresses = section(document, "CA索引", "原样地址；链与项目归属未经外部核验。讨论量不代表可信度或投资价值。");
    let count = 0;
    for (const [projectIndex, project] of data.projects.entries()) {
      for (const [index, address] of project.addresses.entries()) {
        count++;
        const card = element(document, "article", "briefing-index-card");
        card.appendChild(element(document, "h3", "", project.name));
        line(card, "公链／归属", address.chain);
        card.appendChild(AddressControl(document, address.address, api));
        source(card, address.source_message_ids, `index/${projectIndex}/${index}`);
        const normalized = address.address.toLowerCase().startsWith("0x") ? address.address.toLowerCase() : address.address;
        const groups = new Set((report.sourceMessages || []).filter(m => address.source_message_ids.includes(m.eventId)).map(m => m.group));
        const network = address.chain.toLowerCase();
        const matches = (object(report.crossGroupCA).items || []).filter(c => c.address === normalized && (
          c.network === network || (c.network === "unknown" && address.chain === "未确认" && c.groupNames.every(g => groups.has(g)))
        ));
        if (matches.length === 1) {
          const stats = matches[0];
          line(card, "窗口内捕获讨论", `${stats.groupCount} 群 · ${stats.mentionCount} 次提及；重复转发不是独立证实`);
        }
        addresses.appendChild(card);
      }
    }
    if (!count) addresses.appendChild(EmptyState(document, "未提供可核对的完整CA"));
    side.appendChild(addresses);
    columns.appendChild(side);
    content.appendChild(columns);
  } else {
    for (const [key, label] of [["progress", "关键进展"], ["notices", "重要通知"], ["blockers", "风险阻塞"], ["tasks", "待办清单"]]) {
      const panel = section(document, label);
      for (const [index, item] of data.business[key].entries()) {
        const card = element(document, "article", "briefing-project");
        note(card, item, `business/${key}/${index}`);
        if (key === "tasks") {
          line(card, "负责人", item.owner);
          line(card, "截止时间", item.deadline);
        }
        panel.appendChild(card);
      }
      if (!data.business[key].length) panel.appendChild(EmptyState(document, "无有效信息"));
      content.appendChild(panel);
    }
  }
  const gaps = section(document, "来源与缺口");
  for (const [index, item] of data.gaps.entries()) note(gaps, item, `gap/${index}`);
  line(gaps, "未读取内容", "图片、语音、附件和链接正文未读取，不能作为结论依据。");
  line(gaps, "时间口径", `时间均为通知采集时间；原始发送时间未提供。${scope.unknownTimeCount || 0} 条可读记录的采集时间不明。`);
  line(gaps, "原文覆盖", `${scope.missingCount || 0} 条原文当前不可读；页面可展开 ${scope.displayedSourceCount || 0} 条原文，不代表完整群聊。`);
  line(gaps, "引用编号", "M 开头为本报告的本地引用编号，不是企业微信平台消息ID；展开原文可查发言者、群名与采集时间。");
  line(gaps, "外部核验", "未进行外部核验；群内自述、转述或推测不是已核验事实。");
  source(gaps, (report.sourceMessages || []).map(m => m.eventId), "all");
  content.appendChild(gaps);
  return content;
}

export function renderAnalyses({ root, payload, api, viewState = {} }) {
  const page = begin(root, "群消息简报", "按周期阅读，一次一份；仅整理已捕获消息，保留原文供核对。", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const range = object(payload.dateRange);
  const rangeAvailable = [range.minDate, range.maxDate].every(value => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value));
  const collection = items(payload).filter(item => !rangeAvailable || (
    analysisEndDate(item) >= range.minDate && analysisEndDate(item) <= range.maxDate
  )).sort((a, b) =>
    (Date.parse(b.windowEnd) || 0) - (Date.parse(a.windowEnd) || 0));
  const cadences = ["two_hour", "six_hour", "daily"];
  const cadenceOf = item => cadences.includes(item.cadence) ? item.cadence : "two_hour";
  const keyOf = item => item.jobId || item.analysisId || JSON.stringify([item.windowStart, item.windowEnd]);
  const hasReport = item => Boolean(item.summary) || [item.topics, item.findings, item.cryptoAddresses]
    .some(value => Array.isArray(value) && value.length);
  if (!cadences.includes(viewState.cadence)) {
    viewState.cadence = collection.some(item => cadenceOf(item) === "two_hour") ? "two_hour" : cadenceOf(collection[0] || {});
  }
  page.content.className += " briefing-page";
  const toolbar = element(document, "div", "briefing-toolbar");
  const tabs = element(document, "div", "readonly-tabs");
  tabs.setAttribute("role", "group");
  tabs.setAttribute("aria-label", "总结周期");
  const buttons = [];
  for (const cadence of cadences) {
    const button = element(document, "button", "readonly-tab", analysisCadenceLabel(cadence));
    button.type = "button";
    button.addEventListener("click", () => {
      viewState.cadence = cadence;
      viewState.jobId = null;
      draw();
    });
    buttons.push({button, cadence});
    tabs.appendChild(button);
  }
  toolbar.appendChild(tabs);
  const dateLabel = element(document, "label", "briefing-history", "日期（北京时间）");
  dateLabel.setAttribute("for", "briefing-date");
  const datePicker = element(document, "input", "briefing-select briefing-date");
  datePicker.type = "date";
  datePicker.setAttribute("id", "briefing-date");
  datePicker.min = rangeAvailable ? range.minDate : "";
  datePicker.max = rangeAvailable ? range.maxDate : "";
  datePicker.disabled = !rangeAvailable;
  datePicker.addEventListener("change", () => {
    viewState.date = datePicker.value;
    viewState.jobId = null;
    draw();
  });
  dateLabel.appendChild(datePicker);
  const allDates = element(document, "button", "readonly-tab", "近 3 天");
  allDates.type = "button";
  allDates.addEventListener("click", () => {viewState.date = ""; viewState.jobId = null; draw();});
  dateLabel.appendChild(allDates);
  toolbar.appendChild(dateLabel);
  const label = element(document, "label", "briefing-history", "报告时间");
  label.setAttribute("for", "briefing-history");
  const history = element(document, "select", "briefing-select");
  history.setAttribute("id", "briefing-history");
  history.addEventListener("change", () => {
    viewState.jobId = history.value || null;
    draw();
  });
  label.appendChild(history);
  toolbar.appendChild(label);
  page.content.appendChild(toolbar);
  const host = element(document, "div", "briefing-body");
  page.content.appendChild(host);

  function draw() {
    host.replaceChildren();
    history.replaceChildren();
    page.content.scrollTop = 0;
    if (viewState.date && (!rangeAvailable || viewState.date < range.minDate || viewState.date > range.maxDate)) {
      viewState.date = "";
      viewState.jobId = null;
    }
    datePicker.value = viewState.date || "";
    allDates.setAttribute("aria-pressed", String(!viewState.date));
    allDates.disabled = !rangeAvailable;
    for (const {button, cadence} of buttons) {
      button.className = `readonly-tab${viewState.cadence === cadence ? " active" : ""}`;
      button.setAttribute("aria-pressed", String(viewState.cadence === cadence));
    }
    const period = collection.filter(item => cadenceOf(item) === viewState.cadence && (
      !viewState.date || analysisEndDate(item) === viewState.date
    ));
    const latestReport = period.find(hasReport) || period[0];
    const selected = period.find(item => keyOf(item) === viewState.jobId);
    if (!selected) viewState.jobId = null;
    const item = selected || latestReport;
    const automatic = element(document, "option", "", "最新报告（自动更新）");
    automatic.value = "";
    history.appendChild(automatic);
    for (const record of period) {
      const option = element(document, "option", "", `${analysisWindowLabel(record)} · ${analysisStateLabel(record.state)}`);
      option.value = keyOf(record);
      history.appendChild(option);
    }
    history.value = viewState.jobId || "";
    history.disabled = !period.length;
    if (!item) {
      host.appendChild(EmptyState(document, `暂无${viewState.date ? ` ${viewState.date}` : ""} ${analysisCadenceLabel(viewState.cadence)}报告`));
      return;
    }
    if (period[0] !== item && period[0].state !== "succeeded") {
      host.appendChild(element(document, "p", "briefing-notice",
        `最新周期：${analysisWindowLabel(period[0])} · ${analysisStateLabel(period[0].state)}。下方为此前报告，请留意时间。`));
    }
    const result = element(document, "article", "analysis-result");
    const heading = element(document, "header", "briefing-report-header");
    const meta = element(document, "div", "briefing-meta");
    meta.appendChild(element(document, "span", "", viewState.jobId ? "历史报告" : "最新可读报告"));
    meta.appendChild(StatusPill(document, analysisStateLabel(item.state), statusKind(item.state)));
    heading.appendChild(meta);
    heading.appendChild(element(document, "h2", "record-title", `${analysisCadenceLabel(viewState.cadence)}群聊简报`));
    heading.appendChild(element(document, "p", "analysis-window", analysisWindowLabel(item)));
    result.appendChild(heading);
    host.appendChild(result);
    if (!hasReport(item)) {
      result.appendChild(EmptyState(document, "该周期尚无总结正文，任务状态如上；这里不会自动补跑。"));
    } else if (object(item.briefing).version === 2) {
      result.appendChild(StructuredBriefing(document, item, api));
    } else {
      result.appendChild(element(document, "p", "briefing-note", "旧模板报告，保留原内容；新规则从后续生成的报告生效，不重跑历史。"));
      const overview = section(document, "本期速览");
      overview.className += " briefing-overview";
      overview.appendChild(element(document, "p", "briefing-summary", item.summary || "本份报告没有总述，可查看下方话题与观点。"));
      const summarySources = ReportSources(document, item,
        stringList(item.summarySourceMessageIDs).length ? item.summarySourceMessageIDs : item.sourceReferences, "summary");
      if (summarySources) overview.appendChild(summarySources);
      result.appendChild(overview);
      const topics = Array.isArray(item.topics) ? item.topics : [];
      const findings = Array.isArray(item.findings) ? item.findings : [];
      const isRisk = finding => ["risk", "disagreement", "open_question"].includes(object(finding).category);
      const extras = findings.filter(finding => !isRisk(finding));
      const risks = findings.filter(isRisk);
      if (topics.length || extras.length) {
        const panel = section(document, "重点话题", "点击话题展开详情与原文。");
        for (const [index, topic] of topics.entries()) {
          const safeTopic = object(topic);
          const topicCard = element(document, "details", "briefing-topic");
          topicCard.setAttribute("data-disclosure-key", `${keyOf(item)}/topic/${index}`);
          topicCard.appendChild(element(document, "summary", "", safeTopic.title || "未命名话题"));
          if (safeTopic.summary) {
            topicCard.appendChild(element(document, "p", "record-body", safeTopic.summary));
          }
          const sources = ReportSources(document, item, analysisSourceIDs(safeTopic), `topic-sources/${index}`);
          if (sources) topicCard.appendChild(sources);
          panel.appendChild(topicCard);
        }
        if (extras.length) {
          const extra = element(document, "details", "briefing-topic");
          extra.setAttribute("data-disclosure-key", `${keyOf(item)}/extra-findings`);
          extra.appendChild(element(document, "summary", "", `补充观点（${extras.length} 条）`));
          extra.appendChild(JsonFindingList(document, extras, item, "extras"));
          panel.appendChild(extra);
        }
        result.appendChild(panel);
      }
      if (risks.length) {
        const riskPanel = section(document, "风险与分歧", "以下是群内陈述或推测，不代表已经证实。");
        riskPanel.className += " briefing-risks";
        riskPanel.appendChild(JsonFindingList(document, risks, item, "risks"));
        result.appendChild(riskPanel);
      }
      const caCards = CrossCACards(document, item, api);
      if (caCards) result.appendChild(caCards);
      const sourceList = ReportSources(document, item,
        (item.sourceMessages || []).map(message => message.eventId), "all-sources", "查看报告全部可用原文");
      if (sourceList) result.appendChild(sourceList);
    }
    const task = element(document, "details", "briefing-task");
    task.setAttribute("data-disclosure-key", `${keyOf(item)}/task`);
    task.appendChild(element(document, "summary", "", "任务信息"));
    task.appendChild(element(document, "p", "briefing-note", `尝试 ${formatValue(item.attempt)}/${formatValue(item.maximumAttempts)} · ${analysisStateLabel(item.state)}`));
    if (item.state === "retry_wait" && item.nextAttemptAt) {
      task.appendChild(element(document, "p", "briefing-note", `下次重试 ${formatDate(item.nextAttemptAt)}`));
    }
    result.appendChild(task);
    host.appendChild(element(document, "p", "briefing-note", rangeAvailable
      ? `可查 ${range.minDate} 至 ${range.maxDate}，按北京时间的报告周期结束日期归类。更早记录仍保存在本机，未删除。`
      : "日期范围暂不可用，请刷新页面；历史记录仍保存在本机。"));
  }
  draw();
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
      ["级别", safe.severity === "critical" || safe.severity === "warning"
        ? `${severityLabel(safe.severity)}（${safe.severity}）`
        : safe.severity],
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

export function renderProviders({ root, payload, api }) {
  void api;
  const page = begin(root, "配置中心", "仅显示 MiniMax 模型与配置状态，不传输凭据", payload);
  if (page.unavailable) {
    return cleanup;
  }
  const document = page.document;
  const providerSection = section(document, "MiniMax 分析服务", "浏览器不会显示或读取凭据内容");
  const card = element(document, "article", "provider-card");
  card.appendChild(element(document, "h3", "record-title", "MiniMax-M2.7"));
  card.appendChild(StatusPill(
    document,
    payload.aiConfigured === true ? "已配置" : "未配置",
    payload.aiConfigured === true ? "ready" : "neutral"
  ));
  providerSection.appendChild(card);
  page.content.appendChild(providerSection);
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
  rows.appendChild(ReadonlyControl(document, "分析数据库", sourceStatus(payload, "analysis")));
  rows.appendChild(ReadonlyControl(document, "监听活动", listenerStateLabel(payload.listenerState)));
  const messagesDependency = object(payload.messagesDependency);
  const lastMessageStatus = messagesDependency.available === false
    ? sourceReasonLabel(messagesDependency.reason)
    : payload.lastMessageAt
      ? formatDate(payload.lastMessageAt)
      : "尚无记录";
  rows.appendChild(ReadonlyControl(document, "最近消息", lastMessageStatus));
  rows.appendChild(ReadonlyControl(document, "规则匹配", sourceStatus(payload, "ruleMatches")));
  rows.appendChild(ReadonlyControl(document, "分析任务", sourceStatus(payload, "analysisJobs")));
  rows.appendChild(ReadonlyControl(document, "API 模式", "GET / HEAD 只读"));
  page.content.appendChild(rows);

  const worker = object(payload.analysisWorker);
  const jobCounts = object(payload.jobCounts);
  if (Object.keys(worker).length || Object.keys(jobCounts).length) {
    const analysis = section(document, "MiniMax 分析", "后台运行与已记录任务状态");
    analysis.appendChild(ReadonlyControl(document, "分析工作器", worker.active === true ? "活动中" : "未活动"));
    const labels = [
      ["等待执行", jobCounts.queued], ["正在分析", jobCounts.running],
      ["等待重试", jobCounts.retryWait], ["需要配置凭据", jobCounts.credentialRequired],
      ["执行失败", jobCounts.failed], ["已完成", jobCounts.succeeded],
      ["窗口无消息", jobCounts.skippedEmpty],
    ];
    for (const [label, count] of labels) {
      if (Number.isInteger(count) && count >= 0) {
        analysis.appendChild(ReadonlyControl(document, label, count));
      }
    }
    page.content.appendChild(analysis);
  }

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
    const badges = RuleAnnotationBadges(document, item);
    if (badges) {
      card.appendChild(badges);
    }
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
  { id: "analyses", label: "分析记录", icon: "analysis", endpoint: "/api/analyses", render: renderAnalyses, readOnly: true },
  { id: "rules", label: "监控规则", icon: "rules", endpoint: "/api/rules", render: renderRules, readOnly: true },
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
