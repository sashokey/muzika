import AppKit
import CoreServices
import Darwin
import Foundation

@MainActor
final class LibrarySourceWatcher {
    private nonisolated final class Callback: Sendable {
        let notify: @MainActor @Sendable () -> Void

        init(_ notify: @escaping @MainActor @Sendable () -> Void) {
            self.notify = notify
        }
    }

    private let filesystemCallback: Callback
    private let queue = DispatchQueue(label: "muzika.filesystem-events", qos: .utility)
    private let center = NSWorkspace.shared.notificationCenter
    private var observations: [NSObjectProtocol] = []
    private var stream: FSEventStreamRef?
    private var directoryWatches: [DispatchSourceFileSystemObject] = []
    private var paths: [String] = []
    private var leases: [SecurityScopeLease] = []

    init(onFilesChanged: @escaping @MainActor @Sendable () -> Void,
         onVolumesChanged: @escaping @MainActor @Sendable () -> Void) {
        filesystemCallback = Callback(onFilesChanged)
        observations = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in onVolumesChanged() }
            }
        }
    }

    func watch(_ roots: [LibrarySource]) {
        var scoped: [String: SecurityScopeLease] = [:]
        for var root in roots where root.status == .ready {
            if let lease = root.open() {
                scoped[root.url.path] = lease
            }
        }
        let currentPaths = scoped.keys.sorted()
        guard currentPaths != paths || (stream == nil && directoryWatches.isEmpty) else { return }
        stop()
        paths = currentPaths
        guard !paths.isEmpty else { return }
        if let started = Self.startStream(paths: paths, on: queue, notifying: filesystemCallback) {
            stream = started
            leases = Array(scoped.values)
        } else {
            directoryWatches = scoped.compactMap { path, lease in
                Self.watchDirectory(at: path, holding: lease, on: queue, notifying: filesystemCallback)
            }
        }
    }

    private nonisolated static func startStream(
        paths: [String], on queue: DispatchQueue, notifying handler: Callback
    ) -> FSEventStreamRef? {
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot |
                                               kFSEventStreamCreateFlagFileEvents |
                                               kFSEventStreamCreateFlagIgnoreSelf)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard let info, count > 0 else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in callback.notify() }
        }
        guard let result = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(result, queue)
        guard FSEventStreamStart(result) else {
            FSEventStreamInvalidate(result)
            FSEventStreamRelease(result)
            return nil
        }
        return result
    }

    private nonisolated static func watchDirectory(
        at path: String, holding lease: SecurityScopeLease, on queue: DispatchQueue, notifying handler: Callback
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue
        )
        watch.setEventHandler {
            Task { @MainActor in handler.notify() }
        }
        watch.setCancelHandler {
            close(descriptor)
            withExtendedLifetime(lease) {}
        }
        watch.activate()
        return watch
    }

    private func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        for watch in directoryWatches { watch.cancel() }
        directoryWatches.removeAll()
        leases.removeAll()
    }

    isolated deinit {
        stop()
        for observation in observations {
            center.removeObserver(observation)
        }
    }
}
