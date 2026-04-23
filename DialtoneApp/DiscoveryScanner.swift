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
        var domainImageFallback: DomainImageFallback?
    }

    private struct DomainImageFallback {
        var url: URL
        var kind: PurchaseCandidate.ImageKind
    }

    private let logStore: LocalLogStore
    private let session: URLSession
    private let onStatus: (String) -> Void
    private let onCandidates: ([PurchaseCandidate]) -> Void
    private let onReport: (DomainDiscoveryReport) -> Void

    private let bootstrapExtraDomainCount = 12
    private let recentDomainWindow = 20
    private let randomRoundDelayRange = 25...70

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
        onStatus("Scanning randomized domain mix")

        var recentDomains: [String] = []
        let bootstrapDomains = randomizedBootstrapDomains()

        logStore.append(.agent, "Batch started", metadata: [
            "batch": "randomized_bootstrap",
            "domains": "\(bootstrapDomains.count)"
        ])
        for domain in bootstrapDomains {
            guard !Task.isCancelled else { return }
            await waitWhilePaused()
            await scanDomain(domain)
            rememberRecentDomain(domain, in: &recentDomains)
        }
        logStore.append(.agent, level: .success, "Batch finished", metadata: ["batch": "randomized_bootstrap"])

        var round = 1
        while !Task.isCancelled {
            let roundDomains = randomizedFullCorpusRound(recentDomains: recentDomains)
            logStore.append(.agent, "Batch started", metadata: [
                "batch": "randomized_full_corpus",
                "round": "\(round)",
                "domains": "\(roundDomains.count)"
            ])

            for domain in roundDomains {
                guard !Task.isCancelled else { return }
                await waitWhilePaused()
                let delaySeconds = UInt64(Int.random(in: randomRoundDelayRange))
                onStatus("Next random scan in \(delaySeconds)s: \(domain)")
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                await waitWhilePaused()
                await scanDomain(domain)
                rememberRecentDomain(domain, in: &recentDomains)
            }

            logStore.append(.agent, level: .success, "Batch finished", metadata: [
                "batch": "randomized_full_corpus",
                "round": "\(round)"
            ])
            round += 1
        }
    }

    private func randomizedBootstrapDomains() -> [String] {
        let highSignal = DomainCorpus.highSignal.shuffled()
        let highSignalSet = Set(highSignal)
        let extraDomains = Array(DomainCorpus.all
            .filter { !highSignalSet.contains($0) }
            .shuffled()
            .prefix(bootstrapExtraDomainCount))

        return (highSignal + extraDomains).shuffled()
    }

    private func randomizedFullCorpusRound(recentDomains: [String]) -> [String] {
        let recentSet = Set(recentDomains)
        let shuffled = DomainCorpus.all.shuffled()
        return shuffled.filter { !recentSet.contains($0) } + shuffled.filter { recentSet.contains($0) }
    }

    private func rememberRecentDomain(_ domain: String, in recentDomains: inout [String]) {
        recentDomains.removeAll { $0 == domain }
        recentDomains.append(domain)

        if recentDomains.count > recentDomainWindow {
            recentDomains.removeFirst(recentDomains.count - recentDomainWindow)
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
        var domainImageFallback: DomainImageFallback?

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
            if probe.source == .homepage, let fallback = parsed.domainImageFallback {
                domainImageFallback = fallback
            }
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

        let enrichedCandidates = applyDomainImageFallback(domainImageFallback, to: candidates)
        let dedupedCandidates = dedupeCandidates(enrichedCandidates)
        let report = DomainDiscoveryReport(
            domain: domain,
            startedAt: startedAt,
            finishedAt: Date(),
            networkCalls: networkCalls,
            discoveredApiCalls: Array(discoveredApiCalls.prefix(80)),
            candidates: Array(dedupedCandidates.prefix(20))
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

            if isX402Manifest(object) {
                result.candidates.append(contentsOf: parseX402Manifest(object: object, domain: domain, sourceURL: sourceURL))
            } else {
                let generic = parseGenericProductJSON(object: object, domain: domain, sourceURL: sourceURL, source: source)
                result.candidates.append(contentsOf: generic)
            }
        }

        if looksLikeHTML(sourceURL: sourceURL, text: text) {
            result.candidates.append(contentsOf: parseJSONLDProducts(html: text, domain: domain, sourceURL: sourceURL))
            result.candidates.append(contentsOf: parseOpenGraphProduct(html: text, domain: domain, sourceURL: sourceURL))
            if source == .homepage {
                result.domainImageFallback = domainImageFallback(in: text, sourceURL: sourceURL)
            }
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
                ?? Money.parseFirstPrice(in: title, currency: currency)
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
                ?? Money.parseFirstPrice(in: title, currency: stringValue(product["currency_code"]))
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
                    ?? Money.parseFirstPrice(in: title)
                    ?? Money.parseFirstPrice(in: description)
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

    private func parseX402Manifest(
        object: Any,
        domain: String,
        sourceURL: URL
    ) -> [PurchaseCandidate] {
        guard let root = object as? [String: Any] else { return [] }

        let items = (root["items"] as? [[String: Any]]) ?? [root].filter { $0["resource"] != nil }
        guard !items.isEmpty else { return [] }

        let candidates = items.prefix(16).compactMap { item -> PurchaseCandidate? in
            let resourceObject = item["resource"] as? [String: Any]
            let resourceURLString = stringValue(resourceObject?["url"]) ?? stringValue(item["resource"])
            let metadata = item["metadata"] as? [String: Any]
            let rawTitle = stringValue(item["title"])
                ?? stringValue(item["name"])
                ?? stringValue(resourceObject?["name"])
                ?? stringValue(metadata?["networkSlug"]).map { "JSON-RPC proxy - \($0)" }
                ?? stringValue(resourceObject?["description"])
                ?? x402TitleFromResourceURL(resourceURLString, sourceURL: sourceURL)

            guard let title = rawTitle else { return nil }

            let description = stringValue(item["description"])
                ?? stringValue(resourceObject?["description"])
                ?? stringValue(metadata?["description"])
            let productURL = resourceURLString
                .flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }
                ?? stringValue(item["url"]).flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }
            let price = x402MoneyHint(from: item)
            let paymentHint = PaymentHint(method: "x402", endpoint: productURL, acceptedRails: acceptedRails(from: item))

            let call = DiscoveredApiCall(
                domain: domain,
                method: x402Method(from: item),
                url: productURL ?? sourceURL,
                source: .discoveredURL,
                capability: title,
                priceHint: price,
                paymentHint: paymentHint,
                confidence: price == nil ? 0.7 : 0.84
            )

            return PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: description,
                price: price,
                imageURL: nil,
                productURL: productURL,
                sourceURL: sourceURL,
                sourceKind: .x402,
                purchaseStrategy: .x402,
                confidence: price == nil ? 0.68 : 0.84,
                discoveredApiCall: call
            )
        }

        return Array(dedupeCandidates(candidates).prefix(12))
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
            let pricing = dictionary["pricing"] as? [String: Any]
            let payment = dictionary["payment"] as? [String: Any]
            let description = stringValue(dictionary["description"]).map(stripHTML)
            let currency = stringValue(dictionary["currency"])
                ?? stringValue(dictionary["priceCurrency"])
                ?? stringValue(offer?["priceCurrency"])
                ?? stringValue(pricing?["currency"])
                ?? stringValue(payment?["currency"])
            let price = x402MoneyHint(from: dictionary)
                ?? Money.parse(
                    dictionary["price"]
                        ?? dictionary["amount"]
                        ?? offer?["price"]
                        ?? pricing?["price"]
                        ?? pricing?["amount"]
                        ?? payment?["price"]
                        ?? payment?["amount"],
                    currency: currency
                )
                ?? Money.parseFirstPrice(
                    in: [title, description].compactMap { $0 }.joined(separator: " "),
                    currency: currency
                )

            let productURL = stringValue(dictionary["url"])
                .flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }
            let imageURL = imageURL(from: dictionary["image"], sourceURL: sourceURL)
            let candidateSourceKind = sourceKind == .agentCard && (price != nil || containsText(dictionary, matching: ["x402"]))
                ? .x402
                : sourceKind

            let hasBuyingSignal = price != nil
                || productURL != nil
                || candidateSourceKind == .commerceManifest
                || candidateSourceKind == .ucp
                || containsText(dictionary, matching: ["x402", "purchase", "checkout", "subscription", "billing"])

            guard hasBuyingSignal else { return nil }

            return PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: description,
                price: price,
                imageURL: imageURL,
                productURL: productURL,
                sourceURL: sourceURL,
                sourceKind: candidateSourceKind,
                purchaseStrategy: purchaseStrategy(for: candidateSourceKind, domain: domain),
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
                let description = stringValue(dictionary["description"]).map(stripHTML)
                let price = Money.parse(
                    dictionary["price"] ?? offer?["price"],
                    currency: stringValue(dictionary["priceCurrency"]) ?? stringValue(offer?["priceCurrency"])
                ) ?? Money.parseFirstPrice(
                    in: [title, description].compactMap { $0 }.joined(separator: " "),
                    currency: stringValue(dictionary["priceCurrency"]) ?? stringValue(offer?["priceCurrency"])
                )

                candidates.append(
                    PurchaseCandidate(
                        domain: domain,
                        merchantName: merchantName(for: domain),
                        title: title,
                        description: description,
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
        guard let title = metaValue(in: html, keys: ["og:title", "twitter:title"]) else {
            return []
        }

        let description = metaValue(in: html, keys: ["og:description", "description"]).map(stripHTML)
        guard let price = Money.parse(
            metaValue(in: html, keys: ["product:price:amount", "og:price:amount", "twitter:data1"]),
            currency: metaValue(in: html, keys: ["product:price:currency", "og:price:currency"])
        ) ?? Money.parseFirstPrice(in: [title, description].compactMap { $0 }.joined(separator: " ")) else {
            return []
        }

        let imageURL = metaValue(in: html, keys: ["og:image", "twitter:image"])
            .flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }

        return [
            PurchaseCandidate(
                domain: domain,
                merchantName: merchantName(for: domain),
                title: title,
                description: description,
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

    private func applyDomainImageFallback(_ fallback: DomainImageFallback?, to candidates: [PurchaseCandidate]) -> [PurchaseCandidate] {
        guard let fallback else { return candidates }

        return candidates.map { candidate in
            guard candidate.imageURL == nil else { return candidate }
            var enriched = candidate
            enriched.imageURL = fallback.url
            enriched.imageKind = fallback.kind
            return enriched
        }
    }

    private func domainImageFallback(in html: String, sourceURL: URL) -> DomainImageFallback? {
        if let openGraphImage = metaValue(in: html, keys: ["og:image", "og:image:secure_url", "twitter:image"]),
           let url = URL(string: openGraphImage, relativeTo: sourceURL)?.absoluteURL {
            return DomainImageFallback(url: url, kind: .domainOpenGraph)
        }

        return faviconURL(in: html, sourceURL: sourceURL).map { DomainImageFallback(url: $0, kind: .favicon) }
    }

    private func faviconURL(in html: String, sourceURL: URL) -> URL? {
        let preferredRelValues = [
            "apple-touch-icon",
            "apple-touch-icon-precomposed",
            "icon",
            "shortcut icon",
            "mask-icon"
        ]

        for relValue in preferredRelValues {
            if let href = linkHref(in: html, relContaining: relValue),
               let url = URL(string: href, relativeTo: sourceURL)?.absoluteURL {
                return url
            }
        }

        return URL(string: "/favicon.ico", relativeTo: sourceURL)?.absoluteURL
    }

    private func linkHref(in html: String, relContaining relValue: String) -> String? {
        let linkPattern = #"<link\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) else { return nil }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let relNeedle = relValue.lowercased()

        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attributeValue("rel", in: tag)?.lowercased(),
                  rel.contains(relNeedle),
                  let href = attributeValue("href", in: tag) else {
                continue
            }

            return decodeHTMLEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func extractURLs(from text: String, baseURL: URL, domain: String) -> [URL] {
        var urls = OrderedURLSet()
        let patterns = [
            #"https?://[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]+"#,
            #"(?:href|src)=["']([^"']+)["']"#,
            #"(?m)^\s*(/[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range).prefix(300) {
                let captureIndex = match.numberOfRanges > 1 ? 1 : 0
                guard let matchRange = Range(match.range(at: captureIndex), in: text) else { continue }
                let raw = cleanURLCandidate(String(text[matchRange]))
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
        if containsURLQuote(url) { return false }
        if isBinary(contentType: nil, url: url) || looksLikeBinaryAssetURL(url) { return false }
        if looksLikeEditorialOrReportURL(url) { return false }

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
            "price",
            "checkout",
            "cart",
            "order",
            "billing",
            "subscription",
            "offer",
            "buy",
            "purchase",
            "artifact",
            "api-doc",
            "api-reference",
            "x402",
            "wp-json/wc/store/products"
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

    private func looksLikeBinaryAssetURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let blockedPathParts = [
            "/attachments/",
            "/attachment/",
            "/assets/",
            "/images/",
            "/image/",
            "/media/",
            "/uploads/",
            "/static/",
            "/_next/image",
            "/cdn-cgi/image"
        ]

        return blockedPathParts.contains { path.contains($0) }
    }

    private func looksLikeEditorialOrReportURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let blockedPrefixes = [
            "/q/",
            "/r/",
            "/blog/",
            "/blogs/",
            "/article/",
            "/articles/",
            "/guides/",
            "/guide/",
            "/reports/",
            "/report/",
            "/top-sites/"
        ]

        if blockedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }

        let components = path
            .split(separator: "/")
            .map(String.init)

        if let first = components.first,
           first.count == 4,
           first.allSatisfy(\.isNumber) {
            return true
        }

        return false
    }

    private func cleanURLCandidate(_ value: String) -> String {
        var cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>“”‘’`"))

        let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]}\"'’”`")
        while let last = cleaned.unicodeScalars.last, trailingPunctuation.contains(last) {
            cleaned.removeLast()
        }

        return cleaned
    }

    private func containsURLQuote(_ url: URL) -> Bool {
        let value = url.absoluteString
        return value.contains("'") || value.contains("\"") || value.contains("`") || value.contains("%27") || value.contains("%22")
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

    private func attributeValue(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b\#(escapedName)\s*=\s*(["'])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let valueRange = Range(match.range(at: 2), in: tag) else {
            return nil
        }

        let value = String(tag[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
        x402MoneyHint(from: operation)
            ?? Money.parse(operation["x-price"])
            ?? Money.parse(operation["price"])
            ?? Money.parse(operation["cost"])
            ?? Money.parse((operation["x402"] as? [String: Any])?["price"])
            ?? Money.parse((operation["x-payment"] as? [String: Any])?["price"])
    }

    private func paymentHint(from operation: [String: Any]) -> PaymentHint? {
        if x402MoneyHint(from: operation) != nil || containsText(operation, matching: ["x402"]) {
            return PaymentHint(method: "x402", endpoint: nil, acceptedRails: ["x402"])
        }

        guard let payment = operation["x-payment"] as? [String: Any] else { return nil }
        return PaymentHint(
            method: stringValue(payment["method"]) ?? "payment",
            endpoint: stringValue(payment["endpoint"]).flatMap(URL.init(string:)),
            acceptedRails: (payment["rails"] as? [String]) ?? []
        )
    }

    private func isX402Manifest(_ object: Any) -> Bool {
        guard let root = object as? [String: Any] else { return false }
        if root["items"] as? [[String: Any]] != nil { return true }
        return root["resource"] != nil && root["accepts"] != nil
    }

    private func x402MoneyHint(from dictionary: [String: Any]) -> Money? {
        let normalized = normalizedDictionary(dictionary)
        let keyedPrices: [(key: String, currency: String?)] = [
            ("x-x402-price-usdc", "USDC"),
            ("x-x402-price-usd", "USD"),
            ("x402-price-usdc", "USDC"),
            ("x402-price-usd", "USD"),
            ("x402_price_usdc", "USDC"),
            ("x402_price_usd", "USD"),
            ("x-price-usdc", "USDC"),
            ("x-price-usd", "USD"),
            ("price_usdc", "USDC"),
            ("price_usd", "USD"),
            ("priceusd", "USD"),
            ("cost_usdc", "USDC"),
            ("cost_usd", "USD")
        ]

        for keyedPrice in keyedPrices {
            if let value = normalized[keyedPrice.key],
               let money = Money.parse(value, currency: keyedPrice.currency) {
                return money
            }
        }

        let nestedKeys = ["x402", "x-payment", "payment", "paymentrequirements", "payment_requirements"]
        for key in nestedKeys {
            if let nested = normalized[key] as? [String: Any],
               let money = x402MoneyHint(from: nested) {
                return money
            }
        }

        if let accepts = normalized["accepts"] as? [[String: Any]] {
            return x402AcceptPrice(from: accepts)
        }

        if let accepts = normalized["accept"] as? [[String: Any]] {
            return x402AcceptPrice(from: accepts)
        }

        return nil
    }

    private func x402AcceptPrice(from accepts: [[String: Any]]) -> Money? {
        var best: (priority: Int, money: Money)?

        for accept in accepts {
            let normalized = normalizedDictionary(accept)
            let asset = stringValue(normalized["asset"])
                ?? stringValue(normalized["currency"])
                ?? stringValue(normalized["token"])
            let assetName = x402AssetName(from: accept)
            let amount = normalized["amount"]
                ?? normalized["maxamountrequired"]
                ?? normalized["max_amount_required"]
                ?? normalized["price"]
            let decimals = intValue(normalized["decimals"])
                ?? intValue(normalized["assetdecimals"])
                ?? intValue(normalized["asset_decimals"])
                ?? defaultDecimals(forX402Asset: asset, assetName: assetName)

            guard let money = parseX402Amount(amount, asset: asset, assetName: assetName, decimals: decimals) else {
                continue
            }

            let priority = x402AssetPriority(accept)
            if best == nil
                || priority > best!.priority
                || (priority == best!.priority && money.amount < best!.money.amount) {
                best = (priority, money)
            }
        }

        return best?.money
    }

    private func parseX402Amount(_ value: Any?, asset: String?, assetName: String?, decimals: Int?) -> Money? {
        guard let value else { return nil }

        let currency = normalizedX402Currency(asset, assetName: assetName)
        guard let rawAmount = stringValue(value)?.replacingOccurrences(of: ",", with: ""),
              !rawAmount.isEmpty else {
            return nil
        }

        if rawAmount.contains(".") || decimals == nil || decimals == 0 {
            return Money.parse(rawAmount, currency: currency)
        }

        guard let decimal = Decimal(string: rawAmount), let decimalPlaces = decimals else {
            return Money.parse(rawAmount, currency: currency)
        }

        var divisor = Decimal(1)
        for _ in 0..<decimalPlaces {
            divisor *= Decimal(10)
        }

        return Money(amount: decimal / divisor, currency: currency)
    }

    private func defaultDecimals(forX402Asset asset: String?, assetName: String?) -> Int? {
        let normalizedName = assetName?.lowercased() ?? ""
        if normalizedName.contains("usdc")
            || normalizedName.contains("usd coin")
            || normalizedName.contains("global dollar") {
            return 6
        }

        guard let asset else { return nil }
        let normalized = asset.lowercased()

        if normalized.hasPrefix("usdc") || normalized == "usd" {
            return 6
        }

        if normalized.hasPrefix("0x") || normalized.count >= 32 {
            return 6
        }

        if normalized == "sbtc" || normalized == "btc" {
            return 8
        }

        if normalized == "stx" {
            return 6
        }

        return nil
    }

    private func normalizedX402Currency(_ asset: String?, assetName: String?) -> String {
        let normalizedName = assetName?.lowercased() ?? ""
        if normalizedName.contains("usdc") || normalizedName.contains("usd coin") {
            return "USDC"
        }

        if normalizedName.contains("global dollar") {
            return "USD"
        }

        guard let asset, !asset.isEmpty else { return "USD" }
        let uppercased = asset.uppercased()

        if uppercased.hasPrefix("USDC") {
            return "USDC"
        }

        if asset.lowercased().hasPrefix("0x") || asset.count >= 32 {
            return "USDC"
        }

        return uppercased
    }

    private func x402AssetPriority(_ accept: [String: Any]) -> Int {
        let normalized = normalizedDictionary(accept)
        let assetName = x402AssetName(from: accept)?.lowercased() ?? ""
        let asset = (stringValue(normalized["asset"])
            ?? stringValue(normalized["currency"])
            ?? stringValue(normalized["token"])
            ?? "")
            .lowercased()

        if assetName.contains("usdc")
            || assetName.contains("usd coin")
            || assetName.contains("global dollar") {
            return 4
        }

        if asset.hasPrefix("usdc") { return 4 }
        if asset.hasPrefix("0x") || asset.count >= 32 { return 4 }
        if asset == "usd" { return 3 }
        if asset == "stx" { return 2 }
        if asset == "sbtc" || asset == "btc" { return 1 }
        return 0
    }

    private func x402AssetName(from accept: [String: Any]) -> String? {
        if let extra = accept["extra"] as? [String: Any],
           let name = stringValue(extra["name"]) {
            return name
        }

        let normalized = normalizedDictionary(accept)
        return stringValue(normalized["assetname"])
            ?? stringValue(normalized["asset_name"])
            ?? stringValue(normalized["name"])
    }

    private func acceptedRails(from item: [String: Any]) -> [String] {
        guard let accepts = item["accepts"] as? [[String: Any]] else { return ["x402"] }
        let rails = accepts.compactMap { accept -> String? in
            let normalized = normalizedDictionary(accept)
            let scheme = stringValue(normalized["scheme"]) ?? "x402"
            let network = stringValue(normalized["network"])
            let asset = stringValue(normalized["asset"])

            return [scheme, network, asset]
                .compactMap { $0 }
                .joined(separator: ":")
        }

        return rails.isEmpty ? ["x402"] : rails
    }

    private func x402Method(from item: [String: Any]) -> String {
        guard
            let extensions = item["extensions"] as? [String: Any],
            let bazaar = extensions["bazaar"] as? [String: Any],
            let info = bazaar["info"] as? [String: Any],
            let input = info["input"] as? [String: Any],
            let method = stringValue(input["method"])
        else {
            return "GET"
        }

        return method.uppercased()
    }

    private func x402TitleFromResourceURL(_ value: Any?, sourceURL: URL) -> String? {
        guard let string = stringValue(value),
              let url = URL(string: string, relativeTo: sourceURL)?.absoluteURL else {
            return nil
        }

        let component = url.lastPathComponent.replacingOccurrences(of: "-", with: " ")
        guard !component.isEmpty else { return nil }
        return component.capitalized
    }

    private func normalizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        if let string = stringValue(value) {
            return Int(string)
        }

        return nil
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
            if path.contains("x402") { return .x402 }
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
        CandidateDedupe.dedupe(candidates)
    }

    private func bestCandidate(in candidates: [PurchaseCandidate]) -> PurchaseCandidate {
        candidates.max { candidateScore($0) < candidateScore($1) } ?? candidates[0]
    }

    private func candidateDedupeKey(for candidate: PurchaseCandidate) -> String {
        if let offerKey = machineReadableOfferKey(for: candidate) {
            return offerKey
        }

        return titleDedupeKey(for: candidate)
    }

    private func machineReadableOfferKey(for candidate: PurchaseCandidate) -> String? {
        guard shouldClusterMachineReadableOffer(candidate) else { return nil }

        let value = normalizeForDedupe([
            candidate.title,
            candidate.description ?? "",
            candidate.sourceURL.path,
            candidate.productURL?.path ?? "",
            candidate.discoveredApiCall?.capability ?? ""
        ].joined(separator: " "))

        let families: [(String, [String])] = [
            ("membership", ["membership", "member"]),
            ("subscription", ["subscription", "subscribe", "plan", "monthly", "yearly"]),
            ("license", ["license", "licensing", "seat"]),
            ("checkout", ["checkout", "cart", "order"]),
            ("purchase", ["purchase", "buy", "payment", "billing", "charge", "invoice"])
        ]

        for family in families where family.1.contains(where: { value.contains($0) }) {
            return "\(candidate.domain)|machine-offer|\(family.0)"
        }

        return nil
    }

    private func shouldClusterMachineReadableOffer(_ candidate: PurchaseCandidate) -> Bool {
        switch candidate.sourceKind {
        case .openAPI, .ucp, .commerceManifest, .agentCard, .siteAI:
            return true
        case .productsJSON, .woocommerce, .jsonLD, .htmlFallback, .x402:
            return false
        }
    }

    private func titleDedupeKey(for candidate: PurchaseCandidate) -> String {
        let title = normalizeForDedupe(candidate.title)
        return "\(candidate.domain)|\(title)"
    }

    private func normalizeForDedupe(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\p{P}\p{S}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func candidateScore(_ candidate: PurchaseCandidate) -> Double {
        var score = candidate.confidence
        if candidate.price != nil { score += 0.30 }
        if candidate.productURL != nil { score += 0.15 }
        if candidate.imageURL != nil { score += 0.10 }
        if candidate.discoveredApiCall != nil { score += 0.04 }
        score += sourcePriority(candidate.sourceKind)
        return score
    }

    private func sourcePriority(_ kind: CandidateSourceKind) -> Double {
        switch kind {
        case .productsJSON, .woocommerce:
            return 0.08
        case .jsonLD:
            return 0.07
        case .commerceManifest, .x402:
            return 0.06
        case .openAPI:
            return 0.05
        case .ucp:
            return 0.04
        case .agentCard, .siteAI:
            return 0.03
        case .htmlFallback:
            return 0.01
        }
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
