import Foundation

/// Plain words for what a tool is doing, for the HUD and the activity list: "Searching the web",
/// "Reading resume.pdf", "Opening Spotify". Raw commands and payloads never show. New tool families
/// add their phrases here.
public enum ToolPhrases {
    /// Plain words for the HUD: "Searching the web", "Reading resume.pdf". Commands stay hidden.
    public static func describe(title: String, kind: String?) -> (title: String, detail: String?) {
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
