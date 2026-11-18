#!/usr/bin/env swift
import Foundation

// Generate release notes from actual changes. Only non-empty categories are shown.
let env = ProcessInfo.processInfo.environment
let version = env["APP_VERSION"] ?? "1.0.0"
let previous = env["PREVIOUS_TAG"] ?? ""
let firstOfficial = version == "1.0.0" && previous.isEmpty
let destination = URL(fileURLWithPath: "build/release-notes.md")
let baseline = URL(fileURLWithPath: "docs/RELEASE_NOTES.md")

func gitLog(since tag: String? = nil) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["log", "--no-merges", "--format=%s", tag.map { "\($0)..HEAD" } ?? "HEAD"]
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

enum Kind: String, CaseIterable {
    case added = "新增"
    case fixed = "修复"
    case improved = "优化"
    case changed = "修改"
    case removed = "移除"
    case docs = "文档"
    case build = "构建与发布"
}

func categorized(_ subject: String) -> (Kind, String)? {
    let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !title.hasPrefix("Merge ") else { return nil }
    let lower = title.lowercased()
    let patterns: [(Kind, [String])] = [
        (.added, ["feat", "feature", "add", "新增", "添加"]),
        (.fixed, ["fix", "bugfix", "修复"]),
        (.improved, ["perf", "optimize", "优化", "improve"]),
        (.changed, ["refactor", "change", "修改", "调整", "style"]),
        (.removed, ["remove", "delete", "移除", "删除"]),
        (.docs, ["docs", "doc", "文档"]),
        (.build, ["ci", "build", "release", "构建", "发布"])
    ]
    for (kind, prefixes) in patterns {
        for prefix in prefixes {
            // Support conventional commits with scopes: fix(xiaomi): detail
            let simple = prefix + ":"
            if lower.hasPrefix(simple) {
                let detail = String(title.dropFirst(simple.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (kind, detail.isEmpty ? title : detail)
            }
            let scopeStart = prefix + "("
            if lower.hasPrefix(scopeStart), let close = title.firstIndex(of: ")"),
               title.index(after: close) < title.endIndex,
               title[title.index(after: close)] == ":" {
                let detail = String(title[title.index(close, offsetBy: 2)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (kind, detail.isEmpty ? title : detail)
            }
        }
    }
    // Keep informative uncategorized commit subjects rather than invent a category.
    return (.changed, title)
}

let installation = """
## 安装说明
- `ParcelHelper.ipa` 是未签名 IPA，需要自行签名后安装。
- 第三方签名可能影响系统通知、实时活动和快捷指令。
"""

let releaseNotes: String
if firstOfficial {
    // The initial release is deliberately hand-authored, describing the baseline.
    releaseNotes = try String(contentsOf: baseline, encoding: .utf8)
} else {
    let messages = previous.isEmpty ? gitLog() : gitLog(since: previous)
    var entries: [Kind: [String]] = [:]
    for subject in messages {
        guard let (kind, detail) = categorized(subject) else { continue }
        if !entries[kind, default: []].contains(detail) {
            entries[kind, default: []].append(detail)
        }
    }
    var sections: [String] = ["# ParcelHelper \(version)"]
    for kind in Kind.allCases {
        guard let items = entries[kind], !items.isEmpty else { continue }
        sections.append("## \(kind.rawValue)\n" + items.map { "- " + $0 }.joined(separator: "\n"))
    }
    if entries.isEmpty {
        sections.append("本次发布未检测到可归类的代码提交，请查看 GitHub 提交记录。")
    }
    sections.append(installation)
    releaseNotes = sections.joined(separator: "\n\n") + "\n"
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try releaseNotes.write(to: destination, atomically: true, encoding: .utf8)
print("Generated release notes for \(version) (only categories with changes)")
