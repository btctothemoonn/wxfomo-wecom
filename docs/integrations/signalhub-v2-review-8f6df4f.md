# SignalHub v2：Mac 审阅与离线验证回执

日期：2026-09-06。范围：只读审阅、合成样例离线校验。没有实现发送器、接收器或启用真实同步。

## 版本与结论

- Signal：`btctothemoonn/SIgnal-hub`，main 指定提交 `8f6df4f9e8ed7812ba06f6b92b481ca12f5c0939`。
- 对照 Mac 发布提交：`dc259a93ab41a8b00f64a638a5a3ab0c762ffb95`；本地基线 `cdcab99366dc6266a915c389d78b291fc8430644`，树 `a155eb014eac02afb61d0c1d66524cf51761c8c3` 与该发布版本一致。
- 审阅分支：`codex/wecom-notification-probe`。本回执的提交号由 Git 提交记录给出；本轮不自动推送、合并或部署。
- 已完整读取指定版本的 [README](https://github.com/btctothemoonn/SIgnal-hub/blob/8f6df4f9e8ed7812ba06f6b92b481ca12f5c0939/docs/integrations/wecom-summary/README.md)、[V2-COMPATIBILITY](https://github.com/btctothemoonn/SIgnal-hub/blob/8f6df4f9e8ed7812ba06f6b92b481ca12f5c0939/docs/integrations/wecom-summary/V2-COMPATIBILITY.md) 及全部七个 `*.example.json`（其中一个文件包含三类签名向量）。

**结论：上传字段与主要行为已对齐，没有发现需重新设计 payload 的冲突；发现一处市场报告样例的去重语义不一致，修正并重签后才可作为统一的合成基准。签名算法本身验证通过。**

## 1. 需要 Signal 修正的样例

位置：[report.example.json](https://github.com/btctothemoonn/SIgnal-hub/blob/8f6df4f9e8ed7812ba06f6b92b481ca12f5c0939/docs/integrations/wecom-summary/report.example.json)，sourceReferences 第 124/131 行，caDiscussions 第 151–153 行。

该样例只有两条可读来源，昵称分别为“小林（合成昵称）”和“小周（合成昵称）”；CA mentionCount=2，而 uniqueStatementCount=1、duplicateCount=1。

Mac `cross_ca.py:cross_ca_cards` 的去重键是 `(昵称或事件键, NFC/空白/EVM大小写归一后的正文)`。在本样例中，全部两条可读消息都必须贡献这两次 CA 提及，即使两段正文完全相同，不同昵称也产生两条去重陈述。因此当前 1/1 不能由该算法与所给来源元数据同时产生。

用现有 Mac 纯函数进行了单变量合成对照，没有读取聊天正文：

| 两条合成来源 | mentionCount | uniqueStatementCount | duplicateCount |
| --- | --- | --- | --- |
| 同一地址、相同合成正文、两个不同昵称 | 2 | 2 | 0 |
| 仅将第二条昵称改成与第一条相同 | 2 | 1 | 1 |
| Signal 市场报告当前声明（不同昵称） | 2 | 1 | 1 |

建议保持既有 Mac 去重规则及样例不同昵称不变，把市场报告的两个计数改为 **2/0**；随后重新生成 signature.example.json 中 **report** 向量的 body/bodySha256/signature。CA 提醒样例不提供昵称，其 1/1 仍可对应同一昵称搬运，不需要据此一起更改；另外两类签名也不因报告改动而必然变化。

这里的“2 条去重陈述”仍不表示“2 次独立证实”，报告中“不构成独立证实”的风险说明可以保留。另一种合法合成方案是同时调整报告所有身份与归属，使两条来源确为同一昵称；无论选哪种，都不能只改数字而不重签。

本轮按审阅边界保留原七个固定版本样例，未替 Signal 修改样例或 Mac 生产规则。

## 2. 接受的明确化与 Mac 后续适配

以下与产品要求一致，不需要重新询问用户默认参数：

- 规范 network 与 briefing 的原样 chain 分离；原样 CA 不随内部 EVM 匹配键转小写。
- expired 可以由消息归并/修订提前发生，不要求 evaluatedAt 已经过 expiresAt；关闭后的同 episode 不复活。
- firstReceivedAt/syncedAt/effectiveStatus/delayed 是服务器读取字段，不能进入上传白名单；同 episode 首收时间不可重设。
- GET /api/wecom/status 与列表共用本人授权状态；退出登录清空浏览器内存缓存，网络故障保留缓存只适用于当前授权会话。
- 单管理员空间必须为本人独占；多账号 ACL 未完成是网站上线前置条件，不要求 Mac 添加 owner 或改变 payload。
- 三类向量验证原始字节，ACK 不增加 type 字段，依靠固定请求上下文和 typed 存储键关联。
- 端到端 60 秒需合成源入库、检测、接收和浏览器显示联合测量；仅 triggeredAt 到 firstReceivedAt 不能证明全部延迟。
- 八字段 heartbeat 没有独立隔离/漏检数字，先用固定错误码表示，不能塞入 lastError 自由文本或擅自增字段。

Mac 现有实施计划有两处需要在下一阶段更新，但不是 Signal 上传格式错误：

1. Task 2 的示例测试仍取签名文件顶层 body/device/timestamp/nonce/signature；Signal v2 已是顶层 secret 加 vectors 数组。应循环每个 vector，secret 取顶层，body 与 fixture 文件的规范序列化字节逐项比对。不要要求 Signal 改回单向量格式。
2. 原 Task 2 将一般 400 归为单项隔离；应先识别 `400 unsupported_schema`，持久暂停该 schemaVersion 的发送并回报，保留队列，不继续隔离整批积压，也不回退 v1。认证暂停/限流与版本暂停的范围需分别测试。

本轮没有修改已批准计划中的功能代码，也未创建任何生产 signal_contract/signal_transport 模块；以上只作为后续最小修订项。

## 3. 实际离线结果

环境：Python 3.7.3、Node v14.18.0。仅使用标准库和已有 Mac 纯函数。

| 检查 | 结果与边界 |
| --- | --- |
| 固定版本样例完整性 | 7/7 原始字节 Git blob SHA 一致，清单保存在 fixtures manifest |
| 正文样例 | 市场、业务、active/expired/catchup CA、八字段心跳共 6/6 通过结构、引用闭包、长度与计数等式检查 |
| 完整 briefing | 两份报告通过当前 Mac validate_briefing；地址证据由合成字面值构造，不代表核验真实消息 |
| Python 签名 | report/ca_alert/heartbeat 的规范 UTF-8 字节、SHA256、HMAC 全部 3/3 一致 |
| Node 独立签名 | 三类同样 3/3 一致；不读取 Python 计算结果作为期待值 |
| 非法变体 | 24 个变体被拒绝：v1、布尔冒充整数、原文键、错误缺口/完整性、伪造缺失身份、悬空编号、错误计数、无引用结论、非法 Unicode/控制字符、超长文本、unknown 实时链、重复群、catchup 发新提示、服务器字段回传等 |
| 其他边界 | 600 个补充平面字符、原样 CA 大小写证据保护、重复 JSON 键拒绝、提前关闭、关闭快照保持、昵称去重 A/B 对照均通过 |
| 来源语义 | **1 项未通过：上节报告样例的 1/1 与不同昵称不一致** |

复现命令（仓库根目录）：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m scripts.check_signalhub_v2_handoff
node scripts/check-signalhub-v2-signatures.mjs
```

Python 检查器在固定 8f6df4f 样例上有意以 **exit 1** 报出仍存在的来源语义问题，不能把结构部分 PASS 写成“全部通过”。Node 签名检查 **exit 0**。检查器不被现有 `test_wxfomo_*.py` 自动测试集合收集，不引入已知失败的生产回归测试。

脚本是针对此次合成材料的审阅工具，不是未来线上严格校验器或安全审计：不证明原文依据、权限、重放事务、幂等数据库、调度、并发、资源上限或网页表现。没有运行全套无关测试、接收器或浏览器联调。

## 4. 下一阶段最小范围与状态

先由 Signal 修正市场报告计数和对应签名，回传新的文档/样例提交；Mac 只复核该差异及全部签名，不重做全盘审阅。之后可按已确认方案先实现离线 v2 校验、独立 outbox 与签名发送，再接只读报告导出与实时 CA。必须分开报告以下状态：

| 状态 | 本轮结果 |
| --- | --- |
| 协议对齐 | 字段与主语义已对齐；统一合成基准仍有 1 项待修正 |
| 代码实现 | 仅新增离线审阅工具和固定样例，没有同步/接收功能实现 |
| 合成联调 | 本地材料验证已做；两端接收器与浏览器端到端未做 |
| 真实同步启用 | 未启用，未部署，未配置真实凭证，未安装 LaunchAgent |

本轮既未读取/改写真实数据库或 relay 边界，也未访问生产写入口、调用付费模型或发送真实/历史消息。运行服务与 AI 周期保持不变。
