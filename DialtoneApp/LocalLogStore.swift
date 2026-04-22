import AppKit
import Combine
import Foundation

@MainActor
final class LocalLogStore: ObservableObject {
    @Published private(set) var agentLines: [LogLine] = []
    @Published private(set) var networkLines: [LogLine] = []
    @Published private(set) var purchaseLines: [LogLine] = []

    let logDirectory: URL
    let appSupportDirectory: URL

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        logDirectory = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DialtoneApp Desktop", isDirectory: true)

        appSupportDirectory = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DialtoneApp Desktop", isDirectory: true)

        createDirectories(fileManager: fileManager)
        ensureLogFiles(fileManager: fileManager)
        reload()
    }

    func append(
        _ channel: LogChannel,
        level: LogLevel = .info,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        let timestamp = dateFormatter.string(from: Date())
        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(sanitize($0.value))" }
            .joined(separator: " ")

        let line: String
        if metadataText.isEmpty {
            line = "\(timestamp) [\(level.rawValue.uppercased())] \(sanitize(message))"
        } else {
            line = "\(timestamp) [\(level.rawValue.uppercased())] \(sanitize(message)) \(metadataText)"
        }

        appendLine(line, to: channel)
        push(LogLine(channel: channel, level: level, text: line), channel: channel)
    }

    func lines(for channel: LogChannel) -> [LogLine] {
        switch channel {
        case .agent: return agentLines
        case .network: return networkLines
        case .purchases: return purchaseLines
        }
    }

    func clear(_ channel: LogChannel) {
        let url = fileURL(for: channel)
        do {
            try Data().write(to: url, options: .atomic)
            switch channel {
            case .agent: agentLines = []
            case .network: networkLines = []
            case .purchases: purchaseLines = []
            }
            append(.agent, level: .warning, "Cleared local log", metadata: ["channel": channel.rawValue])
        } catch {
            append(.agent, level: .error, "Unable to clear local log", metadata: ["channel": channel.rawValue, "error": error.localizedDescription])
        }
    }

    func reload() {
        agentLines = readLines(.agent)
        networkLines = readLines(.network)
        purchaseLines = readLines(.purchases)
    }

    func revealLogFiles() {
        NSWorkspace.shared.activateFileViewerSelecting([logDirectory])
    }

    func writeDomainState(domains: [String]) {
        let url = appSupportDirectory.appendingPathComponent("domains.json")
        let states = domains.map {
            [
                "domain": $0,
                "last_scan_status": "pending",
                "last_scanned_at": NSNull()
            ] as [String: Any]
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: states, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            append(.agent, level: .error, "Unable to write domain state", metadata: ["error": error.localizedDescription])
        }
    }

    private func createDirectories(fileManager: FileManager) {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        } catch {
            assertionFailure("Unable to create DialtoneApp Desktop directories: \(error)")
        }
    }

    private func ensureLogFiles(fileManager: FileManager) {
        for channel in LogChannel.allCases {
            let path = fileURL(for: channel).path
            if !fileManager.fileExists(atPath: path) {
                fileManager.createFile(atPath: path, contents: nil)
            }
        }
    }

    private func readLines(_ channel: LogChannel) -> [LogLine] {
        let url = fileURL(for: channel)
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return []
        }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { line in
                LogLine(channel: channel, level: parseLevel(from: line), text: line)
            }
    }

    private func appendLine(_ line: String, to channel: LogChannel) {
        let url = fileURL(for: channel)
        let data = Data((line + "\n").utf8)

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                assertionFailure("Unable to write DialtoneApp Desktop log: \(error)")
            }
        }
    }

    private func push(_ line: LogLine, channel: LogChannel) {
        switch channel {
        case .agent:
            agentLines.append(line)
            agentLines = Array(agentLines.suffix(1_000))
        case .network:
            networkLines.append(line)
            networkLines = Array(networkLines.suffix(2_000))
        case .purchases:
            purchaseLines.append(line)
            purchaseLines = Array(purchaseLines.suffix(1_000))
        }
    }

    private func fileURL(for channel: LogChannel) -> URL {
        logDirectory.appendingPathComponent(channel.fileName)
    }

    private func parseLevel(from line: String) -> LogLevel {
        if line.contains("[ERROR]") { return .error }
        if line.contains("[WARNING]") { return .warning }
        if line.contains("[SUCCESS]") { return .success }
        return .info
    }

    private func sanitize(_ value: String) -> String {
        var sanitized = value
        let blockedKeys = [
            "authorization",
            "set-cookie",
            "cookie",
            "token",
            "secret",
            "signature",
            "card",
            "stripe"
        ]

        for key in blockedKeys {
            sanitized = sanitized.replacingOccurrences(
                of: #"(?i)\#(key)[=:]\S+"#,
                with: "\(key)=<redacted>",
                options: .regularExpression
            )
        }

        if sanitized.count > 2_000 {
            sanitized = String(sanitized.prefix(2_000)) + "...<truncated>"
        }

        return sanitized
    }
}
