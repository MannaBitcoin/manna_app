import Foundation
import OSLog

class AppLogger {
    static let shared = AppLogger()

    private let appGroupIdentifier = "group.com.lightning.manna"
    let logDir: URL?
    private let queue = DispatchQueue(label: "com.lightning.manna.logger", qos: .utility)
    private let logger = Logger(subsystem: "com.lightning.manna", category: "AppLogger")

    private init() {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            let logDirURL = containerURL.appendingPathComponent("logs")
            if (try? FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)) != nil {
                logDir = logDirURL
                return
            }
        }
        logDir = nil

    }

    func logD(_ message: String, tag: String? = nil) { log(message: message, level: LogLevel.debug, tag: tag) }
    func logI(_ message: String, tag: String? = nil) { log(message: message, level: LogLevel.info, tag: tag) }
    func logW(_ message: String, tag: String? = nil) { log(message: message, level: LogLevel.warning, tag: tag) }
    func logE(_ message: String, tag: String? = nil) { log(message: message, level: LogLevel.error, tag: tag) }
    func logF(_ message: String, tag: String? = nil) { log(message: message, level: LogLevel.fatal, tag: tag) }

    private func log(message: String, level: LogLevel, tag: String?) {
        guard let fileURL = logDir?.appendingPathComponent("ios.jsonl") else { return }

        let stackTrace =
            (level == .error || level == .fatal) ? Thread.callStackSymbols.dropFirst().joined(separator: "\n") : nil
        queue.async {
            var entry: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "lvl": level.rawValue,
                "msg": message,
                "tag": tag ?? "",
            ]

            if let stack = stackTrace {
                entry["stack"] = stack
            }

            if level != .debug {
                do {
                    let data = try JSONSerialization.data(withJSONObject: entry)
                    if let line = String(data: data, encoding: .utf8) {
                        try line.appendToURL(fileURL)
                    }
                } catch {
                    os_log("Failed to write log: %@", log: .default, type: .error, error.localizedDescription)
                }
            }
        }

        let tagStr = tag ?? "no-tag"
        if let stack = stackTrace {
            logger.log(
                level: level.osLogType,
                "\(level.rawValue, privacy: .public) | \(tagStr, privacy: .public) | \(message, privacy: .public)"
            )
            logger.error("Stack:\n\(stack, privacy: .public)")
        } else {
            logger.log(
                level: level.osLogType,
                "\(level.rawValue, privacy: .public) | \(tagStr, privacy: .public) | \(message, privacy: .public)"
            )
        }

    }
}

enum LogLevel: String {
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"
    case fatal = "F"

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .info
        case .error: return .error
        case .fatal: return .fault
        }
    }
}

extension String {
    fileprivate func appendToURL(_ url: URL) throws {
        let line = self + "\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            let fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.seekToEnd()
            fileHandle.write(data)
            try fileHandle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
