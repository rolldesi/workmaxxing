import AppKit
import SwiftUI

/// Fork: the Workmaxxing start window, shown at launch. Laid out like an
/// editor's empty window (centered column, action cards, recent projects),
/// but every project opens as a workspace with agents already running.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    static let showAtLaunchKey = "cmuxFork.welcome.showAtLaunch"

    private var window: NSWindow?

    static func showAtLaunchIfEnabled() {
        guard UserDefaults.standard.object(forKey: showAtLaunchKey) as? Bool ?? true else { return }
        // After session restore has put the main window up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { shared.show() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView(onDone: { [weak self] in self?.close() }))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Opens a workspace rooted at `folder` with `agents` boxes running
    /// `command` (0 = one plain terminal).
    static func launch(folder: String, agents: Int, command: String) {
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        LeftSidebarRecents.add(folder)
        let name = (folder as NSString).lastPathComponent
        guard let workspace = tabManager.addWorkspaceIfActive(
            title: name,
            workingDirectory: folder,
            inheritWorkingDirectory: false,
            select: true
        ) else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if agents > 0, !trimmed.isEmpty, let layout = agentLayout(count: agents, command: trimmed) {
            workspace.applyCustomLayout(layout, baseCwd: folder)
        }
    }

    /// Columns of boxes, like the presets in cmux.json: 8 agents is 2, 2, 4.
    static func agentLayout(count: Int, command: String) -> CmuxLayoutNode? {
        let columns: [Int]
        switch count {
        case 1: columns = [1]
        case 2: columns = [1, 1]
        case 3: columns = [1, 2]
        case 4: columns = [2, 2]
        case 5: columns = [2, 2, 1]
        case 6: columns = [2, 2, 2]
        case 7: columns = [2, 2, 3]
        default: columns = [2, 2, 4]
        }
        var box = 0
        func pane() -> [String: Any] {
            box += 1
            var surface: [String: Any] = ["type": "terminal", "name": "box \(box)", "command": command]
            if box == 1 { surface["focus"] = true }
            return ["pane": ["surfaces": [surface]]]
        }
        func chain(_ direction: String, _ items: [[String: Any]]) -> [String: Any] {
            guard items.count > 1 else { return items[0] }
            var node: [String: Any] = ["direction": direction, "children": [items[0], chain(direction, Array(items.dropFirst()))]]
            if items.count > 2 { node["split"] = 1.0 / Double(items.count) }
            return node
        }
        let tree = chain("horizontal", columns.map { rows in chain("vertical", (0..<rows).map { _ in pane() }) })
        guard let data = try? JSONSerialization.data(withJSONObject: tree) else { return nil }
        return try? JSONDecoder().decode(CmuxLayoutNode.self, from: data)
    }

    /// Where Clone and New project put folders.
    static var projectsRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = (home as NSString).appendingPathComponent("Desktop/Projects")
        return FileManager.default.fileExists(atPath: preferred) ? preferred : home
    }
}

private struct WelcomeFolder: Identifiable, Hashable, Sendable {
    let path: String
    let modified: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
}

private struct WelcomeView: View {
    let onDone: () -> Void

    @AppStorage("cmuxFork.welcome.agents") private var agents = 4
    @AppStorage("cmuxFork.welcome.command") private var command = "claude"
    @AppStorage(WelcomeWindowController.showAtLaunchKey) private var showAtLaunch = true
    @State private var query = ""
    @State private var recents: [WelcomeFolder] = []
    @State private var projects: [WelcomeFolder] = []
    @State private var showsAll = false
    @State private var busy: String?
    @State private var problem: String?

    private static let agentChoices = [0, 1, 2, 3, 4, 6, 8]
    private static let recentLimit = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actionCards
                agentStrip
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                projectList
                footer
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Workmaxxing").font(.system(size: 26, weight: .bold))
            }
            Text(String(localized: "welcome.subtitle", defaultValue: "Open a project and put your agents to work in parallel."))
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.leading, 34)
        }
    }

    private var actionCards: some View {
        HStack(spacing: 10) {
            WelcomeCard(symbol: "folder", title: String(localized: "welcome.open", defaultValue: "Open project"), action: openOther)
            WelcomeCard(symbol: "arrow.down.circle", title: String(localized: "welcome.clone", defaultValue: "Clone repo"), action: cloneRepo)
            WelcomeCard(symbol: "plus.square", title: String(localized: "welcome.new", defaultValue: "New project"), action: newProject)
        }
        .disabled(busy != nil)
        .overlay(alignment: .bottomLeading) {
            if let busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                .offset(y: 22)
            }
        }
    }

    private var agentStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "welcome.agents", defaultValue: "Agents per project"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker("", selection: $agents) {
                    ForEach(Self.agentChoices, id: \.self) { count in
                        Text(count == 0 ? String(localized: "welcome.terminal", defaultValue: "Terminal") : "\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                TextField(String(localized: "welcome.command", defaultValue: "claude"), text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 130)
                    .disabled(agents == 0)
                    .help(String(localized: "welcome.commandHelp", defaultValue: "Command each box runs, e.g. claude or codex"))
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(showsAll
                     ? String(localized: "welcome.allProjects", defaultValue: "All projects")
                     : String(localized: "welcome.recent", defaultValue: "Recent projects"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if allFolders.count > Self.recentLimit || showsAll {
                    Button(showsAll
                           ? String(localized: "welcome.showRecent", defaultValue: "Show recent")
                           : String(format: String(localized: "welcome.viewAll", defaultValue: "View all (%d)"), allFolders.count)) {
                        showsAll.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
            if showsAll {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(String(localized: "welcome.search", defaultValue: "Search projects"), text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            let rows = showsAll ? filtered(allFolders) : Array(allFolders.prefix(Self.recentLimit))
            if rows.isEmpty {
                Text(String(localized: "welcome.empty", defaultValue: "No projects yet. Open or clone one above."))
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { folder in
                        WelcomeRecentRow(folder: folder) { launch(folder.path) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle(String(localized: "welcome.showAtLaunch", defaultValue: "Show at launch"), isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(localized: "welcome.reopenHint", defaultValue: "Reopen from Apps ▸ Open Project…"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    // MARK: Data

    /// Recent first, then other projects by last change, without duplicates.
    private var allFolders: [WelcomeFolder] {
        let recentPaths = Set(recents.map(\.path))
        return recents + projects.filter { !recentPaths.contains($0.path) }
    }

    private func filtered(_ folders: [WelcomeFolder]) -> [WelcomeFolder] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(trimmed) || $0.parent.localizedCaseInsensitiveContains(trimmed) }
    }

    private func load() async {
        let recentPaths = LeftSidebarRecents.load()
        let found = await Task.detached(priority: .userInitiated) { () -> ([WelcomeFolder], [WelcomeFolder]) in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let roots = ["Desktop/Projects", "Desktop/Full Scale Projects", "Developer", "Projects", "Code", "src"]
                .map { (home as NSString).appendingPathComponent($0) }
            func folder(_ path: String) -> WelcomeFolder? {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                return WelcomeFolder(path: path, modified: modified)
            }
            let recents = recentPaths.compactMap(folder)
            let projects = roots.flatMap { root -> [WelcomeFolder] in
                let children = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                return children.filter { !$0.hasPrefix(".") }.compactMap { folder((root as NSString).appendingPathComponent($0)) }
            }
            .sorted { $0.modified > $1.modified }
            return (recents, projects)
        }.value
        recents = found.0
        projects = found.1
    }

    // MARK: Actions

    private func launch(_ path: String) {
        WelcomeWindowController.launch(folder: path, agents: agents, command: command)
        onDone()
    }

    private func openOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: WelcomeWindowController.projectsRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launch(url.path)
    }

    private func cloneRepo() {
        guard let url = Self.ask(
            title: String(localized: "welcome.clone.title", defaultValue: "Clone a repository"),
            message: String(
                format: String(localized: "welcome.clone.message", defaultValue: "Paste a git URL. It is cloned into %@."),
                (WelcomeWindowController.projectsRoot as NSString).abbreviatingWithTildeInPath
            ),
            placeholder: "https://github.com/owner/repo.git"
        ) else { return }
        let name = URL(string: url)?.deletingPathExtension().lastPathComponent
            ?? (url as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
        guard !name.isEmpty, !name.hasPrefix("-"), name != ".", name != "..", !name.contains("/") else {
            problem = String(localized: "welcome.clone.badURL", defaultValue: "That doesn't look like a git URL.")
            return
        }
        let destination = (WelcomeWindowController.projectsRoot as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination) else {
            launch(destination)
            return
        }
        busy = String(format: String(localized: "welcome.clone.busy", defaultValue: "Cloning %@…"), name)
        problem = nil
        Task {
            let result = await Self.git(["clone", "--", url, destination], in: WelcomeWindowController.projectsRoot)
            busy = nil
            if result == nil {
                launch(destination)
            } else {
                problem = result
            }
        }
    }

    private func newProject() {
        guard let name = Self.ask(
            title: String(localized: "welcome.new.title", defaultValue: "New project"),
            message: String(
                format: String(localized: "welcome.new.message", defaultValue: "Creates a folder in %@ and runs git init."),
                (WelcomeWindowController.projectsRoot as NSString).abbreviatingWithTildeInPath
            ),
            placeholder: "my-project"
        ), !name.contains("/"), !name.hasPrefix(".") else { return }
        let destination = (WelcomeWindowController.projectsRoot as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
        } catch {
            problem = error.localizedDescription
            return
        }
        Task {
            _ = await Self.git(["init", "--quiet"], in: destination)
            launch(destination)
        }
    }

    /// A one-field prompt; nil when cancelled or empty.
    private static func ask(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "welcome.ok", defaultValue: "Continue"))
        alert.addButton(withTitle: String(localized: "welcome.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Runs git with arguments (never a shell). Returns nil on success, else the error text.
    private static func git(_ arguments: [String], in directory: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return error.localizedDescription
            }
            guard process.terminationStatus != 0 else { return nil }
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "git exited with status \(process.terminationStatus)" : text
        }.value
    }
}

/// An action card: icon over a short label, lifted surface, brighter on hover.
private struct WelcomeCard: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.05))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// A recent-project row: name, then its folder, highlighted on hover.
private struct WelcomeRecentRow: View {
    let folder: WelcomeFolder
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(folder.name).font(.system(size: 13)).lineLimit(1)
                Text(folder.parent)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text(folder.modified, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
