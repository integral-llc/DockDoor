import Defaults
import SwiftUI

struct SupportSettingsView: View {
    @ObservedObject var updaterState: UpdaterState
    @StateObject private var permissionsChecker = PermissionsChecker()
    @Default(.hideDockDoorProBanner) private var hideDockDoorProBanner

    init(updaterState: UpdaterState) {
        self.updaterState = updaterState
    }

    var body: some View {
        BaseSettingsView {
            VStack(alignment: .leading, spacing: 20) {
                if !hideDockDoorProBanner {
                    DockDoorProBanner {
                        hideDockDoorProBanner = true
                    }
                }

                permissionsSection
                updatesSection
                acknowledgmentsSection
            }
        }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        SettingsGroup(header: "Permissions", compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required for dock hover detection and window switcher hotkeys",
                    icon: "accessibility",
                    isGranted: permissionsChecker.accessibilityPermission,
                    action: { SystemPreferencesHelper.openAccessibilityPreferences() }
                )
                .settingsSearchTarget("support.accessibility")

                Divider().padding(.leading, 40)

                PermissionRow(
                    title: "Screen Recording",
                    description: "Required for capturing window previews. Without this, only compact list view is available.",
                    icon: "record.circle",
                    isGranted: permissionsChecker.screenRecordingPermission,
                    action: { SystemPreferencesHelper.openScreenRecordingPreferences() }
                )
                .settingsSearchTarget("support.screenRecording")
            }

            Text("Changes to permissions require an app restart to take effect.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Updates Section

    // Fork: Sparkle is disabled, so this section only shows the version and debug logging.
    private var updatesSection: some View {
        SettingsGroup(header: "About") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "checkmark.seal.fill", color: .green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current Version")
                            .font(.body)
                        Text("Version \(updaterState.currentVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                Divider().padding(.leading, 40)

                DebugLoggingRow()
                    .settingsSearchTarget("support.debugLogging")
            }
        }
    }

    // MARK: - Acknowledgments Section

    private var acknowledgmentsSection: some View {
        SettingsGroup(header: "Acknowledgments") {
            VStack(alignment: .leading, spacing: 12) {
                // Community Contributors
                Text("Community Contributors")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                ContributorRow(
                    name: "illavoluntas",
                    detail: "Website, documentation, Discord moderation",
                    icon: "person.fill"
                )

                Divider()

                // Translation Contributors
                Text("Translation Contributors")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                VStack(spacing: 2) {
                    TranslatorRow(name: "Rocco 'Roccobot' Casadei", language: "Italian", profile: "Roccobot")
                    TranslatorRow(name: "favorsjewelry5", language: "Chinese Traditional", profile: "favorsjewelry5")
                    TranslatorRow(name: "Денис Єгоров", language: "Ukrainian", profile: "makedonsky47")
                    TranslatorRow(name: "HuangxinDong", language: "Chinese Simplified", profile: "HuangxinDong")
                    TranslatorRow(name: "don.julien.7", language: "German", profile: "JuGro1332")
                    TranslatorRow(name: "awaustin", language: "Chinese Simplified", profile: "awaustin")
                    TranslatorRow(name: "illavoluntas", language: "French", profile: "illavoluntas")
                    TranslatorRow(name: "Diamant", language: "French", profile: "Diamant")
                }

                Divider()

                // Audio Assets
                Text("Audio Assets")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                AudioAssetRow(
                    name: "Magic Glow",
                    author: "IENBA",
                    sourceURL: "https://freesound.org/s/752274/",
                    license: "CC0"
                )
            }
        }
    }
}

private struct DockDoorProBanner: View {
    private static let iconURL = URL(string: "https://pro.dockdoor.net/_astro/dockdoor-icon.DNTkj7IN_GoFVN.webp")!
    private static let destinationURL = URL(string: "https://pro.dockdoor.net")!

    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            proIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "DockDoor Pro", comment: "DockDoor Pro banner title"))
                    .font(.headline)

                Text(String(localized: "A separate paid app that fully replaces the macOS Dock with profiles, widgets, file tray, media controls with lyrics, and a built-in switcher.", comment: "DockDoor Pro banner description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: Self.destinationURL) {
                    Label(String(localized: "Learn More", comment: "DockDoor Pro banner link"), systemImage: "arrow.up.right")
                }
                .buttonStyle(AccentButtonStyle(small: true))
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Never show DockDoor Pro banner again", comment: "DockDoor Pro banner dismiss accessibility label"))
            .help(String(localized: "Never show again", comment: "DockDoor Pro banner dismiss help text"))
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var proIcon: some View {
        AsyncImage(url: Self.iconURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
            default:
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.mint)
            }
        }
        .frame(width: 48, height: 48)
        .background(Color.mint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Helper Views

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let icon: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, color: isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)
                    .font(.callout)

                if !isGranted {
                    Button("Grant") {
                        action()
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DebugLoggingRow: View {
    @Default(.debugMode) var debugMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "ant.fill", color: .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug Logging")
                        .font(.body)
                    Text("Capture performance metrics for troubleshooting")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: $debugMode)
                    .labelsHidden()
            }

            if debugMode {
                HStack(spacing: 12) {
                    Button("Export Logs") {
                        if let url = DebugLogger.exportLogs() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .buttonStyle(AccentButtonStyle(small: true))

                    Button("Clear Logs") {
                        DebugLogger.clearLogs()
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                }
                .padding(.leading, 40)
            }
        }
    }
}

private struct ContributorRow: View {
    let name: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(name)
                .font(.body)

            Spacer()

            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct TranslatorRow: View {
    let name: String
    let language: String
    let profile: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(name)
                .font(.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(language)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)

            Link(destination: URL(string: "https://crowdin.com/profile/\(profile)")!) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AudioAssetRow: View {
    let name: String
    let author: String
    let sourceURL: String
    let license: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(name)
                .font(.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(license)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)

            Link(destination: URL(string: sourceURL)!) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}
