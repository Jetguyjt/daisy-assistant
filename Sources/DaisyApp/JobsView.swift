import AppKit
import SwiftUI
import DaisyCore

/// Background jobs: start one, see what each is doing, read what it found. Each runs in a Hermes
/// session of its own, two at a time, while the conversation carries on.
struct JobsView: View {
    @ObservedObject var jobs: JobsModel
    @ObservedObject var approvals: ApprovalQueue
    @State private var goal = ""
    @State private var title = ""

    var body: some View {
        HUDPage(kicker: kicker, title: "Jobs") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("What should run in the background?", text: $goal).hudField().onSubmit(start)
                    TextField("Name (optional)", text: $title).hudField().frame(width: 170).onSubmit(start)
                    Button { start() } label: { Label("Start job", systemImage: "play.fill") }
                        .buttonStyle(HUDButtonStyle(kind: .primary, compact: true))
                        .disabled(!jobs.available || goal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(jobs.available
                     ? "Jobs run two at a time; the rest wait. Anything a job wants to send or change stops at a card like any other."
                     : "Background jobs need Hermes. Switch the brain in Setup.")
                    .font(.system(size: 11)).foregroundStyle(jobs.available ? HUD.dim : HUD.amber)
            }
            .padding(.bottom, 4)
            if jobs.jobs.isEmpty {
                Text("No jobs yet.").font(.system(size: 12)).foregroundStyle(HUD.dim).padding(.vertical, 6)
            }
            ForEach(jobs.jobs) { job in
                JobRow(job: job, step: jobs.steps[job.id], plan: jobs.plans[job.id], approvals: approvals,
                       cancel: { jobs.cancel(job.id) }, dismiss: { jobs.dismiss(job.id) })
            }
            if jobs.jobs.contains(where: \.status.finished) {
                Button("Clear finished") { jobs.clearFinished() }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).padding(.top, 4)
            }
        }
    }

    private var kicker: String {
        "BACKGROUND JOBS / \(jobs.running.count) RUNNING · \(jobs.queued.count) WAITING"
    }

    private func start() {
        guard jobs.start(goal, title: title) != nil else { return }
        goal = ""; title = ""
    }
}

/// One job: what was asked, where it stands, what it's doing, and its answer when done.
private struct JobRow: View {
    let job: Job
    let step: String?
    let plan: AgentPlan?
    let approvals: ApprovalQueue
    let cancel: () -> Void
    let dismiss: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                JobGlyph(status: job.status).frame(width: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title ?? job.goal).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(job.status.finished ? HUD.steel : HUD.ice).lineLimit(2)
                    if job.title != nil {
                        Text(job.goal).font(.system(size: 11.5)).foregroundStyle(HUD.dim).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if job.status.finished {
                    if let result = job.result {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
                            .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                    }
                    Button("Remove") { dismiss() }.buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                } else {
                    Button("Cancel") { cancel() }.buttonStyle(HUDButtonStyle(kind: .danger, compact: true))
                }
            }
            HStack(spacing: 6) {
                Text(JobGlyph.label(job.status))
                    .foregroundStyle(job.status == .needsApproval ? HUD.amber : job.status == .failed ? HUD.crimson : HUD.accent.opacity(0.85))
                Text("·")
                if job.status == .running || job.status == .needsApproval, let started = job.started {
                    TimelineView(.periodic(from: .now, by: 1)) { context in Text(Self.duration(context.date.timeIntervalSince(started))) }
                } else if let started = job.started, let finished = job.finished {
                    Text(Self.duration(finished.timeIntervalSince(started)))
                } else {
                    Text(job.created.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(HUD.label(9)).tracking(1.1).foregroundStyle(HUD.dim).monospacedDigit()
            if !job.status.finished, let step {
                Text(step + "…").font(.system(size: 12)).foregroundStyle(HUD.steel)
            }
            if let plan, !plan.entries.isEmpty, !job.status.finished || expanded {
                PlanView(plan: plan, limit: 6).padding(.leading, 24)
            }
            if job.status == .needsApproval {
                ApprovalQueueList(queue: approvals, source: .job(job.id))
            }
            if let problem = job.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(job.status == .failed ? HUD.crimson : HUD.dim).textSelection(.enabled)
            }
            if job.status.finished, let result = job.result {
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownView(text: expanded ? result : Self.preview(result))
                    if result.count > Self.previewLength || result.components(separatedBy: "\n").count > 6 {
                        Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                            .buttonStyle(.plain).font(HUD.label(9)).tracking(1.2).foregroundStyle(HUD.accent)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
    }

    private static let previewLength = 420

    private static func preview(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").prefix(6).joined(separator: "\n")
        return lines.count > previewLength ? String(lines.prefix(previewLength)) + "…" : lines
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return whole < 60 ? "\(whole)S" : "\(whole / 60)M \(whole % 60)S"
    }
}

/// A job's state at a glance.
struct JobGlyph: View {
    let status: Job.Status
    var body: some View {
        Group {
            switch status {
            case .queued: Image(systemName: "clock").foregroundStyle(HUD.dim)
            case .running: ProgressView().controlSize(.mini).tint(HUD.accent)
            case .needsApproval: Image(systemName: "hand.raised.fill").foregroundStyle(HUD.amber)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(HUD.accent)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(HUD.crimson)
            case .cancelled: Image(systemName: "minus.circle").foregroundStyle(HUD.dim)
            }
        }
        .font(.system(size: 12))
        .accessibilityLabel(Self.label(status).capitalized)
    }

    static func label(_ status: Job.Status) -> String {
        switch status {
        case .queued: return "WAITING"
        case .running: return "RUNNING"
        case .needsApproval: return "NEEDS YOUR OK"
        case .done: return "DONE"
        case .failed: return "DIDN'T FINISH"
        case .cancelled: return "CANCELLED"
        }
    }
}

/// One line for the telemetry panel: what's running in the background, with a way to the Jobs tab.
struct JobsReadout: View {
    @ObservedObject var jobs: JobsModel
    let open: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("JOBS").font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.dim)
                Text(summary).font(.system(size: 12)).foregroundStyle(attention ? HUD.amber : HUD.ice).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: open) { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(HUD.dim)
                .accessibilityLabel("Open jobs")
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.line.opacity(0.12)).frame(height: 1) }
    }

    private var attention: Bool { jobs.jobs.contains { $0.status == .needsApproval } }
    private var summary: String {
        let running = jobs.running.count, waiting = jobs.queued.count
        if attention { return "A job needs your OK" }
        if running == 0 && waiting == 0 { return jobs.available ? "None running" : "Needs Hermes" }
        return "\(running) running" + (waiting > 0 ? " · \(waiting) waiting" : "")
    }
}
