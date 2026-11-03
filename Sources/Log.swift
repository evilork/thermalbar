// Log.swift - structured logging to the unified log (Console.app, subsystem com.evilork.thermalbar).
import Foundation
import os

enum Log {
    static let subsystem = "com.evilork.thermalbar"
    private static let app = Logger(subsystem: subsystem, category: "app")

    /// A plain closure for code that should not depend on os.Logger (pure files, tests).
    static let sink: (String) -> Void = { message in
        app.notice("\(message, privacy: .public)")
    }
}
