 import SwiftUI
 import AppKit
 @preconcurrency import SwiftTerm
 
 // MARK: - Pane (owns the terminal view and its SSH session)
 
 /// One terminal. It lives in `TerminalWorkspace`, not in the SwiftUI view, so
 /// the session keeps running when you switch to another screen.
 @MainActor
 final class TerminalPane: NSObject, TerminalViewDelegate, Identifiable {
     let id = UUID()
     let node: NodeProfile
     let view: TerminalView
     private var connection: PTYConnection?
 
     init(node: NodeProfile) {
         self.node = node
         self.view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
         super.init()
         view.terminalDelegate = self
         connect()
     }
 
     func connect() {
         connection?.stop()
         
         // Fix: Use the TerminalView's native methods directly rather than looking for a feedSender object.
         let conn = PTYConnection(
             onOutput: { [weak self] bytes in 
                 self?.view.feed(byteArray: ArraySlice(bytes))
             },
             onStatus: { [weak self] text in 
                 self?.view.feed(text: text) 
             }
         )
         connection = conn
         // The real size arrives through sizeChanged once the view has a frame.
         conn.start(node: node, cols: 80, rows: 24)
     }
 
     func stop() {
         connection?.stop()
         connection = nil
     }
 
     // MARK: TerminalViewDelegate
 
     func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
         connection?.resize(cols: newCols, rows: newRows)
     }
 
     func send(source: TerminalView, data: ArraySlice<UInt8>) {
         connection?.send(data)
     }
 
     func setTerminalTitle(source: TerminalView, title: String) {}
     func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
     func scrolled(source: TerminalView, position: Double) {}
     func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
     func bell(source: TerminalView) { NSSound.beep() }
     func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
     func clipboardRead(source: TerminalView) -> Data? { nil }
 
     func clipboardCopy(source: TerminalView, content: Data) {
         if let text = String(data: content, encoding: .utf8) { Clipboard.copy(text) }
     }
 
     func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
         // Only open web links; a terminal should not be able to launch other schemes.
         guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
         NSWorkspace.shared.open(url)
     }
 }
 
 @MainActor
 @Observable
 final class TerminalWorkspace {
     static let maxPanes = 4
     private(set) var panes: [TerminalPane] = []
 
     var canOpenMore: Bool { panes.count < Self.maxPanes }
 
     func open(_ node: NodeProfile) {
         guard canOpenMore else { return }
         panes.append(TerminalPane(node: node))
     }
 
     /// Two nodes side by side.
     func openDual(_ nodes: [NodeProfile]) {
         for node in nodes.filter(\.isComplete).prefix(2) { open(node) }
     }
 
     func close(_ pane: TerminalPane) {
         pane.stop()
         panes.removeAll { $0.id == pane.id }
     }
 
     func reconnect(_ pane: TerminalPane) { pane.connect() }
 }
 
 // MARK: - SwiftUI
 
 private struct TerminalHost: NSViewRepresentable {
     let pane: TerminalPane
     func makeNSView(context: Context) -> TerminalView { pane.view }
     func updateNSView(_ nsView: TerminalView, context: Context) {}
 }
 
 struct TerminalsView: View {
     @Environment(AppModel.self) private var app
     @Environment(TerminalWorkspace.self) private var workspace
 
     var body: some View {
         Group {
             if workspace.panes.isEmpty {
                 ContentUnavailableView {
                     Label("No terminals open", systemImage: "terminal")
                 } description: {
                     Text("Open up to four SSH terminals side by side. They stay connected while you use the rest of the app.")
                 } actions: {
                     Button("Open two nodes side by side") { workspace.openDual(app.vault.nodes) }
                         .buttonStyle(.borderedProminent)
                         .disabled(app.vault.nodes.filter(\.isComplete).count < 2)
                     if app.vault.nodes.filter(\.isComplete).count < 2 {
                         Text("Add two nodes with logins first, or open one from the + menu.")
                             .font(.callout).foregroundStyle(.secondary)
                     }
                 }
             } else {
                 panesLayout
             }
         }
         .navigationTitle("Terminals")
         .toolbar {
             ToolbarItem {
                 Menu {
                     ForEach(app.vault.nodes.filter(\.isComplete)) { node in
                         Button(node.displayName) { workspace.open(node) }
                     }
                 } label: {
                     Label("New terminal", systemImage: "plus")
                 }
                 .disabled(!workspace.canOpenMore || app.vault.nodes.filter(\.isComplete).isEmpty)
                 .help(workspace.canOpenMore ? "Open a terminal" : "Four terminals is the maximum")
             }
         }
     }
 
     private var panesLayout: some View {
         let rows = stride(from: 0, to: workspace.panes.count, by: 2).map {
             Array(workspace.panes[$0..<min($0 + 2, workspace.panes.count)])
         }
         return VStack(spacing: 8) {
             ForEach(rows.indices, id: \.self) { r in
                 HStack(spacing: 8) {
                     ForEach(rows[r]) { pane in cell(pane) }
                 }
             }
         }
         .padding(8)
     }
 
     private func cell(_ pane: TerminalPane) -> some View {
         VStack(spacing: 0) {
             HStack(spacing: 8) {
                 Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                 Text(pane.node.displayName).font(.headline)
                 Text("\(pane.node.username)@\(pane.node.host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                 Spacer()
                 Button { workspace.reconnect(pane) } label: { Image(systemName: "arrow.clockwise") }
                     .buttonStyle(.borderless)
                     .help("Reconnect")
                     .accessibilityLabel("Reconnect \(pane.node.displayName)")
                 Button { workspace.close(pane) } label: { Image(systemName: "xmark.circle.fill") }
                     .buttonStyle(.borderless)
                     .help("Close this terminal")
                     .accessibilityLabel("Close \(pane.node.displayName)")
             }
             .padding(.horizontal, 10)
             .padding(.vertical, 6)
             .background(.bar)
 
             TerminalHost(pane: pane)
                 .frame(minWidth: 240, minHeight: 160)
                 .contentShape(Rectangle())
                 .onTapGesture { pane.view.window?.makeFirstResponder(pane.view) }
         }
         .clipShape(RoundedRectangle(cornerRadius: 8))
         .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
         .frame(maxWidth: .infinity, maxHeight: .infinity)
     }
 }
