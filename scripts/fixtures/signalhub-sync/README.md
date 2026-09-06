# Mac v2 合成候选样例

基于 Signal `8f6df4f9e8ed7812ba06f6b92b481ca12f5c0939`。
仅把市场报告 `uniqueStatementCount/duplicateCount` 修正为 `2/0`，以匹配样例的两个不同昵称；重新计算 report 签名。正文结构、其余两类载荷不变。

这是 Mac 的候选修正，不代表 Signal 已合并。原始样例完整保存在相邻 `signalhub-v2-handoff-8f6df4f/`，不得覆盖其固定版本证据。
`signature.json` 三类向量由 Node 标准库生成，由 Python 生产签名函数独立复算；secret 和固定时间仅供离线测试，不能作为生产配置或发送至网站。

真实源库、凭证、聊天正文均未用于生成这些样例。协议校验只能确认结构/引用闭包，不能证明来源内容。
