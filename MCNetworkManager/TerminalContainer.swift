import SwiftUI
import SwiftTerm

/// Receives events from SwiftTerm's TerminalView and forwards them to the SSH session.
@MainActor
final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    let session: SSHSession

    init(session: SSHSession) { self.session = session }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    // Kitty clipboard protocol: deny by default so a remote program cannot read your clipboard.
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        []
    }

    func kittyClipboardRequestPermission(source: TerminalView,
                                         request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        .deny
    }
}

#if os(macOS)
struct TerminalContainer: NSViewRepresentable {
    let session: SSHSession

    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        session.terminal = view
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}
}
#else
struct TerminalContainer: UIViewRepresentable {
    let session: SSHSession

    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        session.terminal = view
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}
}
#endif
