import AppKit
import SwiftUI

struct LogWindow: View {
    @EnvironmentObject private var model: BotShoppingModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                LogPane(channel: .agent)
                    .tabItem { Label("Agent", systemImage: "antenna.radiowaves.left.and.right") }
                LogPane(channel: .network)
                    .tabItem { Label("Network", systemImage: "network") }
                LogPane(channel: .purchases)
                    .tabItem { Label("Purchases", systemImage: "creditcard") }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

private struct LogPane: View {
    @EnvironmentObject private var model: BotShoppingModel
    let channel: LogChannel

    @State private var searchText = ""
    @State private var domainFilter = ""
    @State private var statusFilter = "all"
    @State private var selection = Set<UUID>()

    private var filteredLines: [LogLine] {
        model.logs.lines(for: channel).filter { line in
            let text = line.text.lowercased()
            let matchesSearch = searchText.isEmpty || text.contains(searchText.lowercased())
            let matchesDomain = domainFilter.isEmpty || text.contains(domainFilter.lowercased())
            let matchesStatus = statusFilter == "all" || line.level.rawValue == statusFilter
            return matchesSearch && matchesDomain && matchesStatus
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)

                TextField("Domain", text: $domainFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Picker("Status", selection: $statusFilter) {
                    Text("All").tag("all")
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }
                .frame(width: 180)

                Spacer()

                Button {
                    copySelected()
                } label: {
                    Label("Copy selected", systemImage: "doc.on.doc")
                }
                .disabled(selection.isEmpty)

                Button {
                    model.logs.clear(channel)
                    selection = []
                } label: {
                    Label("Clear", systemImage: "trash")
                }

                Button {
                    model.logs.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            List(filteredLines, selection: $selection) { line in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(color(for: line.level))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)

                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .tag(line.id)
            }
            .listStyle(.inset)

            HStack {
                Text("\(filteredLines.count) lines")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.logs.revealLogFiles()
                } label: {
                    Label("Reveal Log Files", systemImage: "folder")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func copySelected() {
        let selectedText = filteredLines
            .filter { selection.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .success: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
