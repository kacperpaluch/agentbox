import SwiftUI
import SkillboxCore
import Sparkle

struct ContentView: View {
    @State private var model: AppModel
    let updater: SPUUpdater
    @State private var section: SectionKind? = .library
    @State private var showGit = false
    @State private var showProject = false
    @State private var showHistory = false
    init(updater: SPUUpdater) { self.updater = updater; _model = State(initialValue: AppModel()) }
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
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
        .sheet(isPresented: $showGit) { AddGitView { url, path in await model.addGit(url, subpath: path) } }
        .sheet(isPresented: $showProject) {
            ProjectEditor(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, project: nil, initialSelection: model.projectDefaults) { project, selection in
                await model.addProject(project, selection: selection)
            }
        }
        .sheet(item: $model.updateReview) { plan in SkillUpdatesView(model: model, plan: plan, synchronizing: model.reviewIncludesSync).id(plan.id) }
        .sheet(isPresented: $showHistory) { OperationHistoryView(entries: model.operationLog) }
        .environment(\.enabledTools, model.enabledTools)
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
