import AppKit
import DaisyCore
import SwiftUI

/// Add or edit a project: name, color, status, due date, notes, a folder on this Mac, and links.
struct ProjectEditor: View {
    @ObservedObject var projects: ProjectsModel
    @State var project: Project
    let isNew: Bool
    /// How many tasks are in it, for "its tasks move with it".
    let taskCount: Int
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var originalName = ""

    var body: some View {
        let renamed = !isNew && Project.squashed(project.name) != originalName && !originalName.isEmpty
        VStack(alignment: .leading, spacing: 13) {
            Text(isNew ? "New project" : "Edit project").font(.system(size: 17, weight: .semibold)).foregroundStyle(HUD.ice)
            TextField("Name, e.g. College Applications", text: $project.name).hudField()
            if renamed, taskCount > 0 {
                Text("Its \(taskCount) task\(taskCount == 1 ? "" : "s") move\(taskCount == 1 ? "s" : "") to the new name.")
                    .font(.system(size: 11)).foregroundStyle(HUD.dim)
            }
            HStack(alignment: .top, spacing: 14) {
                field("STATUS") {
                    Picker("Status", selection: $project.status) {
                        ForEach(Project.Status.allCases) { status in Text(status.title).tag(status) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 150)
                }
                field("DUE") { TextField("YYYY-MM-DD (optional)", text: $project.due).hudField().frame(width: 190) }
            }
            Text(project.status.hint).font(.system(size: 11)).foregroundStyle(HUD.dim)
            field("COLOR") { ColorSwatches(selection: $project.color) }
            field("FOLDER") { folderRow }
            Text("NOTES").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
            TextEditor(text: $project.notes).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                .frame(height: 80).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
            LinksEditor(links: $project.links)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(HUDButtonStyle(kind: .ghost))
                Spacer()
                Button(isNew ? "Add project" : "Save project") { save() }
                    .buttonStyle(HUDButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let notice = projects.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .padding(24).frame(width: 540)
        .background(HUD.deep)
        .onAppear { originalName = project.name; projects.notice = nil }
    }

    @ViewBuilder private var folderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(project.folder.isEmpty ? HUD.dim : HUD.accent)
            Text(project.folder.isEmpty ? "None. Daisy can look here for the project's files." : (project.folder as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12)).foregroundStyle(project.folder.isEmpty ? HUD.dim : HUD.ice)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Choose…", action: chooseFolder).buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            if !project.folder.isEmpty {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.folder, isDirectory: true)) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(HUD.steel).help("Open in Finder")
                Button { project.folder = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(HUD.crimson).help("Clear the folder")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "The folder where this project's files live."
        if !project.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: project.folder, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url { project.folder = url.path }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
            content()
        }
    }

    private func save() {
        var draft = project
        draft.name = Project.squashed(draft.name)
        draft.due = draft.due.trimmingCharacters(in: .whitespaces)
        draft.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await projects.save(draft) { saved(); dismiss() }
        }
    }
}

/// Just the name, from a project header's menu.
struct ProjectRenameSheet: View {
    @ObservedObject var projects: ProjectsModel
    let project: Project
    let taskCount: Int
    let saved: () -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Rename “\(project.name)”").font(.system(size: 17, weight: .semibold)).foregroundStyle(HUD.ice)
            TextField("Name", text: $name).hudField().onSubmit(save)
            if taskCount > 0 {
                Text("Its \(taskCount) task\(taskCount == 1 ? "" : "s") move\(taskCount == 1 ? "s" : "") with it.")
                    .font(.system(size: 11)).foregroundStyle(HUD.dim)
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(HUDButtonStyle(kind: .ghost))
                Spacer()
                Button("Rename", action: save).buttonStyle(HUDButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(Project.squashed(name).isEmpty || Project.squashed(name) == project.name)
            }
            if let notice = projects.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .padding(24).frame(width: 420)
        .background(HUD.deep)
        .onAppear { name = project.name; projects.notice = nil }
    }

    private func save() {
        var renamed = project
        renamed.name = Project.squashed(name)
        guard !renamed.name.isEmpty, renamed.name != project.name else { return }
        Task { if await projects.save(renamed) { saved(); dismiss() } }
    }
}

/// The project colors as squares; the chosen one is ringed.
struct ColorSwatches: View {
    @Binding var selection: ProjectColor
    var body: some View {
        HStack(spacing: 7) {
            ForEach(ProjectColor.allCases) { option in
                let color = option.color
                Button { selection = option } label: {
                    Rectangle().fill(color).frame(width: 18, height: 18)
                        .overlay(Rectangle().strokeBorder(HUD.void.opacity(0.6), lineWidth: 1))
                        .padding(3)
                        .overlay(Rectangle().strokeBorder(option == selection ? HUD.ice : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
    }
}
