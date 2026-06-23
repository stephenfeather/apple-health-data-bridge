import Foundation

public enum LogLevel: String, Sendable { case quiet, normal, verbose }

public struct Overrides: Sendable {
    public var dataRoot: String?
    public var subject: String?
    public var logLevel: LogLevel?
    public init(dataRoot: String? = nil, subject: String? = nil, logLevel: LogLevel? = nil) {
        self.dataRoot = dataRoot; self.subject = subject; self.logLevel = logLevel
    }
}

public struct Settings: Sendable {
    public let dataRoot: URL
    public let logLevel: LogLevel
    public let subjects: [SubjectEntry]
    public let selectedSubject: SubjectEntry?
}

public enum ConfigLoader {
    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/apple-health-data-bridge/config.toml")
    }
    /// Returns nil if the file does not exist; throws on malformed TOML.
    public static func load(path: String) throws -> Config? {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        let text = try String(contentsOfFile: expanded, encoding: .utf8)
        return try TOMLCodec.decode(Config.self, from: text)
    }
}

public enum ConfigWriter {
    public static func write(_ config: Config, path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let toml = try TOMLCodec.encode(config)
        try toml.write(to: url, atomically: true, encoding: .utf8)
    }
}

public enum SettingsResolver {
    private static let defaultDataRoot = "~/Documents/apple-health-data-bridge"

    public static func resolve(config: Config?, overrides: Overrides) -> Settings {
        let rawRoot = overrides.dataRoot ?? config?.dataRoot ?? defaultDataRoot
        let dataRoot = URL(fileURLWithPath: (rawRoot as NSString).expandingTildeInPath)
        let level = overrides.logLevel ?? config?.logLevel.flatMap(LogLevel.init(rawValue:)) ?? .normal
        let subjects = config?.subjects ?? []
        let selectedKey = overrides.subject ?? config?.defaultSubject
        let selected = selectedKey.flatMap { key in subjects.first { $0.key == key } }
        return Settings(dataRoot: dataRoot, logLevel: level, subjects: subjects, selectedSubject: selected)
    }
}
