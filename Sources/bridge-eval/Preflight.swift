import Foundation

/// PHI git-safety guard (design §9). `run` must NEVER read fixtures from, or write artifacts into, a
/// git-TRACKED path — real PDFs and raw/scored artifacts contain PHI and this repo is public. Fail loud.
/// The pure `decide` is unit-tested without git; `assertUntracked` adds the `git ls-files` probe.
enum Preflight {
    struct GuardError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func decide(path: String, isTracked: Bool) -> Result<Void, GuardError> {
        if isTracked {
            return .failure(GuardError(message: "Refusing: '\(path)' is git-tracked. Fixtures and run "
                + "artifacts may contain PHI and must never live on a tracked path. Move it under a "
                + "gitignored dir (eval/fixtures, eval/runs) or pass an off-repo --fixtures path."))
        }
        return .success(())
    }

    static func assertUntracked(_ path: String, role: String) throws {
        let tracked = isGitTracked(path)
        if case .failure(let err) = decide(path: path, isTracked: tracked) {
            throw GuardError(message: "[\(role)] " + err.message)
        }
    }

    /// `git ls-files --error-unmatch` exits 0 iff the path is tracked. Run from the path's directory so
    /// the correct repo root is used. Any failure to even run git (no repo) means "not tracked" -> allow.
    static func isGitTracked(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", dir.isEmpty ? "." : dir,
                             "ls-files", "--error-unmatch", url.lastPathComponent]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
