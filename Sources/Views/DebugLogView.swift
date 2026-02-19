import SwiftUI
import AppKit
import OSLog

struct DebugLogView: View {
    @State private var logText = ""
    @State private var entryCount = 0
    @State private var isLoading = true
    @State private var filterText = ""
    @State private var autoRefresh = true
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter logs...", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { refresh() }

                Toggle("Auto", isOn: $autoRefresh)
                    .toggleStyle(.checkbox)

                Button("Refresh") { refresh() }
                    .keyboardShortcut("r")

                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
            }
            .padding(10)

            Divider()

            // Log content — plain NSTextView for performance
            if isLoading {
                Spacer()
                ProgressView("Loading logs...")
                Spacer()
            } else if logText.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No logs found")
                        .font(.headline)
                    Text("Try recording something first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                LogTextView(text: $logText)
            }

            Divider()

            // Status bar
            HStack {
                Text("\(entryCount) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last hour · com.idanyekutiel.wispah")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(minWidth: 700, minHeight: 400)
        .onAppear { refresh() }
        .onReceive(timer) { _ in
            if autoRefresh { refresh() }
        }
    }

    private func refresh() {
        let filter = filterText
        DispatchQueue.global(qos: .userInitiated).async {
            let (text, count) = Self.readLogs(filter: filter)
            DispatchQueue.main.async {
                self.logText = text
                self.entryCount = count
                self.isLoading = false
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func readLogs(filter: String) -> (String, Int) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = Date().addingTimeInterval(-3600)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", "com.idanyekutiel.wispah")
            let entries = try store.getEntries(at: position, matching: predicate)

            var lines: [String] = []
            let lowercaseFilter = filter.lowercased()
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let message = logEntry.composedMessage
                if !filter.isEmpty && !message.lowercased().contains(lowercaseFilter) { continue }
                let level: String
                switch logEntry.level {
                case .error: level = "ERROR"
                case .fault: level = "FAULT"
                case .info: level = "INFO "
                case .debug: level = "DEBUG"
                default: level = "OTHER"
                }
                let time = timeFormatter.string(from: logEntry.date)
                lines.append("[\(level)] \(time)  \(message)")
            }
            return (lines.joined(separator: "\n"), lines.count)
        } catch {
            return ("Failed to read logs: \(error.localizedDescription)", 0)
        }
    }
}

// MARK: - AppKit NSTextView wrapper for performance

struct LogTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        // Scroll to bottom
        textView.scrollToEndOfDocument(nil)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        let wasAtBottom = isScrolledToBottom(scrollView)
        textView.string = text
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let contentView = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = contentView.bounds.height
        let scrollOffset = contentView.bounds.origin.y
        return scrollOffset + visibleHeight >= documentHeight - 20
    }
}
