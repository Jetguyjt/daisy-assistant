import DaisyCore
import Foundation

/// The Tasks tab's projects. It keeps its own TaskStore on tasks.json; the app model keeps one for the
/// tasks. Both take the file's lock and read it again before writing, so neither writes over the other,
/// and Hermes's tools go through the same lock.
@MainActor final class ProjectsModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var notice: String?
    private let url: URL
    private var store: TaskStore?

    init(url: URL = TaskStore.defaultURL) { self.url = url }

    private func opened() throws -> TaskStore {
        if let store { return store }
        let made = try TaskStore(url: url)
        store = made
        return made
    }

    func reload() async {
        do { projects = try await opened().projects() } catch { notice = error.localizedDescription }
    }

    /// The project a task's project name means, if any.
    func project(named name: String) -> Project? {
        let key = Project.key(name)
        return key.isEmpty ? nil : projects.first { $0.key == key }
    }

    /// Adds or changes a project; a new name moves its tasks with it. False (with a notice) when it
    /// couldn't be saved, and the list is reloaded.
    func save(_ project: Project) async -> Bool {
        var project = project
        project.links = project.links.map(Self.tidy)
        do {
            try await opened().saveProject(project, expectedRevision: project.revision)
            notice = nil
            await reload()
            return true
        } catch {
            notice = error.localizedDescription
            await reload()
            return false
        }
    }

    func delete(_ project: Project, tasks: ProjectDeletion) async -> Bool {
        do {
            try await opened().deleteProject(project, tasks: tasks)
            notice = nil
            await reload()
            return true
        } catch {
            notice = error.localizedDescription
            await reload()
            return false
        }
    }

    /// A link as it's saved from an editor: a file's path follows the file and gets a bookmark, and a
    /// cleared title goes back to the default.
    static func tidy(_ link: TaskLink) -> TaskLink {
        var link = link.refreshed()
        link.title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.title.isEmpty { link.title = link.defaultTitle }
        return link
    }
}
