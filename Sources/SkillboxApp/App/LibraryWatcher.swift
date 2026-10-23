import Foundation
import CoreServices

/// Watches the library folder and reports changes made outside Agentbox.
///
/// The library is a plain folder, so a skill edited in an editor, a `catalog.json` rewritten by the
/// CLI or a whole library restored from a backup are all perfectly normal ways for it to change —
/// and none of them went through the app. Without this, the window kept showing what the library
/// looked like when it was last opened, and a project needing synchronization only revealed itself
/// once the user happened to click something.
///
/// FSEvents is the platform's own answer to "tell me when this tree changes": one stream for the
/// whole folder, coalesced by the system, no polling.
final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private var root: URL?

    /// Agentbox's own bookkeeping inside the library. A recovery snapshot is taken before *every*
    /// metadata write and a full backup once a day, so watching them would mean answering the app's
    /// own writes with a reload, over and over.
    private static let ignoredComponents = [".agentbox-snapshots", "backups"]

    /// Whether the paths FSEvents reported are worth a reload — that is, whether anything outside
    /// Agentbox's own backup directories changed. Separated from the stream so the rule can be
    /// tested without waiting on the file system.
    static func shouldReload(paths: [String], root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        return paths.contains { path in
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            return !ignoredComponents.contains { relative == $0 || relative.hasPrefix($0 + "/") }
        }
    }

    /// Starts watching `root`, calling `onChange` on the main actor. Starting again replaces the
    /// previous watch, which is what switching libraries needs.
    ///
    /// The latency lets the system coalesce a burst — copying a skill directory is many events for
    /// one logical change — while `noDefer` still delivers the first one straight away, so a single
    /// saved file does not sit waiting for the full second.
    func start(root: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let standardized = root.standardizedFileURL
        self.root = standardized
        let context = Box(root: standardized, onChange: onChange)
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(context).toOpaque(),
            retain: nil,
            release: { pointer in pointer.map { Unmanaged<Box>.fromOpaque($0).release() } },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            guard count > 0, LibraryWatcher.shouldReload(paths: paths, root: box.root) else { return }
            let handler = box.onChange
            Task { @MainActor in handler() }
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &streamContext,
            [standardized.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        root = nil
    }

    deinit { stop() }

    /// The callback gets one opaque pointer, so what it needs travels in one object.
    private final class Box {
        let root: URL
        let onChange: @MainActor () -> Void
        init(root: URL, onChange: @escaping @MainActor () -> Void) { self.root = root; self.onChange = onChange }
    }
}
