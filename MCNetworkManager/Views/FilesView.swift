import SwiftUI
import Citadel
import NIOCore

// MARK: - Remote file entry

struct RemoteEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64

    var icon: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "log", "md", "json", "yml", "yaml", "toml", "conf", "cfg", "ini", "sh", "bash", "properties":
            return "doc.text"
        case "jar", "zip", "gz", "tar", "tgz", "7z":
            return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "webp":
            return "photo"
        default:
            return "doc"
        }
    }
}

// MARK: - Browser model

@MainActor
@Observable
final class FileBrowserModel {
    var nodeID: UUID?
    var currentPath: String = "/"
    var entries: [RemoteEntry] = []
    var isLoading = false
    var error: String?
    var selectedIDs: Set<UUID> = []

    func load(nodes: [NodeProfile]) async {
        guard let nodeID, let node = nodes.first(where: { $0.id == nodeID }) else {
            entries = []
            error = nil
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let client = try await SSHService.connect(node)
            defer { Task { try? await client.close() } }
            let sftp = try await client.openSFTP()
            defer { Task { try? await sftp.close() } }

            // listDirectory returns [SFTPPathComponent] or similar in current Citadel
            let listing = try await sftp.listDirectory(atPath: currentPath)

            var result: [RemoteEntry] = []
            for component in listing {
                let name = component.filename
                if name == "." || name == ".." { continue }

                // attributes.isDirectory is the usual flag
                let isDir = component.attributes.isDirectory == true
                    || (component.attributes.permissions?.isDirectory ?? false)

                let size = Int64(component.attributes.size ?? 0)
                let fullPath = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"

                result.append(RemoteEntry(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    size: size
                ))
            }

            result.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            entries = result
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
    }

    func enter(_ entry: RemoteEntry) {
        guard entry.isDirectory else { return }
        currentPath = entry.path
        selectedIDs = []
    }

    func goUp() {
        guard currentPath != "/" else { return }
        var parts = currentPath.split(separator: "/").map(String.init)
        _ = parts.popLast()
        currentPath = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        selectedIDs = []
    }
}

// MARK: - View

struct FilesView: View {
    @Environment(AppModel.self) private var app
    @State private var browser = FileBrowserModel()
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Picker("Node", selection: $browser.nodeID) {
                    Text("Choose node…").tag(UUID?.none)
                    ForEach(app.vault.nodes) { node in
                        Text(node.displayName).tag(UUID?.some(node.id))
                    }
                }
                .frame(maxWidth: 220)

                Button {
                    browser.goUp()
                    Task { await browser.load(nodes: app.vault.nodes) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(browser.currentPath == "/" || browser.nodeID == nil)
                .help("Go up one folder")

                Text(browser.currentPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    Task { await browser.load(nodes: app.vault.nodes) }
                } label: {
                    if browser.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(browser.nodeID == nil)
                .help("Refresh")
            }
            .padding(12)

            Divider()

            // Main content
            Group {
                if browser.nodeID == nil {
                    ContentUnavailableView(
                        "Choose a node",
                        systemImage: "server.rack",
                        description: Text("Select one of your nodes above to browse its files over SFTP.")
                    )
                } else if browser.isLoading && browser.entries.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = browser.error {
                    ContentUnavailableView(
                        "Could not list files",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if browser.entries.isEmpty {
                    ContentUnavailableView(
                        "Empty folder",
                        systemImage: "folder",
                        description: Text("This directory contains no files.")
                    )
                } else {
                    Table(browser.entries, selection: $browser.selectedIDs) {
                        TableColumn("Name") { entry in
                            Label(entry.name, systemImage: entry.icon)
                                .onTapGesture(count: 2) {
                                    if entry.isDirectory {
                                        browser.enter(entry)
                                        Task { await browser.load(nodes: app.vault.nodes) }
                                    }
                                }
                        }
                        TableColumn("Size") { entry in
                            Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        .width(100)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first,
                           let entry = browser.entries.first(where: { $0.id == id }) {
                            if entry.isDirectory {
                                Button("Open") {
                                    browser.enter(entry)
                                    Task { await browser.load(nodes: app.vault.nodes) }
                                }
                            } else {
                                Button("Download to Downloads folder") {
                                    Task { await download(entry) }
                                }
                            }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first,
                           let entry = browser.entries.first(where: { $0.id == id }),
                           entry.isDirectory {
                            browser.enter(entry)
                            Task { await browser.load(nodes: app.vault.nodes) }
                        }
                    }
                }
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle("Files")
        .onChange(of: browser.nodeID) { _, _ in
            browser.currentPath = "/"
            browser.selectedIDs = []
            Task { await browser.load(nodes: app.vault.nodes) }
        }
    }

    private func download(_ entry: RemoteEntry) async {
        guard let nodeID = browser.nodeID,
              let node = app.vault.nodes.first(where: { $0.id == nodeID }) else { return }
        statusMessage = "Downloading \(entry.name)…"
        do {
            let client = try await SSHService.connect(node)
            defer { Task { try? await client.close() } }
            let sftp = try await client.openSFTP()
            defer { Task { try? await sftp.close() } }

            let buffer = try await sftp.withFile(filePath: entry.path, flags: .read) { file in
                try await file.readToEnd()
            }

            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = downloads.appendingPathComponent(entry.name)
            try Data(buffer: buffer).write(to: dest)
            statusMessage = "Saved to Downloads/\(entry.name)"
        } catch {
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}
