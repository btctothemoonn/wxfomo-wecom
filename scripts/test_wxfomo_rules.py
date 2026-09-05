import unittest

from scripts.wxfomo_lan.rules import evaluate_message, rules_payload


class RuleTests(unittest.TestCase):
    def test_risk_and_accumulation_can_both_match(self):
        result = evaluate_message("聪明钱加仓，但合约是 HONEYPOT，卖不掉")
        self.assertEqual(result["tags"], ["高风险", "资金信号"])
        self.assertEqual(result["priority"], 50)
        self.assertEqual(result["severity"], "critical")
        self.assertEqual(
            [item["ruleId"] for item in result["matchedRules"]],
            [
                "recommended.risk.contract-liquidity",
                "recommended.signal.accumulation",
            ],
        )

    def test_bare_addresses_require_the_whole_body(self):
        self.assertEqual(evaluate_message("0x" + "a" * 40)["tags"], ["CA"])
        self.assertNotIn("CA", evaluate_message("看这个 0x" + "a" * 40)["tags"])

    def test_market_report_and_chatter_boundaries(self):
        self.assertEqual(
            evaluate_message("MC: $2m\nLP: $100k\n地址：abc")["tags"],
            ["行情播报"],
        )
        self.assertEqual(evaluate_message("今天天气不错")["matchedRules"], [])

    def test_payload_exposes_exact_five_read_only_rules(self):
        payload = rules_payload()
        self.assertTrue(payload["available"])
        self.assertEqual(len(payload["items"]), 5)
        self.assertEqual(
            [item["priority"] for item in payload["items"]], [50, 40, 30, 20, 10]
        )


if __name__ == "__main__":
    unittest.main()
