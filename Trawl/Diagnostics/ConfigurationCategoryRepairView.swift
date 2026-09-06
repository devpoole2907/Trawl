//
//  ConfigurationCategoryRepairView.swift
//  Trawl
//
//  The wizard step that separates two servers' download categories for them.
//

import SwiftData
import SwiftUI

/// Shows the plan, lets the user change the names, then applies it.
///
/// Deliberately not a one-tap "Fix It". The names it proposes end up as folders on
/// the user's disk and in every download client's UI, and a repair that invents a
/// filesystem layout without showing it first is how a helpful wizard becomes one
/// people stop trusting. Everything is on screen before anything is written.
struct ConfigurationCategoryRepairView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    let repair: ConfigurationGuidedRepair
    /// Called once every change has been applied, so the wizard can re-run the audit
    /// rather than keep showing a finding that is no longer true.
    var onApplied: () async -> Void = {}

    @State private var plans: [ConfigurationCategoryRepair.Plan] = []
    @State private var outcomes: [UUID: ConfigurationCategoryRepair.Outcome] = [:]
    @State private var isApplying = false
    @State private var hasApplied = false

    private var isSABnzbd: Bool {
        plans.contains { sabnzbdEndpoints.contains($0.change.endpoint) }
    }

    private var sabnzbdEndpoints: Set<String> {
        Set(sabnzbdProfiles.filter(\.isEnabled).map {
            DownloadClientLinkChecker.normalizedEndpoint(from: $0.hostURL)
        })
    }

    private var activeSabnzbdEndpoint: String? {
        guard let id = sabnzbdServiceManager?.activeProfileID,
              let profile = sabnzbdProfiles.first(where: { $0.id == id }) else { return nil }
        return DownloadClientLinkChecker.normalizedEndpoint(from: profile.hostURL)
    }

    /// Two servers cannot be repaired onto the same name, and the check has to run
    /// against what is in the fields right now rather than what was suggested.
    private var duplicateNames: Set<String> {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for plan in plans {
            let value = plan.normalizedCategory
            guard !value.isEmpty else { continue }
            if !seen.insert(value).inserted { duplicates.insert(value) }
        }
        return duplicates
    }

    private var canApply: Bool {
        !isApplying
            && !plans.isEmpty
            && duplicateNames.isEmpty
            && plans.allSatisfy(\.isValid)
    }

    var body: some View {
        Form {
            Section {
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($plans) { $plan in
                planSection($plan)
            }

            if hasApplied {
                Section {
                    Label(
                        "Run the setup check again to confirm.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                }
            }
        }
        .navigationTitle("Separate Categories")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) { applyBar }
        .task {
            // Built once. Rebuilding on every body pass would throw away whatever the
            // user has typed the moment anything else on screen changed.
            guard plans.isEmpty else { return }
            plans = repair.downloadCategoryChanges.map(ConfigurationCategoryRepair.Plan.init)
        }
    }

    private var explanation: String {
        let base = "Each server needs a category of its own so the download client keeps their downloads apart. Trawl will point each one at the category below."
        guard isSABnzbd else { return base }
        return base + " Any that SABnzbd does not already have will be created first, each with its own folder."
    }

    @ViewBuilder
    private func planSection(_ plan: Binding<ConfigurationCategoryRepair.Plan>) -> some View {
        let change = plan.wrappedValue.change
        let outcome = outcomes[change.id] ?? .pending

        Section {
            LabeledContent("Download Client") {
                Text(change.downloadClientName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Now") {
                Text(change.currentCategory.map { "\"\($0)\"" } ?? "Not set")
                    .foregroundStyle(.secondary)
            }
            TextField("Category", text: plan.category)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .disabled(isApplying || outcome.isTerminal)
                .accessibilityIdentifier("configuration-repair-category-\(change.instanceID.uuidString)")

            outcomeRow(outcome, plan: plan.wrappedValue)
        } header: {
            Text(change.serverName)
        }
    }

    @ViewBuilder
    private func outcomeRow(
        _ outcome: ConfigurationCategoryRepair.Outcome,
        plan: ConfigurationCategoryRepair.Plan
    ) -> some View {
        switch outcome {
        case .pending:
            // Validation is shown where the value is, not collected into a banner at
            // the bottom that names a server the user has to go and find.
            if !plan.isValid {
                Label("Enter a category name without slashes.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if duplicateNames.contains(plan.normalizedCategory) {
                Label("Another server above is already using this name.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Applying...").font(.footnote).foregroundStyle(.secondary)
            }
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("configuration-repair-succeeded")
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("configuration-repair-failed")
        }
    }

    private var applyBar: some View {
        Button {
            Task { await applyAll() }
        } label: {
            Group {
                if isApplying {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Applying...")
                    }
                } else {
                    // A retry after a partial failure is the common second press, so
                    // the button says so rather than offering "Apply" over results.
                    Text(hasApplied ? "Apply Again" : "Apply Changes")
                }
            }
            #if os(iOS)
            .frame(maxWidth: .infinity)
            #endif
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canApply)
        .padding()
        #if os(macOS)
        .frame(maxWidth: .infinity)
        #endif
        .background(.bar)
        .accessibilityIdentifier("configuration-repair-apply")
    }

    private func applyAll() async {
        isApplying = true
        defer { isApplying = false }

        let engine = ConfigurationCategoryRepair(
            serviceManager: serviceManager,
            sabnzbdServiceManager: sabnzbdServiceManager,
            sabnzbdEndpoints: sabnzbdEndpoints,
            activeSabnzbdEndpoint: activeSabnzbdEndpoint
        )

        for plan in plans {
            // A server that is already done is not touched again, so pressing Apply
            // after a partial failure retries only what failed.
            if case .succeeded = outcomes[plan.id] { continue }
            outcomes[plan.id] = .running
            outcomes[plan.id] = await engine.apply(plan)
        }

        hasApplied = true
        // Only when everything landed. Re-auditing after a partial failure would
        // replace the per-server errors on screen with a finding that says less.
        if plans.allSatisfy({ if case .succeeded = outcomes[$0.id] { true } else { false } }) {
            await onApplied()
        }
    }
}
