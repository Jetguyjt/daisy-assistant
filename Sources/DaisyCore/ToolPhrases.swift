import Foundation

/// Plain words for what a tool is doing, for the HUD and the activity list: "Searching the web",
/// "Reading resume.pdf", "Opening Spotify". Raw commands and payloads never show. New tool families
/// add their phrases here.
public enum ToolPhrases {
    /// Plain words for the HUD: "Searching the web", "Reading resume.pdf". Commands stay hidden.
    /// `input` is the tool call's arguments (ACP's rawInput), which plugin tools need: their title is
    /// only the tool's name.
    public static func describe(title: String, kind: String?, input: JSONValue? = nil) -> (title: String, detail: String?) {
        let parts = title.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        // Hermes adds counts in brackets to some titles: "todo (3 items)", "delegate batch (2 tasks)".
        let head = (parts.first?.lowercased() ?? "").replacingOccurrences(of: "\\s*\\([^)]*\\)$", with: "", options: .regularExpression)
        let rest = parts.count > 1 ? parts[1] : ""
        let file: String? = rest.isEmpty ? nil : URL(fileURLWithPath: rest).lastPathComponent
        switch head {
        case "terminal", "process", "process_manage": return (command(rest), nil)
        case "read", "read_file": return ("Reading a file", file)
        case "write", "write_file": return ("Writing a file", file)
        case "search", "search_files", "search files", "find": return ("Searching your files", rest.isEmpty ? nil : rest)
        case "web search", "web_search": return ("Searching the web", rest.isEmpty ? nil : rest)
        case "web extract", "web_extract", "fetch": return ("Reading a web page", nil)
        case "memory": return ("Updating memory", nil)
        case "session_search", "session search": return ("Searching past conversations", nil)
        case "skill_view", "skills_list", "skill view", "skills list": return ("Checking skills", nil)
        case "skill_manage": return ("Updating a skill", nil)
        case "delegate_task", "delegate", "delegate task", "delegate batch": return ("Handing off a subtask", nil)
        case "execute_code": return ("Running code", nil)
        case "todo", "todo_list": return ("Planning", nil)
        case "vision_analyze": return ("Looking at an image", nil)
        // Hermes keeps some tools folded away until the model asks for one.
        case "tool_describe", "tool describe", "tool_search", "tool search": return ("Getting a tool ready", nil)
        case "chrome_tabs": return ("Checking your tabs", nil)
        case "chrome_focus": return (site(input).map { "Switching to \($0)" } ?? "Switching tabs", nil)
        case "chrome_open":
            guard let site = site(input) else { return ("Opening a page", nil) }
            return (input?["reuse"]?.boolValue == true ? "Switching to \(site)" : "Opening \(site)", nil)
        case "computer_look", "computer_act": return (computer(head, input: input), nil)
        case "approval_grant": return ("Asking for a standing OK", nil)
        case "gmail_search": return ("Checking your email", nil)
        case "gmail_read": return ("Reading an email", nil)
        case "gmail_send": return ("Sending an email", nil)
        case "gmail_reply": return ("Replying to an email", nil)
        case "gmail_modify": return ("Tidying your inbox", nil)
        case "gmail_delete": return ("Moving email to the trash", nil)
        case "calendar_list": return ("Checking your calendar", nil)
        case "calendar_write": return ("Updating your calendar", nil)
        case "calendar_delete": return ("Removing a calendar event", nil)
        case "drive_search": return ("Searching your Drive", nil)
        case "drive_read": return ("Reading a Drive file", nil)
        case "drive_upload": return ("Uploading to Drive", nil)
        case "drive_share": return ("Sharing a Drive file", nil)
        case "drive_delete": return ("Deleting a Drive file", nil)
        case "docs_write": return ("Editing a Google Doc", nil)
        case "sheets_write": return ("Editing a Google Sheet", nil)
        case "imsg_send": return (texting(input), nil)
        case "reminders_list": return ("Checking your reminders", nil)
        case "reminders_add": return ("Adding a reminder", nil)
        case "reminders_complete": return ("Checking off a reminder", nil)
        case "notes_search": return ("Checking your notes", nil)
        case "tasks_list": return ("Checking your tasks", nil)
        case "tasks_add": return (tasks("Adding", input?["tasks"]), nil)
        case "tasks_update": return (linking(input?["changes"]) ?? "Updating your tasks", nil)
        case "tasks_remove": return (tasks("Removing", input?["tasks"]), nil)
        case "projects_list": return ("Checking your projects", nil)
        case "projects_add": return (projects("Adding", input?["projects"]), nil)
        case "projects_update": return (linking(input?["changes"]) ?? "Updating your projects", nil)
        case "projects_remove": return ("Removing a project", nil)
        case "notes_read": return ("Reading a note", nil)
        case "notes_create": return ("Writing a new note", nil)
        case "notes_append": return ("Adding to a note", nil)
        default:
            if head.hasPrefix("patch") { return ("Editing a file", file) }
            if head.hasPrefix("memory") { return ("Updating memory", nil) }
            if head.hasPrefix("browser") { return ("Using the browser", nil) }
            switch kind {
            case "read": return ("Reading", nil)
            case "search": return ("Searching", nil)
            case "fetch": return ("Fetching from the web", nil)
            case "edit": return ("Editing a file", nil)
            case "execute": return ("Working", nil)
            default:
                let words = title.replacingOccurrences(of: "_", with: " ")
                return (words.isEmpty ? "Working" : words.prefix(1).uppercased() + words.dropFirst(), nil)
            }
        }
    }

    /// Daisy's computer tools in plain words, from the call's arguments: "Looking at Mail", "Typing in
    /// Notes". Never the text being typed.
    private static func computer(_ tool: String, input: JSONValue?) -> String {
        let app = (input?["app"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let action = input?["action"]?.stringValue ?? ""
        let place = app.isEmpty ? "" : " in \(app)"
        if tool == "computer_look" {
            switch action {
            case "list_apps": return "Checking open apps"
            case "list_windows": return "Checking open windows"
            default: return app.isEmpty ? "Looking at the screen" : "Looking at \(app)"
            }
        }
        switch action {
        case "": return "Using an app"
        case "type": return "Typing" + place
        case "key": return "Pressing a key" + place
        case "scroll": return "Scrolling" + place
        case "drag": return "Dragging" + place
        case "set_value": return "Changing a setting" + place
        case "focus_app": return app.isEmpty ? "Switching apps" : "Switching to \(app)"
        default: return "Clicking" + place
        }
    }

    /// "Texting Dad": who, as the user said it (or the number). Never the message.
    private static func texting(_ input: JSONValue?) -> String {
        let to = (input?["to"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to.count <= 40, !to.contains(where: \.isNewline) else { return "Sending a text" }
        return "Texting \(to)"
    }

    /// "Adding 12 tasks", "Adding a task"; "Adding your tasks" when the count isn't there.
    static func tasks(_ verb: String, _ list: JSONValue?) -> String {
        guard let count = list?.arrayValue?.count, count > 0 else { return "\(verb) your tasks" }
        return count == 1 ? "\(verb) a task" : "\(verb) \(count) tasks"
    }

    /// "Adding a project", "Adding 3 projects"; "Adding your projects" when the count isn't there.
    static func projects(_ verb: String, _ list: JSONValue?) -> String {
        guard let count = list?.arrayValue?.count, count > 0 else { return "\(verb) your projects" }
        return count == 1 ? "\(verb) a project" : "\(verb) \(count) projects"
    }

    /// "Linking a doc", "Linking an event", "Adding links": when a tasks_update or projects_update call
    /// adds links. Nil when it doesn't.
    static func linking(_ changes: JSONValue?) -> String? {
        let added = (changes?.arrayValue ?? []).flatMap { $0["add_links"]?.arrayValue ?? [] }
        guard let first = added.first else { return nil }
        guard added.count == 1 else { return "Adding links" }
        let kind = first["kind"]?.stringValue ?? first.stringValue.flatMap { TaskLink.detect($0)?.kind.rawValue }
            ?? (first["file_id"] != nil ? "google_drive" : first["event_id"] != nil ? "calendar_event"
                : first["message_id"] != nil || first["thread_id"] != nil ? "gmail" : "")
        let word = ["google_doc": "a doc", "google_drive": "a Drive file", "calendar_event": "an event", "gmail": "an email",
                    "file": "a file", "note": "a note", "reminder": "a reminder"][kind] ?? "a link"
        return "Linking \(word)"
    }

    /// Where a Chrome tool is headed: "Gmail" for mail.google.com, otherwise the site without www.
    private static func site(_ input: JSONValue?) -> String? {
        guard var text = input?["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var host = URLComponents(string: text)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let names = ["mail.google.com": "Gmail", "gmail.com": "Gmail", "calendar.google.com": "Google Calendar",
                     "drive.google.com": "Google Drive", "docs.google.com": "Google Docs"]
        return names[host] ?? host
    }

    public static func command(_ command: String) -> String {
        let text = command.trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ").map(String.init)
        let tool = URL(fileURLWithPath: words.first ?? "").lastPathComponent
        switch tool {
        case "imsg": return words.contains("send") ? "Sending a message" : "Looking through Messages"
        case "open":
            if let index = words.firstIndex(of: "-a"), index + 1 < words.count {
                return "Opening " + words[(index + 1)...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return "Opening"
        case "mdfind", "find", "fd", "locate": return "Searching your files"
        case "du", "df": return "Checking storage"
        case "ls", "tree": return "Looking in a folder"
        case "gws":
            if text.contains("calendar") { return ["insert", "update", "delete", "patch", "move"].contains(where: text.contains) ? "Updating your calendar" : "Checking your calendar" }
            if text.contains("gmail") { return text.contains("send") ? "Sending email" : "Checking email" }
            return "Checking Google"
        case "remindctl": return "Checking reminders"
        case "memo": return "Checking notes"
        case "osascript": return "Talking to a Mac app"
        case "curl", "wget": return "Fetching from the web"
        case "git": return "Checking a repo"
        case "python", "python3": return "Running a script"
        default: return "Running a command"
        }
    }
}
