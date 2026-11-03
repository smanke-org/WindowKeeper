import Foundation

/// The app binary is also its CLI. With a command after it, it runs that
/// command against the running app and exits; without one, it opens the app.
///   windowkeeper help                         every command, with examples
///   windowkeeper items add --title "Milk"     run one command
///   windowkeeper items list --json            one JSON object on stdout
///   windowkeeper mcp                          an MCP server on stdin and stdout
/// Exit codes: 0 ok, 1 error, 2 usage, 3 not found, 4 app not running.
enum AgentCLI {
    /// nil when the app should open normally.
    static func runIfRequested() -> Int32? {
        var words = Array(CommandLine.arguments.dropFirst())
        // macOS and Xcode pass flags like -NSDocumentRevisionsDebugMode. Not ours.
        guard let first = words.first, !first.hasPrefix("-") || ["--help", "-h", "--version"].contains(first) else { return nil }
        let json = words.contains("--json")
        words.removeAll { $0 == "--json" }
        do {
            switch first {
            case "help", "--help", "-h":
                return help(Array(words.dropFirst()), json: json)
            case "--version", "version":
                print(json ? JSON.string(["version": version]) : "windowkeeper \(version)")
                return 0
            case "mcp":
                AgentMCP.serve()
                return 0
            default:
                return try run(words, json: json)
            }
        } catch let error as AgentError {
            fail(error, json: json)
            return error.exit
        } catch {
            fail(.invalid(error.localizedDescription), json: json)
            return 1
        }
    }

    /// Through the ~/.local/bin link, Bundle.main cannot find Info.plist. Follow the link.
    static var version: String {
        let plist = AgentBinary.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func run(_ words: [String], json: Bool) throws -> Int32 {
        // The longest command name that matches the first words: "items add".
        guard let command = AgentCommands.all
            .filter({ words.starts(with: $0.name.split(separator: " ").map(String.init)) })
            .max(by: { $0.name.count < $1.name.count }) else {
            throw AgentError.usage("unknown command \"\(words.prefix(2).joined(separator: " "))\". Run `windowkeeper help`")
        }
        var rest = Array(words.dropFirst(command.name.split(separator: " ").count))
        if rest.contains("--help") || rest.contains("-h") {
            print(usage(command))
            return 0
        }
        let launch = !rest.contains("--no-launch")
        rest.removeAll { $0 == "--no-launch" }
        let values = try parse(rest, for: command)
        let request = JSON.data(["command": command.name, "args": values])
        let reply = try AgentSocket.send(request, launch: launch)
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? JSONObject else {
            throw AgentError.invalid("the app sent no answer")
        }
        if object["ok"] as? Bool == true {
            let result = object["result"] ?? [:]
            print(json ? JSON.string(result) : human(result))
            return 0
        }
        let error = object["error"] as? JSONObject ?? [:]
        let code = error["code"] as? String ?? "error"
        throw AgentError(code: code, message: error["message"] as? String ?? "unknown error",
                         exit: ["usage": 2, "not_found": 3, "app_unavailable": 4][code] ?? 1)
    }

    /// --name value, --flag, and positional values, checked against the params.
    static func parse(_ words: [String], for command: AgentCommand) throws -> [String: String] {
        var values: [String: String] = [:]
        var positional = command.params.filter(\.positional)
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if name == "yes", command.destructive { values["yes"] = "true"; index += 1; continue }
                guard let param = command.params.first(where: { $0.name == name }) else {
                    throw AgentError.usage("\(command.name) has no option --\(name). Run `windowkeeper \(command.name) --help`")
                }
                let next = index + 1 < words.count ? words[index + 1] : nil
                if param.kind == .boolean, next == nil || next!.hasPrefix("--") || !["true", "false", "yes", "no"].contains(next!.lowercased()) {
                    values[name] = "true"
                    index += 1
                } else {
                    guard let next else { throw AgentError.usage("--\(name) needs a value") }
                    values[name] = param.kind == .path ? absolute(next) : next
                    index += 2
                }
            } else {
                guard !positional.isEmpty else { throw AgentError.usage("unexpected \"\(word)\". Run `windowkeeper \(command.name) --help`") }
                let param = positional.removeFirst()
                values[param.name] = param.kind == .path ? absolute(word) : word
                index += 1
            }
        }
        for param in command.params where param.required && values[param.name] == nil {
            throw AgentError.usage("missing \(param.positional ? "<\(param.name)>" : "--\(param.name)"). Example: \(command.example)")
        }
        return values
    }

    /// A path as the app needs it: ~ expanded, and relative to the shell's folder.
    private static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL.currentDirectory()).standardizedFileURL.path
    }

    // MARK: Help

    private static func help(_ words: [String], json: Bool) -> Int32 {
        if json {
            print(JSON.string(["commands": AgentCommands.all.map(schema)]))
            return 0
        }
        let name = words.joined(separator: " ")
        if let command = AgentCommands.all.first(where: { $0.name == name }) {
            print(usage(command))
            return 0
        }
        var lines = ["windowkeeper: drive WindowKeeper from the shell. Every command takes --json.", ""]
        let width = (AgentCommands.all.map(\.name.count).max() ?? 0) + 2
        for command in AgentCommands.all {
            lines.append("  " + command.name.padding(toLength: width, withPad: " ", startingAt: 0) + command.summary)
        }
        lines += ["", "More: windowkeeper help <command>, windowkeeper help --json (every command as a schema).",
                  "Exit codes: 0 ok, 1 error, 2 usage, 3 not found, 4 app not running."]
        print(lines.joined(separator: "\n"))
        return 0
    }

    static func usage(_ command: AgentCommand) -> String {
        var lines = ["\(command.summary)", "", "  windowkeeper \(command.name)" + command.params.map { param in
            let shown = param.positional ? "<\(param.name)>" : param.kind == .boolean ? "--\(param.name)" : "--\(param.name) <\(param.kind.rawValue)>"
            return " " + (param.required ? shown : "[\(shown)]")
        }.joined() + (command.destructive ? " [--yes]" : "")]
        if !command.params.isEmpty { lines.append("") }
        for param in command.params {
            lines.append("  " + (param.positional ? param.name : "--" + param.name).padding(toLength: 14, withPad: " ", startingAt: 0) + param.help)
        }
        if command.destructive { lines.append("  --yes         do it. Without --yes it only shows what it would change") }
        lines += ["", "Example: \(command.example)"]
        return lines.joined(separator: "\n")
    }

    static func schema(_ command: AgentCommand) -> JSONObject {
        var properties: JSONObject = [:]
        for param in command.params {
            properties[param.name] = ["type": param.kind.jsonType, "description": param.help]
        }
        if command.destructive {
            properties["yes"] = ["type": "boolean", "description": "Do it. Without yes it only shows what it would change."]
        }
        return ["name": command.name, "description": command.summary + " Example: " + command.example,
                "readOnly": command.readOnly, "destructive": command.destructive,
                "inputSchema": ["type": "object", "properties": properties,
                                "required": command.params.filter(\.required).map(\.name)]]
    }

    // MARK: Output

    /// Short plain lines for people. Agents use --json. A result's own values go one per line;
    /// a nested object is an indented block under its name; a list of objects is one line per
    /// item ("- id: …  name: …"), with any lists inside an item indented below it.
    static func human(_ result: Any) -> String {
        guard let object = result as? JSONObject else { return scalar(result) }
        let lines = block(object, indent: "", inline: false)
        return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
    }

    private static func block(_ object: JSONObject, indent: String, inline: Bool) -> [String] {
        var flat: [String] = []
        var nested: [String] = []
        for key in ordered(object.keys) {
            let value = object[key]!
            if let items = value as? [Any], !items.isEmpty, items.allSatisfy({ $0 is JSONObject }) {
                nested.append("\(indent)\(key):")
                for item in items.compactMap({ $0 as? JSONObject }) {
                    var lines = block(item, indent: indent + "    ", inline: true)
                    guard !lines.isEmpty else { continue }
                    lines[0] = indent + "  - " + lines[0].dropFirst(indent.count + 4)
                    nested += lines
                }
            } else if let child = value as? JSONObject, !child.isEmpty {
                nested.append("\(indent)\(key):")
                nested += block(child, indent: indent + "  ", inline: inline)
            } else {
                flat.append("\(key): \(scalar(value))")
            }
        }
        let own = inline ? (flat.isEmpty ? [] : [indent + flat.joined(separator: "  ")]) : flat.map { indent + $0 }
        return own + nested
    }

    private static func ordered(_ keys: Dictionary<String, Any>.Keys) -> [String] {
        let first = ["id", "title", "name", "app"]
        return keys.sorted { a, b in (first.firstIndex(of: a) ?? 9, a) < (first.firstIndex(of: b) ?? 9, b) }
    }

    private static func scalar(_ value: Any) -> String {
        // JSON booleans arrive as NSNumber; show them as yes and no.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "yes" : "no" }
            return CFNumberIsFloatType(number) ? "\(number.doubleValue)" : "\(number.int64Value)"
        }
        if value is NSNull { return "none" }
        if let list = value as? [Any] { return list.isEmpty ? "(none)" : list.map(scalar).joined(separator: ", ") }
        if let object = value as? JSONObject, object.isEmpty { return "(none)" }
        return "\(value)"
    }

    private static func fail(_ error: AgentError, json: Bool) {
        if json {
            print(JSON.string(error.json))
        } else {
            FileHandle.standardError.write(Data("windowkeeper: \(error.message)\n".utf8))
        }
    }
}
