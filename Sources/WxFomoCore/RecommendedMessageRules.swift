import Foundation

public enum RecommendedMessageRuleCatalog {
  public static let rules: [MessageRule] = [
    MessageRule(
      id: "recommended.risk.contract-liquidity",
      name: "风险｜合约与流动性危险",
      priority: 50,
      condition: MessageRuleCondition(
        includeKeywords: [
          "貔貅", "honeypot", "rug", "撤池", "跑路", "黑名单",
          "冻结权限", "增发", "mint权限", "卖不掉",
        ]
      ),
      actions: [
        .capture,
        .addTag("高风险"),
        .localAlert(severity: .critical, title: "风险｜合约与流动性危险"),
      ]
    ),
    MessageRule(
      id: "recommended.signal.exit",
      name: "退出｜砸盘与清仓信号",
      priority: 40,
      condition: MessageRuleCondition(
        includeKeywords: ["砸盘", "清仓", "出货", "割肉", "止损", "撤退"]
      ),
      actions: [
        .capture,
        .addTag("退出信号"),
        .localAlert(severity: .warning, title: "退出｜砸盘与清仓信号"),
      ]
    ),
    MessageRule(
      id: "recommended.signal.accumulation",
      name: "资金｜明确买入与看多信号",
      priority: 30,
      condition: MessageRuleCondition(
        includeKeywords: [
          "聪明钱", "smart money", "大额买入", "加仓", "建仓", "扫货",
          "重仓", "看好", "吸筹", "抄底",
        ]
      ),
      actions: [
        .capture,
        .addTag("资金信号"),
        .localAlert(severity: .warning, title: "资金｜明确买入与看多信号"),
      ]
    ),
    MessageRule(
      id: "recommended.capture.bare-ca",
      name: "CA｜裸地址重点捕捉",
      priority: 20,
      condition: MessageRuleCondition(
        regularExpressions: [
          #"^\s*0x[a-fA-F0-9]{40}\s*$"#,
          #"^\s*[1-9A-HJ-NP-Za-km-z]{32,44}\s*$"#,
        ]
      ),
      actions: [.capture, .addTag("CA")]
    ),
    MessageRule(
      id: "recommended.capture.market-report",
      name: "Meme｜结构化行情播报",
      priority: 10,
      condition: MessageRuleCondition(
        regularExpressions: [
          #"(?:MC:|体重：|血量：)[\s\S]{0,800}(?:LP:|深度：|流动：|池子：|地址[:：]|副本：|链:)"#
        ]
      ),
      actions: [.capture, .addTag("行情播报")]
    ),
  ]
}
