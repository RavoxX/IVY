import AppKit
import IVYCore
import SwiftUI

struct ConnectorListing: Identifiable {
    var id: String
    var title: String
    var detail: String
    var publisher: String
    var endpoint: URL?
    var documentation: URL?
    var symbol = "puzzlepiece.extension"
    var color: Color = .accentColor

    static let featured: [ConnectorListing] = [
        .init(id: "gmail", title: "Gmail", detail: "Search emails, read threads, and work with drafts.", publisher: "Google",
              endpoint: URL(string: "https://gmailmcp.googleapis.com/mcp/v1"),
              documentation: URL(string: "https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server"), symbol: "envelope", color: .red),
        .init(id: "drive", title: "Google Drive", detail: "Search files, read documents, and access your workspace.", publisher: "Google",
              endpoint: URL(string: "https://drivemcp.googleapis.com/mcp/v1"),
              documentation: URL(string: "https://developers.google.com/workspace/drive/api/guides/configure-mcp-server"), symbol: "externaldrive", color: .green),
        .init(id: "calendar", title: "Google Calendar", detail: "Find events, check availability, and manage your schedule.", publisher: "Google",
              endpoint: URL(string: "https://calendarmcp.googleapis.com/mcp/v1"),
              documentation: URL(string: "https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server"), symbol: "calendar", color: .blue),
        .init(id: "notion", title: "Notion", detail: "Search and update pages in your Notion workspace.", publisher: "Notion",
              endpoint: URL(string: "https://mcp.notion.com/mcp"), documentation: URL(string: "https://developers.notion.com/guides/mcp/get-started-with-mcp"), symbol: "doc.text", color: .gray),
        .init(id: "figma", title: "Figma", detail: "Use design context in your assistant conversations.", publisher: "Figma",
              endpoint: URL(string: "https://mcp.figma.com/mcp"), documentation: URL(string: "https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/"), symbol: "square.stack.3d.up", color: .purple),
        .init(id: "linear", title: "Linear", detail: "Find issues, plan projects, and update your team's work.", publisher: "Linear",
              endpoint: URL(string: "https://mcp.linear.app/mcp"), documentation: URL(string: "https://linear.app/docs/mcp"), symbol: "line.3.horizontal.decrease.circle", color: .indigo),
        .init(id: "canva", title: "Canva", detail: "Create, search, and edit designs through Canva tools.", publisher: "Canva",
              endpoint: URL(string: "https://mcp.canva.com/mcp"), documentation: URL(string: "https://www.canva.dev/docs/apps/mcp/"), symbol: "paintbrush", color: .cyan),
        .init(id: "slack", title: "Slack", detail: "Search conversations and use approved workspace tools.", publisher: "Slack",
              endpoint: URL(string: "https://mcp.slack.com/mcp"), documentation: URL(string: "https://docs.slack.dev/ai/slack-mcp-server"), symbol: "number", color: .pink),
        .init(id: "asana", title: "Asana", detail: "Find tasks and coordinate projects with your team.", publisher: "Asana",
              endpoint: URL(string: "https://mcp.asana.com/v2/mcp"), documentation: URL(string: "https://developers.asana.com/docs/integrating-with-asanas-mcp-server"), symbol: "checkmark.circle", color: .orange),
        .init(id: "hubspot", title: "HubSpot", detail: "Access customer and CRM context with HubSpot.", publisher: "HubSpot",
              endpoint: URL(string: "https://mcp.hubspot.com/"), documentation: URL(string: "https://developers.hubspot.com/docs/apps/developer-platform/build-apps/integrate-with-the-remote-hubspot-mcp-server"), symbol: "person.3", color: .orange),
        .init(id: "microsoft", title: "Microsoft 365", detail: "Discover servers for Outlook, OneDrive, SharePoint, and Teams.", publisher: "Server-dependent",
              endpoint: nil, documentation: nil, symbol: "square.grid.2x2", color: .blue)
    ]
}

enum ConnectorCategory: String, CaseIterable, Identifiable {
    case workspace = "Google & Microsoft", productivity = "Notes & projects", design = "Design",
         communication = "Communication", crm = "Sales & CRM"
    var id: String { rawValue }
    var apps: [String] {
        switch self {
        case .workspace: return ["gmail", "drive", "calendar", "microsoft"]
        case .productivity: return ["notion", "linear", "asana"]
        case .design: return ["figma", "canva"]
        case .communication: return ["slack"]
        case .crm: return ["hubspot"]
        }
    }
}

struct ConnectorSettings: View {
    @ObservedObject var manager: ConnectorManager
    @Environment(\.colorScheme) private var scheme
    @State private var tab = "discover"
    @State private var category = "all"
    @State private var search = ""
    @State private var results: [ConnectorListing] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var registryLoaded = false
    @State private var message = ""
    @State private var selected: ConnectorListing?
    @State private var selectedAccount: UUID?
    @State private var showCustom = false

    private var featured: [ConnectorListing] {
        ConnectorListing.featured.filter { search.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(search) }
    }
    private var filteredAccounts: [ConnectorAccount] {
        manager.accounts.filter { search.isEmpty || ($0.name + " " + ($0.endpoint.host ?? "")).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("View", selection: $tab) {
                    Text("Discover").tag("discover")
                    Text("My apps (\(manager.accounts.count))").tag("connected")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 235)
                Spacer()
                Button { showCustom = true } label: { Label("Add custom connector", systemImage: "plus") }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tab == "discover" ? "Find an app or MCP server" : "Search your apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if tab == "discover" { Task { await loadRegistry() } } }
                if tab == "discover" {
                    Picker("Category", selection: $category) {
                        Text("All categories").tag("all")
                        ForEach(ConnectorCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 150)
                    Button("Search registry") { Task { await loadRegistry() } }.disabled(loading)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == "discover" {
                        ForEach(ConnectorCategory.allCases) { group in
                            let items = featured.filter { group.apps.contains($0.id) }
                            if (category == "all" || category == group.rawValue) && !items.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(group.rawValue).font(.headline)
                                        Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 12, alignment: .top)], spacing: 12) {
                                        ForEach(items) { app in appCard(app) }
                                    }
                                }
                            }
                        }
                        if featured.isEmpty && !registryLoaded {
                            ContentUnavailableView("No featured app matches", systemImage: "magnifyingglass",
                                description: Text("Search the MCP registry to discover more servers."))
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("MCP registry").font(.headline)
                                Spacer()
                                if loading { ProgressView().controlSize(.small) }
                                Button(registryLoaded ? "Load more" : "Browse servers") { Task { await loadRegistry(more: registryLoaded) } }
                                    .disabled(loading || (registryLoaded && cursor == nil))
                            }
                            Text("More services and community servers. Published by their authors; check the publisher before connecting.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(results) { app in
                                HStack(spacing: 12) {
                                    ConnectorLogo(listing: nil, size: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(app.title).font(.callout.bold())
                                        Text(app.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(app.publisher).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Set up") { selected = app }
                                }.padding(14).background(SettingsPalette.card(scheme), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(SettingsPalette.border(scheme)))
                            }
                            if registryLoaded && results.isEmpty { Text("No compatible remote servers found.").foregroundStyle(.secondary) }
                            Link("About the MCP registry", destination: URL(string: "https://registry.modelcontextprotocol.io")!).font(.caption)
                        }
                    } else {
                        if filteredAccounts.isEmpty {
                            ContentUnavailableView(manager.accounts.isEmpty ? "No apps connected yet" : "No matching apps",
                                systemImage: "puzzlepiece.extension", description: Text("Choose an app in Discover or add a custom MCP server."))
                        }
                        ForEach(filteredAccounts) { account in
                            HStack(spacing: 14) {
                                ConnectorLogo(listing: ConnectorListing.featured.first { $0.endpoint == account.endpoint })
                                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(account.name).font(.headline)
                                    Text(manager.status[account.id] ?? "Disconnected").font(.caption).foregroundStyle(.secondary)
                                    Text("\(account.enabledTools.count) tools enabled · " + (account.endpoint.host ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Manage") { selectedAccount = account.id }
                            }.padding(16).background(SettingsPalette.card(scheme), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SettingsPalette.border(scheme)))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Account setup varies by service. Connected tools are available to the assistant after you enable them.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).background(SettingsPalette.window(scheme))
        .sheet(item: $selected) { listing in
            ConnectorEditor(manager: manager, name: listing.title, endpoint: listing.endpoint?.absoluteString ?? "", documentation: listing.documentation)
        }
        .sheet(isPresented: $showCustom) { ConnectorEditor(manager: manager, name: "", endpoint: "", documentation: nil) }
        .sheet(isPresented: Binding(get: { selectedAccount != nil }, set: { if !$0 { selectedAccount = nil } })) {
            if let id = selectedAccount, let account = manager.accounts.first(where: { $0.id == id }) {
                ConnectorEditor(manager: manager, name: account.name, endpoint: account.endpoint.absoluteString,
                    documentation: ConnectorListing.featured.first { $0.endpoint == account.endpoint }?.documentation, existingID: id)
            }
        }
        .onChange(of: search) { _, _ in results = []; cursor = nil; registryLoaded = false; message = "" }
    }

    private func appCard(_ app: ConnectorListing) -> some View {
        let account = manager.accounts.first { $0.endpoint == app.endpoint }
        return Button {
            if let account { selectedAccount = account.id }
            else if app.endpoint == nil { search = "microsoft"; Task { await loadRegistry() } }
            else { selected = app }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ConnectorLogo(listing: app, size: 32)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.title).font(.callout.bold()).foregroundStyle(.primary)
                        Text(app.publisher).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(app.detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                HStack {
                    if account != nil {
                        Label("Added", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(app.endpoint == nil ? "Find servers" : "Connect").font(.caption.weight(.medium)).foregroundStyle(.blue)
                    }
                    Spacer()
                    Image(systemName: account == nil ? "plus" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsPalette.card(scheme), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SettingsPalette.border(scheme)))
        }.buttonStyle(.plain)
    }

    private func loadRegistry(more: Bool = false) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let submittedSearch = search
        var url = URLComponents(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        url.queryItems = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "version", value: "latest")]
        if !search.isEmpty { url.queryItems?.append(URLQueryItem(name: "search", value: search)) }
        if more, let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        do {
            let (data, response) = try await MCPRedirectGuard.session().data(from: url.url!)
            guard submittedSearch == search else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw MCPError.protocolError }
            let items = (value["servers"]?.arrayValue ?? []).compactMap { entry -> ConnectorListing? in
                let server = entry["server"] ?? entry
                guard let name = server["name"]?.stringValue,
                      let remote = server["remotes"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "streamable-http" }),
                      let endpoint = remote["url"]?.stringValue.flatMap(URL.init(string:)), MCPURL.validate(endpoint) else { return nil }
                return ConnectorListing(id: name, title: server["title"]?.stringValue ?? name,
                    detail: String((server["description"]?.stringValue ?? "").prefix(400)), publisher: name,
                    endpoint: endpoint, documentation: server["websiteUrl"]?.stringValue.flatMap(URL.init(string:)))
            }
            results = more ? results + items.filter { item in !results.contains { $0.id == item.id } } : items
            cursor = value["metadata"]?["nextCursor"]?.stringValue
            if cursor == "" { cursor = nil }
            registryLoaded = true; tab = "discover"
            message = "\(results.count) remote servers found in the registry."
        } catch { message = "Couldn't load the registry. Featured apps and custom connections are still available." }
    }
}

private struct ConnectorEditor: View {
    @ObservedObject var manager: ConnectorManager
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State var endpoint: String
    let documentation: URL?
    var existingID: UUID?
    @State private var accountID: UUID?
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var scope = ""
    @State private var error = ""
    private var id: UUID? { accountID ?? existingID }
    private var busy: Bool { id.map { manager.busy.contains($0) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(name.isEmpty ? "Add connector" : name).font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding(24)
            Form {
                Section("Connection") {
                    TextField("App name", text: $name).disabled(id != nil)
                    TextField("MCP server URL", text: $endpoint).disabled(id != nil)
                    if let documentation, documentation.scheme == "https", documentation.user == nil {
                        Link("Setup instructions from the service", destination: documentation)
                    }
                    Text("Only connect servers you trust. Enabled tools can access this account. Connector results are included in AI requests to your selected model provider.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Connect / reconnect") { connect() }.disabled(busy)
                        Button("Sign in with browser") { signIn() }.disabled(busy)
                        if busy { ProgressView().controlSize(.small); Button("Cancel sign-in") { manager.oauth.cancel() } }
                    }
                    if let id { Text(manager.status[id] ?? "").font(.caption) }
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Advanced authentication") {
                    TextField("OAuth client ID (if required)", text: $clientID)
                    SecureField("OAuth client secret (if required)", text: $clientSecret)
                    TextField("OAuth scopes (optional, space-separated)", text: $scope)
                    Text("Servers with dynamic registration need no client ID. Google requires your own Cloud project and Desktop OAuth client. Slack, Asana and some other services require app registration. IVY opens the service's consent page and uses a loopback callback with PKCE.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Server-issued bearer token (optional)", text: $token)
                    Text("Tokens and OAuth grants are stored in macOS Keychain. Disconnect stops access in IVY; Revoke asks the service to invalidate its grant.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let id, let tools = manager.tools[id] {
                    Section("Available tools · \(tools.count)") {
                        Text("Enable only the tools you want IVY to use. Each call asks for confirmation with its arguments; server-provided read-only labels do not bypass approval.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(tools) { tool in
                            Toggle(isOn: Binding(get: { manager.accounts.first { $0.id == id }?.enabledTools.contains(tool.name) == true },
                                set: { manager.setEnabled($0, tool: tool.name, id: id) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.name).font(.callout.bold())
                                    Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    }
                }
                if let id {
                    Section {
                        HStack {
                            Button("Disconnect") { Task { await manager.disconnect(id) } }
                            Button("Revoke access", role: .destructive) { Task { await manager.disconnect(id, revoke: true) } }
                            Spacer()
                            Button("Remove", role: .destructive) { Task { await manager.disconnect(id, remove: true); dismiss() } }
                        }.disabled(busy)
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 680, height: 720)
    }
    private func ensureAccount() throws -> UUID {
        if let id { return id }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw MCPError.invalidURL }
        let value = try manager.add(name: name, endpoint: url); accountID = value; return value
    }
    private func connect() {
        do {
            let id = try ensureAccount()
            if !token.isEmpty { try manager.setToken(token, id: id); token = "" }
            Task { await manager.connect(id) }
        } catch { self.error = error.localizedDescription }
    }
    private func signIn() {
        do {
            let id = try ensureAccount()
            Task { await manager.signIn(id: id, clientID: clientID, clientSecret: clientSecret, scope: scope); clientSecret = "" }
        } catch { self.error = error.localizedDescription }
    }
}
