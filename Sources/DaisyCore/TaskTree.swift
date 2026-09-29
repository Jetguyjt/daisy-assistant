import Foundation

/// Which tasks the Tasks tab shows.
public enum TaskFilter: Hashable, Sendable {
    case open, status(TaskStatus), finished, all
    public func keeps(_ item: WorkItem) -> Bool {
        switch self {
        case .open: item.status.isOpen
        case .status(let status): item.status == status
        case .finished: item.status.isFinished
        case .all: true
        }
    }
    public var title: String {
        switch self {
        case .open: "All open"
        case .status(let status): status.title
        case .finished: "Finished"
        case .all: "Everything"
        }
    }
}

/// A task with its subtasks, as the Tasks tab draws it.
public struct TaskNode: Identifiable, Sendable, Equatable {
    public let item: WorkItem
    public var children: [TaskNode]
    /// False when it's only shown because something under it matches.
    public let matches: Bool
    /// Everything under it, and how many of those are finished, whatever the filter hides.
    public let subtasks: Int
    public let finished: Int
    public var id: UUID { item.id }
}

/// The top-level tasks of one project ("" for none), with the project's open count.
public struct TaskGroup: Identifiable, Sendable, Equatable {
    public let project: String
    /// The project itself; nil for the tasks with none.
    public let details: Project?
    public var nodes: [TaskNode]
    public let open: Int
    /// Every task in it, whatever the filter hides.
    public let total: Int
    public var id: String { project.lowercased() }
}

public enum TaskTree {
    /// Each task's parent, leaving out parents that are missing or that loop back around: those tasks
    /// show at the top level. The plugin reads nesting the same way.
    public static func parents(_ items: [WorkItem]) -> [UUID: UUID] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: UUID] = [:]
        for item in items {
            guard let parent = item.parent, byID[parent] != nil else { continue }
            var seen: Set<UUID> = [item.id], node: UUID? = parent, loops = false
            while let current = node {
                if seen.contains(current) { loops = true; break }
                seen.insert(current)
                node = byID[current]?.parent.flatMap { byID[$0] == nil ? nil : $0 }
            }
            if !loops { result[item.id] = parent }
        }
        return result
    }

    public static func descendants(of id: UUID, in items: [WorkItem]) -> [WorkItem] {
        let children = childMap(items, parents(items))
        var found: [WorkItem] = [], stack = Array((children[id] ?? []).reversed())
        while let item = stack.popLast() {
            found.append(item)
            stack.append(contentsOf: (children[item.id] ?? []).reversed())
        }
        return found
    }

    /// Projects, each with its tasks nested. A task shows when the filter keeps it and it matches the
    /// search (or something above it does), and its parents show with it for context. With no search, all
    /// open or everything, projects show even when they have nothing to show (open shows the active and
    /// paused ones). Archived projects and their tasks only show with `archived`. `projects` defaults to
    /// the ones the tasks name.
    public static func groups(_ items: [WorkItem], projects: [Project]? = nil, filter: TaskFilter = .all, query: String = "",
                              archived: Bool = true) -> [TaskGroup] {
        var byKey: [String: Project] = [:]
        for project in projects ?? TaskDocument(tasks: items).projects where byKey[project.key] == nil { byKey[project.key] = project }
        let parentOf = parents(items)
        let children = childMap(items, parentOf)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func found(_ item: WorkItem) -> Bool {
            needle.isEmpty || [item.title, item.project, item.notes].joined(separator: " ").localizedStandardContains(needle)
        }
        func build(_ item: WorkItem, aboveMatched: Bool) -> (node: TaskNode?, total: Int, finished: Int) {
            let searched = aboveMatched || found(item)
            var kids: [TaskNode] = [], total = 0, finished = 0
            for child in children[item.id] ?? [] {
                let built = build(child, aboveMatched: searched && !needle.isEmpty)
                if let node = built.node { kids.append(node) }
                total += 1 + built.total
                finished += (child.status.isFinished ? 1 : 0) + built.finished
            }
            let matches = filter.keeps(item) && searched
            let node = matches || !kids.isEmpty ? TaskNode(item: item, children: kids, matches: matches, subtasks: total, finished: finished) : nil
            return (node, total, finished)
        }
        var roots: [String: [WorkItem]] = [:]
        for item in sorted(items) where parentOf[item.id] == nil {
            let key = Project.key(item.project)
            if !key.isEmpty, byKey[key] == nil { byKey[key] = .named(item.project) }
            roots[key, default: []].append(item)
        }
        let plain = needle.isEmpty && (filter == .open || filter == .all)
        let entries: [(key: String, project: Project?)] = byKey.map { ($0.key, $0.value) } + [("", nil)]
        let groups = entries.compactMap { key, project -> TaskGroup? in
            if project?.status == .archived, !archived { return nil }
            var open = 0, total = 0
            let nodes = (roots[key] ?? []).compactMap { root -> TaskNode? in
                let family = [root] + descendants(root.id, children)
                open += family.filter(\.status.isOpen).count
                total += family.count
                return build(root, aboveMatched: false).node
            }
            let showsEmpty = plain && project.map { filter == .all ? true : $0.status == .active || $0.status == .paused } == true
            guard !nodes.isEmpty || showsEmpty else { return nil }
            return TaskGroup(project: project?.name ?? "", details: project, nodes: nodes, open: open, total: total)
        }
        // Projects by name, then the tasks with none, then archived projects.
        func rank(_ group: TaskGroup) -> Int { group.details == nil ? 1 : group.details?.status == .archived ? 2 : 0 }
        return groups.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.project.localizedStandardCompare($1.project) == .orderedAscending
        }
    }

    /// The tasks in archived projects, which the Tasks tab leaves out until they're shown.
    public static func archived(_ items: [WorkItem], projects: [Project]) -> Set<UUID> {
        let keys = Set(projects.filter { $0.status == .archived }.map(\.key))
        return keys.isEmpty ? [] : Set(items.filter { keys.contains(Project.key($0.project)) }.map(\.id))
    }

    /// Every task, parents before their subtasks, with how deep each sits.
    public static func outline(_ items: [WorkItem]) -> [(depth: Int, item: WorkItem)] {
        var out: [(depth: Int, item: WorkItem)] = []
        func walk(_ node: TaskNode, _ depth: Int) {
            out.append((depth, node.item))
            node.children.forEach { walk($0, depth + 1) }
        }
        groups(items).forEach { $0.nodes.forEach { walk($0, 0) } }
        return out
    }

    /// Open before finished, then the order they were added in.
    static func sorted(_ items: [WorkItem]) -> [WorkItem] {
        items.sorted {
            if $0.status.isFinished != $1.status.isFinished { return $1.status.isFinished }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func childMap(_ items: [WorkItem], _ parentOf: [UUID: UUID]) -> [UUID: [WorkItem]] {
        var children: [UUID: [WorkItem]] = [:]
        for item in sorted(items) { if let parent = parentOf[item.id] { children[parent, default: []].append(item) } }
        return children
    }

    private static func descendants(_ id: UUID, _ children: [UUID: [WorkItem]]) -> [WorkItem] {
        (children[id] ?? []).flatMap { [$0] + descendants($0.id, children) }
    }
}

/// How many tasks sit in each status.
public struct TaskCounts: Equatable, Sendable {
    public let byStatus: [TaskStatus: Int]
    public init(_ items: [WorkItem]) { byStatus = Dictionary(grouping: items, by: \.status).mapValues(\.count) }
    public subscript(_ status: TaskStatus) -> Int { byStatus[status] ?? 0 }
    public var total: Int { byStatus.values.reduce(0, +) }
    public var open: Int { TaskStatus.allCases.filter(\.isOpen).reduce(0) { $0 + self[$1] } }
    public var finished: Int { total - open }
    /// For the header: "58 open · 21 in progress · 9 need review".
    public var summary: String {
        guard total > 0 else { return "No tasks" }
        guard open > 0 else { return "Nothing open · \(finished) finished" }
        let parts: [(TaskStatus, String, String)] = [(.inProgress, "in progress", "in progress"), (.needsReview, "needs review", "need review"),
                                                     (.waiting, "waiting", "waiting"), (.blocked, "blocked", "blocked")]
        return (["\(open) open"] + parts.compactMap { status, one, many in
            self[status] > 0 ? "\(self[status]) \(self[status] == 1 ? one : many)" : nil
        }).joined(separator: " · ")
    }
}
