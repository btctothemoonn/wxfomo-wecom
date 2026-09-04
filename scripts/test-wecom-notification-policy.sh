#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
policy="$repo_root/Sources/WxFomoCore/WeComNotificationPolicy.swift"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wxfomo-wecom-policy-test.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

/bin/cat > "$fixture_dir/main.swift" <<'SWIFT'
import Foundation

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

check(
  WeComNotificationPolicy.isNotificationIdentifier("com.tencent.WeWorkMac"),
  "direct WeCom identifier"
)
check(
  WeComNotificationPolicy.applicationBundleIdentifier == "com.tencent.WeWorkMac",
  "case-preserving WeCom application bundle identifier"
)
check(
  WeComNotificationPolicy.isNotificationIdentifier("88L2Q4487U.com.tencent.WeWorkMac"),
  "Team-prefixed WeCom identifier"
)
check(
  WeComNotificationPolicy.isNotificationIdentifier(
    "  88l2q4487u.COM.TENCENT.WEWORKMAC  \n"
  ),
  "identifier normalization"
)
check(
  !WeComNotificationPolicy.isNotificationIdentifier("com.tencent.xinWeChat"),
  "personal WeChat must be rejected"
)
check(
  !WeComNotificationPolicy.isNotificationIdentifier(
    "OTHERTEAM.com.tencent.WeWorkMac"
  ),
  "unknown Team ID must be rejected"
)

let policy = WeComNotificationPolicy()
let groupMessage = policy.groupMessage(
  title: "项目群",
  subtitle: "",
  body: "张三：测试消息",
  configuredGroups: ["项目群", "其他群"]
)
check(groupMessage?.group == "项目群", "configured group match")
check(groupMessage?.sender == "张三", "group sender prefix")
check(groupMessage?.content == "测试消息", "group content without sender prefix")

let suffixedTitle = policy.groupMessage(
  title: "项目群 (3条新消息)",
  subtitle: "",
  body: "李四: 已完成",
  configuredGroups: ["项目群"]
)
check(suffixedTitle == nil, "unverified group title suffix must fail closed")

let groupInSubtitle = policy.groupMessage(
  title: "王五",
  subtitle: "项目群",
  body: "已完成",
  configuredGroups: ["项目群"]
)
check(groupInSubtitle?.group == "项目群", "group in subtitle")
check(groupInSubtitle?.sender == "王五", "sender in title")
check(groupInSubtitle?.content == "已完成", "body with field sender")

check(
  policy.groupMessage(
    title: "联系人张三",
    subtitle: "",
    body: "普通单聊消息",
    configuredGroups: ["项目群"]
  ) == nil,
  "direct message must be rejected"
)
check(
  policy.groupMessage(
    title: "项目群客服",
    subtitle: "",
    body: "张三：普通单聊消息",
    configuredGroups: ["项目群"]
  ) == nil,
  "group-name substring in a direct-chat title must be rejected"
)
check(
  policy.groupMessage(
    title: "项目群（客服）",
    subtitle: "",
    body: "张三：普通单聊消息",
    configuredGroups: ["项目群"]
  ) == nil,
  "parenthesized direct-chat title must be rejected"
)
check(
  policy.groupMessage(
    title: "项目群",
    subtitle: "",
    body: "张三：群消息",
    configuredGroups: ["项目群", "项目 群"]
  )?.group == "项目群",
  "internal whitespace must keep configured groups distinct"
)
check(
  policy.groupMessage(
    title: "  Café  ",
    subtitle: "张三",
    body: "消息",
    configuredGroups: ["Café"]
  )?.group == "Café",
  "outer whitespace and canonical Unicode equivalence"
)
check(
  policy.groupMessage(
    title: "alpha",
    subtitle: "张三",
    body: "CASE_PRIVATE",
    configuredGroups: ["Alpha"]
  ) == nil,
  "group names must remain case-sensitive"
)
check(
  policy.groupMessage(
    title: "Cafe",
    subtitle: "张三",
    body: "DIACRITIC_PRIVATE",
    configuredGroups: ["Café"]
  ) == nil,
  "group names must preserve diacritics"
)
check(
  policy.groupMessage(
    title: "项目群",
    subtitle: "张三",
    body: "SPACE_PRIVATE",
    configuredGroups: ["项目 群"]
  ) == nil,
  "group names must preserve internal whitespace"
)
check(
  policy.groupMessage(
    title: "项目​群",
    subtitle: "张三",
    body: "ZERO_WIDTH_PRIVATE",
    configuredGroups: ["项目群"]
  ) == nil,
  "group names must preserve internal zero-width characters"
)
check(
  policy.groupMessage(
    title: "项目群",
    subtitle: "张三",
    body: "李四：冲突消息",
    configuredGroups: ["项目群"]
  ) == nil,
  "conflicting sender fields must fail closed"
)
check(
  policy.groupMessage(
    title: "未配置群",
    subtitle: "",
    body: "张三：群消息",
    configuredGroups: ["项目群"]
  ) == nil,
  "unconfigured group must be rejected"
)
check(
  policy.groupMessage(
    title: "项目群",
    subtitle: "",
    body: "缺少发送者前缀",
    configuredGroups: ["项目群"]
  ) == nil,
  "ambiguous notification must fail closed"
)
check(
  policy.groupMessage(
    title: "项目群",
    subtitle: "",
    body: "https://example.com",
    configuredGroups: ["项目群"]
  ) == nil,
  "URL scheme must not be mistaken for an ASCII sender prefix"
)

let candidates = NotificationDatabaseLocation.candidates(
  homeDirectory: "/tmp/wxfomo-home",
  darwinUserDirectory: "/tmp/wxfomo-darwin/"
)
check(
  candidates.map { $0.path } == [
    "/tmp/wxfomo-home/Library/Group Containers/group.com.apple.usernoted/db2/db",
    "/tmp/wxfomo-darwin/com.apple.notificationcenter/db2/db",
  ],
  "macOS 14 and macOS 13 database candidates"
)
let selected = NotificationDatabaseLocation.resolve(
  homeDirectory: "/tmp/wxfomo-home",
  darwinUserDirectory: "/tmp/wxfomo-darwin/",
  fileExists: { $0.hasPrefix("/tmp/wxfomo-darwin/") },
  isReadable: { _ in true }
)
check(
  selected.path == "/tmp/wxfomo-darwin/com.apple.notificationcenter/db2/db",
  "fallback to the existing Darwin user database"
)
let selectedReadable = NotificationDatabaseLocation.resolve(
  homeDirectory: "/tmp/wxfomo-home",
  darwinUserDirectory: "/tmp/wxfomo-darwin/",
  fileExists: { _ in true },
  isReadable: { $0.hasPrefix("/tmp/wxfomo-darwin/") }
)
check(
  selectedReadable.path == "/tmp/wxfomo-darwin/com.apple.notificationcenter/db2/db",
  "skip an existing but unreadable group-container database"
)

if failures.isEmpty {
  print("PASS: WeCom notification policy")
} else {
  for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
  exit(1)
}
SWIFT

swiftc \
  "$policy" \
  "$repo_root/Sources/WxFomoCore/NotificationDatabaseLocation.swift" \
  "$fixture_dir/main.swift" \
  -lsqlite3 \
  -o "$fixture_dir/wecom-policy-test" \
  || fail "could not compile the production WeCom policy"
"$fixture_dir/wecom-policy-test"
