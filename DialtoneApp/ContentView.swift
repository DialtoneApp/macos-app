//
//  ContentView.swift
//  DialtoneApp
//
//  Created by aa on 4/22/26.
//

import AppKit
import Combine
import SwiftUI

enum ShoppingCategory: String, CaseIterable, Identifiable {
    case household = "Household"
    case digitalTools = "Digital tools"
    case aiServices = "AI services"
    case travel = "Travel"
    case apparel = "Apparel"
    case electronics = "Electronics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .household: return "house"
        case .digitalTools: return "keyboard"
        case .aiServices: return "cpu"
        case .travel: return "airplane"
        case .apparel: return "tshirt"
        case .electronics: return "desktopcomputer"
        }
    }
}

enum ApprovalMode: String, CaseIterable, Identifiable {
    case suggestOnly = "Suggest only"
    case askEveryTime = "Ask every time"
    case autoApproveSmall = "Auto-approve small buys"

    var id: String { rawValue }
}

struct ShoppingSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let merchant: String
    let price: String
    let protocolName: String
    let risk: String
    let icon: String
    let accent: Color
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
}

final class BotShoppingModel: ObservableObject {
    @Published var botEnabled = true
    @Published var weeklyBudget = 75.0
    @Published var autoApproveLimit = 12.0
    @Published var approvalMode: ApprovalMode = .askEveryTime
    @Published var selectedCategories: Set<ShoppingCategory> = [.household, .digitalTools, .aiServices]
    @Published var merchantAllowlist = "dialtoneapp.com, stableemail.dev, anybrowse.dev"
    @Published var requireApprovalForPhysicalGoods = true
    @Published var requireApprovalForRecurringPayments = true
    @Published var requireApprovalOverLimit = true
    @Published var scanUCP = true
    @Published var scanX402 = true
    @Published var scanOpenAPI = true
    @Published var status = "Watching trusted commerce surfaces"

    let suggestions: [ShoppingSuggestion] = [
        ShoppingSuggestion(
            title: "AI-readiness membership",
            merchant: "dialtoneapp.com",
            price: "$9.00 / month",
            protocolName: "Commerce API",
            risk: "Recurring, needs approval",
            icon: "checklist.checked",
            accent: .teal
        ),
        ShoppingSuggestion(
            title: "Website screenshot run",
            merchant: "anybrowse.dev",
            price: "$0.02",
            protocolName: "x402",
            risk: "Within auto limit",
            icon: "camera.viewfinder",
            accent: .indigo
        ),
        ShoppingSuggestion(
            title: "Inbox for agent tests",
            merchant: "stableemail.dev",
            price: "$3.00",
            protocolName: "x402 / MPP",
            risk: "Policy approval recommended",
            icon: "envelope.badge",
            accent: .green
        )
    ]

    let activity: [ActivityItem] = [
        ActivityItem(
            title: "Checked UCP retail examples",
            detail: "Catalogs are useful; final card checkout still needs owner authority.",
            icon: "cart.badge.questionmark"
        ),
        ActivityItem(
            title: "Checked x402 services",
            detail: "API purchases are clearer because price appears before retry payment.",
            icon: "creditcard.trianglebadge.exclamationmark"
        ),
        ActivityItem(
            title: "No autonomous purchase made",
            detail: "v0.0.1 is UI-only and keeps every suggestion pending.",
            icon: "pause.circle"
        )
    ]

    var selectedCategorySummary: String {
        let count = selectedCategories.count
        if count == ShoppingCategory.allCases.count {
            return "All categories"
        }

        return "\(count) active categories"
    }

    var weeklyBudgetText: String {
        "$\(Int(weeklyBudget)) / week"
    }

    var autoApproveText: String {
        "$\(Int(autoApproveLimit))"
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: BotShoppingModel
    @State private var selectedSection: AppSection? = .setup

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedSection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            ScrollView {
                VStack(spacing: 18) {
                    HeroPanel()
                    StatusStrip()

                    switch selectedSection ?? .setup {
                    case .setup:
                        SetupScreen()
                    case .discover:
                        DiscoveryScreen()
                    case .approvals:
                        ApprovalsScreen()
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
    case setup = "Setup"
    case discover = "Discover"
    case approvals = "Approvals"
    case activity = "Activity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .setup: return "slider.horizontal.3"
        case .discover: return "magnifyingglass"
        case .approvals: return "checkmark.seal"
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

struct HeroPanel: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image("MenuBarIcon")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 16, height: 16)

                        Text("Bot with a budget")
                    }
                    .font(.headline)
                    .foregroundStyle(.teal)

                    Text("DialtoneApp Desktop")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))

                    Text("Configure what DialtoneApp Desktop should watch, how much it can spend, and when it must ask before buying.")
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
                MetricPill(icon: "wallet.pass", label: "Budget", value: model.weeklyBudgetText, tint: .green)
                MetricPill(icon: "checkmark.shield", label: "Approval", value: model.approvalMode.rawValue, tint: .blue)
                MetricPill(icon: "tag", label: "Scope", value: model.selectedCategorySummary, tint: .orange)
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
            Label("UCP", systemImage: model.scanUCP ? "checkmark.circle.fill" : "circle")
            Label("x402", systemImage: model.scanX402 ? "checkmark.circle.fill" : "circle")
            Label("OpenAPI", systemImage: model.scanOpenAPI ? "checkmark.circle.fill" : "circle")
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SetupScreen: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Card(title: "Budget", icon: "wallet.pass") {
                    SliderRow(
                        title: "Weekly spend",
                        value: $model.weeklyBudget,
                        range: 10...500,
                        displayValue: model.weeklyBudgetText
                    )

                    SliderRow(
                        title: "Auto-approve cap",
                        value: $model.autoApproveLimit,
                        range: 1...100,
                        displayValue: model.autoApproveText
                    )

                    Picker("Approval mode", selection: $model.approvalMode) {
                        ForEach(ApprovalMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Card(title: "Where to look", icon: "scope") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ShoppingCategory.allCases) { category in
                            CategoryToggle(category: category)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 18) {
                Card(title: "Allowed merchants", icon: "building.2") {
                    TextEditor(text: $model.merchantAllowlist)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 118)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Card(title: "Discovery surfaces", icon: "network") {
                    Toggle("UCP shopping files", isOn: $model.scanUCP)
                    Toggle("x402 payment APIs", isOn: $model.scanX402)
                    Toggle("OpenAPI and commerce manifests", isOn: $model.scanOpenAPI)

                    Divider()

                    Toggle("Ask for physical goods", isOn: $model.requireApprovalForPhysicalGoods)
                    Toggle("Ask for recurring payments", isOn: $model.requireApprovalForRecurringPayments)
                    Toggle("Ask above auto cap", isOn: $model.requireApprovalOverLimit)
                }
            }
        }
    }
}

struct DiscoveryScreen: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: "Suggested purchases",
                subtitle: "These are static v0.0.1 examples based on the AI bot buying report."
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(model.suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion)
                }
            }
        }
    }
}

struct ApprovalsScreen: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Card(title: "Approval policy", icon: "checkmark.seal") {
                Picker("Mode", selection: $model.approvalMode) {
                    ForEach(ApprovalMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Divider()

                Toggle("Require approval for physical delivery", isOn: $model.requireApprovalForPhysicalGoods)
                Toggle("Require approval for subscriptions", isOn: $model.requireApprovalForRecurringPayments)
                Toggle("Require approval over \(model.autoApproveText)", isOn: $model.requireApprovalOverLimit)
            }

            Card(title: "Pending queue", icon: "tray") {
                ApprovalRow(title: "AI-readiness membership", detail: "Recurring $9.00 monthly charge", price: "$9.00")
                ApprovalRow(title: "Agent inbox", detail: "Email capability needs policy review", price: "$3.00")
                ApprovalRow(title: "Retail cart handoff", detail: "Physical goods always ask in v0.0.1", price: "$42.00")
            }
        }
    }
}

struct ActivityScreen: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        Card(title: "Background activity", icon: "clock.arrow.circlepath") {
            VStack(spacing: 12) {
                ForEach(model.activity) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(.teal)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.detail)
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

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let displayValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(displayValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 1)
        }
    }
}

struct CategoryToggle: View {
    @EnvironmentObject private var model: BotShoppingModel
    let category: ShoppingCategory

    var body: some View {
        Toggle(isOn: categoryBinding) {
            Label(category.rawValue, systemImage: category.icon)
        }
    }

    private var categoryBinding: Binding<Bool> {
        Binding(
            get: { model.selectedCategories.contains(category) },
            set: { isOn in
                if isOn {
                    model.selectedCategories.insert(category)
                } else {
                    model.selectedCategories.remove(category)
                }
            }
        )
    }
}

struct SuggestionCard: View {
    let suggestion: ShoppingSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: suggestion.icon)
                    .font(.title2)
                    .foregroundStyle(suggestion.accent)
                    .frame(width: 34, height: 34)
                    .background(suggestion.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()

                Text(suggestion.protocolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(suggestion.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(suggestion.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.headline)
                Text(suggestion.merchant)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(suggestion.price)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(suggestion.risk)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                } label: {
                    Label("Review", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                } label: {
                    Label("Hold", systemImage: "pause")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ApprovalRow: View {
    let title: String
    let detail: String
    let price: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(price)
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Button {
            } label: {
                Image(systemName: "checkmark")
            }
            Button {
            } label: {
                Image(systemName: "xmark")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.teal)
                Text("DialtoneApp Desktop")
                    .font(.headline)
                Spacer()
            }

            HStack {
                Label(model.weeklyBudgetText, systemImage: "wallet.pass")
                Spacer()
                Label(model.botEnabled ? "Watching" : "Paused", systemImage: model.botEnabled ? "eye" : "pause")
            }
            .foregroundStyle(.secondary)

            Divider()

            ForEach(model.suggestions.prefix(2)) { suggestion in
                HStack {
                    Image(systemName: suggestion.icon)
                        .foregroundStyle(suggestion.accent)
                    VStack(alignment: .leading) {
                        Text(suggestion.title)
                        Text("\(suggestion.merchant) - \(suggestion.price)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Full Window", systemImage: "macwindow")
            }

            Button {
                model.botEnabled.toggle()
            } label: {
                Label(model.botEnabled ? "Pause Desktop Agent" : "Resume Desktop Agent", systemImage: model.botEnabled ? "pause" : "play")
            }

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit DialtoneApp Desktop", systemImage: "power")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

#Preview {
    ContentView()
        .environmentObject(BotShoppingModel())
}
