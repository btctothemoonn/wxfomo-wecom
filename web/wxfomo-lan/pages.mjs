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
  return `[${formatDate(start)}, ${formatDate(end)})`;
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
      `${formatValue(message.group)} · ${formatValue(message.sender)}`
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
    const sources = analysisSourceIDs(safeFinding);
    if (sources.length) {
      item.appendChild(
        element(document, "p", "source-reference", `来源 ${sources.join(" · ")}`)
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

function CrossCACards(document, report) {
  const data = object(report.crossGroupCA);
  const cards = Array.isArray(data.items) ? data.items : [];
  if (!cards.length && data.sourcesComplete !== false) return null;
  const panel = section(document, "跨群 CA", "仅统计本周期已捕获的消息，不代表链上验证或投资建议");
  if (data.sourcesComplete === false) {
    panel.appendChild(element(document, "p", "record-body", "部分原文不可用，以下统计可能不完整。"));
  }
  for (const raw of cards) {
    const card = object(raw);
    const entry = element(document, "section", "topic-card");
    entry.appendChild(element(document, "code", "address-value", card.address));
    entry.appendChild(element(document, "p", "source-reference", card.network === "unknown"
      ? "链待确认，暂不跨群合并" : `${card.network} · 链信息来自消息标注或地址格式`));
    entry.appendChild(element(document, "p", "record-body",
      `${formatValue(card.groupCount)} 群 · ${formatValue(card.mentionCount)} 条提及 · ${formatValue(card.uniqueStatementCount)} 条去重发言 · ${formatValue(card.duplicateCount)} 条重复传播`));
    entry.appendChild(element(document, "p", "source-reference", `涉及群：${formatValue(card.groupNames)}`));
    if (Array.isArray(card.speakers) && card.speakers.length) {
      entry.appendChild(element(document, "p", "source-reference", `发言昵称：${formatValue(card.speakers)}（同名不代表同一人）`));
    }
    entry.appendChild(element(document, "p", "record-body", card.summary || (
      card.summaryUnavailableReason === "unresolved_sources"
        ? "已有 AI 引用暂不能唯一关联到此 CA，保留原文供核对。"
        : "本次报告未生成单独的 AI 摘要，可查看下方原文。")));
    const ids = new Set(stringList(card.sourceMessageIDs));
    const scope = JSON.stringify([report.jobId, card.address, card.network, card.groupNames]);
    const sources = AnalysisSourceList(document, (report.sourceMessages || []).filter(message => ids.has(message.eventId)), scope);
    if (sources) {
      const disclosure = element(document, "details", "relay-provenance");
      disclosure.setAttribute("data-disclosure-key", `ca/${scope}`);
      disclosure.appendChild(element(document, "summary", "", "来源示例（最多 5 条）"));
      disclosure.appendChild(sources);
      entry.appendChild(disclosure);
    }
    panel.appendChild(entry);
  }
  panel.appendChild(element(document, "p", "source-reference", `显示 ${cards.length}/${formatValue(data.total)} 个 CA；重复传播按相同昵称和正文估算，不等于独立认可人数。`));
  return panel;
}

export function renderAnalyses({ root, payload, api }) {
  void api;
  const page = begin(root, "分析记录", "最近 30 个任务、总结与可追溯来源；历史记录保留在本机", payload);
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
    job.appendChild(StatusPill(document, analysisStateLabel(item.state), statusKind(item.state)));
    job.appendChild(element(document, "p", "analysis-job-mode", item.mode || "分析任务"));
    job.appendChild(element(document, "p", "analysis-cadence", `周期 ${analysisCadenceLabel(item.cadence)}`));
    job.appendChild(element(document, "p", "analysis-window", analysisWindowLabel(item)));
    job.appendChild(
      element(document, "p", "analysis-job-meta", `尝试 ${formatValue(item.attempt)}/${formatValue(item.maximumAttempts)}`)
    );
    if (item.state === "retry_wait" && item.nextAttemptAt) {
      job.appendChild(element(document, "p", "analysis-job-meta", `下次重试 ${formatDate(item.nextAttemptAt)}`));
    }
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
    result.appendChild(element(document, "h3", "record-title", `${analysisCadenceLabel(item.cadence)}总结`));
    result.appendChild(element(document, "p", "analysis-window", analysisWindowLabel(item)));
    if (item.summary) {
      result.appendChild(element(document, "p", "record-body", item.summary));
    }
    for (const topic of Array.isArray(item.topics) ? item.topics : []) {
      const safeTopic = object(topic);
      const topicCard = element(document, "section", "topic-card");
      topicCard.appendChild(element(document, "h4", "topic-title", safeTopic.title || "主题"));
      if (safeTopic.summary) {
        topicCard.appendChild(element(document, "p", "record-body", safeTopic.summary));
      }
      const sources = analysisSourceIDs(safeTopic);
      if (sources.length) {
        topicCard.appendChild(
          element(document, "p", "source-reference", `来源 ${sources.join(" · ")}`)
        );
      }
      result.appendChild(topicCard);
    }
    if (Array.isArray(item.findings) && item.findings.length) {
      result.appendChild(JsonFindingList(document, item.findings));
    }
    const summarySources = stringList(item.summarySourceMessageIDs).length
      ? stringList(item.summarySourceMessageIDs)
      : stringList(item.sourceReferences);
    if (summarySources.length) {
      result.appendChild(
        element(document, "p", "source-reference", `总结来源 ${summarySources.join(" · ")}`)
      );
    }
    const caCards = CrossCACards(document, item);
    if (caCards) result.appendChild(caCards);
    const addresses = !caCards && Array.isArray(item.cryptoAddresses) ? item.cryptoAddresses : [];
    if (addresses.length) {
      const addressList = element(document, "ul", "analysis-ca-list");
      for (const rawAddress of addresses) {
        const address = object(rawAddress);
        if (typeof address.address !== "string" || !address.address) {
          continue;
        }
        const row = element(document, "li", "analysis-ca-item");
        row.appendChild(element(document, "span", "rule-tag", "CA"));
        row.appendChild(element(document, "code", "address-value", address.address));
        if (typeof address.contextSummary === "string" && address.contextSummary) {
          row.appendChild(element(document, "span", "analysis-ca-context", address.contextSummary));
        }
        const sources = analysisSourceIDs(address);
        if (sources.length) {
          row.appendChild(element(document, "span", "source-reference", `来源 ${sources.join(" · ")}`));
        }
        addressList.appendChild(row);
      }
      if (addressList.children.length) {
        result.appendChild(addressList);
      }
    }
    const sourceList = AnalysisSourceList(document, item.sourceMessages, item.jobId);
    if (sourceList) {
      const disclosure = element(document, "details", "relay-provenance");
      disclosure.setAttribute("data-disclosure-key", `report/${item.jobId}`);
      disclosure.appendChild(element(document, "summary", "", "查看报告来源"));
      disclosure.appendChild(sourceList);
      result.appendChild(disclosure);
    }
    details.appendChild(result);
  }
  split.appendChild(details);
  page.content.appendChild(split);
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
