#if MUZIKA_DEV_LOGS
import OSLog
#endif

enum MuzikaDiagnostics {
    static func report(_ message: @autoclosure () -> String) {
        #if MUZIKA_DEV_LOGS
        let event = message()
        Logger(subsystem: "app.muzika.local", category: "Application").debug("\(event, privacy: .private)")
        #endif
    }
}
