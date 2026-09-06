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
            Image(systemName: issue.severity == .problem ? "exclamationmark.triangle.fill" : issue.severity == .unknown ? "questionmark.diamond.fill" : "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(issue.severity == .note ? Color.secondary : Color.orange)
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
    /// Optional so the wizard still presents anywhere these are not injected. A fix
    /// that needs one falls back to its guidance text rather than a blank screen.
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?
    /// Needed by the category repair, which creates a SABnzbd category before it
    /// repoints an Arr at it. Passed down explicitly for the same reason every fix
    /// destination re-injects `serviceManager`: a repair that silently degrades to
    /// "not connected" because an environment value did not survive the push is
    /// indistinguishable, from the outside, from a server that is actually down.
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?

    let issues: [ConfigurationIssue]
    let onDismissIssue: (ConfigurationIssue) -> Void
    let onRecheck: () async -> Void
    /// Opened *about* one finding rather than about the setup as a whole.
    ///
    /// A screen that says "Prowlarr is managing your indexers, want to add it?" and
    /// then opens a wizard showing an unrelated download-client repair has answered a
    /// question nobody asked. When a caller names a kind, the finding it asked about
    /// is what comes up first; the rest of the check is one tap away and still there.
    var focusedKind: ConfigurationIssueKind?
    /// How this wizard is being shown.
    ///
    /// `.sheet` brings its own `NavigationStack` and a Done button, which is what a
    /// modal needs. `.screen` is the wizard *as* a destination: on iPad and Mac the
    /// Setup Check is a row of the sidebar, and a row whose entire screen is one
    /// button that opens a sheet is a click spent on nothing. Presented as a screen
    /// it has no stack of its own - the column already has one, and nesting a second
    /// produces the band of empty space that every nested navigation container in
    /// this app has produced - and no Done, because there is nothing to dismiss. A
    /// fix then pushes onto the column's own stack, which is exactly where the same
    /// screen reached by hand would land.
    var presentation: Presentation = .sheet

    enum Presentation {
        case sheet
        case screen
    }

    @State private var stepIndex = 0
    @State private var isRechecking = false
    @State private var ignoredThisRun = false
    @State private var hasLeftFocus = false

    /// Notes are shown but never made into steps: they are things to be aware of,
    /// and marching the user through "these two hostnames differ" as if it were a
    /// repair is how a wizard teaches people to dismiss it without reading.
    private var steps: [ConfigurationIssue] { issues.problems }
    private var unknowns: [ConfigurationIssue] { issues.unknowns }
    private var notes: [ConfigurationIssue] { issues.notes }

    private var currentStep: ConfigurationIssue? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    /// The finding the caller opened this about, while it is still on screen.
    private var focusedIssue: ConfigurationIssue? {
        guard !hasLeftFocus, let focusedKind else { return nil }
        return issues.first { $0.kind == focusedKind }
    }

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .sheet:
            NavigationStack {
                wizardContent
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
        case .screen:
            // The title is set by whatever is showing this - the screen's own row
            // names it, and a second `navigationTitle` here would only race it.
            wizardContent
        }
    }

    @ViewBuilder
    private var wizardContent: some View {
        // Identity is what makes this read as a sequence rather than a form whose
        // labels keep changing. Without it SwiftUI sees one `Form` throughout and
        // diffs the rows in place, so pressing Next silently swapped the text and
        // left no sense of having moved - which is the whole of "it doesn't
        // transition nicely". Keyed on the step's own id rather than the index so
        // ignoring a step, which shrinks the list under a stationary index, still
        // counts as a move.
        Group {
            if let focusedIssue {
                focusedContent(focusedIssue)
                    .id("focus-\(focusedIssue.id)")
            } else if steps.isEmpty {
                if !unknowns.isEmpty {
                    incompleteContent.id("incomplete")
                } else if ignoredThisRun {
                    finishedContent.id("finished")
                } else {
                    allClearContent.id("all-clear")
                }
            } else if let currentStep {
                stepContent(currentStep)
                    .id("step-\(currentStep.id)")
            } else {
                finishedContent.id("finished")
            }
        }
        // Forward-only on purpose: every control here moves on - Next, Skip, Ignore -
        // and there is no Back to justify the symmetric pair. A page arrives from the
        // trailing edge and the one it replaces leaves past the leading edge.
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        // Clipped, or the outgoing page is drawn over the navigation bar and past
        // the window edge on the way out.
        .clipped()
        .safeAreaInset(edge: .bottom) { advanceBar }
    }

    /// The Next/Finish bar.
    ///
    /// Lifted out of the step itself so it stays put while the page behind it moves.
    /// Inside the transition it slid off with its own page and a second one slid in
    /// underneath, which reads as the whole screen lurching rather than as a step
    /// advancing.
    @ViewBuilder
    private var advanceBar: some View {
        if focusedIssue == nil, currentStep != nil {
            Button {
                advance()
            } label: {
                Text(stepIndex == steps.count - 1 ? "Finish" : "Next")
                    #if os(iOS)
                    // Full-width CTA in thumb reach. A Mac gets a normal button, sized
                    // to its word and centred under the centred form, rather than a
                    // 1500pt blue bar across the bottom of the window.
                    .frame(maxWidth: .infinity)
                    #endif
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
            .padding()
            // The bar still spans the pane; on macOS only the button inside it stops
            // doing so, which `.infinity` here keeps true once the button is narrow.
            #if os(macOS)
            .frame(maxWidth: .infinity)
            #endif
            .background(.bar)
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

            fixSection(issue)

            Section {
                Button("Skip for Now") { advance() }
                Button("Ignore This", role: .destructive) {
                    // Animated for the same reason Next is: the page is being
                    // replaced either way, and only one of the two moving would make
                    // Ignore feel like a different kind of action than it is.
                    withAnimation(.snappy) {
                        ignoredThisRun = true
                        onDismissIssue(issue)
                        // The list shrinks under us, so the index stays put and now
                        // points at the next problem on its own.
                        clampStepIndex()
                    }
                }
            } footer: {
                Text("Ignoring hides this until Trawl is restarted. It does not change anything on your servers.")
            }
        }
    }

    /// One finding, on its own, because that is what the caller asked about.
    ///
    /// Deliberately not `stepContent`: this is not step 1 of anything, there is
    /// nothing to skip, and numbering it would imply a sequence the user did not
    /// start. It offers the one fix and a way into the rest of the check.
    private func focusedContent(_ issue: ConfigurationIssue) -> some View {
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
            }

            fixSection(issue)

            Section {
                Button("See the Full Check") {
                    withAnimation(.snappy) { hasLeftFocus = true }
                }
                .accessibilityIdentifier("configuration-wizard-full-check")
            } footer: {
                Text(fullCheckSummary)
            }
        }
    }

    private var fullCheckSummary: String {
        let problems = steps.count
        let unknownCount = unknowns.count
        if problems == 0, unknownCount == 0 { return "Nothing else needs attention." }
        if problems == 0 {
            return unknownCount == 1
                ? "1 other check could not be completed."
                : "\(unknownCount) other checks could not be completed."
        }
        return problems == 1 ? "1 other problem was found." : "\(problems) other problems were found."
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
            verificationSection
            recheckSection
        }
    }

    private var incompleteContent: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "questionmark.diamond.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Setup Check Incomplete")
                        .font(.title3.weight(.semibold))
                    Text("Trawl could not verify every configured service. Review the checks below, then try again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            verificationSection
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
                    Text("Review Complete")
                        .font(.title3.weight(.semibold))
                    Text("Run the check again to confirm your changes. Skipped or ignored issues may still need attention.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            notesSection
            verificationSection
            recheckSection
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    // A note with somewhere to go is offered as a link rather than
                    // drawn as text. These were static rows, so a note like "review
                    // your download clients" - or "Prowlarr is managing your
                    // indexers, add it" - carried a fix destination that nothing
                    // could ever reach. They stay out of the numbered repair steps
                    // either way: a note is something to know, not something to be
                    // marched through.
                    if let destination = note.fix.destination {
                        NavigationLink {
                            fixDestination(destination)
                        } label: {
                            ConfigurationIssueRow(issue: note)
                        }
                        .accessibilityIdentifier("configuration-note-\(note.kind.rawValue)")
                    } else {
                        ConfigurationIssueRow(issue: note)
                    }
                }
            } header: {
                Text("Worth Knowing")
            } footer: {
                Text("These are often correct - a container name and a LAN address can be the same machine. Nothing here stops downloads working.")
            }
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        if !unknowns.isEmpty {
            Section {
                ForEach(unknowns) { issue in
                    ConfigurationIssueRow(issue: issue)
                }
            } header: {
                Text("Couldn't Verify")
            } footer: {
                Text("These checks are not passes. Restore the affected connections and check again.")
            }
        }
    }

    private var recheckSection: some View {
        Section {
            Button {
                Task {
                    isRechecking = true
                    await onRecheck()
                    withAnimation(.snappy) {
                        stepIndex = 0
                        ignoredThisRun = false
                    }
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

    /// The one place a fix is offered, so a step and a focused finding cannot drift
    /// into offering different things about the same issue.
    ///
    /// A guided repair gets both routes: the repair Trawl can run, and underneath it
    /// the screen where the same change is made by hand. Offering only the automatic
    /// one would make the wizard the only way to do it, which is the opposite of what
    /// this wizard is for - every other step pushes the real management screen so the
    /// fix sticks after the wizard closes.
    @ViewBuilder
    private func fixSection(_ issue: ConfigurationIssue) -> some View {
        Section {
            if let repair = issue.fix.guidedRepair, let actionTitle = issue.fix.actionTitle {
                NavigationLink {
                    ConfigurationCategoryRepairView(repair: repair, onApplied: onRecheck)
                        .environment(serviceManager)
                        .environment(sabnzbdServiceManager)
                } label: {
                    Label(actionTitle, systemImage: "wand.and.sparkles")
                }
                .accessibilityIdentifier("configuration-wizard-guided-fix")

                if let destination = issue.fix.destination {
                    NavigationLink {
                        fixDestination(destination)
                    } label: {
                        Label("Change It Myself", systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("configuration-wizard-fix")
                }
            } else if let destination = issue.fix.destination, let actionTitle = issue.fix.actionTitle {
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
    }

    /// The real management screen for a fix, pushed into the wizard's own stack.
    @ViewBuilder
    private func fixDestination(_ destination: ConfigurationFixDestination) -> some View {
        switch destination {
        case .downloadClientsManagement:
            ArrDownloadClientListView(serviceType: .sonarr)
                .environment(serviceManager)
        case .arrDownloadClients(let serviceType, let instanceID):
            ArrDownloadClientListView(serviceType: serviceType, initialInstanceID: instanceID)
                .environment(serviceManager)
        case .rootFolders(let instanceID):
            ArrRootFoldersView(initialInstanceID: instanceID)
                .environment(serviceManager)
        case .prowlarrIndexers:
            ProwlarrIndexerListView()
                .environment(serviceManager)
        case .prowlarrApplications:
            ProwlarrApplicationsListView()
                .environment(serviceManager)
        case .bazarrLinkedApplications(let instanceID):
            BazarrLinkedApplicationsListView(initialInstanceID: instanceID)
                .environment(serviceManager)
        case .bazarrLanguageProfiles:
            BazarrLanguageProfilesView()
                .environment(serviceManager)
        case .bazarrProviders:
            BazarrProvidersView()
                .environment(serviceManager)
        case .serviceSettings(let serviceType, let instanceID):
            ArrServiceSettingsView(serviceType: serviceType, initialProfileID: instanceID)
                .environment(serviceManager)
        case .arrRemotePathMappings:
            ArrRemotePathMappingListView()
                .environment(serviceManager)
        case .arrHealth:
            ArrHealthView()
                .environment(serviceManager)
        case .seerrLinkedApplications:
            if let client = seerrServiceManager?.activeClient {
                SeerrLinkedApplicationsView(apiClient: client)
            } else {
                unavailableFixDestination(
                    "Seerr is not connected",
                    detail: "Reconnect Seerr from Settings, then run the setup check again."
                )
            }
        case .cleanuparr:
            CleanuparrDashboardView()
        case .sabnzbdCategories:
            if let sabnzbdServiceManager {
                SABnzbdCategoriesView()
                    .environment(sabnzbdServiceManager)
            } else {
                unavailableFixDestination(
                    "SABnzbd is not connected",
                    detail: "Reconnect SABnzbd from Settings, then run the setup check again."
                )
            }
        }
    }

    /// A fix whose screen needs a connection the app does not currently have.
    ///
    /// Shown rather than hidden: the finding is real, and a button that opens a blank
    /// screen teaches people the wizard is broken rather than that their service is.
    private func unavailableFixDestination(_ title: String, detail: String) -> some View {
        ServiceErrorView(title: title, message: detail, systemImage: "network.slash")
    }
}
