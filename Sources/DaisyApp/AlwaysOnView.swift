import AppKit
import SwiftUI
import DaisyCore

/// Under the jobs list in the JOBS tab: what Hermes runs on its own while Daisy is closed. Its
/// scheduled jobs, what they said last, and the Kanban board, all read from $HERMES_HOME and refreshed
/// every minute while this is on screen.
struct AlwaysOnView: View {
    @ObservedObject var feed: AlwaysOnFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ALWAYS ON").hudCaption(HUD.accent)
                Spacer()
                Button { Task { await feed.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).help("Read again")
            }
            Text("Hermes's scheduled jobs and Kanban board. They run in Hermes's gateway, so they carry on while Daisy is closed; nothing here sends anything.")
                .font(.system(size: 11.5)).foregroundStyle(HUD.dim).fixedSize(horizontal: false, vertical: true)
            scheduled
            latest
            kanban
            if let problem = feed.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled)
            }
        }
        .padding(.top, 18)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
        .task {
            while !Task.isCancelled {
                await feed.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    // MARK: Scheduled

    @ViewBuilder private var scheduled: some View {
        caption("SCHEDULED")
        if feed.jobs.isEmpty {
            Text("No scheduled jobs yet. DAISY_CRON=1 bash scripts/setup-hermes.sh adds the inbox triage and the repo digest; they fire while the gateway runs (DAISY_GATEWAY=1).")
                .font(.system(size: 12)).foregroundStyle(HUD.dim).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(feed.jobs) { job in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: job.paused ? "pause.circle" : "clock").font(.system(size: 11))
                    .foregroundStyle(job.paused ? HUD.dim : HUD.accent).frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.system(size: 13, weight: .medium)).foregroundStyle(job.paused ? HUD.steel : HUD.ice)
                    Text(Self.describe(job)).font(.system(size: 11)).foregroundStyle(HUD.dim)
                    if let error = job.lastError, job.lastStatus != "ok" {
                        Text(error).font(.system(size: 11)).foregroundStyle(HUD.crimson).lineLimit(2).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    static func describe(_ job: CronJobInfo) -> String {
        var parts = [AlwaysOnSchedule.plain(job.schedule)]
        if job.paused { parts.append("paused") }
        else if let next = job.nextRun { parts.append("next " + Self.when(next)) }
        if let last = job.lastRun { parts.append("last " + Self.when(last) + (job.lastStatus.map { " (\($0))" } ?? "")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Latest runs

    @ViewBuilder private var latest: some View {
        caption("LATEST")
        if feed.runs.isEmpty {
            Text("Nothing has run yet. Output lands in ~/.hermes/cron/output and shows up here.")
                .font(.system(size: 12)).foregroundStyle(HUD.dim)
        }
        ForEach(feed.runs) { run in CronRunRow(run: run) }
    }

    // MARK: Kanban

    @ViewBuilder private var kanban: some View {
        caption(feed.board.map { "KANBAN · \($0.name.uppercased())" } ?? "KANBAN")
        if let board = feed.board {
            if board.tasks.isEmpty {
                Text("The board is empty.").font(.system(size: 12)).foregroundStyle(HUD.dim)
            } else {
                Text(board.counts.map { "\($0.status.uppercased()) \($0.count)" }.joined(separator: " · "))
                    .font(HUD.label(9)).tracking(1.1).foregroundStyle(HUD.steel)
                ForEach(board.open.prefix(8)) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(task.status.uppercased()).font(HUD.label(8)).tracking(1.1)
                            .foregroundStyle(task.status == "blocked" ? HUD.amber : task.status == "running" ? HUD.accent : HUD.dim)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.system(size: 12.5)).foregroundStyle(HUD.ice).lineLimit(2)
                            if let problem = task.problem, task.status == "blocked" {
                                Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 6)
                        if let assignee = task.assignee { Text(assignee).font(.system(size: 11)).foregroundStyle(HUD.dim).lineLimit(1) }
                    }
                }
                if board.open.count > 8 {
                    Text("and \(board.open.count - 8) more (hermes kanban list)").font(.system(size: 11)).foregroundStyle(HUD.dim)
                }
            }
        } else {
            Text("No Kanban board yet. Hermes starts one the first time a task goes on it.")
                .font(.system(size: 12)).foregroundStyle(HUD.dim)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim).padding(.top, 6)
    }

    /// "5:30 AM" today, "tomorrow 5:30 AM", "Tue 5:30 AM" within the week, a date after that.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday " + time }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One run: what it said at a glance, the whole answer when opened.
private struct CronRunRow: View {
    let run: CronRun
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                glyph.font(.system(size: 12)).frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.jobName).font(.system(size: 13, weight: .medium)).foregroundStyle(HUD.ice)
                    Text(label).font(HUD.label(9)).tracking(1.1).foregroundStyle(HUD.dim)
                }
                Spacer(minLength: 8)
                Button(open ? "Less" : "Open") { open.toggle() }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            Group {
                if open {
                    MarkdownView(text: run.detail)
                    HStack {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(run.detail, forType: .string) }
                        Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([run.file]) }
                    }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                } else if !run.summary.isEmpty {
                    Text(run.summary).font(.system(size: 12)).foregroundStyle(tint).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.07)).frame(height: 1) }
    }

    private var label: String {
        let status: String
        switch run.outcome {
        case .ok: status = "DONE"
        case .skipped: status = "NOTHING TO DO"
        case .failed: status = "DIDN'T FINISH"
        case .blocked: status = "BLOCKED"
        }
        return run.ranAt.map { status + " · " + AlwaysOnView.when($0).uppercased() } ?? status
    }

    private var tint: Color {
        switch run.outcome {
        case .ok: return HUD.steel
        case .skipped: return HUD.dim
        case .failed: return HUD.crimson
        case .blocked: return HUD.amber
        }
    }

    @ViewBuilder private var glyph: some View {
        switch run.outcome {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(HUD.accent)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(HUD.dim)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(HUD.crimson)
        case .blocked: Image(systemName: "hand.raised.fill").foregroundStyle(HUD.amber)
        }
    }
}

/// Cron schedules in words when they're the simple kind: "30 5 * * *" is "every day at 5:30 AM".
enum AlwaysOnSchedule {
    static func plain(_ expression: String) -> String {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]), (0..<60).contains(minute),
              (0..<24).contains(hour), fields[2] == "*", fields[3] == "*",
              let time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else { return expression }
        let clock = time.formatted(date: .omitted, time: .shortened)
        switch fields[4] {
        case "*": return "every day at " + clock
        case "1-5": return "weekdays at " + clock
        case "0,6", "6,0": return "weekends at " + clock
        default: return expression
        }
    }
}
