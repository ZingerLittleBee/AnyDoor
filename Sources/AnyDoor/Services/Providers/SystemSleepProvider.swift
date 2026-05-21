import Foundation

/// Put the entire system to sleep via `pmset sleepnow`.
///
/// This triggers a full system sleep (CPU, RAM suspend-to-RAM), distinct from
/// `DisplaySleepProvider` which only turns off the display while the machine
/// keeps running.
actor SystemSleepProvider: ActionProvider {
    let itemKey: BuiltinItem = .systemSleep
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/pmset",
            args: ["sleepnow"]
        )
    }
}
