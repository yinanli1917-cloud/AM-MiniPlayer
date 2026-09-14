//
//  PureEditionIsolationTests.swift
//  Mirrors scripts/assert_pure_edition.sh gates ① and ② as unit tests so CI
//  catches an accidental NanoPodFullEdition dependency or MediaRemote string
//  leak into the pure-edition source trees without needing a full build.
//  See docs/wt-e-full-edition-plan-2026-09-12.md §5.
//

import XCTest

final class PureEditionIsolationTests: XCTestCase {

    /// Repo root, derived from this file's path (Tests/MusicMiniPlayerTests/PureEditionIsolationTests.swift).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Gate ①: package dependency graph
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_pureTargets_doNotDependOnNanoPodFullEdition() throws {
        let swiftBinary = "/usr/bin/swift"
        guard FileManager.default.isExecutableFile(atPath: swiftBinary) else {
            throw XCTSkip("swift binary not found at \(swiftBinary)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftBinary)
        process.arguments = ["package", "dump-package"]
        process.currentDirectoryURL = repoRoot

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw XCTSkip("failed to launch 'swift package dump-package': \(error)")
        }

        let deadline = Date().addingTimeInterval(90)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            throw XCTSkip("'swift package dump-package' exceeded 90s timeout")
        }

        guard process.terminationStatus == 0 else {
            throw XCTSkip("'swift package dump-package' exited with status \(process.terminationStatus)")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let targets = json["targets"] as? [[String: Any]]
        else {
            XCTFail("failed to parse 'swift package dump-package' JSON output")
            return
        }

        let guardedTargetNames: Set<String> = ["MusicMiniPlayer", "MusicMiniPlayerAppKit", "MusicMiniPlayerCore"]

        for target in targets {
            guard let name = target["name"] as? String, guardedTargetNames.contains(name) else { continue }
            let dependencies = target["dependencies"] as? [[String: Any]] ?? []

            for dependency in dependencies {
                for (_, value) in dependency {
                    guard let names = value as? [Any] else { continue }
                    let dependsOnFullEdition = names.contains { ($0 as? String) == "NanoPodFullEdition" }
                    XCTAssertFalse(
                        dependsOnFullEdition,
                        "pure-edition target '\(name)' must not depend on NanoPodFullEdition"
                    )
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Gate ②: source tree scan
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_coreAndAppKitSources_containNoMediaRemoteReferences() throws {
        let scannedDirectories = [
            "Sources/MusicMiniPlayerCore",
            "Sources/MusicMiniPlayerAppKit",
        ]

        var offendingFiles: [String] = []

        for relativeDir in scannedDirectories {
            let dirURL = repoRoot.appendingPathComponent(relativeDir)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                if contents.range(of: "MediaRemote", options: .caseInsensitive) != nil {
                    offendingFiles.append(fileURL.path)
                }
            }
        }

        XCTAssertTrue(
            offendingFiles.isEmpty,
            "found MediaRemote reference(s) in pure-edition source tree: \(offendingFiles)"
        )
    }
}
