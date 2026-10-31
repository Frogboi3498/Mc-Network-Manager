import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case setup, mods, network, provision, monitor, terminals, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .mods: return "Mods"
        case .network: return "Network"
        case .provision: return "Build"
        case .monitor: return "Monitor"
        case .terminals: return "Terminals"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "slider.horizontal.3"
        case .mods: return "puzzlepiece.extension"
        case .network: return "network"
        case .provision: return "hammer"
        case .monitor: return "waveform.path.ecg"
        case .terminals: return "terminal"
        case .account: return "person.crop.circle"
        }
    }
}

extension View {
    /// Apple HIG: interactive controls are at least 44x44 points.
    func hitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct RootView: View {
    @State private var selection: AppSection? = .setup

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            detail(for: selection ?? .setup)
        }
        #else
        TabView(selection: Binding(get: { selection ?? .setup }, set: { selection = $0 })) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { detail(for: section) }
                    .tabItem { Label(section.title, systemImage: section.symbol) }
                    .tag(section)
            }
        }
        #endif
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        switch section {
        case .setup: SetupView()
        case .mods: ModsView()
        case .network: NetworkView()
        case .provision: ProvisionView()
        case .monitor: MonitorView()
        case .terminals: DualSSHView()
        case .account: AccountView()
        }
    }
}
