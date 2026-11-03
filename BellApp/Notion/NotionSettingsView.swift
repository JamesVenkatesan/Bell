import SwiftUI

/// Notion, with the setup written out step by step, the columns shown as
/// they really are, and the last sync stated plainly rather than implied.
struct NotionSettingsView: View {
    @Environment(BellStore.self) private var store
    @State private var account = NotionAccount.shared

    @State private var token = ""
    @State private var link = ""
    @State private var confirmingDisconnect = false

    var body: some View {
        Form {
            if let config = account.config, account.hasToken {
                connected(config)
                mapping(config)
                columns(config)
                timing
            } else {
                connect
                steps
            }
            if let error = account.lastError {
                Section { Text(error).font(Bell.Type_.caption).foregroundStyle(Bell.Signal.urgent) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Bell.Surface.canvas)
        .navigationTitle("Notion")
        // Inline: the large title collided with the first section header.
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect Notion?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect and remove Notion tasks", role: .destructive) { account.disconnect(store: store) }
        } message: {
            Text("Tasks that came from Notion are removed from Bell. Nothing in Notion changes, and tasks you added in Bell stay.")
        }
    }

    // MARK: Not connected

    private var connect: some View {
        Section {
            SecureField("Internal integration secret", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Bell.Type_.data(13, weight: .regular))
            TextField("Database link", text: $link, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(Bell.Type_.data(13, weight: .regular))
            Button(account.isWorking ? "Connecting…" : "Connect") {
                Task {
                    if await account.connect(token: token, link: link, store: store) { token = "" }
                }
            }
            .disabled(account.isWorking || token.isEmpty || link.isEmpty)
        } header: {
            Text("Connect a database")
        } footer: {
            Text("The secret is kept in this phone's Keychain and sent only to Notion. Bell only reads: it can't "
                 + "change, add or delete anything in your workspace.")
        }
    }

    private var steps: some View {
        Section("Setting it up (once, about five minutes)") {
            step(1, "On a computer, open notion.so/my-integrations and choose New integration. Pick your workspace, "
                 + "set the type to Internal, and give it any name, such as Bell.")
            step(2, "Under Capabilities, leave only Read content ticked. Bell needs nothing else.")
            step(3, "Copy the Internal Integration Secret (it starts with ntn_) into the first field above.")
            step(4, "Open your Fall 2026 database in Notion, tap ••• at the top right, then Connections, and add the "
                 + "integration. If your course column links to a separate Courses database, connect that one too.")
            step(5, "Still in the database: Share > Copy link, and paste it into the second field.")
        }
    }

    // MARK: Connected

    private func connected(_ config: NotionConfig) -> some View {
        Section {
            LabeledContent("Database", value: config.title.isEmpty ? "Untitled" : config.title)
            LabeledContent("Last synced") {
                if let synced = account.lastSynced {
                    Text(synced, format: .relative(presentation: .named))
                        .foregroundStyle(Bell.Content.secondary)
                } else {
                    Text("Not yet").foregroundStyle(Bell.Content.secondary)
                }
            }
            if let result = account.lastResult {
                LabeledContent("Tasks", value: "\(result.total)")
                if result.unlinked > 0 {
                    LabeledContent("Uncategorised", value: "\(result.unlinked)")
                }
                if result.skipped > 0 {
                    LabeledContent("Rows without a due date", value: "\(result.skipped)")
                }
            }
            Button(account.isWorking ? "Syncing…" : "Sync now") {
                Task { await account.sync(store: store, force: true) }
            }
            .disabled(account.isWorking || !config.mapping.isUsable)
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
        } header: {
            Text("Connected")
        } footer: {
            Text("Reading with: \(config.source.summary)."
                 + (config.otherSources.isEmpty ? "" : " This database has more than one data source; Bell reads the first."))
        }
    }

    private func mapping(_ config: NotionConfig) -> some View {
        Section {
            ForEach(NotionMapping.Role.allCases) { role in
                Picker(role.label, selection: binding(role, config)) {
                    if !role.isRequired { Text("None").tag(String?.none) }
                    else if config.mapping[role] == nil { Text("Choose…").tag(String?.none) }
                    ForEach(config.schema.filter { role.types.contains($0.type) }) { property in
                        Text(property.name).tag(Optional(property.id))
                    }
                }
            }
        } header: {
            Text("Which column is which")
        } footer: {
            Text("Bell guessed from the column types; change anything it got wrong. Columns are remembered by "
                 + "Notion's internal ID, so renaming one in Notion doesn't break this. A row is linked to a "
                 + "course when its course column or title contains one of your course codes; anything else "
                 + "shows as Uncategorised rather than being guessed.")
        }
    }

    private func binding(_ role: NotionMapping.Role, _ config: NotionConfig) -> Binding<String?> {
        Binding {
            account.config?.mapping[role]
        } set: { value in
            var mapping = config.mapping
            mapping[role] = value
            Task { await account.setMapping(mapping, store: store) }
        }
    }

    private func columns(_ config: NotionConfig) -> some View {
        Section("Every column in the database") {
            ForEach(config.schema) { property in
                LabeledContent {
                    Text(property.typeLabel).foregroundStyle(Bell.Content.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(property.name)
                        if let role = NotionMapping.Role.allCases.first(where: { config.mapping[$0] == property.id }) {
                            Text("Used as \(role.label.lowercased())")
                                .font(Bell.Type_.micro)
                                .foregroundStyle(Bell.Content.secondary)
                        }
                    }
                }
            }
        }
    }

    private var timing: some View {
        Section {
            Text("iOS doesn't let an app wake at a set time. Bell asks for a refresh early each morning, and iOS "
                 + "usually grants it, but when depends on battery, signal and how often you open Bell. It also "
                 + "syncs whenever you open it and the last sync is over an hour old, and if a widget notices "
                 + "the data is more than four hours old it asks Bell to sync the next time it runs. Widgets "
                 + "can't fetch anything themselves. Everywhere Notion tasks appear, Bell shows when they were "
                 + "last synced.")
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.secondary)
        } header: {
            Text("How often it syncs")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Bell.Space.base) {
            Text("\(n)").font(Bell.Type_.data(15, weight: .semibold)).foregroundStyle(Bell.Signal.inferred)
            Text(text).font(Bell.Type_.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}
