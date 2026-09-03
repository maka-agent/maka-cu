import Foundation

public enum OpenComputerUseCLICommand: Equatable {
    case launchOnboarding
    /// Speak `maka.cu/3` over stdio. This is the only automation entry point:
    /// the Maka host owns every model-facing word, so there is no second,
    /// model-shaped surface here to drift from it.
    case host
    case doctor(format: DoctorOutputFormat = .text, launchOnboarding: Bool = true)
    case listApps
    case snapshot(app: String, textLimit: SnapshotTextLimit = .defaults, treeLimits: AccessibilityTreeLimits = .defaults)
    case turnEnded(payload: String?)
    case help(command: String?)
    case version
}

public enum DoctorOutputFormat: Equatable {
    case text
    case json
}

public struct OpenComputerUseCLIError: LocalizedError, Equatable {
    public let message: String
    public let helpCommand: String?

    public init(message: String, helpCommand: String? = nil) {
        self.message = message
        self.helpCommand = helpCommand
    }

    public var errorDescription: String? {
        var lines = [message]
        lines.append("")
        lines.append(openComputerUseHelpText(command: helpCommand))
        return lines.joined(separator: "\n")
    }
}

public func parseOpenComputerUseCLI(arguments: [String]) throws -> OpenComputerUseCLICommand {
    guard let first = arguments.first else {
        return .launchOnboarding
    }

    switch first {
    case "-h", "--help", "help":
        if arguments.count > 2 {
            throw OpenComputerUseCLIError(message: "help accepts at most one command", helpCommand: nil)
        }

        return .help(command: arguments.dropFirst().first)
    case "-v", "--version", "version":
        guard arguments.count == 1 else {
            throw OpenComputerUseCLIError(message: "version does not accept any arguments", helpCommand: nil)
        }

        return .version
    case "host":
        return try parseSimpleCommand(name: "host", arguments: Array(arguments.dropFirst()), result: .host)
    case "doctor":
        return try parseDoctor(arguments: Array(arguments.dropFirst()))
    case "list-apps":
        return try parseSimpleCommand(name: "list-apps", arguments: Array(arguments.dropFirst()), result: .listApps)
    case "turn-ended":
        return try parseTurnEnded(arguments: Array(arguments.dropFirst()))
    case "snapshot":
        return try parseSnapshot(arguments: Array(arguments.dropFirst()))
    default:
        if first.hasPrefix("-") {
            throw OpenComputerUseCLIError(message: "Unknown option: \(first)", helpCommand: nil)
        }

        throw OpenComputerUseCLIError(message: "Unknown command: \(first)", helpCommand: nil)
    }
}

public func openComputerUseHelpText(command: String? = nil) -> String {
    switch command {
    case nil:
        return """
        Open Computer Use

        Usage:
          open-computer-use [command] [options]
          open-computer-use

        Commands:
          host                 Speak the maka.cu/3 host protocol over stdio.
          doctor               Print runtime diagnostics and launch onboarding if needed.
          list-apps            Print running or recently used apps.
          snapshot <app>       Print the current accessibility snapshot for an app.
          turn-ended           Notify the running MCP process that the host turn ended.
          help [command]       Show general or command-specific help.
          version              Print the CLI version.

        Global options:
          -h, --help           Show help.
          -v, --version        Show version.

        Notes:
          Running without a command launches the permission onboarding app.
          Use `open-computer-use help <command>` for command-specific help.
        """
    case "host":
        return """
        Usage:
          open-computer-use host

        Speak the maka.cu/3 host protocol over stdio. line-delimited JSON-RPC 2.0,
        one JSON value per line. The Maka host drives it; it is not interactive.
        See docs/maka-cu-host-protocol.md in the Maka repository.
        """
    case "doctor":
        return """
        Usage:
          open-computer-use doctor [--json] [--no-onboarding]

        Print protocol, permission, lock-screen, native capability, and code-signing diagnostics.

        Options:
          --json               Emit one machine-readable JSON object.
          --no-onboarding      Never launch the permission onboarding app.

        Text mode launches onboarding when permissions are missing unless
        --no-onboarding is supplied. JSON mode never launches UI.
        """
    case "list-apps":
        return """
        Usage:
          open-computer-use list-apps

        Print running apps plus recently used apps that can be targeted by Computer Use.
        """
    case "snapshot":
        return """
        Usage:
          open-computer-use snapshot [--text-limit <positive-int|max>] [--max-tree-nodes <positive-int>] [--max-tree-depth <positive-int>] <app>

        Arguments:
          <app>                App name or bundle identifier to inspect.

        Options:
          --text-limit         Override the default 500 character text limit. Use `max` for full text.
          --max-tree-nodes     Override the default 1200 node accessibility tree budget.
          --max-tree-depth     Override the default 64 level accessibility tree depth.

        Print the current accessibility snapshot for the target app.
        """
    case "turn-ended":
        return """
        Usage:
          open-computer-use turn-ended [--previous-notify <argv>] [payload]

        Notify a running local MCP process that the current host turn has ended.
        Codex legacy notify appends the after-agent JSON payload as the last argument.
        """
    case "version":
        return """
        Usage:
          open-computer-use version
          open-computer-use --version
          open-computer-use -v

        Print the CLI version.
        """
    case "help":
        return """
        Usage:
          open-computer-use help [command]

        Show general help or help for a specific command.
        """
    default:
        return """
        Unknown help topic: \(command ?? "")

        \(openComputerUseHelpText())
        """
    }
}

private func parseDoctor(arguments: [String]) throws -> OpenComputerUseCLICommand {
    if arguments.count == 1, let option = arguments.first, option == "-h" || option == "--help" {
        return .help(command: "doctor")
    }

    var format = DoctorOutputFormat.text
    var launchOnboarding = true
    for argument in arguments {
        switch argument {
        case "--json":
            format = .json
            launchOnboarding = false
        case "--no-onboarding":
            launchOnboarding = false
        case "-h", "--help":
            throw OpenComputerUseCLIError(
                message: "doctor help must be requested as `open-computer-use doctor --help`",
                helpCommand: "doctor"
            )
        default:
            throw OpenComputerUseCLIError(
                message: "Unknown doctor option: \(argument)",
                helpCommand: "doctor"
            )
        }
    }
    return .doctor(format: format, launchOnboarding: launchOnboarding)
}

private func parseSimpleCommand(
    name: String,
    arguments: [String],
    result: OpenComputerUseCLICommand
) throws -> OpenComputerUseCLICommand {
    if arguments.isEmpty {
        return result
    }

    if arguments.count == 1, let option = arguments.first, option == "-h" || option == "--help" {
        return .help(command: name)
    }

    throw OpenComputerUseCLIError(message: "\(name) does not accept any arguments", helpCommand: name)
}

private func parseTurnEnded(arguments: [String]) throws -> OpenComputerUseCLICommand {
    if arguments.count == 1, let option = arguments.first, option == "-h" || option == "--help" {
        return .help(command: "turn-ended")
    }

    var payload: String?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--previous-notify":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw OpenComputerUseCLIError(message: "--previous-notify requires a value", helpCommand: "turn-ended")
            }
            index = valueIndex
        case "-h", "--help":
            throw OpenComputerUseCLIError(message: "turn-ended help must be requested as `open-computer-use turn-ended --help`", helpCommand: "turn-ended")
        default:
            if argument.hasPrefix("-") {
                throw OpenComputerUseCLIError(message: "Unknown turn-ended option: \(argument)", helpCommand: "turn-ended")
            }

            guard payload == nil else {
                throw OpenComputerUseCLIError(message: "turn-ended accepts at most one payload argument", helpCommand: "turn-ended")
            }

            payload = argument
        }

        index += 1
    }

    return .turnEnded(payload: payload)
}

private func parseSnapshot(arguments: [String]) throws -> OpenComputerUseCLICommand {
    if arguments.isEmpty {
        throw OpenComputerUseCLIError(message: "snapshot requires an app name or bundle identifier", helpCommand: "snapshot")
    }

    if arguments.count == 1, let value = arguments.first, value == "-h" || value == "--help" {
        return .help(command: "snapshot")
    }

    var app: String?
    var textLimit = SnapshotTextLimit.defaults
    var maxTreeNodes: Int?
    var maxTreeDepth: Int?

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--text-limit":
            index += 1
            guard index < arguments.count else {
                throw OpenComputerUseCLIError(message: "--text-limit requires a positive integer or max value", helpCommand: "snapshot")
            }
            textLimit = try parseTextLimitOption(arguments[index], option: "--text-limit")
        case "--max-tree-nodes":
            index += 1
            guard index < arguments.count else {
                throw OpenComputerUseCLIError(message: "--max-tree-nodes requires a positive integer value", helpCommand: "snapshot")
            }
            maxTreeNodes = try parsePositiveIntegerOption(arguments[index], option: "--max-tree-nodes")
        case "--max-tree-depth":
            index += 1
            guard index < arguments.count else {
                throw OpenComputerUseCLIError(message: "--max-tree-depth requires a positive integer value", helpCommand: "snapshot")
            }
            maxTreeDepth = try parsePositiveIntegerOption(arguments[index], option: "--max-tree-depth")
        case "-h", "--help":
            throw OpenComputerUseCLIError(message: "snapshot help must be requested as `open-computer-use snapshot --help`", helpCommand: "snapshot")
        default:
            if argument.hasPrefix("-") {
                throw OpenComputerUseCLIError(message: "Unknown snapshot option: \(argument)", helpCommand: "snapshot")
            }

            guard app == nil else {
                throw OpenComputerUseCLIError(message: "snapshot accepts exactly one <app> argument", helpCommand: "snapshot")
            }

            app = argument
        }
        index += 1
    }

    guard let app else {
        throw OpenComputerUseCLIError(message: "snapshot requires an app name or bundle identifier", helpCommand: "snapshot")
    }

    return .snapshot(
        app: app,
        textLimit: textLimit,
        treeLimits: AccessibilityTreeLimits.defaults.replacing(
            maxNodeCount: maxTreeNodes,
            maxDepth: maxTreeDepth
        )
    )
}

private func parseTextLimitOption(_ value: String, option: String) throws -> SnapshotTextLimit {
    if value.lowercased() == SnapshotTextLimit.maxKeyword {
        return .max
    }

    guard let integer = Int(value), integer > 0 else {
        throw OpenComputerUseCLIError(message: "\(option) must be a positive integer or max", helpCommand: "snapshot")
    }
    return SnapshotTextLimit(maxCount: integer)
}

private func parsePositiveIntegerOption(_ value: String, option: String) throws -> Int {
    guard let integer = Int(value), integer > 0 else {
        throw OpenComputerUseCLIError(message: "\(option) must be a positive integer", helpCommand: "snapshot")
    }
    return integer
}
