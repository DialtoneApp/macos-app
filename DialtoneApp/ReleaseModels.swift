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
    case policyBlocked = "policy_blocked"
    case failed
}

struct PurchaseFlowResult: Codable, Hashable {
    var state: PurchaseResultState
    var message: String
    var requestID: String?
    var handoffURL: URL?
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
        self.id = id
        self.domain = domain
        self.merchantName = merchantName
        self.title = title
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
            title: title,
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
        let pricePart = price.map { "\($0.currency):\($0.amount)" } ?? "no-price"
        let rawValue = "\(domain)|\(title)|\(pricePart)|\(sourceURL.absoluteString)|\(productURL?.absoluteString ?? "no-product")"
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
