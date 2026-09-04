import {
  ApiError,
  authenticate,
  fetchBootstrap,
  fetchMessages,
  hasSessionToken,
  requestJson,
} from "./api.mjs";
import { copyText } from "./clipboard.mjs";
import {
  WORKSPACE_PAGES,
  isCurrentMessageRequest,
  isCurrentReadOnlyRequest,
  readOnlyPageFromHash,
} from "./pages.mjs";
import {
  applyMessagePage,
  boundedRetryDelay,
  canLoadMessagePage,
  composeDiagnosticsPagePayload,
  composeReadOnlyPagePayload,
  diagnosticsPrimaryFailurePayload,
  diagnosticsPayloadWithLiveBootstrap,
  invalidateListenerFreshness,
  isCurrentConnection,
  isRetriableReadOnlyPayload,
  listenerFreshnessExpiryDelay,
  listenerPresentation,
  prepareMessageReload,
  retainMessageBootstrap,
  retainReadOnlyPayload,
  resetMessageSession,
  routeFromHash,
  runRecurringAttempt,
} from "./state.mjs";

const SVG_NAMESPACE = "http://www.w3.org/2000/svg";
const POLL_INTERVAL_MS = 2000;
const PAGE_SIZE = 100;

const loginView = document.getElementById("login-view");
const tokenForm = document.getElementById("token-form");
const tokenInput = document.getElementById("token-input");
const loginError = document.getElementById("login-error");
const appShell = document.getElementById("app-shell");

function appRouteFromHash(hash) {
  const page = readOnlyPageFromHash(hash);
  return page ? { page: page.id, readOnlyPage: page } : routeFromHash(hash);
}

const model = {
  authenticated: false,
  bootstrap: null,
  route: appRouteFromHash(window.location.hash),
  messages: [],
  latestCursor: null,
  nextBefore: null,
  range: "2h",
  messageType: "all",
  keyword: "",
  loading: false,
  requestGeneration: 0,
  connectionGeneration: 0,
  polling: false,
  statusMessage: "等待连接",
  statusKind: "",
  readOnlyPayload: null,
  readOnlyLoading: false,
  messageRetryAttempt: 0,
  bootstrapRetryAttempt: 0,
  pendingMessageReplace: false,
  readOnlyRetryAttempt: 0,
};

let pollTimer = null;
let bootstrapTimer = null;
let listenerFreshnessTimer = null;
let readOnlyRetryTimer = null;
let pageCleanup = null;

function element(tagName, className, text) {
  const node = document.createElement(tagName);
  if (className) {
    node.className = className;
  }
  if (text !== undefined && text !== null) {
    node.textContent = String(text);
  }
  return node;
}

function icon(name) {
  const svg = document.createElementNS(SVG_NAMESPACE, "svg");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(SVG_NAMESPACE, "use");
  use.setAttribute("href", `/icons.svg#${name}`);
  svg.appendChild(use);
  return svg;
}

function appendIconLabel(parent, iconName, label) {
  parent.appendChild(icon(iconName));
  parent.appendChild(element("span", "nav-label", label));
}

function makeNavItem(label, iconName, options = {}) {
  let item;
  if (options.href) {
    item = element("a", "nav-item");
    item.href = options.href;
  } else {
    item = element("button", "nav-item");
    item.type = "button";
    item.disabled = Boolean(options.disabled);
  }
  if (options.active) {
    item.classList.add("active");
    item.setAttribute("aria-current", "page");
  }
  if (options.title) {
    item.title = options.title;
  }
  appendIconLabel(item, iconName, label);
  if (options.count) {
    item.appendChild(element("span", "nav-badge", options.count));
  }
  return item;
}

function makeSection(title, items) {
  const section = element("section", "nav-section");
  section.appendChild(element("h2", "nav-heading", title));
  for (const item of items) {
    section.appendChild(item);
  }
  return section;
}

function groups() {
  return model.bootstrap && Array.isArray(model.bootstrap.groups)
    ? model.bootstrap.groups
    : [];
}

function sidebar() {
  const sidebarNode = element("aside", "sidebar");
  const brand = element("header", "sidebar-brand");
  const brandRow = element("div", "brand-row");
  brandRow.appendChild(element("div", "brand-mark", "W"));
  const brandText = element("div");
  brandText.appendChild(element("p", "brand-title", "wxFomo"));
  brandText.appendChild(element("p", "brand-subtitle", "群聊信号台"));
  brandRow.appendChild(brandText);
  brand.appendChild(brandRow);

  const listener = element("div", "listener-line");
  const sourceAvailable = Boolean(model.bootstrap.messageSource.available);
  const listenerStatus = listenerPresentation(model.bootstrap);
  listener.appendChild(element("span", `status-dot${listenerStatus.active ? " ready" : ""}`));
  listener.appendChild(element("span", "", listenerStatus.label));
  listener.appendChild(
    element("span", "listener-count", `监听 ${groups().length} 个群`)
  );
  brand.appendChild(listener);
  sidebarNode.appendChild(brand);

  const navigation = element("nav", "sidebar-scroll", "");
  navigation.setAttribute("aria-label", "工作台导航");
  const inboxCount = model.bootstrap.counts && model.bootstrap.counts.inbox;
  navigation.appendChild(
    makeSection("消息", [
      makeNavItem("收件箱", "inbox", {
        href: "#inbox",
        active: model.route.page === "inbox",
        count: inboxCount ? String(inboxCount) : "",
      }),
      makeNavItem("重点捕捉", "target", {
        href: "#priority",
        active: model.route.page === "priority",
      }),
      makeNavItem("提醒中心", "bell", {
        href: "#alerts",
        active: model.route.page === "alerts",
      }),
    ])
  );

  const groupItems = groups().map((group) =>
    makeNavItem(group.name, "users", {
      href: `#group/${encodeURIComponent(group.name)}`,
      active: model.route.page === "group" && model.route.group === group.name,
      count: group.count ? String(group.count) : "",
    })
  );
  if (groupItems.length === 0) {
    groupItems.push(
      makeNavItem("尚无监听群", "users", {
        disabled: true,
        title: "等待 Mac 监听器写入真实消息",
      })
    );
  }
  navigation.appendChild(makeSection("监听群", groupItems));

  navigation.appendChild(
    makeSection(
      "工作台",
      WORKSPACE_PAGES.slice(0, 6).map((page) =>
        makeNavItem(page.label, page.icon, {
          href: `#${page.id}`,
          active: model.route.page === page.id,
        })
      )
    )
  );
  navigation.appendChild(
    makeSection(
      "设置",
      WORKSPACE_PAGES.slice(6).map((page) =>
        makeNavItem(page.label, page.icon, {
          href: `#${page.id}`,
          active: model.route.page === page.id,
          title: "浏览器只读；配置变更仅可在 Mac 操作",
        })
      )
    )
  );
  sidebarNode.appendChild(navigation);

  const footer = element("footer", "sidebar-footer");
  const source = element("div", "source-status");
  source.appendChild(element("span", `status-dot${listenerStatus.active ? " ready" : ""}`));
  const sourceText = element("span", "", "采集状态");
  sourceText.appendChild(
    element(
      "span",
      "source-detail",
      listenerStatus.detail
    )
  );
  source.appendChild(sourceText);
  footer.appendChild(source);
  footer.appendChild(element("div", "readonly-footer-badge", "浏览器只读 · 页面自动刷新"));
  sidebarNode.appendChild(footer);
  return sidebarNode;
}

function selectControl(label, values, selectedValue, onChange) {
  const wrapper = element("label");
  wrapper.appendChild(element("span", "toolbar-label", label));
  const select = element("select", "toolbar-select");
  for (const optionValue of values) {
    const option = element("option", "", optionValue.label);
    option.value = optionValue.value;
    select.appendChild(option);
  }
  select.value = selectedValue;
  select.addEventListener("change", () => onChange(select.value));
  wrapper.appendChild(select);
  return wrapper;
}

function messageTypeChips() {
  const wrapper = element("div", "chip-group");
  wrapper.setAttribute("aria-label", "消息类型");
  for (const value of [
    { value: "all", label: "全部" },
    { value: "text", label: "文本" },
    { value: "media", label: "媒体" },
  ]) {
    const chip = element("button", "filter-chip", value.label);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(model.messageType === value.value));
    if (model.messageType === value.value) {
      chip.classList.add("active");
    }
    chip.addEventListener("click", () => {
      model.messageType = value.value;
      renderWorkbench();
    });
    wrapper.appendChild(chip);
  }
  return wrapper;
}

function groupPicker() {
  const values = [{ value: "all", label: "所有监听群" }];
  for (const [index, group] of groups().entries()) {
    values.push({ value: String(index), label: group.name });
  }
  let selected = "all";
  if (model.route.page === "group") {
    const index = groups().findIndex((group) => group.name === model.route.group);
    selected = index >= 0 ? String(index) : "all";
  }
  return selectControl("群聊 ", values, selected, (value) => {
    if (value === "all") {
      window.location.hash = "inbox";
      return;
    }
    const group = groups()[Number(value)];
    if (group) {
      window.location.hash = `group/${encodeURIComponent(group.name)}`;
    }
  });
}

function toolbar() {
  const toolbarNode = element("div", "toolbar");
  toolbarNode.appendChild(
    selectControl(
      "时间范围 ",
      [
        { value: "30m", label: "最近 30 分钟" },
        { value: "2h", label: "最近 2 小时" },
        { value: "6h", label: "最近 6 小时" },
        { value: "today", label: "今天" },
      ],
      model.range,
      (value) => {
        model.range = value;
        renderWorkbench();
      }
    )
  );
  toolbarNode.appendChild(messageTypeChips());
  toolbarNode.appendChild(groupPicker());

  const search = element("form", "search-form");
  search.setAttribute("role", "search");
  search.appendChild(icon("search"));
  const input = element("input", "search-input");
  input.type = "search";
  input.placeholder = "搜索发送者或内容";
  input.value = model.keyword;
  input.setAttribute("aria-label", "搜索发送者或内容");
  search.appendChild(input);
  search.addEventListener("submit", (event) => {
    event.preventDefault();
    model.keyword = input.value.trim();
    resetAndLoadMessages();
  });
  toolbarNode.appendChild(search);
  toolbarNode.appendChild(element("span", "readonly-badge", "只读模式"));
  return toolbarNode;
}

function rangeStart() {
  const now = new Date();
  if (model.range === "today") {
    return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  }
  const duration = { "30m": 30, "2h": 120, "6h": 360 }[model.range] || 120;
  return now.getTime() - duration * 60 * 1000;
}

function visibleMessages() {
  const start = rangeStart();
  return model.messages.filter((message) => {
    const typeMatches =
      model.messageType === "all" || message.messageType === model.messageType;
    return typeMatches && Date.parse(message.observedAt) >= start;
  });
}

const dateFormatter = new Intl.DateTimeFormat("zh-CN", {
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

function formatObservedAt(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "时间未知" : dateFormatter.format(date);
}

function senderInitial(sender) {
  const characters = Array.from(String(sender || "").trim());
  return characters.length ? characters[0] : "?";
}

function copyButton(content) {
  const button = element("button", "icon-button");
  button.type = "button";
  button.setAttribute("aria-label", "复制消息正文");
  button.title = "复制消息";
  button.appendChild(icon("copy"));
  button.addEventListener("click", async () => {
    const result = await copyText(content);
    if (["clipboard", "execCommand"].includes(result)) {
      button.replaceChildren();
      button.textContent = "已复制";
      button.classList.add("copied");
      window.setTimeout(() => {
        button.replaceChildren(icon("copy"));
        button.classList.remove("copied");
      }, 1400);
    } else {
      button.replaceChildren();
      button.textContent = result === "manual" ? "请手动复制" : "复制失败";
      button.classList.add("copied");
    }
  });
  return button;
}

function messageCard(message) {
  const item = element("li", "message-card");
  if (message.messageType === "media") {
    item.classList.add("media");
  }
  item.appendChild(element("div", "avatar", senderInitial(message.sender)));

  const main = element("div", "message-main");
  const meta = element("div", "message-meta");
  meta.appendChild(element("span", "sender-name", message.sender || "未知发送者"));
  meta.appendChild(element("span", "group-name", message.group));
  if (message.messageType === "media") {
    const badge = element("span", "media-badge");
    badge.appendChild(icon("media"));
    badge.appendChild(element("span", "", "媒体"));
    meta.appendChild(badge);
  }
  main.appendChild(meta);
  main.appendChild(element("p", "message-body", message.content));
  item.appendChild(main);

  const side = element("div", "message-side");
  side.appendChild(element("time", "message-time", formatObservedAt(message.observedAt)));
  side.appendChild(copyButton(message.content));
  item.appendChild(side);
  return item;
}

function feed() {
  const scroll = element("div", "feed-scroll");
  const messages = visibleMessages();
  if (!model.bootstrap.messageSource.available && !messages.length) {
    scroll.appendChild(
      emptyState("消息源不可用", "当前 Mac 后台尚未提供消息数据库；页面不会生成示例数据。")
    );
    return scroll;
  }
  if (!messages.length) {
    const title = model.loading ? "正在读取消息" : "当前范围暂无消息";
    const copy = model.loading
      ? "正在从 Mac 只读消息库载入真实数据。"
      : "可调整时间、类型、群聊或关键词筛选；新消息会在页面可见时自动出现。";
    scroll.appendChild(emptyState(title, copy));
  } else {
    const list = element("ol", "feed-list");
    for (const message of messages) {
      list.appendChild(messageCard(message));
    }
    scroll.appendChild(list);
  }

  if (model.nextBefore) {
    const row = element("div", "load-more-row");
    const button = element(
      "button",
      "secondary-button",
      model.loading ? "载入中…" : "载入更早消息"
    );
    button.type = "button";
    button.disabled = model.loading;
    button.addEventListener("click", () => loadMessages(true));
    row.appendChild(button);
    scroll.appendChild(row);
  }
  return scroll;
}

function emptyState(title, copy) {
  const wrapper = element("div", "empty-state");
  const inner = element("div", "empty-state-inner");
  inner.appendChild(element("p", "empty-state-title", title));
  inner.appendChild(element("p", "empty-state-copy", copy));
  wrapper.appendChild(inner);
  return wrapper;
}

function pageHeader() {
  const header = element("header", "page-header");
  const heading = element("div", "page-heading");
  const title = model.route.page === "group" ? model.route.group : "消息收件箱";
  heading.appendChild(element("h1", "page-title", title));
  heading.appendChild(
    element(
      "p",
      "page-subtitle",
      `已加载 ${model.messages.length} 条 · 最新优先 · 仅显示 Mac 实际采集消息`
    )
  );
  header.appendChild(heading);
  const status = element("div", "header-status");
  const listenerStatus = listenerPresentation(model.bootstrap);
  status.appendChild(
    element(
      "span",
      listenerStatus.active ? "live-status" : "listener-status-unknown",
      `● ${listenerStatus.label}`
    )
  );
  status.appendChild(element("span", "", "最新优先"));
  header.appendChild(status);
  return header;
}

function summaryStrip() {
  const strip = element("div", "summary-strip");
  const visibleCount = visibleMessages().length;
  strip.appendChild(element("span", "", "信息概览"));
  const loaded = element("span", "");
  loaded.appendChild(element("strong", "", String(visibleCount)));
  loaded.appendChild(document.createTextNode(" 条符合当前筛选"));
  strip.appendChild(loaded);
  strip.appendChild(element("span", "", `总计已载入 ${model.messages.length} 条`));
  strip.appendChild(element("span", "", model.nextBefore ? "可继续向前分页" : "已到当前历史末端"));
  return strip;
}

function diagnosticsFooter() {
  const footer = element("footer", "workbench-footer");
  const sourceAvailable = Boolean(model.bootstrap.messageSource.available);
  footer.appendChild(
    element(
      "span",
      sourceAvailable ? "footer-ready" : "footer-error",
      sourceAvailable ? "● 消息库可读取" : "● 消息库不可用"
    )
  );
  footer.appendChild(element("span", "", `· 监听群 ${groups().length}`));
  const latest = model.messages[0];
  footer.appendChild(
    element("span", "", latest ? `· 最近消息 ${formatObservedAt(latest.observedAt)}` : "· 尚无最近消息")
  );
  footer.appendChild(element("span", "footer-spacer", model.statusMessage));
  footer.appendChild(element("span", "", "页面可见时自动增量刷新"));
  return footer;
}

function mainWorkbench() {
  const main = element("main", "main-workbench");
  main.appendChild(pageHeader());
  main.appendChild(toolbar());
  main.appendChild(summaryStrip());
  main.appendChild(feed());
  main.appendChild(diagnosticsFooter());
  return main;
}

function readOnlyWorkbench() {
  const main = element("main", "main-workbench");
  const host = element("div", "workspace-page-host");
  main.appendChild(host);
  if (!model.readOnlyPayload) {
    const loading = element("div", "workspace-loading");
    loading.appendChild(element("p", "empty-state-title", "正在读取 Mac 只读数据"));
    host.appendChild(loading);
  } else {
    const page = model.route.readOnlyPage;
    const payload = page.id === "diagnostics"
      ? diagnosticsPayloadWithLiveBootstrap(model.readOnlyPayload, model.bootstrap)
      : model.readOnlyPayload;
    pageCleanup = page.render({
      root: host,
      payload,
      api: { requestJson, copyText },
    });
  }
  const footer = element("footer", "workbench-footer");
  footer.appendChild(element("span", "footer-ready", "● GET / HEAD 只读"));
  footer.appendChild(element("span", "", "· 页面不会修改 Mac 数据"));
  footer.appendChild(element("span", "footer-spacer", model.statusMessage));
  main.appendChild(footer);
  return main;
}

function renderWorkbench() {
  if (!model.bootstrap) {
    return;
  }
  if (typeof pageCleanup === "function") {
    pageCleanup();
    pageCleanup = null;
  }
  const oldScroll = appShell.querySelector(".feed-scroll");
  const scrollTop = oldScroll ? oldScroll.scrollTop : 0;
  appShell.replaceChildren(
    sidebar(),
    model.route.readOnlyPage ? readOnlyWorkbench() : mainWorkbench()
  );
  const newScroll = appShell.querySelector(".feed-scroll");
  if (newScroll) {
    newScroll.scrollTop = scrollTop;
  }
  scheduleListenerFreshnessExpiry();
}

function clearListenerFreshnessExpiry() {
  if (listenerFreshnessTimer !== null) {
    window.clearTimeout(listenerFreshnessTimer);
    listenerFreshnessTimer = null;
  }
}

function scheduleListenerFreshnessExpiry() {
  clearListenerFreshnessExpiry();
  if (!model.authenticated || document.visibilityState !== "visible") {
    return;
  }
  const delay = listenerFreshnessExpiryDelay(model.bootstrap);
  if (delay === null) {
    return;
  }
  listenerFreshnessTimer = window.setTimeout(() => {
    listenerFreshnessTimer = null;
    model.bootstrap = invalidateListenerFreshness(model.bootstrap);
    renderWorkbench();
  }, delay);
}

async function payloadForReadOnlyPage(page) {
  if (page.id === "automations") {
    const responses = await Promise.all([
      requestJson(page.endpoint),
      requestJson("/api/trades"),
      requestJson("/api/settings/status"),
    ]);
    return composeReadOnlyPagePayload(
      page.id,
      responses[0],
      responses[1],
      responses[2]
    );
  }
  if (page.id === "trading") {
    const responses = await Promise.all([
      requestJson(page.endpoint),
      requestJson("/api/settings/status"),
    ]);
    return composeReadOnlyPagePayload(page.id, responses[0], null, responses[1]);
  }
  if (page.id === "diagnostics") {
    const diagnostics = await requestJson(page.endpoint);
    let messages = {
      available: false,
      reason: model.bootstrap.messageSource.reason || "source_unavailable",
      items: [],
    };
    if (model.bootstrap.messageSource.available) {
      try {
        const messagePage = await fetchMessages({ limit: 1 });
        messages = {
          available: true,
          reason: null,
          items: Array.isArray(messagePage.items) ? messagePage.items : [],
        };
      } catch (error) {
        if (error instanceof ApiError && error.status === 401) {
          throw error;
        }
        if (
          (error instanceof ApiError && [0, 503].includes(error.status))
          || error instanceof TypeError
        ) {
          messages = {
            available: false,
            reason: error instanceof ApiError
              ? error.reason || error.code || "message_source_unavailable"
              : "message_source_unavailable",
            items: [],
          };
        } else {
          throw error;
        }
      }
    }
    return composeDiagnosticsPagePayload(diagnostics, messages);
  }
  return requestJson(page.endpoint);
}

function clearReadOnlyRetry() {
  if (readOnlyRetryTimer !== null) {
    window.clearTimeout(readOnlyRetryTimer);
    readOnlyRetryTimer = null;
  }
}

function scheduleReadOnlyRetry(page) {
  clearReadOnlyRetry();
  if (
    !model.authenticated
    || model.route.readOnlyPage !== page
    || document.visibilityState !== "visible"
  ) {
    return;
  }
  const delay = boundedRetryDelay(model.readOnlyRetryAttempt);
  model.readOnlyRetryAttempt += 1;
  readOnlyRetryTimer = window.setTimeout(() => {
    readOnlyRetryTimer = null;
    if (model.route.readOnlyPage === page) {
      loadReadOnlyPage();
    }
  }, delay);
}

async function loadReadOnlyPage() {
  const page = model.route.readOnlyPage;
  if (!page || !model.authenticated) {
    return;
  }
  clearReadOnlyRetry();
  model.requestGeneration += 1;
  const generation = model.requestGeneration;
  model.readOnlyLoading = true;
  model.statusMessage = "正在读取只读数据";
  renderWorkbench();
  try {
    const payload = await payloadForReadOnlyPage(page);
    if (!isCurrentReadOnlyRequest(
      generation,
      model.requestGeneration,
      page,
      model.route.readOnlyPage
    )) {
      return;
    }
    const previous = model.readOnlyPayload;
    model.readOnlyPayload = retainReadOnlyPayload(previous, payload);
    if (isRetriableReadOnlyPayload(payload)) {
      model.statusMessage = "依赖数据源暂不可读，保留已有内容后重试";
      model.statusKind = "error";
      scheduleReadOnlyRetry(page);
    } else {
      model.readOnlyRetryAttempt = 0;
      model.statusMessage = "只读数据已更新";
      model.statusKind = "ready";
    }
  } catch (error) {
    if (!isCurrentReadOnlyRequest(
      generation,
      model.requestGeneration,
      page,
      model.route.readOnlyPage
    )) {
      return;
    }
    if (error instanceof ApiError && error.status === 401) {
      if (!hasSessionToken()) {
        showLogin("访问密码已失效，请重新输入。 ");
      }
      return;
    }
    if (page.id === "diagnostics") {
      const reason = error instanceof ApiError
        ? error.reason || error.code || "source_unavailable"
        : error instanceof TypeError
          ? "network_error"
          : "source_unavailable";
      model.readOnlyPayload = diagnosticsPrimaryFailurePayload(
        model.readOnlyPayload,
        reason
      );
    } else if (!model.readOnlyPayload) {
      model.readOnlyPayload = {
        available: false,
        reason: "source_unavailable",
        items: [],
        retriableErrors: ["source_unavailable"],
      };
    }
    model.statusMessage = "数据源暂不可读";
    model.statusKind = "error";
    scheduleReadOnlyRetry(page);
  } finally {
    if (generation === model.requestGeneration) {
      model.readOnlyLoading = false;
      renderWorkbench();
    }
  }
}

function queryParameters() {
  const parameters = { limit: PAGE_SIZE };
  if (model.route.page === "group") {
    parameters.group = model.route.group;
  }
  if (model.keyword) {
    parameters.q = model.keyword;
  }
  return parameters;
}

function handleRequestError(error) {
  if (error instanceof ApiError && error.status === 401) {
    if (!hasSessionToken()) {
      showLogin("访问密码已失效，请重新输入。 ");
    }
    return;
  }
  model.statusMessage =
    error instanceof ApiError && error.status === 503
      ? "消息库暂不可读，保留现有内容后重试"
      : "刷新失败，保留现有内容";
  model.statusKind = "error";
}

async function loadMessages(older) {
  if (!canLoadMessagePage(model)) {
    return;
  }
  model.loading = true;
  const generation = model.requestGeneration;
  renderWorkbench();
  const parameters = queryParameters();
  if (older && model.nextBefore) {
    parameters.before = model.nextBefore;
  }
  try {
    const payload = await fetchMessages(parameters);
    if (!isCurrentMessageRequest(
      generation,
      model.requestGeneration,
      Boolean(model.route.readOnlyPage)
    )) {
      return;
    }
    const page = applyMessagePage(model, payload, older ? "older" : "replace");
    model.messages = page.messages;
    model.latestCursor = page.latestCursor;
    model.nextBefore = page.nextBefore;
    model.statusMessage = "刷新成功";
    model.statusKind = "ready";
    model.messageRetryAttempt = 0;
    if (!older) {
      model.pendingMessageReplace = false;
    }
  } catch (error) {
    if (!isCurrentMessageRequest(
      generation,
      model.requestGeneration,
      Boolean(model.route.readOnlyPage)
    )) {
      return;
    }
    handleRequestError(error);
    model.messageRetryAttempt += 1;
  } finally {
    if (generation === model.requestGeneration) {
      model.loading = false;
      renderWorkbench();
    }
  }
}

function resetAndLoadMessages() {
  model.requestGeneration += 1;
  const reload = prepareMessageReload(model);
  model.messages = reload.messages;
  model.latestCursor = reload.latestCursor;
  model.nextBefore = reload.nextBefore;
  model.pendingMessageReplace = reload.pendingMessageReplace;
  model.loading = false;
  model.statusMessage = "正在切换筛选，暂时保留上一视图";
  renderWorkbench();
  loadMessages(false);
}

async function pollNewMessages() {
  await runRecurringAttempt(
    () => !(
      model.polling ||
      model.loading ||
      !model.authenticated ||
      document.visibilityState !== "visible" ||
      !model.bootstrap.messageSource.available
    ),
    async () => {
      if (model.pendingMessageReplace) {
        await loadMessages(false);
        return;
      }
      model.polling = true;
      const generation = model.requestGeneration;
      const parameters = queryParameters();
      if (model.latestCursor) {
        parameters.after = model.latestCursor;
      }
      try {
        const payload = await fetchMessages(parameters);
        if (!isCurrentMessageRequest(
          generation,
          model.requestGeneration,
          Boolean(model.route.readOnlyPage)
        )) {
          return;
        }
        const page = applyMessagePage(model, payload, "incremental");
        model.messages = page.messages;
        model.latestCursor = page.latestCursor;
        model.nextBefore = page.nextBefore;
        model.messageRetryAttempt = 0;
        if (page.receivedCount) {
          model.statusMessage = `收到 ${page.receivedCount} 条增量消息`;
          renderWorkbench();
        }
      } catch (error) {
        if (!isCurrentMessageRequest(
          generation,
          model.requestGeneration,
          Boolean(model.route.readOnlyPage)
        )) {
          return;
        }
        handleRequestError(error);
        model.messageRetryAttempt += 1;
        renderWorkbench();
      } finally {
        model.polling = false;
      }
    },
    () => syncPolling()
  );
}

function syncPolling(delay) {
  if (pollTimer !== null) {
    window.clearTimeout(pollTimer);
    pollTimer = null;
  }
  if (
    model.authenticated &&
    !model.route.readOnlyPage &&
    document.visibilityState === "visible"
  ) {
    const resolvedDelay = delay === undefined
      ? boundedRetryDelay(model.messageRetryAttempt, POLL_INTERVAL_MS)
      : delay;
    pollTimer = window.setTimeout(() => {
      pollTimer = null;
      pollNewMessages();
    }, resolvedDelay);
  }
}

function clearBootstrapRefresh() {
  if (bootstrapTimer !== null) {
    window.clearTimeout(bootstrapTimer);
    bootstrapTimer = null;
  }
}

function scheduleBootstrapRefresh() {
  clearBootstrapRefresh();
  if (!model.authenticated || document.visibilityState !== "visible") {
    return;
  }
  const sourceAvailable = model.bootstrap
    && model.bootstrap.messageSource
    && model.bootstrap.messageSource.available === true;
  const delay = sourceAvailable && model.bootstrapRetryAttempt === 0
    ? POLL_INTERVAL_MS
    : boundedRetryDelay(model.bootstrapRetryAttempt, POLL_INTERVAL_MS);
  bootstrapTimer = window.setTimeout(() => {
    bootstrapTimer = null;
    refreshBootstrap();
  }, delay);
}

async function refreshBootstrap() {
  const generation = model.connectionGeneration;
  try {
    const bootstrap = await fetchBootstrap();
    if (!isCurrentConnection(generation, model.connectionGeneration) || !model.authenticated) {
      return;
    }
    const wasAvailable = model.bootstrap.messageSource.available === true;
    model.bootstrap = retainMessageBootstrap(model.bootstrap, bootstrap);
    const isAvailable = bootstrap.messageSource.available === true;
    model.bootstrapRetryAttempt = isAvailable ? 0 : model.bootstrapRetryAttempt + 1;
    if (!isAvailable) {
      model.statusMessage = "消息源暂不可读，保留已有内容后退避重试";
      model.statusKind = "error";
    }
    renderWorkbench();
    if (!wasAvailable && isAvailable && !model.route.readOnlyPage) {
      await loadMessages(false);
      syncPolling(POLL_INTERVAL_MS);
    }
  } catch (error) {
    if (!isCurrentConnection(generation, model.connectionGeneration) || !model.authenticated) {
      return;
    }
    if (error instanceof ApiError && error.status === 401) {
      if (!hasSessionToken()) {
        showLogin("访问密码已失效，请重新输入。");
      }
      return;
    }
    model.bootstrapRetryAttempt += 1;
    model.bootstrap = invalidateListenerFreshness(model.bootstrap);
    model.statusMessage = "连接状态暂不可读，保留已有内容";
    model.statusKind = "error";
    renderWorkbench();
  } finally {
    if (isCurrentConnection(generation, model.connectionGeneration) && model.authenticated) {
      scheduleBootstrapRefresh();
    }
  }
}

function showLogin(message) {
  model.connectionGeneration += 1;
  model.requestGeneration += 1;
  model.authenticated = false;
  model.bootstrap = null;
  Object.assign(model, resetMessageSession());
  model.readOnlyPayload = null;
  model.readOnlyLoading = false;
  model.messageRetryAttempt = 0;
  model.bootstrapRetryAttempt = 0;
  model.readOnlyRetryAttempt = 0;
  if (typeof pageCleanup === "function") {
    pageCleanup();
    pageCleanup = null;
  }
  clearBootstrapRefresh();
  clearListenerFreshnessExpiry();
  clearReadOnlyRetry();
  syncPolling();
  appShell.hidden = true;
  loginView.hidden = false;
  loginError.textContent = message || "";
  tokenInput.value = "";
  tokenInput.focus();
}

async function connect() {
  model.connectionGeneration += 1;
  const generation = model.connectionGeneration;
  loginError.textContent = "";
  try {
    const bootstrap = await fetchBootstrap();
    if (!isCurrentConnection(generation, model.connectionGeneration)) {
      return;
    }
    model.bootstrap = bootstrap;
    model.authenticated = true;
    model.bootstrapRetryAttempt = bootstrap.messageSource.available === true ? 0 : 1;
    model.route = appRouteFromHash(window.location.hash);
    loginView.hidden = true;
    appShell.hidden = false;
    renderWorkbench();
    syncPolling();
    scheduleBootstrapRefresh();
    if (model.route.readOnlyPage) {
      await loadReadOnlyPage();
    } else {
      await loadMessages(false);
    }
  } catch (error) {
    if (!isCurrentConnection(generation, model.connectionGeneration)) {
      return;
    }
    if (error instanceof ApiError && error.status === 401 && hasSessionToken()) {
      return;
    }
    showLogin(error instanceof ApiError && error.status === 401
      ? "访问密码不正确，请重新输入。"
      : "无法连接 Mac 只读服务，请稍后重试。"
    );
  }
}

tokenForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = tokenForm.querySelector("button[type='submit']");
  button.disabled = true;
  try {
    authenticate(tokenInput.value);
    await connect();
  } catch (_error) {
    loginError.textContent = "请输入访问密码。";
  } finally {
    button.disabled = false;
  }
});

window.addEventListener("hashchange", () => {
  const route = appRouteFromHash(window.location.hash);
  if (
    route.page === model.route.page &&
    (route.page !== "group" || route.group === model.route.group)
  ) {
    return;
  }
  clearReadOnlyRetry();
  model.readOnlyRetryAttempt = 0;
  model.readOnlyPayload = null;
  model.route = route;
  syncPolling();
  if (route.readOnlyPage) {
    loadReadOnlyPage();
  } else {
    resetAndLoadMessages();
  }
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    model.bootstrap = invalidateListenerFreshness(model.bootstrap);
    renderWorkbench();
    syncPolling(POLL_INTERVAL_MS);
    scheduleBootstrapRefresh();
    if (model.route.readOnlyPage) {
      loadReadOnlyPage();
    }
  } else {
    syncPolling(POLL_INTERVAL_MS);
    clearBootstrapRefresh();
    clearListenerFreshnessExpiry();
    clearReadOnlyRetry();
  }
});

if (hasSessionToken()) {
  connect();
} else {
  showLogin("");
}
