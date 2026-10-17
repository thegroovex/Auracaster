import SwiftUI

/// Update sheet (Golden Gate): app icon, version jump, release notes on
/// Liquid Glass, progress and one prominent action.
struct UpdateSheet: View {
    @Environment(UpdateController.self) private var updater
    /// Fixed release for screenshots; nil = the controller's state.
    var release: GitHubRelease?
    var isShowcase = false

    private var shownRelease: GitHubRelease? { release ?? updater.latestRelease }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            footer
        }
        .padding(24)
        .frame(width: 520)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch effectivePhase {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Suche nach Updates …")
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case .upToDate, .idle:
            Label("Du hast die neueste Version.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case .available, .downloading, .installing:
            if let shownRelease {
                ReleaseNotesView(markdown: shownRelease.body ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .frame(height: 200, alignment: .topLeading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            if case .downloading(let progress) = effectivePhase {
                ProgressView(value: progress) {
                    Text("Wird geladen … \(Int(progress * 100)) %")
                        .font(.callout)
                }
            } else if effectivePhase == .installing {
                ProgressView {
                    Text("Wird installiert – Auracaster startet gleich neu …")
                        .font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if shownRelease != nil {
                Button("Auf GitHub ansehen") { updater.openReleasePage() }
                    .buttonStyle(.glass)
            }
            Spacer()
            switch effectivePhase {
            case .available:
                Button("Später") { updater.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button("Jetzt aktualisieren") { updater.downloadAndInstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            case .downloading:
                Button("Abbrechen") { updater.cancelDownload() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            case .installing:
                EmptyView()
            default:
                Button("OK") { updater.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.large)
    }

    // MARK: Text

    private var effectivePhase: UpdateController.Phase {
        isShowcase ? .available : updater.phase
    }

    private var title: String {
        switch effectivePhase {
        case .available, .downloading, .installing: "Neue Version verfügbar"
        case .checking: "Updates"
        case .failed: "Update-Prüfung fehlgeschlagen"
        default: "Auracaster ist aktuell"
        }
    }

    private var subtitle: String {
        let current = updater.currentVersion.description
        if let version = shownRelease?.version, isShowcase || updater.isUpdateAvailable {
            return "Version \(version) – installiert ist \(current)"
        }
        return "Installiert: Version \(current)"
    }
}

/// Small Markdown renderer for GitHub release notes: headings, bullets, inline styles.
struct ReleaseNotesView: View {
    var markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var lines: [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if line.hasPrefix("#") {
            Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                .font(.headline)
                .padding(.top, 4)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(line.dropFirst(2))))
            }
        } else {
            Text(inline(line))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Toolbar / menu badge shown while an update is available.
struct UpdateBadgeButton: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        if updater.isUpdateAvailable {
            Button {
                updater.isSheetPresented = true
            } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
            }
            .tint(.accentColor)
            .help("Neue Version \(updater.latestRelease?.tagName ?? "") verfügbar")
        }
    }
}
