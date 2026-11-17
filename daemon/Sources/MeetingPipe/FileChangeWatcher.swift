import Foundation
import MeetingPipeCore

/// Watches one file for changes made by anyone and calls `onChange` on main once
/// the events have settled (UX96: `ConfigStore` reloading a hand edit).
///
/// An editor's save is usually an atomic replace: a new inode renamed over the
/// path, which leaves a descriptor opened on the old inode deaf to everything
/// after. So the watch is re-armed on the path after every burst, and while the
/// file is absent it watches the nearest directory above it that exists, so a
/// file (or its directory) created or renamed into place later is still seen. The settle delay also covers an
/// in-place save that truncates before it writes: the callback reads the file
/// after the writer is done, not between the truncate and the write.
///
/// `onChange` may fire for a change that is not one (a sibling file in the
/// directory, an attribute touch, the caller's own write); the caller compares
/// content. Main thread only.
final class FileChangeWatcher {
    private let url: URL
    private let settle: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var cancelSettle: (() -> Void)?

    init(url: URL, settle: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.url = url
        self.settle = settle
        self.onChange = onChange
    }

    func start() { arm() }

    func stop() {
        cancelSettle?()
        cancelSettle = nil
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil
        // The file, else the nearest directory above it that exists: on a fresh
        // install not even `~/.config/meeting-pipe/` is there yet, and its creation
        // has to be seen for the watch to walk back down to the file.
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.eventArrived() }
        // Each source closes the descriptor it was made with and nothing else (PERF22's rule).
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func eventArrived() {
        cancelSettle?()
        // A common-mode one-shot, live under an open menu or alert (CONC10).
        cancelSettle = Schedulers.mainRunLoopOnce(settle) { [weak self] in
            guard let self else { return }
            self.cancelSettle = nil
            self.arm()
            self.onChange()
        }
    }
}
