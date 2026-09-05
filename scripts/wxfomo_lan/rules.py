"""Read-only, deterministic message rules mirrored from RecommendedMessageRules.swift."""

import re
import unicodedata


RULE_CATALOG_VERSION = 1
RISK_KEYWORDS = (
    "貔貅", "honeypot", "rug", "撤池", "跑路", "黑名单",
    "冻结权限", "增发", "mint权限", "卖不掉",
)
EXIT_KEYWORDS = ("砸盘", "清仓", "出货", "割肉", "止损", "撤退")
ACCUMULATION_KEYWORDS = (
    "聪明钱", "smart money", "大额买入", "加仓", "建仓", "扫货",
    "重仓", "看好", "吸筹", "抄底",
)

_BARE_ADDRESS = (
    re.compile(r"^\s*0x[a-fA-F0-9]{40}\s*$"),
    re.compile(r"^\s*[1-9A-HJ-NP-Za-km-z]{32,44}\s*$"),
)
_MARKET_REPORT = re.compile(
    r"(?:MC:|体重：|血量：)[\s\S]{0,800}"
    r"(?:LP:|深度：|流动：|池子：|地址[:：]|副本：|链:)"
)


def _keyword_matcher(keywords):
    def match(_normalized, folded):
        return [term for term in keywords if term.casefold() in folded]
    return match


def _regex_matcher(patterns):
    compiled = tuple(re.compile(pattern) for pattern in patterns)

    def match(normalized, _folded):
        terms = []
        for pattern in compiled:
            found = pattern.search(normalized)
            if found:
                terms.append(found.group(0).strip())
        return terms
    return match


def _rule(rule_id, name, priority, keywords=None, patterns=None, tag=None, severity=None):
    return {
        "ruleId": rule_id,
        "name": name,
        "priority": priority,
        "keywords": tuple(keywords or ()),
        "regularExpressions": tuple(patterns or ()),
        "tag": tag,
        "severity": severity,
        "matcher": _keyword_matcher(keywords) if keywords else _regex_matcher(patterns),
    }


RULE_CATALOG = (
    _rule("recommended.risk.contract-liquidity", "风险｜合约与流动性危险", 50,
          RISK_KEYWORDS, tag="高风险", severity="critical"),
    _rule("recommended.signal.exit", "退出｜砸盘与清仓信号", 40,
          EXIT_KEYWORDS, tag="退出信号", severity="warning"),
    _rule("recommended.signal.accumulation", "资金｜明确买入与看多信号", 30,
          ACCUMULATION_KEYWORDS, tag="资金信号", severity="warning"),
    _rule("recommended.capture.bare-ca", "CA｜裸地址重点捕捉", 20,
          patterns=(r"^\s*0x[a-fA-F0-9]{40}\s*$",
                    r"^\s*[1-9A-HJ-NP-Za-km-z]{32,44}\s*$"), tag="CA"),
    _rule("recommended.capture.market-report", "Meme｜结构化行情播报", 10,
          patterns=(r"(?:MC:|体重：|血量：)[\s\S]{0,800}(?:LP:|深度：|流动：|池子：|地址[:：]|副本：|链:)",),
          tag="行情播报"),
)


def _evaluation_payload(matches):
    matched_rules = []
    tags = []
    terms = []
    priority = None
    severity = None
    severity_rank = {None: 0, "warning": 1, "critical": 2}
    for rule, rule_terms in matches:
        matched_rules.append({
            "ruleId": rule["ruleId"],
            "name": rule["name"],
            "priority": rule["priority"],
        })
        priority = rule["priority"] if priority is None else max(priority, rule["priority"])
        if rule["tag"] and rule["tag"] not in tags:
            tags.append(rule["tag"])
        for term in rule_terms:
            if term and term not in terms:
                terms.append(term)
        if severity_rank[rule["severity"]] > severity_rank[severity]:
            severity = rule["severity"]
    return {
        "matchedRules": matched_rules,
        "tags": tags,
        "priority": priority,
        "severity": severity,
        "matchedTerms": terms,
    }


def evaluate_message(content):
    normalized = unicodedata.normalize("NFC", content or "")
    folded = normalized.casefold()
    matches = []
    for rule in RULE_CATALOG:
        rule_terms = rule["matcher"](normalized, folded)
        if rule_terms:
            matches.append((rule, rule_terms))
    return _evaluation_payload(matches)


def rules_payload():
    items = []
    for rule in RULE_CATALOG:
        condition = {
            "includeKeywords": list(rule["keywords"]),
            "regularExpressions": list(rule["regularExpressions"]),
        }
        actions = [{"type": "capture"}]
        if rule["tag"]:
            actions.append({"type": "add_tag", "tag": rule["tag"]})
        if rule["severity"]:
            actions.append({"type": "local_alert", "severity": rule["severity"], "title": rule["name"]})
        items.append({
            "ruleId": rule["ruleId"], "name": rule["name"], "priority": rule["priority"],
            "condition": condition, "actions": actions, "isEnabled": True,
        })
    return {"available": True, "reason": None, "items": items, "invalidRows": 0}
