import SwiftUI
import AppKit
import Combine
import SkillboxCore
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); DispatchQueue.main.async { NSApp.windows.first?.makeKeyAndOrderFront(nil) } }
}
@MainActor final class UpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "cacheBust" }
        items.append(URLQueryItem(name: "cacheBust", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url?.absoluteString
    }
}
enum AppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var display: String {
        let version = short
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Wersja \(version) (\(build))"
    }
}
@main struct AgentboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateFeedDelegate: UpdateFeedDelegate
    private let updaterController: SPUStandardUpdaterController
    init() { let delegate = UpdateFeedDelegate(); updateFeedDelegate = delegate; updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil) }
    var body: some Scene {
        WindowGroup { ContentView(updater: updaterController.updater) }.defaultSize(width: 1100, height: 720)
            .commands { CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: updaterController.updater) } }
    }
}
// The navigation follows the job to be done: build a library, apply it to projects, then adjust the
// application. Recovery and history are supporting tools, not destinations users need to scan first.
enum SectionKind: String, CaseIterable, Identifiable {
    case library = "Biblioteka", projects = "Projekty", settings = "Ustawienia"
    var id: String { rawValue }
    var icon: String { switch self { case .library: "books.vertical"; case .projects: "folder"; case .settings: "gearshape" } }
}
struct OperationLogEntry: Identifiable {
    enum Kind { case success, error }
    let id = UUID(); let date = Date(); let kind: Kind; let text: String
}
struct ContentView: View {
    @StateObject private var model: AppModel
    let updater: SPUUpdater
    @State private var section: SectionKind? = .library
    @State private var showGit = false
    @State private var showProject = false
    @State private var showHistory = false
    init(updater: SPUUpdater) { self.updater = updater; _model = StateObject(wrappedValue: AppModel()) }
    var body: some View {
        NavigationSplitView { VStack(spacing: 0) { List(SectionKind.allCases, selection: $section) { item in
            // The detected-folders banner lives in the Projects tab, so without this the question
            // would wait unseen for whoever happens to open that tab.
            HStack {
                Label(item.rawValue, systemImage: item.icon)
                Spacer()
                if item == .projects, !model.detectedFolders.isEmpty {
                    Text(model.detectedFolders.count, format: .number)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .tag(item)
        }.navigationTitle("Agentbox"); Divider(); Text(AppVersion.display).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.navigationSplitViewColumnWidth(min: 180, ideal: 210) } detail: {
            Group {
                if let serviceError = model.serviceError, section != .settings {
                    ContentUnavailableView {
                        Label("Biblioteka niedostępna", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("\(serviceError)\nDane nie zostały zmienione. Podłącz dysk z biblioteką albo wskaż jej folder w Ustawieniach.")
                    } actions: {
                        Button("Otwórz Ustawienia") { section = .settings }.buttonStyle(.borderedProminent)
                    }
                } else {
                    switch section ?? .library {
                    case .library: LibraryView(model: model, showGit: $showGit)
                    case .projects: ProjectsView(model: model, showProject: $showProject)
                    case .settings: SettingsView(model: model, updater: updater)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { if !model.message.isEmpty { StatusToast(text: model.message) { model.message = "" } } }
        .task(id: model.message) { let current = model.message; guard !current.isEmpty else { return }; try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, model.message == current else { return }; withAnimation { model.message = "" } }
        .overlay { if model.isWorking { ProgressView().controlSize(.large).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .sheet(isPresented: $showGit) { AddGitView { url, path in Task { await model.addGit(url, subpath: path) } } }
        .sheet(isPresented: $showProject) {
            ProjectEditor(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, project: nil, initialSelection: model.projectDefaults) { project, selection in
                Task { await model.addProject(project, selection: selection) }
            }
        }
        .sheet(isPresented: $showHistory) { OperationHistoryView(entries: model.operationLog) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.scanRootsOnActivation() } }
        .toolbar {
            Menu {
                Button { Task { await model.refresh() } } label: {
                    Label("Odśwież bibliotekę i zsynchronizuj projekty", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isWorking)
                Divider()
                Button { showHistory = true } label: { Label("Historia operacji", systemImage: "clock.arrow.circlepath") }
            } label: {
                Label("Narzędzia", systemImage: "ellipsis.circle")
            }
        }
    }
}
struct OperationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [OperationLogEntry]
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .short; value.timeStyle = .medium; return value }()
    var body: some View { VStack(alignment: .leading, spacing: 14) { HStack { Text("Historia operacji").font(.title2.bold()); Spacer(); Button("Zamknij") { dismiss() } }; if entries.isEmpty { ContentUnavailableView("Brak operacji", systemImage: "clock", description: Text("Sukcesy i błędy z tej sesji pojawią się tutaj.")) } else { List(entries) { entry in HStack(alignment: .top) { Image(systemName: entry.kind == .error ? "xmark.octagon.fill" : entry.kind == .success ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(entry.kind == .error ? .red : entry.kind == .success ? .green : .blue); VStack(alignment: .leading) { Text(entry.text).textSelection(.enabled); Text(formatter.string(from: entry.date)).font(.caption).foregroundStyle(.secondary) } } } } }.padding(20).sheetFrame(width: 680, height: 520) }
}
struct StatusToast: View { let text: String; let onClose: () -> Void; var body: some View { HStack(spacing: 10) { Label(text, systemImage: "info.circle.fill"); Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Zamknij") }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial, in: Capsule()).shadow(radius: 8).padding(.bottom, 14) } }
