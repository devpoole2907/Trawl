//
//  ConfigurationWizardView.swift
//  Trawl
//
//  Walks the user through what the configuration audit found.
//

import SwiftUI

/// One finding, rendered for a list. Public so any screen can show findings without
/// the wizard: a settings row, a hub banner, a detail footer.
struct ConfigurationIssueRow: View {
    let issue: ConfigurationIssue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.severity == .problem ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(issue.severity == .problem ? .orange : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configuration-issue-\(issue.kind.rawValue)")
    }
}

/// A step-by-step pass over everything the audit found.
///
/// Built on the same `Form` + `modalFormStyle` chrome as the onboarding sheet, so
/// setting a server up and repairing how it was set up look like one another. Each
/// step pushes the real management screen rather than reimplementing it - the fix
/// happens in the same place the user would have found on their own, which is what
/// makes it stick after the wizard closes.
struct ConfigurationWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager

    let issues: [ConfigurationIssue]
    let onDismissIssue: (ConfigurationIssue) -> Void
    let onRecheck: () async -> Void

    @State private var stepIndex = 0
    @State private var isRechecking = false

    /// Notes are shown but never made into steps: they are things to be aware of,
    /// and marching the user through "these two hostnames differ" as if it were a
    /// repair is how a wizard teaches people to dismiss it without reading.
    private var steps: [ConfigurationIssue] { issues.problems }
    private var notes: [ConfigurationIssue] { issues.notes }

    private var currentStep: ConfigurationIssue? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if steps.isEmpty {
                    allClearContent
                } else if let currentStep {
                    stepContent(currentStep)
                } else {
                    finishedContent
                }
            }
            .navigationTitle("Setup Check")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(minWidth: 560, idealWidth: 620, minHeight: 480)
            #endif
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepContent(_ issue: ConfigurationIssue) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: issue.systemImage)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(issue.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(issue.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } header: {
                Text("Problem \(stepIndex + 1) of \(steps.count)")
            }

            Section {
                if let destination = issue.fix.destination, let actionTitle = issue.fix.actionTitle {
                    NavigationLink {
                        fixDestination(destination)
                    } label: {
                        Label(actionTitle, systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("configuration-wizard-fix")
                }
            } footer: {
                Text(issue.fix.guidance)
            }

            Section {
                Button("Skip for Now") { advance() }
                Button("Ignore This", role: .destructive) {
                    onDismissIssue(issue)
                    // The list shrinks under us, so the index stays put and now
                    // points at the next problem on its own.
                    clampStepIndex()
                }
            } footer: {
                Text("Ignoring hides this until Trawl is restarted. It does not change anything on your servers.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                advance()
            } label: {
                Text(stepIndex == steps.count - 1 ? "Finish" : "Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    // MARK: Terminal states

    private var allClearContent: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("Everything Is Wired Up")
                        .font(.title3.weight(.semibold))
                    Text("Trawl could not find anything wrong with how your services are pointed at each other.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            notesSection
            recheckSection
        }
    }

    private var finishedContent: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("That's Everything")
                        .font(.title3.weight(.semibold))
                    Text("Run the check again to confirm the changes took effect.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            notesSection
            recheckSection
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    ConfigurationIssueRow(issue: note)
                }
            } header: {
                Text("Worth Knowing")
            } footer: {
                Text("These are often correct - a container name and a LAN address can be the same machine. Nothing here stops downloads working.")
            }
        }
    }

    private var recheckSection: some View {
        Section {
            Button {
                Task {
                    isRechecking = true
                    await onRecheck()
                    stepIndex = 0
                    isRechecking = false
                }
            } label: {
                if isRechecking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking...")
                    }
                } else {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRechecking)
            .accessibilityIdentifier("configuration-wizard-recheck")
        }
    }

    // MARK: Navigation

    private func advance() {
        guard stepIndex < steps.count else { return }
        withAnimation(.snappy) { stepIndex += 1 }
    }

    private func clampStepIndex() {
        if stepIndex > steps.count { stepIndex = steps.count }
    }

    /// The real management screen for a fix, pushed into the wizard's own stack.
    @ViewBuilder
    private func fixDestination(_ destination: ConfigurationFixDestination) -> some View {
        switch destination {
        case .downloadClientsManagement, .arrDownloadClients(.prowlarr), .arrDownloadClients(.bazarr):
            ArrDownloadClientListView(serviceType: .sonarr)
                .environment(serviceManager)
        case .arrDownloadClients(let serviceType):
            ArrDownloadClientListView(serviceType: serviceType)
                .environment(serviceManager)
        case .rootFolders:
            ArrRootFoldersView()
                .environment(serviceManager)
        case .prowlarrIndexers:
            ProwlarrIndexerListView()
                .environment(serviceManager)
        case .prowlarrApplications:
            ProwlarrApplicationsListView()
                .environment(serviceManager)
        case .bazarrLinkedApplications:
            BazarrLinkedApplicationsListView()
                .environment(serviceManager)
        case .serviceSettings(let serviceType):
            ArrServiceSettingsView(serviceType: serviceType)
                .environment(serviceManager)
        }
    }
}
