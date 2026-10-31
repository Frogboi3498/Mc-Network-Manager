import SwiftUI

struct ProvisionView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runner: ProvisionRunner
    @Environment(\.openURL) private var openURL

    var body: some View {
        let problems = runner.problems(in: store)

        VStack(alignment: .leading, spacing: 12) {
            if !problems.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") .font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Before you build") }
            }

            HStack {
                Button {
                    runner.start(store: store)
                } label: {
                    Label(runner.running ? "Building..." : "Build my network", systemImage: "hammer.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.running || !problems.isEmpty)
                .hitTarget()

                if runner.running {
                    Button("Stop", role: .destructive) { runner.cancel() }.hitTarget()
                    ProgressView().controlSize(.small)
                    Text(runner.currentHost).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let url = runner.tailscaleLoginURL, runner.running {
                Button { openURL(url) } label: { Label("Sign this machine in to Tailscale", systemImage: "link") }
                    .buttonStyle(.bordered)
                    .hitTarget()
            }

            if runner.finished {
                Label(runner.succeeded ? "Finished. Check the Monitor tab." : "Something went wrong. Read the log, fix it, and build again.",
                      systemImage: runner.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.headline)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "The build log appears here." : runner.log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: runner.log) { _, _ in proxy.scrollTo("bottom") }
            }
        }
        .padding()
        .navigationTitle("Build")
    }
}
