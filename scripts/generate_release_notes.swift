#!/usr/bin/env swift
import Foundation

// Executed on the macOS GitHub Actions runner. No third-party dependencies.
let env = ProcessInfo.processInfo.environment
let version = env["APP_VERSION"] ?? "1.0.0"
let previous = env["PREVIOUS_TAG"] ?? ""
let firstOfficial = version == "1.0.0" && previous.isEmpty
let destination = URL(fileURLWithPath: "build/release-notes.md")
let baseline = URL(fileURLWithPath: "docs/RELEASE_NOTES.md")

func gitLog(since tag: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["log", "--no-merges", "--format=%s", "\(tag)..HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
    } catch {
        return []
    }
}

let releaseNotes: String
if firstOfficial {
    releaseNotes = try String(contentsOf: baseline, encoding: .utf8)
} else {
    var additions: [String] = []
    var changes: [String] = []
    var fixes: [String] = []
    let messages = previous.isEmpty ? [] : gitLog(since: previous)
    for original in messages {
        var title = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.hasPrefix("Merge ") { continue }
        let lower = title.lowercased()
        if ["feat:", "feature:", "add:", "新增:"].contains(where: lower.hasPrefix) {
            title = String(title.split(separator: ":", maxSplits: 1).last ?? Substring(title))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            additions.append("- " + title)
        } else if ["fix:", "bugfix:", "修复:"].contains(where: lower.hasPrefix) {
            title = String(title.split(separator: ":", maxSplits: 1).last ?? Substring(title))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fixes.append("- " + title)
        } else {
            for prefix in ["docs:", "refactor:", "perf:", "chore:", "style:", "build:", "ci:", "修改:"] {
                if lower.hasPrefix(prefix) {
                    title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            changes.append("- " + title)
        }
    }
    func lines(_ items: [String]) -> String {
        items.isEmpty ? "- 本版本暂无此类变更。" : Array(Set(items)).sorted().joined(separator: "\n")
    }
    releaseNotes = """
    # ParcelHelper v\(version)

    ## 新增
    \(lines(additions))

    ## 修改
    \(lines(changes))

    ## 修复
    \(lines(fixes))

    ## 安装说明
    - `ParcelHelper.ipa` 为 **未签名 IPA**，需要自行签名后安装。
    - 第三方签名可能影响系统通知、实时活动及快捷指令。

    """
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try releaseNotes.write(to: destination, atomically: true, encoding: .utf8)
print("Generated structured release notes for v\(version)")
