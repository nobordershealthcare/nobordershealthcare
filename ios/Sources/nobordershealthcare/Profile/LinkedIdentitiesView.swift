// LinkedIdentitiesView.swift — Manage multiple country identities from the profile.
//
// Shows all VerifiedIdentity records linked to this device.
// Allows the user to:
//   • See all linked countries with flag, provider, verification date
//   • Add a new identity for any country via a sheet (IdentityView in isSheet mode)
//   • Delete / revoke a specific country identity
//
// Embedded in ProfileView under the "Verified Identities" section.

import SwiftUI

// MARK: - LinkedIdentitiesView

struct LinkedIdentitiesView: View {

    @State private var identities: [VerifiedIdentity] = []
    @State private var showAddSheet = false

    var body: some View {
        Section {
            if identities.isEmpty {
                emptyRow
            } else {
                ForEach(identities) { identity in
                    identityRow(identity)
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { identities[$0].id }
                    toDelete.forEach { VerifiedIdentityStore.remove(id: $0) }
                    identities = VerifiedIdentityStore.loadAll()
                }
            }

            addButton
        } header: {
            HStack {
                Label("Verified Identities", systemImage: "person.badge.shield.checkmark.fill")
                Spacer()
                if !identities.isEmpty {
                    Text("\(identities.count)")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.navy.opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(Color.navy)
                }
            }
        } footer: {
            Text("Each linked identity lets emergency responders verify your records from that country's health system.")
                .font(.caption2)
        }
        .onAppear { identities = VerifiedIdentityStore.loadAll() }
        .sheet(isPresented: $showAddSheet) {
            identities = VerifiedIdentityStore.loadAll()
        } content: {
            IdentityView(isSheet: true, onDone: {
                identities = VerifiedIdentityStore.loadAll()
            })
        }
    }

    // MARK: - Rows

    private func identityRow(_ identity: VerifiedIdentity) -> some View {
        HStack(spacing: 14) {
            // Flag circle
            ZStack {
                Circle()
                    .fill(Color.navy.opacity(0.08))
                    .frame(width: 44, height: 44)
                Text(identity.countryFlag)
                    .font(.title2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(identity.countryName)
                        .font(.subheadline).fontWeight(.semibold)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                Text(identity.providerName)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Verified \(identity.verifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer()

            if identity.expiresAt != nil {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.title2).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No identity linked yet")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Link your national ID to access cross-border health records")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.navy)
                Text("Link identity for another country")
                    .font(.subheadline).foregroundStyle(Color.navy)
            }
        }
    }
}

#Preview {
    List {
        LinkedIdentitiesView()
    }
}
