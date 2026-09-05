# 群消息总结精简版 Implementation Plan

> 执行方式：按用户省额度的要求，在当前任务内执行，避免多轮代理和重复全盘扫描。

**Goal:** 保留消息监听、搜索、发言人归因、MiniMax 定时总结与跨群 CA 摘要，移除交易和行情平台。

**Architecture:** 延用独立 Swift 通知监听器和 Python 只读网页服务。消息库和分析库路径不变；网页不再依赖原生 workspace.sqlite3。总结页使用原有 AI 结果与冻结消息来源，不新建行情服务。

**Tech Stack:** macOS Swift 5.2、Python 3.7 标准库、原生 JavaScript。

**Spec:** 本对话中用户已批准的精简范围与“覆盖全部 7 群”；历史消息不变。

## Global Constraints

- 不修改、删除或迁移用户消息库、密钥、报告；relay 生效行号不变。
- 保留 HTTPS 凭据安全、页面只读认证、通知去重、来源验证和重试。
- 精简前建立含当前未提交改动的 Git 检查点和回退分支。
- 不切换 MiniMax、不接行情/钱包/交易，不自动重跑历史 AI 报告。

### Task 1: 移除未用网页和旧工作区接口

**Files:** scripts/wxfomo_lan/server.py、web/wxfomo-lan/{pages,state,app}.mjs、对应 Python/JS 测试。

- [x] 添加失败测试：交易、行情、语音页面不注册；四个旧 API GET 返回 404；设置/诊断只读本机分析库。
- [x] 运行 `python3 -m unittest scripts.test_wxfomo_lan_server.LanServerTests.test_summary_lite_has_no_market_or_trading_apis` 和前端测试，观察 FAIL。
- [x] 移除 WorkspaceRepository 依赖和旧路由；删除已废弃的页面函数、组合请求和专属测试；保留现用消息/总结/规则安全测试。
- [x] 同样命令 PASS；现用分析端到端测试 PASS。

### Task 2: 清理原生 App 遗留

**Files:** Sources/、Package.swift、原生 App 专用脚本、scripts/wxfomo_lan/workspace.py、README.md、AGENTS.md。

- [x] 核对独立监听器未导入 Sources；列出依赖原生 Sources 的测试及构建脚本。
- [x] 从精简版工作树移除原生 App 和只针对它的测试；完整版本保留在回退分支。
- [x] README 只写当前启动、监控、总结、权限和恢复步骤；AGENTS.md 列出最短入口，减少后续重复读取。
- [x] 验证启动脚本只需要现存文件；现用 Python/前端安全回归通过。

### Task 3: 跨群 CA 摘要与交付

**Files:** 总结来源聚合模块、analysis.py、pages.mjs、对应测试。

- [x] 合成测试覆盖：同 CA 多群同作者同文计重复传播；不同链不合并；未知链标待确认；每卡有原文引用。
- [x] 在现有周期总结内展示统计与已有 AI 地址讨论摘要；不调用交易/行情 API。
- [x] 先跑新增用例，再统一运行现用 Python/前端完整回归。
- [x] 精确重启原 launcher，认证 API 核对 7 群、原消息/历史报告、配置状态和旧入口 404。
- [x] 报告实际减少的文件/行数、回退版本、跨群 CA 的实际验收情况。

## 验收结果（2026-09-05）

- 已有 69 个旧文件移除，主要为原生 App、旧工作区和专用测试；回退分支 codex/pre-summary-lite-20260905。
- Python 完整 200 项通过；随后新增空闲日志静默测试，相关 worker 模块 25 项通过。前端及 launcher-readiness 三项检查通过。
- 重启后认证 API：7 群 active、analysis worker active、MiniMax 已配置；旧行情/交易 404；未认证 401；POST 405。
- 原有 13,526 条消息逐行摘要校验一致；两份历史 result_json 校验一致；relay afterRowId 仍为 13193。
- 2h/6h 已有成功报告及来源完整的 CA 卡片。24h 既有 transport_error 失败记录未重新调用 AI。
- /api/analyses 本机约 0.32 秒。统计每份冻结窗口完整集合，展示最近 30 个任务，每份最多 50 张卡。
- 内置浏览器两次导航超时，视觉验收未完成；静态前端自动测试和真实 API/数据库链路已验证。未宣称完整浏览器验收通过。
- 当前服务由 scripts/start-wxfomo-lan.sh --allow-lan 运行，地址 http://192.168.3.209:8765/ 。本次未推送或合并。
