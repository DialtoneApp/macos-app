import CryptoKit
import Foundation

struct Money: Codable, Hashable {
    var amount: Decimal
    var currency: String

    var displayValue: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = amount < 1 ? 4 : 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(currency) \(amount)"
    }

    static func parse(_ value: Any?, currency: String? = nil) -> Money? {
        guard let value else { return nil }

        let rawValue: String
        if let number = value as? NSNumber {
            rawValue = number.stringValue
        } else if let string = value as? String {
            rawValue = string
        } else {
            return nil
        }

        let normalized = rawValue
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let detectedCurrency: String
        if let currency {
            detectedCurrency = currency.uppercased()
        } else if normalized.contains("€") {
            detectedCurrency = "EUR"
        } else if normalized.contains("£") {
            detectedCurrency = "GBP"
        } else if normalized.contains("₹") {
            detectedCurrency = "INR"
        } else {
            detectedCurrency = "USD"
        }

        let allowed = CharacterSet(charactersIn: "0123456789.")
        let numeric = normalized.unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()

        guard !numeric.isEmpty, let decimal = Decimal(string: numeric) else {
            return nil
        }

        return Money(amount: decimal, currency: detectedCurrency)
    }

    static func parseFirstPrice(in value: String?, currency: String? = nil) -> Money? {
        guard let value else { return nil }

        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let symbolPattern = #"([$€£₹])\s*([0-9]+(?:\.[0-9]{1,6})?)"#
        if let match = firstMatch(in: normalized, pattern: symbolPattern),
           match.count == 2,
           let decimal = Decimal(string: match[1]) {
            return Money(amount: decimal, currency: currencyCode(for: match[0], fallback: currency))
        }

        let prefixedCurrencyPattern = #"(?i)\b(USD|USDC|EUR|GBP|INR)\s*([0-9]+(?:\.[0-9]{1,6})?)"#
        if let match = firstMatch(in: normalized, pattern: prefixedCurrencyPattern),
           match.count == 2,
           let decimal = Decimal(string: match[1]) {
            return Money(amount: decimal, currency: match[0].uppercased())
        }

        let suffixedCurrencyPattern = #"(?i)\b([0-9]+(?:\.[0-9]{1,6})?)\s*(USD|USDC|EUR|GBP|INR)\b"#
        if let match = firstMatch(in: normalized, pattern: suffixedCurrencyPattern),
           match.count == 2,
           let decimal = Decimal(string: match[0]) {
            return Money(amount: decimal, currency: match[1].uppercased())
        }

        return nil
    }

    private static func firstMatch(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1 else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let matchRange = Range(match.range(at: index), in: value) else { return nil }
            return String(value[matchRange])
        }
    }

    private static func currencyCode(for symbol: String, fallback: String?) -> String {
        if let fallback {
            return fallback.uppercased()
        }

        switch symbol {
        case "€": return "EUR"
        case "£": return "GBP"
        case "₹": return "INR"
        default: return "USD"
        }
    }
}

enum DiscoverySource: String, Codable, Hashable, CaseIterable {
    case ucp = "UCP"
    case commerceManifest = "Commerce manifest"
    case agentCard = "Agent card"
    case siteAI = "siteai.json"
    case llms = "llms.txt"
    case openAPI = "OpenAPI"
    case swagger = "Swagger"
    case shopifyProducts = "products.json"
    case woocommerceStore = "WooCommerce Store API"
    case robots = "robots.txt"
    case sitemap = "sitemap.xml"
    case homepage = "Homepage"
    case discoveredURL = "Discovered URL"
}

enum CandidateSourceKind: String, Codable, Hashable, CaseIterable {
    case ucp = "UCP"
    case productsJSON = "products.json"
    case openAPI = "OpenAPI"
    case commerceManifest = "Commerce manifest"
    case x402 = "x402"
    case jsonLD = "JSON-LD"
    case htmlFallback = "HTML fallback"
    case agentCard = "Agent card"
    case siteAI = "siteai.json"
    case woocommerce = "WooCommerce"
}

enum PurchaseStrategy: String, Codable, Hashable {
    case dialtoneappNetwork = "dialtoneapp_network"
    case browserCheckout = "browser_checkout"
    case apiAction = "api_action"
    case x402 = "x402"
    case unsupported = "unsupported"

    var label: String {
        switch self {
        case .dialtoneappNetwork: return "DialtoneApp Network"
        case .browserCheckout: return "Browser handoff"
        case .apiAction: return "API action"
        case .x402: return "x402"
        case .unsupported: return "Unsupported"
        }
    }
}

struct PaymentHint: Codable, Hashable {
    var method: String
    var endpoint: URL?
    var acceptedRails: [String]
}

struct DiscoveredApiCall: Identifiable, Codable, Hashable {
    var id = UUID()
    var domain: String
    var method: String
    var url: URL
    var source: DiscoverySource
    var capability: String?
    var priceHint: Money?
    var paymentHint: PaymentHint?
    var confidence: Double
}

enum CandidateDecision: String, Codable, Hashable {
    case pending
    case dismissed
    case approved
}

enum PurchaseResultState: String, Codable, Hashable {
    case purchased
    case needsLogin = "needs_login"
    case needsBotBuyerCard = "needs_bot_buyer_card"
    case needsBrowserCheckout = "needs_browser_checkout"
    case unsupportedMerchant = "unsupported_merchant"
    case failed
}

struct PurchaseFlowResult: Codable, Hashable {
    var state: PurchaseResultState
    var message: String
    var requestID: String?
    var handoffURL: URL?
}

enum DesktopPurchaseReadiness: String, Hashable {
    case checking
    case signedOut
    case signedInCheckingCard
    case signedInNeedsCard
    case ready
    case unavailable

    var label: String {
        switch self {
        case .checking:
            return "Checking login"
        case .signedOut:
            return "Not signed in"
        case .signedInCheckingCard:
            return "Signed in, checking card"
        case .signedInNeedsCard:
            return "Needs bot-buyer card"
        case .ready:
            return "Ready to buy"
        case .unavailable:
            return "Card status unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .signedOut:
            return "person.crop.circle.badge.xmark"
        case .signedInCheckingCard:
            return "person.crop.circle.badge.checkmark"
        case .signedInNeedsCard:
            return "creditcard.trianglebadge.exclamationmark"
        case .ready:
            return "checkmark.seal"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }
}

struct PurchaseCandidate: Identifiable, Codable, Hashable {
    var id: UUID
    var domain: String
    var merchantName: String
    var title: String
    var description: String?
    var price: Money?
    var imageURL: URL?
    var productURL: URL?
    var sourceURL: URL
    var sourceKind: CandidateSourceKind
    var purchaseStrategy: PurchaseStrategy
    var discoveredAt: Date
    var confidence: Double
    var discoveredApiCall: DiscoveredApiCall?
    var fingerprint: String
    var decision: CandidateDecision
    var result: PurchaseFlowResult?

    init(
        id: UUID = UUID(),
        domain: String,
        merchantName: String,
        title: String,
        description: String?,
        price: Money?,
        imageURL: URL?,
        productURL: URL?,
        sourceURL: URL,
        sourceKind: CandidateSourceKind,
        purchaseStrategy: PurchaseStrategy,
        discoveredAt: Date = Date(),
        confidence: Double,
        discoveredApiCall: DiscoveredApiCall? = nil,
        decision: CandidateDecision = .pending,
        result: PurchaseFlowResult? = nil
    ) {
        let displayTitle = PurchaseCandidate.displayTitle(from: title)

        self.id = id
        self.domain = domain
        self.merchantName = merchantName
        self.title = displayTitle
        self.description = description
        self.price = price
        self.imageURL = imageURL
        self.productURL = productURL
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.purchaseStrategy = purchaseStrategy
        self.discoveredAt = discoveredAt
        self.confidence = confidence
        self.discoveredApiCall = discoveredApiCall
        self.decision = decision
        self.result = result
        self.fingerprint = PurchaseCandidate.makeFingerprint(
            domain: domain,
            title: displayTitle,
            price: price,
            sourceURL: sourceURL,
            productURL: productURL
        )
    }

    static func makeFingerprint(
        domain: String,
        title: String,
        price: Money?,
        sourceURL: URL,
        productURL: URL?
    ) -> String {
        _ = sourceURL
        let pricePart = price.map { "\($0.currency):\($0.amount)" } ?? "no-price"
        let normalizedTitle = title
            .lowercased()
            .replacingOccurrences(of: #"[\p{P}\p{S}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let productPart = productURL.map { url in
            "\(url.host?.lowercased() ?? "")\(url.path)"
        } ?? "no-product"
        let rawValue = "\(domain)|\(normalizedTitle)|\(pricePart)|\(productPart)"
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func displayTitle(from value: String) -> String {
        var cleaned = value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"^\((?:paid|free)[^)]*\)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        guard !cleaned.isEmpty else { return "Untitled item" }
        return compactLongTitle(cleaned)
    }

    private static func compactLongTitle(_ value: String) -> String {
        let limit = 120
        guard value.count > limit else { return value }

        let suffix = trailingActionSuffix(from: value)
        var core = value
        let cutMarkers = [
            ". Columns:",
            " Columns:",
            ". Use cases:",
            " Use cases:",
            ". Source:",
            " Source:"
        ]

        for marker in cutMarkers {
            if let range = core.range(of: marker, options: .caseInsensitive) {
                core = String(core[..<range.lowerBound])
                break
            }
        }

        core = core.trimmingCharacters(in: .whitespacesAndNewlines)

        if let suffix, !core.localizedCaseInsensitiveContains(suffix) {
            let suffixText = " - \(suffix)"
            let coreLimit = max(32, limit - suffixText.count)
            return truncate(core, limit: coreLimit) + suffixText
        }

        return truncate(core, limit: limit)
    }

    private static func trailingActionSuffix(from value: String) -> String? {
        let separators = [" \u{2014} ", " -- ", " - "]

        for separator in separators {
            guard let range = value.range(of: separator, options: .backwards) else { continue }
            let suffix = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty, suffix.count <= 32 {
                return suffix
            }
        }

        return nil
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let hardEnd = value.index(value.startIndex, offsetBy: max(0, limit - 3))
        var prefix = String(value[..<hardEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        if let lastSpace = prefix.range(of: " ", options: .backwards),
           prefix.distance(from: prefix.startIndex, to: lastSpace.lowerBound) > limit / 2 {
            prefix = String(prefix[..<lastSpace.lowerBound])
        }

        return prefix + "..."
    }
}

enum CandidateDedupe {
    static func dedupe(_ candidates: [PurchaseCandidate]) -> [PurchaseCandidate] {
        var groups: [String: [PurchaseCandidate]] = [:]
        var groupOrder: [String] = []

        for candidate in candidates {
            let key = semanticKey(for: candidate)
            if groups[key] == nil {
                groups[key] = []
                groupOrder.append(key)
            }
            groups[key]?.append(candidate)
        }

        return groupOrder.flatMap { key -> [PurchaseCandidate] in
            guard let group = groups[key] else { return [] }
            if isCommercialOfferKey(key) {
                return [bestCandidate(in: group)]
            }

            let priced = group.filter { $0.price != nil }

            if priced.isEmpty {
                return [bestCandidate(in: group)]
            }

            var priceKeys: [String] = []
            var bestByPrice: [String: PurchaseCandidate] = [:]

            for candidate in priced {
                let priceKey = candidate.price.map { "\($0.currency):\($0.amount)" } ?? "no-price"
                if let existing = bestByPrice[priceKey] {
                    if isPreferred(candidate, over: existing) {
                        bestByPrice[priceKey] = candidate
                    }
                } else {
                    priceKeys.append(priceKey)
                    bestByPrice[priceKey] = candidate
                }
            }

            return priceKeys.compactMap { bestByPrice[$0] }
        }
    }

    static func semanticKey(for candidate: PurchaseCandidate) -> String {
        if let offerKey = commercialOfferKey(for: candidate) {
            return offerKey
        }

        let title = normalizeForDedupe(candidate.title)
        return "\(candidate.domain.lowercased())|title|\(title)"
    }

    static func isPreferred(_ candidate: PurchaseCandidate, over existing: PurchaseCandidate) -> Bool {
        score(candidate) > score(existing)
    }

    static func score(_ candidate: PurchaseCandidate) -> Double {
        var score = candidate.confidence
        if candidate.price != nil { score += 0.30 }
        if candidate.productURL != nil { score += 0.15 }
        if candidate.imageURL != nil { score += 0.10 }
        if candidate.discoveredApiCall != nil { score += 0.04 }
        if candidate.description?.isEmpty == false { score += 0.03 }
        score += purchaseStrategyPriority(candidate.purchaseStrategy)
        score += sourcePriority(candidate.sourceKind)
        return score
    }

    private static func bestCandidate(in candidates: [PurchaseCandidate]) -> PurchaseCandidate {
        candidates.max { score($0) < score($1) } ?? candidates[0]
    }

    private static func commercialOfferKey(for candidate: PurchaseCandidate) -> String? {
        guard shouldClusterCommercialOffer(candidate) else { return nil }
        return "\(candidate.domain.lowercased())|commercial-offer|site"
    }

    private static func isCommercialOfferKey(_ key: String) -> Bool {
        key.contains("|commercial-offer|")
    }

    private static func shouldClusterCommercialOffer(_ candidate: PurchaseCandidate) -> Bool {
        switch candidate.sourceKind {
        case .openAPI, .ucp, .commerceManifest, .agentCard, .siteAI:
            return true
        case .jsonLD, .htmlFallback:
            return candidate.price != nil && isBroadCommercialPage(candidate.productURL ?? candidate.sourceURL)
        case .productsJSON, .woocommerce, .x402:
            return false
        }
    }

    private static func isBroadCommercialPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        let components = url.path
            .split(separator: "/")
            .map { String($0).lowercased() }

        guard components.count <= 1 else { return false }
        guard let slug = components.first else { return true }

        let commerceSlugs = [
            "bot-buyer",
            "buy",
            "cart",
            "checkout",
            "membership",
            "plan",
            "plans",
            "pricing",
            "product",
            "products",
            "subscribe",
            "subscription"
        ]

        return commerceSlugs.contains(slug)
    }

    private static func normalizeForDedupe(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\p{P}\p{S}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func purchaseStrategyPriority(_ strategy: PurchaseStrategy) -> Double {
        switch strategy {
        case .dialtoneappNetwork:
            return 0.35
        case .x402:
            return 0.28
        case .apiAction:
            return 0.20
        case .browserCheckout:
            return 0
        case .unsupported:
            return -0.25
        }
    }

    private static func sourcePriority(_ kind: CandidateSourceKind) -> Double {
        switch kind {
        case .openAPI:
            return 0.09
        case .commerceManifest, .x402:
            return 0.08
        case .ucp:
            return 0.07
        case .jsonLD:
            return 0.06
        case .productsJSON, .woocommerce:
            return 0.05
        case .agentCard, .siteAI:
            return 0.04
        case .htmlFallback:
            return 0.01
        }
    }
}

struct NetworkCallRecord: Identifiable, Codable, Hashable {
    var id: String
    var timestamp: Date
    var domain: String
    var method: String
    var url: URL
    var probeType: String
    var statusCode: Int?
    var durationMS: Int
    var contentType: String?
    var byteCount: Int
    var redirectTarget: URL?
    var parseResult: String
    var error: String?
}

struct DomainDiscoveryReport: Identifiable, Codable, Hashable {
    var id = UUID()
    var domain: String
    var startedAt: Date
    var finishedAt: Date
    var networkCalls: [NetworkCallRecord]
    var discoveredApiCalls: [DiscoveredApiCall]
    var candidates: [PurchaseCandidate]

    var summary: String {
        "\(networkCalls.count) calls, \(discoveredApiCalls.count) endpoints, \(candidates.count) candidates"
    }
}

enum LogChannel: String, CaseIterable, Identifiable {
    case agent
    case network
    case purchases

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var fileName: String { "\(rawValue).log" }
}

enum LogLevel: String, CaseIterable, Identifiable {
    case success
    case info
    case warning
    case error

    var id: String { rawValue }
}

struct LogLine: Identifiable, Hashable {
    var id = UUID()
    var channel: LogChannel
    var level: LogLevel
    var text: String
}
