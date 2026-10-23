import SwiftUI
import SkillboxCore

/// Codex CLI, the Codex IDE extension and the ChatGPT desktop app share one file
/// (`~/.codex/config.toml`); Claude Code has an equivalent "user" scope in `~/.claude.json`. A
/// server declared there loads in every project automatically — Agentbox only reads those files and
/// lets each folder or standalone project opt one server out, without ever touching the global file
/// itself.
///
/// This view lists them from the server's side, one row per (tool, server name) with a toggle per
/// place that can see it — the natural way to answer "where is this server active", instead of
/// hunting through Projekty one folder at a time for the same information.
///
/// Named "Serwery klientów" rather than anything with "globalne" in it: the old name collided with
/// the global *skill* selection, which pushes files out, where this one only opts out of files
/// somebody else already wrote. Syncing lives in Projekty — this view only records the choice.
struct ClientServersView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Serwery klientów").font(.title2.bold())
                    Text("Serwery MCP spoza Agentbox, ładowane automatycznie przez Codex i Claude Code").rowMetadata()
                }
                Spacer()
                Button("Zamknij") { dismiss() }
            }
            .padding(.horizontal, Space.page).padding(.vertical, Space.section - 2)
            Divider()
            List {
                explanation
                if model.enabledTools.contains(.codex) { toolSection(.codex, title: "Codex", source: "~/.codex/config.toml — dzielony z aplikacją ChatGPT Desktop i wtyczką IDE") }
                if model.enabledTools.contains(.claude) { toolSection(.claude, title: "Claude Code", source: "zasięg „user” w ~/.claude.json") }
            }
        }
        .sheetFrame(width: 760, height: 640)
        // Okno arkusza zasłania overlay z App.swift, więc postęp musi być rysowany też tutaj.
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
    }

    private var explanation: some View {
        Text("Serwery poniżej nie są zarządzane przez Agentbox — Codex albo Claude Code same je ładują w każdym projekcie. Odznaczenie folderu albo projektu przy serwerze dopisuje dla niego lokalny override (bez zmiany globalnego pliku); przełącznik zapisuje tylko wybór — zmiana trafia na dysk po „Synchronizuj wszystkie” w Projektach.")
            .font(.caption).foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func toolSection(_ tool: Tool, title: String, source: String) -> some View {
        let names = model.globalMCPServerNames(tool: tool)
        let groups = model.globalMCPGroups(tool: tool)
        Section {
            if names.isEmpty {
                Text("Nie znaleziono żadnych globalnych serwerów.").font(.caption).foregroundStyle(.secondary)
            } else if groups.isEmpty {
                Text("Znaleziono \(names.count), ale żaden projekt nie ma zaznaczonego \(title) — nie ma tu więc czego wyłączać.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in GlobalServerRow(model: model, tool: tool, name: name, groups: groups) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(source).font(.caption).foregroundStyle(.secondary).textCase(nil)
            }
        }
    }
}
