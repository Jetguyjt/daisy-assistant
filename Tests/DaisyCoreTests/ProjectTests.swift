import Foundation
import DaisyCore

final class ProjectTests {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("tasks.json") }
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func setUp() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private struct Expected: Decodable {
        struct Entry: Decodable { let id, name, color, status: String; let revision: Int }
        struct Named: Decodable { let name, id, color: String }
        let projects: [Entry]
        let named: [Named]
    }

    func testOldFilesBecomeProjectsWithoutAWrite() async throws {
        let legacy = try taskFixture("legacy-tasks.json")
        try legacy.write(to: url)
        let expected = try JSONDecoder().decode(Expected.self, from: try taskFixture("legacy-projects-expected.json"))
        let store = try TaskStore(url: url)
        let projects = await store.projects()
        expectEqual(projects.map(\.name), expected.projects.map(\.name))
        expectEqual(projects.map(\.id.uuidString), expected.projects.map(\.id))
        expectEqual(projects.map(\.color.rawValue), expected.projects.map(\.color))
        expectTrue(projects.allSatisfy { $0.status == .active && $0.revision == 0 })
        _ = await store.all()
        try expectEqual(try Data(contentsOf: url), legacy)
        for named in expected.named {
            expectEqual(Project.named(named.name).id.uuidString, named.id)
            expectEqual(Project.named(named.name).color.rawValue, named.color)
        }
        expectEqual(Project.named("  college   applications ").name, "college applications")

        // The first change writes the new form, with the projects the names made.
        try await store.save(WorkItem(title: "Chem worksheet", project: "school"), expectedRevision: 0)
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        expectEqual(json?["version"] as? Int, 2)
        let stored = json?["projects"] as? [[String: Any]] ?? []
        expectEqual(stored.map { $0["name"] as? String }, ["School", "College essays"])
        expectEqual(stored.map { $0["id"] as? String }, expected.projects.map(\.id))
        let tasks = try TaskFile.read(url)
        expectEqual(tasks.count, 4)
        expectEqual(tasks.last?.project, "School")
        expectEqual(tasks.first { $0.title == "Practice essay draft" }?.notes, "First paragraph is rough.")
    }

    func testTheAppsFileReadsAndWritesTheSame() throws {
        let fixture = try taskFixture("app-written-v2.json")
        try fixture.write(to: url)
        let document = try TaskFile.readDocument(url)
        expectEqual(document.projects.map(\.name), ["College Applications", "Robotics"])
        expectEqual(document.projects.map(\.status), [.active, .archived])
        expectEqual(document.projects[0].folder, "/Users/jordan/Documents/College")
        expectEqual(document.projects[0].links.first?.kind, .googleDoc)
        let essay = try unwrap(document.tasks.first { $0.title == "Why Harvard" })
        expectEqual(essay.links.map(\.kind), [.calendarEvent, .gmail, .file])
        expectEqual(essay.links[2].bookmark, Data("bookmark".utf8))
        expectEqual(document.tasks.first { $0.title == "Robot arm writeup" }?.links.map(\.kind), [.note, .reminder])
        let encoded = try TaskFile.encode(document)
        expectEqual(String(decoding: encoded, as: UTF8.self), String(decoding: fixture, as: UTF8.self))
    }

    func testRenamingMovesItsTasksInTheSameWrite() async throws {
        let store = try TaskStore(url: url)
        let harvard = try await store.save(WorkItem(title: "Harvard", project: "College Applications"), expectedRevision: 0)
        let essay = try await store.save(WorkItem(title: "Why Harvard", project: "college applications", parent: harvard.id), expectedRevision: 0)
        let lab = try await store.save(WorkItem(title: "Physics lab", project: "School"), expectedRevision: 0)
        expectEqual(essay.project, "College Applications")
        var college = try unwrap(await store.projects().first { $0.name == "College Applications" })
        expectEqual(college.revision, 0)
        college.name = "Colleges"; college.color = .teal; college.folder = "/Users/jordan/Documents/College"
        let saved = try await store.saveProject(college, expectedRevision: college.revision)
        expectEqual(saved.revision, 1)
        let tasks = try TaskFile.read(url)
        expectEqual(tasks.filter { $0.project == "Colleges" }.map(\.title), ["Harvard", "Why Harvard"])
        expectEqual(tasks.first { $0.id == harvard.id }?.revision, harvard.revision + 1)
        expectEqual(tasks.first { $0.id == lab.id }?.revision, lab.revision)
        let got1 = await store.projects()
        expectEqual(got1.map(\.name), ["Colleges", "School"])
        let got2 = await store.project(college.id)
        expectEqual(got2?.color, .teal)
        // Another project's name, in any case, is refused; a stale copy is refused.
        var clash = saved; clash.name = "school"
        do { _ = try await store.saveProject(clash, expectedRevision: saved.revision); fail("Renamed onto another project") } catch { }
        do { _ = try await store.saveProject(college, expectedRevision: college.revision); fail("Saved a stale project") } catch { }
        do { _ = try await store.saveProject(Project(name: "SCHOOL"), expectedRevision: 0); fail("Added a second School") } catch { }
        do { _ = try await store.saveProject(Project(name: "No project"), expectedRevision: 0); fail("Took the name for no project") } catch { }
        // A case-only rename still reaches every task.
        var lower = saved; lower.name = "colleges"
        _ = try await store.saveProject(lower, expectedRevision: saved.revision)
        let moved = try TaskFile.read(url).filter { $0.parent != nil || $0.title == "Harvard" }
        expectEqual(Set(moved.map(\.project)), ["colleges"])
    }

    func testDeletingAProjectKeepsOrDeletesItsTasks() async throws {
        let store = try TaskStore(url: url)
        let school = try await store.save(WorkItem(title: "Physics lab", project: "School"), expectedRevision: 0)
        _ = try await store.save(WorkItem(title: "Data table", project: "School", parent: school.id), expectedRevision: 0)
        let harvard = try await store.save(WorkItem(title: "Harvard", project: "College Applications"), expectedRevision: 0)
        _ = try await store.save(WorkItem(title: "Why Harvard", project: "College Applications", parent: harvard.id), expectedRevision: 0)
        _ = try await store.save(WorkItem(title: "Loose idea"), expectedRevision: 0)
        let stale = try unwrap(await store.projects().first { $0.name == "School" })
        var keep = stale; keep.notes = "Chem and physics"
        keep = try await store.saveProject(keep, expectedRevision: keep.revision)
        do { try await store.deleteProject(stale, tasks: .keepTasks); fail("Deleted from a stale copy") } catch { }

        try await store.deleteProject(keep, tasks: .keepTasks)
        var tasks = try TaskFile.read(url)
        expectEqual(tasks.count, 5)
        expectEqual(tasks.filter { $0.project.isEmpty }.map(\.title).sorted(), ["Data table", "Loose idea", "Physics lab"])
        expectEqual(tasks.first { $0.title == "Physics lab" }?.revision, school.revision + 1)
        let got3 = await store.projects()
        expectEqual(got3.map(\.name), ["College Applications"])

        let college = try unwrap(await store.projects().first)
        try await store.deleteProject(college, tasks: .deleteTasks)
        tasks = try TaskFile.read(url)
        expectEqual(tasks.map(\.title).sorted(), ["Data table", "Loose idea", "Physics lab"])
        let got4 = await store.projects()
        expectEqual(got4.count, 0)
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        expectEqual((json?["projects"] as? [Any])?.count, 0)
    }

    func testProjectsWithNoTasksAndArchivedOnes() async throws {
        let store = try TaskStore(url: url)
        let robotics = try await store.saveProject(Project(name: "  Robotics  ", color: .orange, due: "2026-12-01"), expectedRevision: 0)
        expectEqual(robotics.name, "Robotics")
        do { _ = try await store.saveProject(Project(name: "Bad date", due: "2026-02-30"), expectedRevision: 0); fail("Saved a bad date") } catch { }
        do { _ = try await store.saveProject(Project(name: "Bad folder", folder: "Documents"), expectedRevision: 0); fail("Saved a relative folder") } catch { }
        _ = try await store.save(WorkItem(title: "Arm writeup", project: "Old club"), expectedRevision: 0)
        var old = try unwrap(await store.projects().first { $0.name == "Old club" })
        old.status = .archived
        _ = try await store.saveProject(old, expectedRevision: old.revision)
        let items = await store.all(), projects = await store.projects()
        expectEqual(TaskTree.groups(items, projects: projects, filter: .open, archived: false).map(\.project), ["Robotics"])
        expectEqual(TaskTree.groups(items, projects: projects, filter: .open).map(\.project), ["Robotics", "Old club"])
        expectEqual(TaskTree.groups(items, projects: projects, filter: .status(.todo), archived: false).map(\.project), [])
        expectEqual(TaskTree.groups(items, projects: projects, filter: .open, query: "robot", archived: false).map(\.project), [])
        let group = try unwrap(TaskTree.groups(items, projects: projects, archived: true).first { $0.project == "Old club" })
        expectEqual(group.details?.status, .archived); expectEqual(group.total, 1); expectEqual(group.open, 1)
        expectEqual(TaskTree.archived(items, projects: projects), Set(items.map(\.id)))
        // A done project with nothing open drops out of the open view, but shows in everything.
        var done = robotics; done.status = .done
        _ = try await store.saveProject(done, expectedRevision: robotics.revision)
        let after = await store.projects()
        expectEqual(TaskTree.groups(items, projects: after, filter: .open, archived: false).map(\.project), [])
        expectEqual(TaskTree.groups(items, projects: after, filter: .all, archived: false).map(\.project), ["Robotics"])
    }

    func testANameNoTaskUsesIsDroppedUnlessSaved() async throws {
        try Data(#"[{"id": "B7E1C0A2-0000-4000-8000-000000000001", "title": "Arm writeup", "project": "Old club", "revision": 1, "order": 1}]"#.utf8).write(to: url)
        let store = try TaskStore(url: url)
        var task = try unwrap(await store.all().first)
        task.project = "Robotics"
        _ = try await store.save(task, expectedRevision: task.revision)
        let got5 = await store.projects()
        expectEqual(got5.map(\.name), ["Robotics"])
        let saved = try await store.saveProject(Project(name: "Summer"), expectedRevision: 0)
        _ = try await store.save(WorkItem(title: "Nothing to do with it"), expectedRevision: 0)
        let got6 = await store.projects()
        expectEqual(got6.map(\.name), ["Robotics", "Summer"])
        let got7 = await store.project(saved.id)
        expectEqual(got7?.revision, 1)
    }

    /// The app and the plugin on one file: the app writes projects and links, Hermes's tools rename,
    /// link and add, and the app reads it all back with nothing lost.
    func testRoundTripWithThePlugin() async throws {
        let bookmarked = root.appendingPathComponent("Why Harvard.txt")
        try Data("draft".utf8).write(to: bookmarked)
        let store = try TaskStore(url: url)
        var college = Project(name: "College Applications", color: .blue, notes: "Early action first.", folder: root.path)
        college.links = [try unwrap(TaskLink.detect("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit"))]
        college = try await store.saveProject(college, expectedRevision: 0)
        let harvard = try await store.save(WorkItem(title: "Harvard", project: "College Applications"), expectedRevision: 0)
        let file = TaskLink.file(path: bookmarked.path).refreshed()
        let essay = try await store.save(WorkItem(title: "Why Harvard", project: "College Applications", parent: harvard.id,
                                                  links: [file]), expectedRevision: 0)
        _ = try await store.save(WorkItem(title: "Physics lab", project: "School"), expectedRevision: 0)

        let output = try plugin("""
        out = {}
        out["projects"] = call("projects_list", {"status": "all"})
        out["rename"] = call("projects_update", {"changes": [{"project": "college applications", "name": "Colleges", "status": "paused",
            "add_links": ["https://drive.google.com/drive/folders/1FolderIdOnDriveTest7"]}]})
        out["link"] = call("tasks_update", {"changes": [{"task": "Why Harvard", "add_links": [{"kind": "calendar_event",
            "event_id": "abc123def456", "calendar_id": "primary", "start": "2026-10-02T15:00:00-04:00", "title": "Interview"}]}]})
        out["add"] = call("tasks_add", {"tasks": [{"title": "Milk", "project": "Groceries"}]})
        out["listed"] = call("tasks_list", {"status": "all"})
        print(json.dumps(out))
        """)
        let result = try unwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let listedProjects = (result["projects"] as? [String: Any])?["projects"] as? [[String: Any]] ?? []
        expectEqual(listedProjects.map { $0["name"] as? String }, ["College Applications", "School"])
        expectEqual(listedProjects.first?["folder"] as? String, root.path)
        expectEqual(((listedProjects.first?["links"] as? [[String: Any]])?.first)?["file_id"] as? String, "1AbCdEfGhIjKlMnOpQrStUv")
        expectEqual((result["rename"] as? [String: Any])?["tasks_moved"] as? Int, 2)
        expectEqual((result["add"] as? [String: Any])?["new_projects"] as? [String], ["Groceries"])
        let listedTasks = (result["listed"] as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
        let essayLinks = listedTasks.first { $0["title"] as? String == "Why Harvard" }?["links"] as? [[String: Any]] ?? []
        expectEqual(essayLinks.map { $0["kind"] as? String }, ["file", "calendar_event"])
        expectEqual(essayLinks.first?["exists"] as? Bool, true)
        expectEqual(essayLinks.first?["path"] as? String, bookmarked.path)
        expectTrue(essayLinks.allSatisfy { $0["bookmark"] == nil })

        let projects = await store.projects()
        expectEqual(projects.map(\.name), ["Colleges", "School", "Groceries"])
        let renamed = try unwrap(projects.first)
        expectEqual(renamed.id, college.id); expectEqual(renamed.status, .paused); expectEqual(renamed.revision, college.revision + 1)
        expectEqual(renamed.notes, "Early action first."); expectEqual(renamed.folder, root.path)
        expectEqual(renamed.links.map(\.kind), [.googleDoc, .googleDrive])
        expectEqual(renamed.links.first?.id, college.links.first?.id)
        expectEqual(projects[2].id, Project.named("Groceries").id); expectEqual(projects[2].color, Project.named("Groceries").color)
        let tasks = await store.all()
        expectEqual(tasks.filter { $0.project == "Colleges" }.map(\.title).sorted(), ["Harvard", "Why Harvard"])
        let linked = try unwrap(tasks.first { $0.id == essay.id })
        expectEqual(linked.links.count, 2)
        expectEqual(linked.links[0], file)
        expectEqual(linked.links[0].bookmark, file.bookmark)
        expectEqual(linked.links[1].kind, .calendarEvent)
        expectEqual(linked.links[1].url, "https://calendar.google.com/calendar/r/day/2026/10/2")
        expectEqual(linked.revision, essay.revision + 2)

        // And back: the app renames it again and the plugin reads the app's write.
        var again = renamed; again.name = "College Applications"
        _ = try await store.saveProject(again, expectedRevision: renamed.revision)
        let reread = try plugin(#"print(json.dumps([t["project"] for t in call("tasks_list", {"status": "all"})["tasks"]]))"#)
        let names = try JSONDecoder().decode([String].self, from: Data(reread.utf8))
        expectEqual(names, ["College Applications", "College Applications", "School", "Groceries"])
    }

    func testTwoWritersKeepEachOthersProjects() async throws {
        let store = try TaskStore(url: url)
        let holder = try hold(seconds: 0.6, writing: #"{"version": 2, "projects": [{"id": "8C1F6E2A-1D3B-4C5D-9E7F-0A1B2C3D4E5F", "name": "From Hermes", "color": "green", "status": "paused", "revision": 1}], "tasks": [{"id": "9D2F6E2A-1D3B-4C5D-9E7F-0A1B2C3D4E5F", "title": "Hermes task", "project": "Other", "revision": 1, "order": 1}]}"#)
        let started = Date()
        _ = try await store.saveProject(Project(name: "From the app"), expectedRevision: 0)
        let waited = Date().timeIntervalSince(started)
        holder.waitUntilExit()
        expectTrue(waited >= 0.3)
        let projects = try TaskFile.readDocument(url).projects
        expectEqual(projects.map(\.name), ["From Hermes", "Other", "From the app"])
        expectEqual(projects.first?.status, .paused); expectEqual(projects.first?.color, .green)
        let other = try TaskStore(url: url)
        let renamed = try await other.saveProject(Project(id: Project.named("Other").id, name: "Others"), expectedRevision: 0)
        expectEqual(renamed.revision, 1)
        let got8 = await store.all()
        expectEqual(got8.first?.project, "Others")
    }

    /// Runs Python against this test's tasks.json with Hermes's tasks tools loaded, the way Hermes calls
    /// them (the check first, then the tool). `call` and `json` are ready for `body`.
    private func plugin(_ body: String) throws -> String {
        let script = """
        import importlib.util, json, os, sys
        folder = os.path.join(sys.argv[1], "hermes", "daisy")
        spec = importlib.util.spec_from_file_location("daisy_plugin", os.path.join(folder, "__init__.py"), submodule_search_locations=[folder])
        plugin = importlib.util.module_from_spec(spec)
        sys.modules["daisy_plugin"] = plugin
        spec.loader.exec_module(plugin)
        def call(name, args):
            tool = plugin.registry.get(name)
            if tool.risk != "read":
                tool.card(args)
            return json.loads(plugin.registry.handler_for(tool)(args))
        """ + "\n" + body
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, repo.path]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("HERMES_") { environment.removeValue(forKey: key) }
        environment["DAISY_TASKS_FILE"] = url.path
        environment["HERMES_HOME"] = root.appendingPathComponent("hermes-home").path
        environment["DAISY_SESSION"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problems = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DaisyError.message("The plugin script failed: \(String(decoding: problems, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A second process holding the lock (as the plugin does while it writes), writing `body` while it has it.
    private func hold(seconds: Double, writing body: String) throws -> Process {
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1] + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        open(sys.argv[1], "w").write(sys.argv[3])
        print("locked", flush=True)
        time.sleep(float(sys.argv[2]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, url.path, String(seconds), body]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard line.hasPrefix("locked") else { throw DaisyError.message("The lock holder didn't start: \(line)") }
        return process
    }
}
