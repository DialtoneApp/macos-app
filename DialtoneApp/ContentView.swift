//
//  ContentView.swift
//  DialtoneApp
//
//  Created by aa on 4/22/26.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class BotShoppingModel: ObservableObject {
    @Published var botEnabled = true {
        didSet {
            scanner?.setEnabled(botEnabled)
        }
    }
    @Published var status = "Starting scanner"
    @Published private(set) var candidates: [PurchaseCandidate] = []
    @Published private(set) var reports: [DomainDiscoveryReport] = []
    @Published private(set) var unseenCandidateCount = 0
    @Published private(set) var purchaseReadiness: DesktopPurchaseReadiness = .checking
    @Published private(set) var purchasingCandidateIDs = Set<UUID>()

    let logs: LocalLogStore

    private var scanner: DomainScanner?
    private let purchaseCoordinator: PurchaseCoordinator
    private var knownCandidateFingerprints = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let logs = LocalLogStore()
        self.logs = logs
        purchaseCoordinator = PurchaseCoordinator(logStore: logs)

        logs.append(.agent, level: .success, "DialtoneApp Desktop launched")
        logs.writeDomainState(domains: DomainCorpus.all)

        scanner = DomainScanner(
            logStore: logs,
            onStatus: { [weak self] status in
                self?.status = status
            },
            onCandidates: { [weak self] candidates in
                self?.ingest(candidates)
            },
            onReport: { [weak self] report in
                guard let self else { return }
                self.reports.insert(report, at: 0)
                self.reports = Array(self.reports.prefix(50))
            }
        )

        NotificationCenter.default.publisher(for: .dialtoneAppOpenURL)
            .compactMap { $0.object as? URL }
            .sink { [weak self] url in
                Task { @MainActor in
                    await self?.handleIncomingURL(url)
                    DialtoneAppOpenURLInbox.markHandled(url)
                }
            }
            .store(in: &cancellables)

        for pendingURL in DialtoneAppOpenURLInbox.drain() {
            Task { @MainActor in
                await handleIncomingURL(pendingURL)
            }
        }

        scanner?.startIfNeeded()
        refreshPurchaseReadiness()
    }

    var pendingCandidates: [PurchaseCandidate] {
        candidates.filter { $0.decision == .pending }
    }

    var dismissedCandidates: [PurchaseCandidate] {
        candidates.filter { $0.decision == .dismissed }
    }

    var approvedCandidates: [PurchaseCandidate] {
        candidates.filter { $0.decision == .approved }
    }

    var scannedDomainCount: Int {
        Set(reports.map(\.domain)).count
    }

    func markCandidatesSeen() {
        guard unseenCandidateCount > 0 else { return }
        unseenCandidateCount = 0
        logs.append(.agent, "Red-dot state cleared")
    }

    func dismiss(_ candidate: PurchaseCandidate) {
        updateCandidate(candidate.id) { candidate in
            candidate.decision = .dismissed
        }
        purchaseCoordinator.reject(candidate)
    }

    func approve(_ candidate: PurchaseCandidate) {
        guard !purchasingCandidateIDs.contains(candidate.id) else { return }
        purchasingCandidateIDs.insert(candidate.id)

        updateCandidate(candidate.id) { candidate in
            candidate.decision = .approved
        }

        Task {
            let result = await purchaseCoordinator.approve(candidate)
            updateCandidate(candidate.id) { candidate in
                candidate.result = result
            }
            purchaseReadiness = await purchaseCoordinator.purchaseReadiness()
            purchasingCandidateIDs.remove(candidate.id)
        }
    }

    func isPurchasing(_ candidate: PurchaseCandidate) -> Bool {
        purchasingCandidateIDs.contains(candidate.id)
    }

    func openSource(for candidate: PurchaseCandidate) {
        NSWorkspace.shared.open(candidate.productURL ?? candidate.sourceURL)
    }

    func openBotBuyer() {
        guard purchaseReadiness == .signedInNeedsCard else { return }
        purchaseCoordinator.openBotBuyer()
        status = "Opening bot-buyer setup"
    }

    func openLogin() {
        guard purchaseReadiness == .signedOut else { return }
        status = "Opening DialtoneApp login"
        Task {
            _ = await purchaseCoordinator.openLogin()
        }
    }

    func logOut() {
        purchaseCoordinator.logOut()
        resetAppDefaults()
        candidates = []
        reports = []
        unseenCandidateCount = 0
        purchasingCandidateIDs = []
        knownCandidateFingerprints = []
        purchaseReadiness = .signedOut
        status = "Signed out"
        logs.resetLocalFiles()
    }

    func handleIncomingURL(_ url: URL) async {
        let isBotBuyerCardCallback = Self.isBotBuyerCardSavedCallback(url)
        let handled = await purchaseCoordinator.handleAuthCallback(url)
        if handled {
            purchaseReadiness = .signedInCheckingCard
            purchaseReadiness = await purchaseCoordinator.purchaseReadiness()
            if isBotBuyerCardCallback {
                status = purchaseReadiness == .ready ? "Ready to buy" : "Processed bot-buyer card callback"
            } else {
                status = "Processed DialtoneApp login callback"
            }
        } else {
            logs.append(.agent, level: .warning, "Ignored unsupported URL callback", metadata: [
                "scheme": url.scheme ?? "none",
                "host": url.host ?? "none"
            ])
        }
    }

    private static func isBotBuyerCardSavedCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "dialtoneapp-desktop"
            && url.host?.lowercased() == "bot-buyer"
            && url.path.lowercased() == "/card-saved"
    }

    private func refreshPurchaseReadiness() {
        purchaseReadiness = .checking
        Task {
            purchaseReadiness = await purchaseCoordinator.purchaseReadiness()
        }
    }

    private func resetAppDefaults() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }

    private func ingest(_ newCandidates: [PurchaseCandidate]) {
        var inserted = 0

        for candidate in CandidateDedupe.dedupe(newCandidates) {
            let semanticKey = CandidateDedupe.semanticKey(for: candidate)

            if let existingIndex = candidates.firstIndex(where: { CandidateDedupe.semanticKey(for: $0) == semanticKey }) {
                knownCandidateFingerprints.insert(candidate.fingerprint)

                if candidates[existingIndex].decision == .pending,
                   CandidateDedupe.isPreferred(candidate, over: candidates[existingIndex]) {
                    let replacedCandidate = candidates[existingIndex]
                    candidates[existingIndex] = candidate
                    logs.append(.agent, "Candidate improved", metadata: [
                        "candidate_id": candidate.id.uuidString,
                        "replaced_candidate_id": replacedCandidate.id.uuidString,
                        "domain": candidate.domain,
                        "title": candidate.title,
                        "source": candidate.sourceKind.rawValue,
                        "price": candidate.price?.displayValue ?? "none"
                    ])
                }

                continue
            }

            guard !knownCandidateFingerprints.contains(candidate.fingerprint) else { continue }
            knownCandidateFingerprints.insert(candidate.fingerprint)
            candidates.insert(candidate, at: 0)
            inserted += 1
            logs.append(.agent, level: .success, "Candidate created", metadata: [
                "candidate_id": candidate.id.uuidString,
                "domain": candidate.domain,
                "title": candidate.title,
                "source": candidate.sourceKind.rawValue,
                "price": candidate.price?.displayValue ?? "none"
            ])
        }

        if inserted > 0 {
            unseenCandidateCount += inserted
            logs.append(.agent, level: .success, "Red-dot state changed", metadata: ["unseen": "\(unseenCandidateCount)"])
        }
    }

    private func updateCandidate(_ id: UUID, mutate: (inout PurchaseCandidate) -> Void) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        mutate(&candidates[index])
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: BotShoppingModel
    @State private var selectedSection: AppSection? = .scanner

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedSection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            ScrollView {
                VStack(spacing: 18) {
                    switch selectedSection ?? .scanner {
                    case .scanner:
                        ScannerOverviewScreen()
                    case .foundItems:
                        DiscoveryScreen()
                    case .activity:
                        ActivityScreen()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1080, minHeight: 720)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case scanner = "DialtoneApp Scanner"
    case foundItems = "Found Items"
    case activity = "Activity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .scanner: return "antenna.radiowaves.left.and.right"
        case .foundItems: return "sparkle.magnifyingglass"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct SidebarView: View {
    @Binding var selectedSection: AppSection?

    var body: some View {
        List(AppSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .navigationTitle("DialtoneApp Desktop")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Menu bar desktop agent", systemImage: "menubar.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The app can keep watching after the main window closes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }
}

struct ScannerOverviewScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeroPanel()
            StatusStrip()
        }
    }
}

struct HeroPanel: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image("MenuBarIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)

                        Text("Bot-buying scanner")
                    }
                    .font(.headline)
                    .foregroundStyle(.teal)

                    Text("DialtoneApp Desktop")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))

                    Text("Scans the fixed v0.0.1 corpus for product feeds, OpenAPI actions, UCP files, x402 metadata, and checkout surfaces before asking you to approve anything.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 650, alignment: .leading)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 12) {
                    Toggle(isOn: $model.botEnabled) {
                        Label(model.botEnabled ? "Watching" : "Paused", systemImage: model.botEnabled ? "eye" : "pause")
                    }
                    .toggleStyle(.switch)

                    Button {
                        NSApplication.shared.keyWindow?.close()
                    } label: {
                        Label("Send to Menu Bar", systemImage: "menubar.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            HStack(spacing: 12) {
                MetricPill(icon: "sparkle.magnifyingglass", label: "Found", value: "\(model.candidates.count) items", tint: .blue)
                MetricPill(icon: "circle.fill", label: "Unseen", value: "\(model.unseenCandidateCount)", tint: .red)
                MetricPill(icon: "network", label: "Scanned", value: "\(model.scannedDomainCount) domains", tint: .orange)
                AccountReadinessPill()
            }
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StatusStrip: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        HStack(spacing: 12) {
            Label(model.status, systemImage: model.botEnabled ? "antenna.radiowaves.left.and.right" : "pause.circle")
                .font(.callout.weight(.medium))
            Spacer()
            AccountReadinessStatus()
            Label("\(DomainCorpus.all.count) domains", systemImage: "list.bullet.rectangle")
            Label("\(model.pendingCandidates.count) pending", systemImage: "tray")
            Label("\(model.logs.networkLines.count) calls", systemImage: "network")
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DiscoveryScreen: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: "Found Items",
                subtitle: "Live candidates discovered from the hard-coded April 2026 bot-buying corpus."
            )

            if model.candidates.isEmpty {
                EmptyScannerState()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    ForEach(model.candidates) { candidate in
                        CandidateCard(candidate: candidate)
                    }
                }
            }
        }
    }
}

struct ActivityScreen: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        Card(title: "Background activity", icon: "clock.arrow.circlepath") {
            VStack(spacing: 12) {
                if model.reports.isEmpty && model.logs.agentLines.isEmpty {
                    Text("No scanner activity yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.reports.prefix(8)) { report in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: report.candidates.isEmpty ? "checkmark.circle" : "sparkles")
                            .font(.title3)
                            .foregroundStyle(report.candidates.isEmpty ? Color.secondary : Color.teal)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.domain)
                                .font(.headline)
                            Text(report.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

struct MetricPill: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AccountReadinessPill: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        if model.purchaseReadiness.isAccountSetupLink {
            Button {
                model.openAccountSetup()
            } label: {
                MetricPill(
                    icon: model.purchaseReadiness.systemImage,
                    label: "Account",
                    value: model.purchaseReadiness.label,
                    tint: model.purchaseReadiness.tint
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(model.purchaseReadiness.accountSetupHelp)
        } else {
            MetricPill(
                icon: model.purchaseReadiness.systemImage,
                label: "Account",
                value: model.purchaseReadiness.label,
                tint: model.purchaseReadiness.tint
            )
        }
    }
}

struct AccountReadinessStatus: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        if model.purchaseReadiness.isAccountSetupLink {
            Button {
                model.openAccountSetup()
            } label: {
                Label(model.purchaseReadiness.label, systemImage: model.purchaseReadiness.systemImage)
            }
            .buttonStyle(.link)
            .foregroundStyle(model.purchaseReadiness.tint)
            .pointingHandCursor()
            .help(model.purchaseReadiness.accountSetupHelp)
        } else {
            Label(model.purchaseReadiness.label, systemImage: model.purchaseReadiness.systemImage)
                .foregroundStyle(model.purchaseReadiness.tint)
        }
    }
}

private extension BotShoppingModel {
    func openAccountSetup() {
        switch purchaseReadiness {
        case .signedOut:
            openLogin()
        case .signedInNeedsCard:
            openBotBuyer()
        case .checking, .signedInCheckingCard, .ready, .unavailable:
            break
        }
    }
}

private extension DesktopPurchaseReadiness {
    var tint: Color {
        switch self {
        case .checking, .signedInCheckingCard:
            return .blue
        case .signedOut, .signedInNeedsCard, .unavailable:
            return .orange
        case .ready:
            return .green
        }
    }

    var isAccountSetupLink: Bool {
        self == .signedOut || self == .signedInNeedsCard
    }

    var accountSetupHelp: String {
        switch self {
        case .signedOut:
            return "Open login"
        case .signedInNeedsCard:
            return "Open bot-buyer"
        case .checking, .signedInCheckingCard, .ready, .unavailable:
            return ""
        }
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                    isHovering = true
                } else if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

struct EmptyScannerState: View {
    var body: some View {
        Card(title: "Scanner warming up", icon: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                Text("DialtoneApp Desktop is scanning the first high-signal domains now.")
                    .font(.headline)

                Text(DomainCorpus.highSignal.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct CandidateCard: View {
    @EnvironmentObject private var model: BotShoppingModel
    let candidate: PurchaseCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let imageURL = candidate.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(candidate.merchantName)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(candidate.sourceKind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.teal.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let description = candidate.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(candidate.price?.displayValue ?? "Price unavailable")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(Int(candidate.confidence * 100))% confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label(candidate.purchaseStrategy.label, systemImage: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(candidate.sourceURL.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let result = candidate.result {
                ResultPill(result: result)
            }

            HStack {
                Button {
                    model.dismiss(candidate)
                } label: {
                    Label("No", systemImage: "xmark")
                }
                .disabled(candidate.decision != .pending)

                Button {
                    model.approve(candidate)
                } label: {
                    Label(approveButtonTitle, systemImage: isPurchasing ? "hourglass" : "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApprove)

                Spacer()

                Button {
                    model.openSource(for: candidate)
                } label: {
                    Label("Open source", systemImage: "safari")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var isPurchasing: Bool {
        model.isPurchasing(candidate)
    }

    private var canApprove: Bool {
        guard !isPurchasing, candidate.decision != .dismissed else { return false }

        guard let state = candidate.result?.state else { return true }

        switch state {
        case .purchased, .needsBrowserCheckout, .unsupportedMerchant:
            return false
        default:
            return true
        }
    }

    private var approveButtonTitle: String {
        if isPurchasing {
            return "Working"
        }

        guard let state = candidate.result?.state else {
            return "Yes, buy"
        }

        switch state {
        case .needsLogin:
            return "Continue"
        case .needsBotBuyerCard:
            return "Check again"
        case .failed:
            return "Retry buy"
        default:
            return "Approved"
        }
    }
}

struct ResultPill: View {
    let result: PurchaseFlowResult

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.state.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.headline)
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var icon: String {
        switch result.state {
        case .purchased: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .needsLogin, .needsBotBuyerCard, .needsBrowserCheckout: return "arrow.up.right.square"
        case .unsupportedMerchant: return "hand.raised.fill"
        }
    }

    private var color: Color {
        switch result.state {
        case .purchased: return .green
        case .failed: return .red
        case .needsLogin, .needsBotBuyerCard, .needsBrowserCheckout: return .orange
        case .unsupportedMerchant: return .yellow
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: BotShoppingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image("MenuBarIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text("DialtoneApp Desktop")
                    .font(.headline)
                Spacer()
            }

            Label(model.botEnabled ? "Watching" : "Paused", systemImage: model.botEnabled ? "eye" : "pause")
            .foregroundStyle(.secondary)

            HStack {
                Label("\(model.unseenCandidateCount) unseen", systemImage: "circle.fill")
                Spacer()
                Label("\(model.pendingCandidates.count) pending", systemImage: "tray")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            if model.candidates.isEmpty {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.candidates.prefix(3)) { candidate in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: candidate.decision == .pending ? "sparkles" : "checkmark.circle")
                            .foregroundStyle(candidate.decision == .pending ? Color.teal : Color.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title)
                                .lineLimit(1)
                            Text("\(candidate.merchantName) - \(candidate.price?.displayValue ?? "no price")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open DialtoneApp Desktop", systemImage: "macwindow")
            }

            Button {
                model.logs.revealLogFiles()
            } label: {
                Label("Reveal Log Files", systemImage: "folder")
            }

            Button {
                model.logOut()
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
            }

            Divider()

            Button {
                model.botEnabled.toggle()
            } label: {
                Label(model.botEnabled ? "Pause Bot" : "Resume Bot", systemImage: model.botEnabled ? "pause" : "play")
            }

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit DialtoneApp Desktop", systemImage: "power")
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct MenuBarLabel: View {
    let unseenCount: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)

            if unseenCount > 0 {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: -2)
            }
        }
        .accessibilityLabel(unseenCount > 0 ? "DialtoneApp Desktop, \(unseenCount) unseen candidates" : "DialtoneApp Desktop")
    }
}

#Preview {
    ContentView()
        .environmentObject(BotShoppingModel())
}
