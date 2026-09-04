import Foundation

public enum CryptoAddressNetwork: String, Codable, CaseIterable, Sendable {
  case ethereum
  case base
  case bsc
  case arbitrum
  case polygon
  case optimism
  case avalanche
  case robinhood
  case evm
  case solana

  public var displayName: String {
    switch self {
    case .ethereum: return "Ethereum"
    case .base: return "Base"
    case .bsc: return "BSC"
    case .arbitrum: return "Arbitrum"
    case .polygon: return "Polygon"
    case .optimism: return "Optimism"
    case .avalanche: return "Avalanche"
    case .robinhood: return "Robinhood"
    case .evm: return "待识别 EVM"
    case .solana: return "Solana"
    }
  }
}

public enum CryptoAddressRoleHint: String, Codable, CaseIterable, Sendable {
  case contractOrToken = "contract_or_token"
  case wallet
  case ambiguous
  case unknown
}

public enum CryptoAddressFamily: String, Codable, CaseIterable, Hashable, Sendable {
  case evm
  case solana
}

/// A locally detected address-shaped value. This does not prove that the address exists on-chain.
public struct CryptoAddressMatch: Equatable, Hashable, Identifiable, Sendable {
  public let address: String
  public let normalizedAddress: String
  public let family: CryptoAddressFamily
  /// The network supported by local message context, or the family fallback when it is unknown.
  public let network: CryptoAddressNetwork

  public var id: String { "\(family.rawValue):\(network.rawValue):\(normalizedAddress)" }

  public init(
    address: String,
    normalizedAddress: String,
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil
  ) {
    self.address = address
    self.normalizedAddress = normalizedAddress
    self.family = family
    self.network = network ?? (family == .solana ? .solana : .evm)
  }

  public func resolvingNetwork(_ network: CryptoAddressNetwork) -> CryptoAddressMatch {
    CryptoAddressMatch(
      address: address,
      normalizedAddress: normalizedAddress,
      family: family,
      network: network
    )
  }
}

/// Deterministic address evidence derived only from the frozen local messages.
public struct CryptoAddressEvidence: Codable, Equatable, Identifiable, Sendable {
  public let address: String
  public let normalizedAddress: String
  public let network: CryptoAddressNetwork
  public let roleHint: CryptoAddressRoleHint
  public let occurrenceCount: Int
  public let directSourceMessageIDs: [String]
  public let contextSourceMessageIDs: [String]

  public var id: String { "\(network.rawValue):\(normalizedAddress)" }

  public init(
    address: String,
    normalizedAddress: String,
    network: CryptoAddressNetwork,
    roleHint: CryptoAddressRoleHint,
    occurrenceCount: Int,
    directSourceMessageIDs: [String],
    contextSourceMessageIDs: [String]
  ) {
    self.address = address
    self.normalizedAddress = normalizedAddress
    self.network = network
    self.roleHint = roleHint
    self.occurrenceCount = occurrenceCount
    self.directSourceMessageIDs = directSourceMessageIDs
    self.contextSourceMessageIDs = contextSourceMessageIDs
  }

  private enum CodingKeys: String, CodingKey {
    case address
    case normalizedAddress = "normalized_address"
    case network
    case roleHint = "role_hint"
    case occurrenceCount = "occurrence_count"
    case directSourceMessageIDs = "direct_source_message_ids"
    case contextSourceMessageIDs = "context_source_message_ids"
  }
}

public enum CryptoAddressDetector {
  public static let detectorVersion = 1
  public static let contextWindowSeconds: TimeInterval = 5 * 60
  public static let neighboringMessagesPerSide = 2

  private static let evmExpression = try! NSRegularExpression(
    pattern: "(?i)(?<![0-9a-f])0x[0-9a-f]{40}(?![0-9a-f])"
  )
  private static let solanaExpression = try! NSRegularExpression(
    pattern: "(?<![1-9A-HJ-NP-Za-km-z])[1-9A-HJ-NP-Za-km-z]{32,44}(?![1-9A-HJ-NP-Za-km-z])"
  )
  private static let contractCueExpression = try! NSRegularExpression(
    pattern: #"(?i)(?:\bCA\b|contract\s*address|mint\s*address|\bmint\b|\btoken\b|合约(?:地址)?|合約(?:地址)?|代币|代幣|币种|幣種)"#
  )
  private static let walletCueExpression = try! NSRegularExpression(
    pattern: #"(?i)(?:\bwallet\b|\bholder\b|smart\s*money|钱包|錢包|聪明钱|聰明錢|持仓|持倉|买入|買入|卖出|賣出|转账|轉賬|收款)"#
  )
  private static let solanaCueExpression = try! NSRegularExpression(
    pattern: #"(?i)(?:\bsol(?:ana)?\b|\bSPL\b|\bCA\b|\bmint\b|contract\s*address|合约(?:地址)?|合約(?:地址)?|地址|gmgn\.ai|dexscreener\.com|birdeye\.so|solscan\.io|pump\.fun)"#
  )
  private static let networkHintExpressions: [(
    CryptoAddressNetwork, NSRegularExpression
  )] = [
    (.ethereum, try! NSRegularExpression(pattern: #"(?i)(?:\beth(?:ereum)?\b|\berc-?20\b|以太坊)"#)),
    (.base, try! NSRegularExpression(pattern: #"(?i)(?:\bbase\b|base\s*chain)"#)),
    (.bsc, try! NSRegularExpression(pattern: #"(?i)(?:\bbsc\b|\bbnb\s*chain\b|\bbep-?20\b|币安链|幣安鏈)"#)),
    (.arbitrum, try! NSRegularExpression(pattern: #"(?i)(?:\barbitrum\b|\barb\b)"#)),
    (.polygon, try! NSRegularExpression(pattern: #"(?i)(?:\bpolygon\b|\bmatic\b)"#)),
    (.optimism, try! NSRegularExpression(pattern: #"(?i)(?:\boptimism\b|\bop\s*mainnet\b)"#)),
    (.avalanche, try! NSRegularExpression(pattern: #"(?i)(?:\bavalanche\b|\bavax\b)"#)),
    (
      .robinhood,
      try! NSRegularExpression(
        pattern: #"(?i)(?:\brobinhood[-_\s]?(?:chain|l2)\b|robinhood\s*(?:[链鏈]|副本))"#
      )
    ),
  ]

  /// Returns unique EVM and likely Solana address formats in deterministic order.
  /// Solana candidates must decode to 32 bytes and include contextual evidence unless the
  /// entire message is the address.
  public static func matches(in content: String) -> [CryptoAddressMatch] {
    var seen = Set<String>()
    return rawAddressMatches(in: content).filter { seen.insert($0.id).inserted }
  }

  public static func detect(in messages: [AIAnalysisSourceMessage]) -> [CryptoAddressEvidence] {
    let ordered = messages.sorted {
      if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
      return $0.messageID < $1.messageID
    }
    var occurrences: [Occurrence] = []

    for (index, message) in ordered.enumerated() {
      for match in rawAddressMatches(in: message.content) {
        let resolvedNetwork: CryptoAddressNetwork
        if match.family == .evm, match.network == .evm {
          let contextIndices = ordered.indices.filter { candidateIndex in
            let candidate = ordered[candidateIndex]
            return candidate.group == message.group
              && abs(candidate.observedAt.timeIntervalSince(message.observedAt)) < contextWindowSeconds
          }
          let context = contextIndices.map { ordered[$0].content }.joined(separator: "\n")
          resolvedNetwork = network(for: .evm, context: context)
        } else {
          resolvedNetwork = match.network
        }
        occurrences.append(
          Occurrence(
            address: match.address,
            normalizedAddress: match.normalizedAddress,
            family: match.family,
            network: resolvedNetwork,
            messageIndex: index
          )
        )
      }
    }

    var grouped: [String: [Occurrence]] = [:]
    var keyOrder: [String] = []
    for occurrence in occurrences {
      let key = "\(occurrence.family.rawValue):\(occurrence.network.rawValue):\(occurrence.normalizedAddress)"
      if grouped[key] == nil { keyOrder.append(key) }
      grouped[key, default: []].append(occurrence)
    }

    return keyOrder.compactMap { key in
      guard let addressOccurrences = grouped[key], let first = addressOccurrences.first else {
        return nil
      }
      let contextIndices = contextMessageIndices(
        for: addressOccurrences.map(\.messageIndex),
        messages: ordered
      )
      let contextText = contextIndices.map { ordered[$0].content }.joined(separator: "\n")
      let directIDs = orderedUnique(addressOccurrences.map { ordered[$0.messageIndex].messageID })
      let contextIDs = contextIndices.map { ordered[$0].messageID }

      return CryptoAddressEvidence(
        address: first.address,
        normalizedAddress: first.normalizedAddress,
        network: first.network,
        roleHint: roleHint(in: contextText),
        occurrenceCount: addressOccurrences.count,
        directSourceMessageIDs: directIDs,
        contextSourceMessageIDs: contextIDs
      )
    }
  }

  private static func contextMessageIndices(
    for directIndices: [Int],
    messages: [AIAnalysisSourceMessage]
  ) -> [Int] {
    var included = Set<Int>()
    for directIndex in directIndices {
      let direct = messages[directIndex]
      let lower = max(0, directIndex - neighboringMessagesPerSide)
      let upper = min(messages.count - 1, directIndex + neighboringMessagesPerSide)
      for index in lower...upper {
        let candidate = messages[index]
        guard candidate.group == direct.group,
              abs(candidate.observedAt.timeIntervalSince(direct.observedAt)) < contextWindowSeconds
        else { continue }
        included.insert(index)
      }
    }
    return included.sorted()
  }

  private static func network(
    for family: CryptoAddressFamily,
    context: String
  ) -> CryptoAddressNetwork {
    guard family == .evm else { return .solana }

    var matches: [CryptoAddressNetwork] = []
    for (network, expression) in networkHintExpressions
    where contains(expression, in: context) {
      matches.append(network)
    }
    return matches.count == 1 ? matches[0] : .evm
  }

  /// Resolve a direct message match against the nearest explicit chain hint. This keeps
  /// separate addresses in formats such as "ETH: 0x... / BSC: 0x..." independently filterable.
  private static func network(
    for family: CryptoAddressFamily,
    address: String,
    context: String
  ) -> CryptoAddressNetwork {
    guard family == .evm else { return .solana }
    let contextRange = NSRange(context.startIndex..<context.endIndex, in: context)
    guard let addressRange = context.range(of: address, options: [.caseInsensitive]) else {
      return network(for: family, context: context)
    }
    let addressNSRange = NSRange(addressRange, in: context)
    let candidates = networkHintExpressions.flatMap { candidate, expression in
      expression.matches(in: context, range: contextRange).map {
        (network: candidate, distance: rangeDistance(addressNSRange, $0.range))
      }
    }.sorted { $0.distance < $1.distance }
    guard let nearest = candidates.first, nearest.distance <= 240 else { return .evm }
    let tiedNetworks = Set(
      candidates
        .prefix { $0.distance == nearest.distance }
        .map(\.network)
    )
    return tiedNetworks.count == 1 ? nearest.network : .evm
  }

  private static func rangeDistance(_ lhs: NSRange, _ rhs: NSRange) -> Int {
    if NSMaxRange(lhs) < rhs.location { return rhs.location - NSMaxRange(lhs) }
    if NSMaxRange(rhs) < lhs.location { return lhs.location - NSMaxRange(rhs) }
    return 0
  }

  private static func roleHint(in context: String) -> CryptoAddressRoleHint {
    let contract = contains(contractCueExpression, in: context)
    let wallet = contains(walletCueExpression, in: context)
    switch (contract, wallet) {
    case (true, false): return .contractOrToken
    case (false, true): return .wallet
    case (true, true): return .ambiguous
    case (false, false): return .unknown
    }
  }

  private static func isLikelySolanaAddress(_ candidate: String, in content: String) -> Bool {
    guard decodedBase58ByteCount(candidate) == 32 else { return false }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == candidate
      || contains(solanaCueExpression, in: content)
  }

  private static func rawAddressMatches(in content: String) -> [CryptoAddressMatch] {
    var results = regexMatches(evmExpression, in: content).map { address in
      CryptoAddressMatch(
        address: address,
        normalizedAddress: address.lowercased(),
        family: .evm,
        network: network(for: .evm, address: address, context: content)
      )
    }
    results.append(
      contentsOf: regexMatches(solanaExpression, in: content).compactMap { address in
        guard isLikelySolanaAddress(address, in: content) else { return nil }
        return CryptoAddressMatch(
          address: address,
          normalizedAddress: address,
          family: .solana,
          network: .solana
        )
      }
    )
    return results
  }

  private static func decodedBase58ByteCount(_ value: String) -> Int? {
    let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
    var bytes: [UInt8] = []
    var leadingZeroCount = 0
    for byte in value.utf8 {
      guard let digit = lookup[byte] else { return nil }
      if bytes.isEmpty && digit == 0 { leadingZeroCount += 1 }
      var carry = digit
      for index in bytes.indices {
        let value = Int(bytes[index]) * 58 + carry
        bytes[index] = UInt8(value & 0xff)
        carry = value >> 8
      }
      while carry > 0 {
        bytes.append(UInt8(carry & 0xff))
        carry >>= 8
      }
    }
    return leadingZeroCount + bytes.count
  }

  private static func regexMatches(_ expression: NSRegularExpression, in text: String) -> [String] {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      return String(text[range])
    }
  }

  private static func contains(_ expression: NSRegularExpression, in text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.firstMatch(in: text, range: range) != nil
  }

  private static func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}

private extension CryptoAddressDetector {
  struct Occurrence {
    let address: String
    let normalizedAddress: String
    let family: CryptoAddressFamily
    let network: CryptoAddressNetwork
    let messageIndex: Int
  }
}
