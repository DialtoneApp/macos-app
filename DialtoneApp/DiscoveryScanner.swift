import Foundation

@MainActor
final class DomainScanner {
    private struct Probe {
        var url: URL
        var source: DiscoverySource
        var label: String
    }

    private struct FetchResult {
        var record: NetworkCallRecord
        var data: Data?
    }

    private struct ParseResult {
        var parseSummary: String = "not parsed"
        var discoveredURLs: [URL] = []
        var apiCalls: [DiscoveredApiCall] = []
        var candidates: [PurchaseCandidate] = []
    }

    private let logStore: LocalLogStore
    private let session: URLSession
    private let onStatus: (String) -> Void
    private let onCandidates: ([PurchaseCandidate]) -> Void
    private let onReport: (DomainDiscoveryReport) -> Void

    private var scanTask: Task<Void, Never>?
    private var paused = false

    init(
        logStore: LocalLogStore,
        onStatus: @escaping (String) -> Void,
        onCandidates: @escaping ([PurchaseCandidate]) -> Void,
        onReport: @escaping (DomainDiscoveryReport) -> Void
    ) {
        self.logStore = logStore
        self.onStatus = onStatus
        self.onCandidates = onCandidates
        self.onReport = onReport

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "DialtoneApp Desktop/0.0.1 (+https://dialtoneapp.com)"
        ]
        session = URLSession(configuration: configuration)
    }

    func startIfNeeded() {
        guard scanTask == nil else { return }

        scanTask = Task { [weak self] in
            await self?.runScanner()
        }
    }

    func setEnabled(_ enabled: Bool) {
        paused = !enabled
        logStore.append(.agent, level: enabled ? .success : .warning, enabled ? "Scanner resumed" : "Scanner paused")
        onStatus(enabled ? "Watching the bot-buyable corpus" : "Paused")
    }

    private func runScanner() async {
        logStore.append(.agent, level: .success, "Scanner started", metadata: ["domains": "\(DomainCorpus.all.count)"])
        logStore.writeDomainState(domains: DomainCorpus.all)
        onStatus("Scanning high-signal domains")

        logStore.append(.agent, "Batch started", metadata: ["batch": "high_signal", "domains": "\(DomainCorpus.highSignal.count)"])
        for domain in DomainCorpus.highSignal {
            await waitWhilePaused()
            await scanDomain(domain)
        }
        logStore.append(.agent, level: .success, "Batch finished", metadata: ["batch": "high_signal"])

        let highSignalSet = Set(DomainCorpus.highSignal)
        let remainingDomains = DomainCorpus.all.filter { !highSignalSet.contains($0) }

        while !Task.isCancelled {
            for domain in remainingDomains {
                await waitWhilePaused()
                let delaySeconds = UInt64(Int.random(in: 60...120))
                onStatus("Next scan in \(delaySeconds)s: \(domain)")
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                await waitWhilePaused()
                await scanDomain(domain)
            }
        }
    }

    @discardableResult
    private func scanDomain(_ domain: String) async -> DomainDiscoveryReport {
        let startedAt = Date()
        var networkCalls: [NetworkCallRecord] = []
        var discoveredApiCalls: [DiscoveredApiCall] = []
        var candidates: [PurchaseCandidate] = []
        var discoveredURLs = OrderedURLSet()
        var probedURLs = Set<URL>()

        onStatus("Scanning \(domain)")
        logStore.append(.agent, "Domain scan started", metadata: ["domain": domain])

        for probe in initialProbes(for: domain) {
            probedURLs.insert(probe.url)
            let fetch = await fetch(domain: domain, probe: probe)
            networkCalls.append(fetch.record)

            guard let data = fetch.data else { continue }
            let parsed = parse(data: data, domain: domain, sourceURL: probe.url, source: probe.source)
            discoveredURLs.append(contentsOf: parsed.discoveredURLs)
            discoveredApiCalls.append(contentsOf: parsed.apiCalls)
            candidates.append(contentsOf: parsed.candidates)
            logStore.append(.agent, "Probe parsed", metadata: [
                "domain": domain,
                "source": probe.source.rawValue,
                "url": probe.url.absoluteString,
                "result": parsed.parseSummary
            ])
        }

        let urlsToFollow = discoveredURLs.values
            .filter { !probedURLs.contains($0) && shouldFollow($0, domain: domain) }
            .prefix(20)

        for url in urlsToFollow {
            probedURLs.insert(url)
            let probe = Probe(url: url, source: .discoveredURL, label: "discovered")
            let fetch = await fetch(domain: domain, probe: probe)
            networkCalls.append(fetch.record)

            guard let data = fetch.data else { continue }
            let parsed = parse(data: data, domain: domain, sourceURL: url, source: .discoveredURL)
            discoveredApiCalls.append(contentsOf: parsed.apiCalls)
            candidates.append(contentsOf: parsed.candidates)
            logStore.append(.agent, "Discovered URL parsed", metadata: [
                "domain": domain,
                "url": url.absoluteString,
                "result": parsed.parseSummary
            ])
        }

        let report = DomainDiscoveryReport(
            domain: domain,
            startedAt: startedAt,
            finishedAt: Date(),
            networkCalls: networkCalls,
            discoveredApiCalls: Array(discoveredApiCalls.prefix(80)),
            candidates: Array(candidates.prefix(20))
        )

        if !report.candidates.isEmpty {
            onCandidates(report.candidates)
        }

        onReport(report)
        logStore.append(.agent, level: .success, "Domain scan finished", metadata: [
            "domain": domain,
            "summary": report.summary
        ])
        onStatus("Finished \(domain): \(report.summary)")

        return report
    }

    private func initialProbes(for domain: String) -> [Probe] {
        let base = "https://\(domain)"
        let paths: [(String, DiscoverySource, String)] = [
            ("/.well-known/ucp", .ucp, "well-known-ucp"),
            ("/.well-known/ucp.json", .ucp, "well-known-ucp-json"),
            ("/.well-known/commerce", .commerceManifest, "well-known-commerce"),
            ("/.well-known/commerce.json", .commerceManifest, "well-known-commerce-json"),
            ("/.well-known/agent.json", .agentCard, "well-known-agent"),
            ("/siteai.json", .siteAI, "siteai"),
            ("/llms.txt", .llms, "llms"),
            ("/openapi.json", .openAPI, "openapi"),
            ("/swagger.json", .swagger, "swagger"),
            ("/products.json", .shopifyProducts, "shopify-products"),
            ("/collections/all/products.json?limit=250", .shopifyProducts, "shopify-all-products"),
            ("/wp-json/wc/store/products?per_page=20", .woocommerceStore, "woocommerce-store"),
            ("/robots.txt", .robots, "robots"),
            ("/sitemap.xml", .sitemap, "sitemap"),
            ("/", .homepage, "homepage")
        ]

        return paths.compactMap { path, source, label in
            URL(string: base + path).map { Probe(url: $0, source: source, label: label) }
        }
    }

    private func fetch(domain: String, probe: Probe) async -> FetchResult {
        let requestID = UUID().uuidString
        let started = Date()
        var request = URLRequest(url: probe.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json,text/plain,text/html,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode
            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")
            let finalURL = httpResponse?.url
            let redirectTarget = finalURL == probe.url ? nil : finalURL
            let level = logLevel(for: statusCode, error: nil)

            let record = NetworkCallRecord(
                id: requestID,
                timestamp: Date(),
                domain: domain,
                method: "GET",
                url: probe.url,
                probeType: probe.label,
                statusCode: statusCode,
                durationMS: durationMS,
                contentType: contentType,
                byteCount: data.count,
                redirectTarget: redirectTarget,
                parseResult: "fetched",
                error: nil
            )

            logNetwork(record, level: level)

            guard let statusCode, (200..<400).contains(statusCode), !isBinary(contentType: contentType, url: probe.url) else {
                return FetchResult(record: record, data: nil)
            }

            return FetchResult(record: record, data: data)
        } catch {
            let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
            let record = NetworkCallRecord(
                id: requestID,
                timestamp: Date(),
                domain: domain,
                method: "GET",
                url: probe.url,
                probeType: probe.label,
                statusCode: nil,
                durationMS: durationMS,
                contentType: nil,
                byteCount: 0,
                redirectTarget: nil,
                parseResult: "failed",
                error: error.localizedDescription
            )
            logNetwork(record, level: .error)
            return FetchResult(record: record, data: nil)
        }
    }

    private func logNetwork(_ record: NetworkCallRecord, level: LogLevel) {
        logStore.append(.network, level: level, "Network call", metadata: [
            "request_id": record.id,
            "domain": record.domain,
            "method": record.method,
            "url": record.url.absoluteString,
            "probe": record.probeType,
            "status": record.statusCode.map(String.init) ?? "none",
            "duration_ms": "\(record.durationMS)",
            "content_type": record.contentType ?? "none",
            "bytes": "\(record.byteCount)",
            "redirect": record.redirectTarget?.absoluteString ?? "none",
            "parse": record.parseResult,
            "error": record.error ?? "none"
        ])
    }

    private func parse(data: Data, domain: String, sourceURL: URL, source: DiscoverySource) -> ParseResult {
        var result = ParseResult()
        let cappedData = data.count > 3_000_000 ? data.prefix(3_000_000) : data[...]
        let text = String(decoding: cappedData, as: UTF8.self)

        result.discoveredURLs = extractURLs(from: text, baseURL: sourceURL, domain: domain)

        if source == .shopifyProducts {
            let parsed = parseShopifyProducts(data: Data(cappedData), domain: domain, sourceURL: sourceURL)
            result.candidates.append(contentsOf: parsed)
        }

        if source == .woocommerceStore {
            let parsed = parseWooCommerceProducts(data: Data(cappedData), domain: domain, sourceURL: sourceURL)
            result.candidates.append(contentsOf: parsed)
        }

        if looksLikeJSON(sourceURL: sourceURL, text: text),
           let object = try? JSONSerialization.jsonObject(with: Data(cappedData), options: [.fragmentsAllowed]) {
            let openAPI = parseOpenAPI(object: object, domain: domain, sourceURL: sourceURL, source: source)
            result.apiCalls.append(contentsOf: openAPI.apiCalls)
            result.candidates.append(contentsOf: openAPI.candidates)

            let generic = parseGenericProductJSON(object: object, domain: domain, sourceURL: sourceURL, source: source)
            result.candidates.append(contentsOf: generic)
        }

        if looksLikeHTML(sourceURL: sourceURL, text: text) {
            result.candidates.append(contentsOf: parseJSONLDProducts(html: text, domain: domain, sourceURL: sourceURL))
            result.candidates.append(contentsOf: parseOpenGraphProduct(html: text, domain: domain, sourceURL: sourceURL))
        }

        result.candidates = dedupeCandidates(result.candidates)
        result.parseSummary = "\(result.discoveredURLs.count) urls, \(result.apiCalls.count) endpoints, \(result.candidates.count) candidates"
        return result
    }

    private func parseShopifyProducts(data: Data, domain: String, sourceURL: URL) -> [PurchaseCandidate] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let products = object["products"] as? [[String: Any]]
        else {
            return []
        }

        return products.prefix(10).compactMap { product in
            guard let title = stringValue(product["title"]), !title.isEmpty else { return nil }
            let variants = product["variants"] as? [[String: Any]]
            let firstVariant = variants?.first
            let currency = stringValue(firstVariant?["currency_code"]) ?? stringValue(object["currency"])
            let price = Money.parse(firstVariant?["price"], currency: currency)
            let description = stringValue(product["body_html"]).map(stripHTML)
            let imageURL = shopifyImageURL(product: product, sourceURL: sourceURL)
            let productURL = productURLForShopifyProduct(product, domain: domain)

            return PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: description,
                price: price,
                imageURL: imageURL,
                productURL: productURL,
                sourceURL: sourceURL,
                sourceKind: .productsJSON,
                purchaseStrategy: .browserCheckout,
                confidence: price == nil ? 0.72 : 0.88
            )
        }
    }

    private func parseWooCommerceProducts(data: Data, domain: String, sourceURL: URL) -> [PurchaseCandidate] {
        guard let products = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return products.prefix(10).compactMap { product in
            guard let title = stringValue(product["name"]), !title.isEmpty else { return nil }
            let price = Money.parse(product["price"], currency: stringValue(product["currency_code"]))
            let description = stringValue(product["short_description"]).map(stripHTML)
            let imageURL = ((product["images"] as? [[String: Any]])?.first?["src"]).flatMap(stringValue).flatMap(URL.init(string:))
            let productURL = stringValue(product["permalink"]).flatMap(URL.init(string:))

            return PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: description,
                price: price,
                imageURL: imageURL,
                productURL: productURL,
                sourceURL: sourceURL,
                sourceKind: .woocommerce,
                purchaseStrategy: .browserCheckout,
                confidence: price == nil ? 0.7 : 0.86
            )
        }
    }

    private func parseOpenAPI(
        object: Any,
        domain: String,
        sourceURL: URL,
        source: DiscoverySource
    ) -> (apiCalls: [DiscoveredApiCall], candidates: [PurchaseCandidate]) {
        guard
            let root = object as? [String: Any],
            root["paths"] != nil,
            let paths = root["paths"] as? [String: Any]
        else {
            return ([], [])
        }

        let allowedMethods = Set(["GET", "POST", "PUT", "PATCH", "DELETE"])
        var apiCalls: [DiscoveredApiCall] = []
        var candidates: [PurchaseCandidate] = []

        for (path, rawPathItem) in paths.sorted(by: { $0.key < $1.key }) {
            guard let pathItem = rawPathItem as? [String: Any] else { continue }

            for (methodKey, rawOperation) in pathItem {
                let method = methodKey.uppercased()
                guard allowedMethods.contains(method), let operation = rawOperation as? [String: Any] else { continue }

                let endpointURL = URL(string: path, relativeTo: URL(string: "https://\(domain)"))?.absoluteURL ?? sourceURL
                let title = stringValue(operation["summary"])
                    ?? stringValue(operation["operationId"])
                    ?? "\(method) \(path)"
                let description = stringValue(operation["description"])
                let price = priceHint(from: operation)
                let paymentHint = paymentHint(from: operation)
                let relevant = price != nil || paymentHint != nil || isPurchaseRelevant(path: path, title: title, description: description)
                let confidence = relevant ? 0.72 : 0.52

                let call = DiscoveredApiCall(
                    domain: domain,
                    method: method,
                    url: endpointURL,
                    source: source == .swagger ? .swagger : .openAPI,
                    capability: title,
                    priceHint: price,
                    paymentHint: paymentHint,
                    confidence: confidence
                )
                apiCalls.append(call)

                if relevant, candidates.count < 8 {
                    candidates.append(
                        PurchaseCandidate(
                            domain: domain,
                            merchantName: merchantName(for: domain),
                            title: title,
                            description: description,
                            price: price,
                            imageURL: nil,
                            productURL: endpointURL,
                            sourceURL: sourceURL,
                            sourceKind: paymentHint?.method.lowercased().contains("x402") == true ? .x402 : .openAPI,
                            purchaseStrategy: domain == "dialtoneapp.com" ? .dialtoneappNetwork : (paymentHint == nil ? .apiAction : .x402),
                            confidence: confidence,
                            discoveredApiCall: call
                        )
                    )
                }

                if apiCalls.count >= 80 { break }
            }
        }

        return (Array(apiCalls.prefix(80)), candidates)
    }

    private func parseGenericProductJSON(
        object: Any,
        domain: String,
        sourceURL: URL,
        source: DiscoverySource
    ) -> [PurchaseCandidate] {
        var dictionaries: [[String: Any]] = []
        collectDictionaries(from: object, into: &dictionaries)

        let sourceKind = candidateKind(for: source, sourceURL: sourceURL)
        return dictionaries.prefix(250).compactMap { dictionary in
            guard let title = stringValue(dictionary["title"]) ?? stringValue(dictionary["name"]) else {
                return nil
            }

            let offer = dictionary["offers"] as? [String: Any]
            let price = Money.parse(
                dictionary["price"] ?? dictionary["amount"] ?? offer?["price"],
                currency: stringValue(dictionary["currency"]) ?? stringValue(dictionary["priceCurrency"]) ?? stringValue(offer?["priceCurrency"])
            )

            let productURL = stringValue(dictionary["url"])
                .flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }
            let imageURL = imageURL(from: dictionary["image"], sourceURL: sourceURL)

            let hasBuyingSignal = price != nil
                || productURL != nil
                || sourceKind == .commerceManifest
                || sourceKind == .ucp
                || containsText(dictionary, matching: ["x402", "purchase", "checkout", "subscription", "billing"])

            guard hasBuyingSignal else { return nil }

            return PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: stringValue(dictionary["description"]).map(stripHTML),
                price: price,
                imageURL: imageURL,
                productURL: productURL,
                sourceURL: sourceURL,
                sourceKind: sourceKind,
                purchaseStrategy: purchaseStrategy(for: sourceKind, domain: domain),
                confidence: price == nil ? 0.6 : 0.78
            )
        }
        .prefix(8)
        .map { $0 }
    }

    private func parseJSONLDProducts(html: String, domain: String, sourceURL: URL) -> [PurchaseCandidate] {
        let pattern = #"<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var candidates: [PurchaseCandidate] = []

        for match in matches.prefix(12) {
            guard let contentRange = Range(match.range(at: 1), in: html) else { continue }
            let jsonText = decodeHTMLEntities(String(html[contentRange]))
            guard let data = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                continue
            }

            var dictionaries: [[String: Any]] = []
            collectDictionaries(from: object, into: &dictionaries)

            for dictionary in dictionaries {
                guard isJSONLDProduct(dictionary),
                      let title = stringValue(dictionary["name"]) ?? stringValue(dictionary["title"]) else {
                    continue
                }

                let offer = dictionary["offers"] as? [String: Any]
                let price = Money.parse(
                    dictionary["price"] ?? offer?["price"],
                    currency: stringValue(dictionary["priceCurrency"]) ?? stringValue(offer?["priceCurrency"])
                )

                candidates.append(
                    PurchaseCandidate(
                        domain: domain,
                        merchantName: merchantName(for: domain),
                        title: title,
                        description: stringValue(dictionary["description"]).map(stripHTML),
                        price: price,
                        imageURL: imageURL(from: dictionary["image"], sourceURL: sourceURL),
                        productURL: stringValue(dictionary["url"]).flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL } ?? sourceURL,
                        sourceURL: sourceURL,
                        sourceKind: .jsonLD,
                        purchaseStrategy: .browserCheckout,
                        confidence: price == nil ? 0.68 : 0.86
                    )
                )
            }
        }

        return Array(dedupeCandidates(candidates).prefix(8))
    }

    private func parseOpenGraphProduct(html: String, domain: String, sourceURL: URL) -> [PurchaseCandidate] {
        guard
            let title = metaValue(in: html, keys: ["og:title", "twitter:title"]),
            let price = Money.parse(
                metaValue(in: html, keys: ["product:price:amount", "og:price:amount", "twitter:data1"]),
                currency: metaValue(in: html, keys: ["product:price:currency", "og:price:currency"])
            )
        else {
            return []
        }

        let imageURL = metaValue(in: html, keys: ["og:image", "twitter:image"])
            .flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }

        return [
            PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: metaValue(in: html, keys: ["og:description", "description"]).map(stripHTML),
                price: price,
                imageURL: imageURL,
                productURL: sourceURL,
                sourceURL: sourceURL,
                sourceKind: .htmlFallback,
                purchaseStrategy: .browserCheckout,
                confidence: 0.7
            )
        ]
    }

    private func extractURLs(from text: String, baseURL: URL, domain: String) -> [URL] {
        var urls = OrderedURLSet()
        let patterns = [
            #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#,
            #"(?:href|src)=["']([^"']+)["']"#,
            #"(?m)^\s*(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range).prefix(300) {
                let captureIndex = match.numberOfRanges > 1 ? 1 : 0
                guard let matchRange = Range(match.range(at: captureIndex), in: text) else { continue }
                let raw = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>),."))
                guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else { continue }
                if shouldFollow(url, domain: domain) {
                    urls.append(url)
                }
            }
        }

        return urls.values
    }

    private func shouldFollow(_ url: URL, domain: String) -> Bool {
        guard url.scheme == "https" || url.scheme == "http" else { return false }
        guard url.host?.lowercased() == domain.lowercased() else { return false }
        if isBinary(contentType: nil, url: url) { return false }

        let value = url.absoluteString.lowercased()
        let tokens = [
            "openapi",
            "swagger",
            "ucp",
            "commerce",
            "agent",
            "siteai",
            "llms",
            "products.json",
            "product",
            "pricing",
            "checkout",
            "cart",
            "order",
            "billing",
            "subscription",
            "api",
            "x402"
        ]
        return tokens.contains { value.contains($0) }
    }

    private func waitWhilePaused() async {
        while paused && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func logLevel(for statusCode: Int?, error: Error?) -> LogLevel {
        if error != nil { return .error }
        guard let statusCode else { return .warning }
        if (200..<300).contains(statusCode) { return .success }
        if statusCode == 404 { return .info }
        if statusCode >= 500 { return .error }
        return .warning
    }

    private func looksLikeJSON(sourceURL: URL, text: String) -> Bool {
        let path = sourceURL.path.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasSuffix(".json") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private func looksLikeHTML(sourceURL: URL, text: String) -> Bool {
        sourceURL.path == "/" || text.localizedCaseInsensitiveContains("<html") || text.localizedCaseInsensitiveContains("<meta")
    }

    private func isBinary(contentType: String?, url: URL) -> Bool {
        let binaryExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "pdf", "zip", "gz", "css", "js", "woff", "woff2", "ttf", "mp4", "mov"])
        if binaryExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let contentType = contentType?.lowercased() else { return false }
        return contentType.hasPrefix("image/") || contentType.hasPrefix("video/") || contentType.hasPrefix("font/")
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func stripHTML(_ value: String) -> String {
        decodeHTMLEntities(value)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private func merchantName(for domain: String) -> String {
        domain.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    private func productURLForShopifyProduct(_ product: [String: Any], domain: String) -> URL? {
        if let onlineURL = stringValue(product["online_store_url"]) {
            return URL(string: onlineURL)
        }

        guard let handle = stringValue(product["handle"]) else { return nil }
        return URL(string: "https://\(domain)/products/\(handle)")
    }

    private func shopifyImageURL(product: [String: Any], sourceURL: URL) -> URL? {
        if let image = product["image"] as? [String: Any],
           let src = stringValue(image["src"]) {
            return URL(string: src, relativeTo: sourceURL)?.absoluteURL
        }

        if let images = product["images"] as? [[String: Any]],
           let src = images.first.flatMap({ stringValue($0["src"]) }) {
            return URL(string: src, relativeTo: sourceURL)?.absoluteURL
        }

        return nil
    }

    private func priceHint(from operation: [String: Any]) -> Money? {
        Money.parse(operation["x-price"])
            ?? Money.parse(operation["price"])
            ?? Money.parse(operation["cost"])
            ?? Money.parse((operation["x402"] as? [String: Any])?["price"])
            ?? Money.parse((operation["x-payment"] as? [String: Any])?["price"])
    }

    private func paymentHint(from operation: [String: Any]) -> PaymentHint? {
        if containsText(operation, matching: ["x402"]) {
            return PaymentHint(method: "x402", endpoint: nil, acceptedRails: ["x402"])
        }

        guard let payment = operation["x-payment"] as? [String: Any] else { return nil }
        return PaymentHint(
            method: stringValue(payment["method"]) ?? "payment",
            endpoint: stringValue(payment["endpoint"]).flatMap(URL.init(string:)),
            acceptedRails: (payment["rails"] as? [String]) ?? []
        )
    }

    private func isPurchaseRelevant(path: String, title: String, description: String?) -> Bool {
        let value = ([path, title, description ?? ""] as [String]).joined(separator: " ").lowercased()
        let tokens = ["buy", "purchase", "checkout", "order", "subscribe", "subscription", "billing", "payment", "invoice", "charge", "price", "pricing", "cart", "license", "plan"]
        return tokens.contains { value.contains($0) }
    }

    private func collectDictionaries(from object: Any, into dictionaries: inout [[String: Any]]) {
        if let dictionary = object as? [String: Any] {
            dictionaries.append(dictionary)
            for value in dictionary.values {
                collectDictionaries(from: value, into: &dictionaries)
            }
        } else if let array = object as? [Any] {
            for item in array {
                collectDictionaries(from: item, into: &dictionaries)
            }
        }
    }

    private func candidateKind(for source: DiscoverySource, sourceURL: URL) -> CandidateSourceKind {
        switch source {
        case .ucp: return .ucp
        case .commerceManifest: return .commerceManifest
        case .agentCard: return .agentCard
        case .siteAI: return .siteAI
        case .openAPI, .swagger: return .openAPI
        case .shopifyProducts: return .productsJSON
        case .woocommerceStore: return .woocommerce
        default:
            let path = sourceURL.path.lowercased()
            if path.contains("ucp") { return .ucp }
            if path.contains("commerce") { return .commerceManifest }
            if path.contains("openapi") || path.contains("swagger") { return .openAPI }
            if path.contains("products.json") { return .productsJSON }
            return .htmlFallback
        }
    }

    private func purchaseStrategy(for sourceKind: CandidateSourceKind, domain: String) -> PurchaseStrategy {
        if domain == "dialtoneapp.com" { return .dialtoneappNetwork }
        switch sourceKind {
        case .x402: return .x402
        case .openAPI, .ucp, .commerceManifest, .agentCard, .siteAI: return .apiAction
        case .productsJSON, .jsonLD, .htmlFallback, .woocommerce: return .browserCheckout
        }
    }

    private func containsText(_ object: Any, matching tokens: [String]) -> Bool {
        let lowercasedTokens = tokens.map { $0.lowercased() }

        if let string = object as? String {
            let value = string.lowercased()
            return lowercasedTokens.contains { value.contains($0) }
        }

        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let lowercasedKey = key.lowercased()
                if lowercasedTokens.contains(where: { lowercasedKey.contains($0) }) {
                    return true
                }
                if containsText(value, matching: tokens) {
                    return true
                }
            }
        }

        if let array = object as? [Any] {
            return array.contains { containsText($0, matching: tokens) }
        }

        return false
    }

    private func imageURL(from value: Any?, sourceURL: URL) -> URL? {
        if let string = stringValue(value) {
            return URL(string: string, relativeTo: sourceURL)?.absoluteURL
        }

        if let strings = value as? [String], let first = strings.first {
            return URL(string: first, relativeTo: sourceURL)?.absoluteURL
        }

        if let dictionary = value as? [String: Any],
           let url = stringValue(dictionary["url"]) ?? stringValue(dictionary["src"]) {
            return URL(string: url, relativeTo: sourceURL)?.absoluteURL
        }

        return nil
    }

    private func isJSONLDProduct(_ dictionary: [String: Any]) -> Bool {
        guard let type = dictionary["@type"] else { return false }
        if let string = type as? String {
            return string.localizedCaseInsensitiveContains("Product") || string.localizedCaseInsensitiveContains("Offer")
        }
        if let array = type as? [String] {
            return array.contains { $0.localizedCaseInsensitiveContains("Product") || $0.localizedCaseInsensitiveContains("Offer") }
        }
        return false
    }

    private func metaValue(in html: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                #"<meta[^>]+(?:property|name)=["']\#(escaped)["'][^>]+content=["']([^"']+)["'][^>]*>"#,
                #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']\#(escaped)["'][^>]*>"#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(html.startIndex..<html.endIndex, in: html)
                guard let match = regex.firstMatch(in: html, range: range),
                      let valueRange = Range(match.range(at: 1), in: html) else {
                    continue
                }
                let value = decodeHTMLEntities(String(html[valueRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }

        return nil
    }

    private func dedupeCandidates(_ candidates: [PurchaseCandidate]) -> [PurchaseCandidate] {
        var seen = Set<String>()
        var deduped: [PurchaseCandidate] = []

        for candidate in candidates where !seen.contains(candidate.fingerprint) {
            seen.insert(candidate.fingerprint)
            deduped.append(candidate)
        }

        return deduped
    }
}

private struct OrderedURLSet {
    private(set) var values: [URL] = []
    private var seen = Set<String>()

    mutating func append(_ url: URL) {
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        values.append(url)
    }

    mutating func append(contentsOf urls: [URL]) {
        for url in urls {
            append(url)
        }
    }
}
