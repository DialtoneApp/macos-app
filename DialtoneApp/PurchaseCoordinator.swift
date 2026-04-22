import AppKit
import Foundation
import Security

@MainActor
final class PurchaseCoordinator {
    private let logStore: LocalLogStore
    private let session: URLSession
    private let loginURL = URL(string: "https://dialtoneapp.com/login")!
    private let botBuyerURL = URL(string: "https://dialtoneapp.com/bot-buyer")!
    private let desktopLoginRequestURL = URL(string: "https://dialtoneapp.com/api/auth/desktop-login-requests")!
    private let desktopLoginExchangeURL = URL(string: "https://dialtoneapp.com/api/auth/desktop-login-requests/exchange")!
    private let desktopCallbackURL = URL(string: "dialtoneapp-desktop://auth/callback")!
    private let pendingDesktopLoginStateKey = "dialtoneapp.desktop_login.state"
    private let pendingDesktopLoginRequestIDKey = "dialtoneapp.desktop_login.request_id"

    init(logStore: LocalLogStore) {
        self.logStore = logStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func reject(_ candidate: PurchaseCandidate) {
        logStore.append(.agent, level: .warning, "Candidate rejected", metadata: [
            "candidate_id": candidate.id.uuidString,
            "domain": candidate.domain,
            "title": candidate.title
        ])
    }

    func approve(_ candidate: PurchaseCandidate) async -> PurchaseFlowResult {
        let purchaseRequestID = UUID().uuidString
        logStore.append(.agent, level: .success, "Candidate approved", metadata: [
            "candidate_id": candidate.id.uuidString,
            "domain": candidate.domain,
            "title": candidate.title
        ])
        logStore.append(.purchases, "Purchase flow started", metadata: [
            "candidate_id": candidate.id.uuidString,
            "purchase_request_id": purchaseRequestID,
            "domain": candidate.domain,
            "strategy": candidate.purchaseStrategy.rawValue
        ])

        guard let token = loadDesktopSessionToken(), !token.isEmpty else {
            let authURL = await openDesktopLogin()
            let result = PurchaseFlowResult(
                state: .needsLogin,
                message: "DialtoneApp login is required before buying.",
                requestID: purchaseRequestID,
                handoffURL: authURL
            )
            logResult(result, candidate: candidate)
            return result
        }

        do {
            let hasCard = try await checkSavedCard(token: token, candidate: candidate, requestID: purchaseRequestID)
            guard hasCard else {
                NSWorkspace.shared.open(botBuyerURL)
                let result = PurchaseFlowResult(
                    state: .needsBotBuyerCard,
                    message: "Add a saved bot-buyer card before DialtoneApp Desktop can buy on your behalf.",
                    requestID: purchaseRequestID,
                    handoffURL: botBuyerURL
                )
                logResult(result, candidate: candidate)
                return result
            }

            let result = try await submitPurchase(candidate: candidate, token: token, purchaseRequestID: purchaseRequestID)
            if result.state == .needsBrowserCheckout, let handoffURL = result.handoffURL {
                NSWorkspace.shared.open(handoffURL)
            }
            logResult(result, candidate: candidate)
            return result
        } catch {
            let result = PurchaseFlowResult(
                state: .failed,
                message: error.localizedDescription,
                requestID: purchaseRequestID,
                handoffURL: nil
            )
            logResult(result, candidate: candidate)
            return result
        }
    }

    func handleAuthCallback(_ url: URL) async -> Bool {
        guard isDesktopAuthCallback(url) else {
            return false
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        if let error = queryItems.trimmedValue(named: "error") {
            logStore.append(.purchases, level: .error, "Desktop login callback returned an error", metadata: [
                "error": error
            ])
            clearPendingDesktopLogin()
            return true
        }

        guard let code = queryItems.trimmedValue(named: "code") else {
            logStore.append(.purchases, level: .error, "Desktop login callback missing code")
            return true
        }

        let returnedState = queryItems.trimmedValue(named: "state")
        if let expectedState = UserDefaults.standard.string(forKey: pendingDesktopLoginStateKey),
           let returnedState,
           returnedState != expectedState {
            logStore.append(.purchases, level: .error, "Desktop login callback state mismatch")
            return true
        }

        do {
            let token = try await exchangeDesktopAuthCode(code: code, state: returnedState)
            try saveDesktopSessionToken(token)
            clearPendingDesktopLogin()
            logStore.append(.purchases, level: .success, "Desktop login token stored in Keychain")
        } catch {
            logStore.append(.purchases, level: .error, "Desktop login exchange failed", metadata: [
                "error": error.localizedDescription
            ])
        }

        return true
    }

    private func openDesktopLogin() async -> URL {
        do {
            let desktopLogin = try await createDesktopLoginRequest()
            NSWorkspace.shared.open(desktopLogin.loginURL)
            logStore.append(.purchases, level: .success, "Desktop login handoff opened", metadata: [
                "desktop_request_id": desktopLogin.requestID ?? "none",
                "state_set": desktopLogin.state.isEmpty ? "false" : "true"
            ])
            return desktopLogin.loginURL
        } catch {
            NSWorkspace.shared.open(loginURL)
            logStore.append(.purchases, level: .warning, "Desktop login request failed; opened fallback login", metadata: [
                "error": error.localizedDescription
            ])
            return loginURL
        }
    }

    private func createDesktopLoginRequest() async throws -> DesktopLoginRequest {
        let state = UUID().uuidString
        var request = URLRequest(url: desktopLoginRequestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "app_name": "DialtoneApp Desktop",
            "app_version": appVersion,
            "callback_url": desktopCallbackURL.absoluteString,
            "state": state
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let durationMS = Int(Date().timeIntervalSince(started) * 1_000)

        logStore.append(.purchases, level: (200..<300).contains(status) ? .success : .warning, "Desktop login request completed", metadata: [
            "status": "\(status)",
            "duration_ms": "\(durationMS)",
            "bytes": "\(data.count)"
        ])

        guard (200..<300).contains(status) else {
            throw DesktopAuthError.requestFailed(status: status)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopAuthError.invalidResponse("desktop login response was not JSON")
        }

        let requestID = stringValue(object["desktop_request_id"])
            ?? stringValue(object["request_id"])
            ?? stringValue(object["id"])
        let responseState = stringValue(object["state"]) ?? state
        let responseLoginURL = stringValue(object["login_url"])
            ?? stringValue(object["loginUrl"])
            ?? stringValue(object["url"])

        guard requestID != nil || responseLoginURL != nil else {
            throw DesktopAuthError.invalidResponse("desktop login response did not include a request id or login URL")
        }

        let handoffURL = responseLoginURL.flatMap(URL.init(string:))
            ?? makeLoginURL(desktopRequestID: requestID)

        UserDefaults.standard.set(responseState, forKey: pendingDesktopLoginStateKey)
        if let requestID {
            UserDefaults.standard.set(requestID, forKey: pendingDesktopLoginRequestIDKey)
        }

        return DesktopLoginRequest(requestID: requestID, state: responseState, loginURL: handoffURL)
    }

    private func exchangeDesktopAuthCode(code: String, state: String?) async throws -> String {
        var request = URLRequest(url: desktopLoginExchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: String] = [
            "code": code,
            "callback_url": desktopCallbackURL.absoluteString
        ]
        if let state {
            body["state"] = state
        }
        if let requestID = UserDefaults.standard.string(forKey: pendingDesktopLoginRequestIDKey) {
            body["desktop_request_id"] = requestID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let durationMS = Int(Date().timeIntervalSince(started) * 1_000)

        logStore.append(.purchases, level: (200..<300).contains(status) ? .success : .warning, "Desktop login code exchange completed", metadata: [
            "status": "\(status)",
            "duration_ms": "\(durationMS)",
            "bytes": "\(data.count)"
        ])

        guard (200..<300).contains(status) else {
            throw DesktopAuthError.exchangeFailed(status: status)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopAuthError.invalidResponse("desktop login exchange response was not JSON")
        }

        guard let token = stringValue(object["session_token"])
            ?? stringValue(object["sessionToken"])
            ?? stringValue(object["token"]) else {
            throw DesktopAuthError.invalidResponse("desktop login exchange response did not include a session token")
        }

        return token
    }

    private func checkSavedCard(token: String, candidate: PurchaseCandidate, requestID: String) async throws -> Bool {
        let url = URL(string: "https://dialtoneapp.com/api/users/me/network-card")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let durationMS = Int(Date().timeIntervalSince(started) * 1_000)

        logStore.append(.purchases, level: status == 200 ? .success : .warning, "Saved-card check completed", metadata: [
            "candidate_id": candidate.id.uuidString,
            "purchase_request_id": requestID,
            "status": "\(status)",
            "duration_ms": "\(durationMS)",
            "bytes": "\(data.count)"
        ])

        guard status == 200 else { return false }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return true
        }

        if let hasCard = object["has_saved_bot_buyer_card"] as? Bool {
            return hasCard
        }

        if let hasCard = object["hasCard"] as? Bool {
            return hasCard
        }

        return true
    }

    private func submitPurchase(
        candidate: PurchaseCandidate,
        token: String,
        purchaseRequestID: String
    ) async throws -> PurchaseFlowResult {
        let url = URL(string: "https://dialtoneapp.com/api/users/me/bot-purchases")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = purchaseBody(candidate: candidate)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let durationMS = Int(Date().timeIntervalSince(started) * 1_000)

        logStore.append(.purchases, level: (200..<300).contains(status) ? .success : .warning, "DialtoneApp Network response", metadata: [
            "candidate_id": candidate.id.uuidString,
            "purchase_request_id": purchaseRequestID,
            "status": "\(status)",
            "duration_ms": "\(durationMS)",
            "bytes": "\(data.count)"
        ])

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let state = PurchaseResultState(rawValue: stringValue(object?["state"]) ?? stringValue(object?["result"]) ?? "") ?? fallbackState(status: status, candidate: candidate)
        let message = stringValue(object?["message"])
            ?? stringValue(object?["reason"])
            ?? defaultMessage(for: state, candidate: candidate)
        let handoffURL = stringValue(object?["checkout_url"])
            .flatMap(URL.init(string:))
            ?? stringValue(object?["handoff_url"]).flatMap(URL.init(string:))
            ?? candidate.productURL

        return PurchaseFlowResult(
            state: state,
            message: message,
            requestID: purchaseRequestID,
            handoffURL: handoffURL
        )
    }

    private func purchaseBody(candidate: PurchaseCandidate) -> [String: Any] {
        var body: [String: Any] = [
            "candidate_id": candidate.id.uuidString,
            "domain": candidate.domain,
            "title": candidate.title,
            "source_url": candidate.sourceURL.absoluteString,
            "purchase_strategy": candidate.purchaseStrategy.rawValue
        ]

        if let description = candidate.description {
            body["description"] = description
        }

        if let price = candidate.price {
            body["price"] = [
                "amount": NSDecimalNumber(decimal: price.amount).stringValue,
                "currency": price.currency
            ]
        }

        if let productURL = candidate.productURL {
            body["product_url"] = productURL.absoluteString
        }

        if let call = candidate.discoveredApiCall {
            body["discovered_api_call"] = [
                "method": call.method,
                "url": call.url.absoluteString
            ]
        }

        return body
    }

    private func fallbackState(status: Int, candidate: PurchaseCandidate) -> PurchaseResultState {
        switch status {
        case 200..<300:
            return .purchased
        case 401:
            return .needsLogin
        case 402:
            return .needsBotBuyerCard
        case 409:
            return .failed
        case 501:
            return .unsupportedMerchant
        default:
            return candidate.purchaseStrategy == .browserCheckout ? .needsBrowserCheckout : .failed
        }
    }

    private func defaultMessage(for state: PurchaseResultState, candidate: PurchaseCandidate) -> String {
        switch state {
        case .purchased:
            return "Purchase completed."
        case .needsLogin:
            return "DialtoneApp login is required before buying."
        case .needsBotBuyerCard:
            return "A saved bot-buyer card is required."
        case .needsBrowserCheckout:
            return "This item was found, but v0.0.1 needs a browser checkout handoff."
        case .unsupportedMerchant:
            return "\(candidate.domain) is not supported by DialtoneApp Network yet."
        case .failed:
            return "Purchase request failed."
        }
    }

    private func makeLoginURL(desktopRequestID: String?) -> URL {
        var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if let desktopRequestID {
            queryItems.append(URLQueryItem(name: "desktop_request_id", value: desktopRequestID))
        }
        components?.queryItems = queryItems
        return components?.url ?? loginURL
    }

    private func isDesktopAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "dialtoneapp-desktop"
            && url.host?.lowercased() == "auth"
            && url.path.lowercased() == "/callback"
    }

    private func clearPendingDesktopLogin() {
        UserDefaults.standard.removeObject(forKey: pendingDesktopLoginStateKey)
        UserDefaults.standard.removeObject(forKey: pendingDesktopLoginRequestIDKey)
    }

    private func logResult(_ result: PurchaseFlowResult, candidate: PurchaseCandidate) {
        let level: LogLevel
        switch result.state {
        case .purchased:
            level = .success
        case .failed:
            level = .error
        default:
            level = .warning
        }

        logStore.append(.purchases, level: level, "Purchase flow finished", metadata: [
            "candidate_id": candidate.id.uuidString,
            "request_id": result.requestID ?? "none",
            "state": result.state.rawValue,
            "handoff": result.handoffURL?.absoluteString ?? "none",
            "message": result.message
        ])
    }

    private func loadDesktopSessionToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "DialtoneApp Desktop",
            kSecAttrAccount as String: "desktop_session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func saveDesktopSessionToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query = desktopSessionQuery()
        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw DesktopAuthError.keychain(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DesktopAuthError.keychain(status: addStatus)
        }
    }

    private func desktopSessionQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "DialtoneApp Desktop",
            kSecAttrAccount as String: "desktop_session"
        ]
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
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
}

private struct DesktopLoginRequest {
    var requestID: String?
    var state: String
    var loginURL: URL
}

private enum DesktopAuthError: LocalizedError {
    case requestFailed(status: Int)
    case exchangeFailed(status: Int)
    case invalidResponse(String)
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            return "Desktop login request failed with status \(status)."
        case .exchangeFailed(let status):
            return "Desktop login code exchange failed with status \(status)."
        case .invalidResponse(let message):
            return message
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain write failed: \(message)"
        }
    }
}

private extension Array where Element == URLQueryItem {
    func trimmedValue(named name: String) -> String? {
        guard let rawValue = first(where: { $0.name == name })?.value else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
