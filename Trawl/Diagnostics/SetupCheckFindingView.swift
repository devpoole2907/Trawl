//
//  SetupCheckFindingView.swift
//  Trawl
//
//  One Setup Check finding: what is wrong, how to fix it, and what to do about it.
//

import SwiftUI

/// A single finding, as the detail column beside the list on iPad and Mac and as the
/// screen a row pushes on iPhone.
///
/// The same screen on every chrome. The phone used to get a separate step-by-step
/// wizard - "Problem 1 of 4", Next, Skip - with its own copy of every fix route, so
/// the two layouts drifted, and the wizard presented as a sheet from a push stack
/// that no other System row used.
///
/// Built on `Form` + `TrawlEntityHeader` + `serviceSettingsFormStyle()`, the shape
/// the other detail panes in the app share.
struct SetupCheckFindingView: View {
    let issue: ConfigurationIssue
    var isIgnored = false
    var lastChecked: Date?
    let onIgnore: () -> Void
    let onRestore: () -> Void
    let onRecheck: () async -> Void

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isDetailPane) private var isDetailPane

    @State private var isRechecking = false

    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: issue.title,
                    subtitle: issue.subject.displayName,
                    systemImage: issue.systemImage,
                    tint: issue.severity.tint,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            Section {
                Text(issue.detail)
                    .fixedSize(horizontal: false, vertical: true)

                if let discriminator = issue.discriminator {
                    LabeledContent("Target") {
                        Text(discriminator)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("What Trawl Found")
            } footer: {
                Text(issue.severity.explanation)
            }

            if hasFix || !issue.fix.guidance.isEmpty {
                Section {
                    fixControls
                } header: {
                    Text("How to Fix It")
                } footer: {
                    if !issue.fix.guidance.isEmpty {
                        Text(issue.fix.guidance)
                    }
                }
            }

            Section {
                Button {
                    Task { await recheck() }
                } label: {
                    if isRechecking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRechecking)
                .accessibilityIdentifier("setup-check-finding-recheck")

                if isIgnored {
                    Button {
                        onRestore()
                    } label: {
                        Label("Stop Ignoring", systemImage: "eye")
                    }
                    .accessibilityIdentifier("setup-check-restore")
                } else {
                    Button(role: .destructive) {
                        onIgnore()
                        // On a phone the finding was pushed from the list; once it is
                        // ignored there is nothing left here to act on. Beside a list
                        // the selection moves on by itself instead.
                        if !isDetailPane { dismiss() }
                    } label: {
                        Label("Ignore This Finding", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("setup-check-ignore")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isIgnored
                         ? "Ignored until Trawl restarts. Nothing on your servers was changed."
                         : "Ignoring hides this until Trawl restarts. It does not change anything on your servers.")
                    if let lastChecked {
                        Text("Last checked \(lastChecked, format: .relative(presentation: .named)).")
                    }
                }
            }
        }
        .serviceSettingsFormStyle()
        .paneAwareNavigationTitle(issue.severity.title, subtitle: issue.subject.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func recheck() async {
        isRechecking = true
        await onRecheck()
        isRechecking = false
    }

    private var hasFix: Bool {
        issue.fix.actionTitle != nil && (issue.fix.guidedRepair != nil || issue.fix.destination != nil)
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges = [ArrDetailBadge(icon: issue.severity.systemImage, label: issue.severity.badgeLabel, color: issue.severity.tint)]
        if let serviceType = issue.subject.serviceType {
            badges.append(
                ArrDetailBadge(
                    icon: serviceType.systemImage,
                    label: serviceType.displayName,
                    color: serviceType.serviceIdentity.brandColor
                )
            )
        }
        if isIgnored {
            badges.append(ArrDetailBadge(icon: "eye.slash", label: "Ignored", color: .secondary))
        }
        return badges
    }

    /// A guided repair gets both routes: the repair Trawl can run, and underneath it
    /// the screen where the same change is made by hand. Offering only the automatic
    /// one would make the Setup Check the only way to do it.
    @ViewBuilder
    private var fixControls: some View {
        if let repair = issue.fix.guidedRepair, let actionTitle = issue.fix.actionTitle {
            NavigationLink {
                ConfigurationCategoryRepairView(repair: repair, onApplied: onRecheck)
                    .environment(serviceManager)
                    .environment(sabnzbdServiceManager)
            } label: {
                Label(actionTitle, systemImage: "wand.and.sparkles")
            }
            .accessibilityIdentifier("setup-check-guided-fix")

            if let destination = issue.fix.destination {
                NavigationLink {
                    SetupCheckFixDestinationView(destination: destination)
                } label: {
                    Label("Change It Myself", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("setup-check-fix")
            }
        } else if let destination = issue.fix.destination, let actionTitle = issue.fix.actionTitle {
            NavigationLink {
                SetupCheckFixDestinationView(destination: destination)
            } label: {
                Label(actionTitle, systemImage: "wrench.and.screwdriver")
            }
            .accessibilityIdentifier("setup-check-fix")
        } else {
            // A manual fix: the guidance in the footer is the whole answer, and there
            // is no Trawl screen that makes the change. Said plainly rather than
            // leaving an empty section.
            Label("Change this on the server itself", systemImage: "server.rack")
                .foregroundStyle(.secondary)
        }
    }
}

extension ConfigurationIssueSeverity {
    var title: String {
        switch self {
        case .problem: "Problem"
        case .unknown: "Could Not Verify"
        case .note: "Worth Knowing"
        }
    }

    var badgeLabel: String { title.uppercased() }

    var systemImage: String {
        switch self {
        case .problem: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.diamond.fill"
        case .note: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .problem: .orange
        case .unknown: .yellow
        case .note: .blue
        }
    }

    /// What this severity means, said once where the user is reading the finding.
    var explanation: String {
        switch self {
        case .problem:
            "Something you expect to work cannot until this is fixed."
        case .unknown:
            "Trawl could not read this part of the setup, so it is not a pass. Restore the connection and check again."
        case .note:
            "Often deliberate - a container name and a LAN address can be the same machine. Nothing here stops downloads working."
        }
    }
}
