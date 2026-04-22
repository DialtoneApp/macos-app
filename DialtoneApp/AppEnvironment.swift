import Foundation

struct AppEnvironment {
    static let developmentFrontendURL = URL(string: "http://localhost:5173")!
    static let developmentAPIBaseURL = URL(string: "http://localhost:8787")!
    static let productionFrontendURL = URL(string: "https://dialtoneapp.com")!

    var frontendURL: URL
    var apiBaseURL: URL

    static var current: AppEnvironment {
        AppEnvironment(
            frontendURL: configuredURL(named: "FRONTEND_URL", defaultURL: defaultFrontendURL),
            apiBaseURL: configuredURL(named: "API_BASE_URL", defaultURL: defaultAPIBaseURL)
        )
    }

    func frontendPath(_ path: String) -> URL {
        frontendURL.appendingPath(path)
    }

    func apiPath(_ path: String) -> URL {
        apiBaseURL.appendingPath(path)
    }

    private static var defaultFrontendURL: URL {
        #if DEBUG
        developmentFrontendURL
        #else
        productionFrontendURL
        #endif
    }

    private static var defaultAPIBaseURL: URL {
        #if DEBUG
        developmentAPIBaseURL
        #else
        productionFrontendURL
        #endif
    }

    private static func configuredURL(named name: String, defaultURL: URL) -> URL {
        let rawValue = ProcessInfo.processInfo.environment[name]
            ?? Bundle.main.object(forInfoDictionaryKey: name) as? String

        guard
            let rawValue,
            let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme != nil,
            url.host != nil
        else {
            return defaultURL
        }

        return url
    }
}

private extension URL {
    func appendingPath(_ path: String) -> URL {
        path
            .split(separator: "/")
            .reduce(self) { url, component in
                url.appendingPathComponent(String(component), isDirectory: false)
            }
    }
}
