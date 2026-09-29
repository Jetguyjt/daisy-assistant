import Foundation
import DaisyCore

final class TaskTreeTests {
    private func list() -> [WorkItem] {
        let harvard = WorkItem(title: "Harvard", project: "College Applications", order: 1)
        let yale = WorkItem(title: "Yale", project: "College Applications", status: .inProgress, order: 5)
        return [
            harvard,
            WorkItem(title: "Why Harvard", project: "College Applications", parent: harvard.id, status: .needsReview, notes: "About a hobby", order: 2),
            WorkItem(title: "Intellectual experience", project: "College Applications", parent: harvard.id, status: .done, order: 3),
            WorkItem(title: "Activities", project: "College Applications", parent: harvard.id, order: 4),
            yale,
            WorkItem(title: "Yale community", project: "College Applications", parent: yale.id, status: .submitted, order: 6),
            WorkItem(title: "Return library books", status: .waiting, order: 7),
            WorkItem(title: "Physics lab", project: "School", status: .blocked, order: 8)
        ]
    }

    func testGroupsByProjectAndNestsSubtasks() {
        let groups = TaskTree.groups(list())
        expectEqual(groups.map(\.project), ["College Applications", "School", ""])
        let college = groups[0]
        expectEqual(college.nodes.map(\.item.title), ["Harvard", "Yale"])
        expectEqual(college.nodes[0].children.map(\.item.title), ["Why Harvard", "Activities", "Intellectual experience"])
        expectEqual(college.nodes[0].subtasks, 3); expectEqual(college.nodes[0].finished, 1)
        expectEqual(college.open, 4)
        expectEqual(groups[2].nodes.map(\.item.title), ["Return library books"])
        let outline = TaskTree.outline(list()).map { "\($0.depth) \($0.item.title)" }
        expectEqual(outline.prefix(4).map { $0 }, ["0 Harvard", "1 Why Harvard", "1 Activities", "1 Intellectual experience"])
    }

    func testFiltersKeepParentsForContext() {
        let review = TaskTree.groups(list(), filter: .status(.needsReview))
        expectEqual(review.count, 1)
        let harvard = review[0].nodes[0]
        expectEqual(harvard.item.title, "Harvard"); expectFalse(harvard.matches)
        expectEqual(harvard.children.map(\.item.title), ["Why Harvard"]); expectTrue(harvard.children[0].matches)
        expectEqual(harvard.subtasks, 3)
        let finished = TaskTree.groups(list(), filter: .finished).flatMap(\.nodes)
        expectEqual(finished.map(\.item.title), ["Harvard", "Yale"])
        expectEqual(finished.flatMap(\.children).map(\.item.title), ["Intellectual experience", "Yale community"])
        let open = TaskTree.groups(list(), filter: .open).flatMap(\.nodes).flatMap(\.children).map(\.item.title)
        expectEqual(open, ["Why Harvard", "Activities"])
        expectEqual(TaskTree.groups(list(), filter: .status(.idea)), [])
    }

    func testSearchShowsWhatsUnderAMatch() {
        let harvard = TaskTree.groups(list(), filter: .all, query: "harvard").flatMap(\.nodes)
        expectEqual(harvard.map(\.item.title), ["Harvard"])
        expectEqual(harvard[0].children.map(\.item.title), ["Why Harvard", "Activities", "Intellectual experience"])
        let notes = TaskTree.groups(list(), query: "hobby").flatMap(\.nodes)
        expectEqual(notes.map(\.item.title), ["Harvard"]); expectFalse(notes[0].matches)
        expectEqual(notes[0].children.map(\.item.title), ["Why Harvard"])
        let project = TaskTree.groups(list(), filter: .open, query: "school").flatMap(\.nodes).map(\.item.title)
        expectEqual(project, ["Physics lab"])
    }

    func testLoopsAndMissingParentsShowAtTheTop() throws {
        struct Entry: Encodable { let id: String; let title: String; let parent: String? }
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [Entry(id: a.uuidString, title: "Loop A", parent: b.uuidString), Entry(id: b.uuidString, title: "Loop B", parent: a.uuidString),
                       Entry(id: c.uuidString, title: "Lost", parent: UUID().uuidString)]
        let items = try JSONDecoder().decode([WorkItem].self, from: try JSONEncoder().encode(entries))
        expectEqual(TaskTree.parents(items), [:])
        let tops = TaskTree.groups(items).flatMap(\.nodes)
        expectEqual(Set(tops.map(\.item.title)), ["Loop A", "Loop B", "Lost"])
        expectTrue(tops.allSatisfy(\.children.isEmpty))
        expectEqual(TaskTree.descendants(of: a, in: items), [])
    }

    func testHeaderCounts() {
        var items: [WorkItem] = []
        for (status, count) in [(TaskStatus.todo, 25), (.inProgress, 21), (.needsReview, 9), (.idea, 3), (.done, 12), (.submitted, 2)] {
            items += (0..<count).map { WorkItem(title: "\(status.title) \($0)", status: status) }
        }
        let counts = TaskCounts(items)
        expectEqual(counts.open, 58); expectEqual(counts.finished, 14); expectEqual(counts[.inProgress], 21)
        expectEqual(counts.summary, "58 open · 21 in progress · 9 need review")
        let few = TaskCounts([WorkItem(title: "A", status: .needsReview), WorkItem(title: "B", status: .waiting), WorkItem(title: "C", status: .blocked)])
        expectEqual(few.summary, "3 open · 1 needs review · 1 waiting · 1 blocked")
        expectEqual(TaskCounts([]).summary, "No tasks")
        expectEqual(TaskCounts([WorkItem(title: "A", status: .done), WorkItem(title: "B", status: .dropped)]).summary, "Nothing open · 2 finished")
        expectEqual(TaskFilter.open.title, "All open"); expectEqual(TaskFilter.status(.waiting).title, "Waiting")
        expectTrue(TaskFilter.finished.keeps(WorkItem(title: "S", status: .submitted)))
        expectFalse(TaskFilter.open.keeps(WorkItem(title: "S", status: .dropped)))
    }
}
