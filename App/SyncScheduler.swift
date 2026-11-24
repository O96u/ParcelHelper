import Foundation
import SwiftUI

// Refresh only while the app is foregrounded. iOS doesn't guarantee
// unattended background polling for an ordinary unsigned/sideloaded app.
@MainActor enum NativeHomeRefresh {
    // SwiftUI's .refreshable task can be cancelled when its view disappears or
    // is rebuilt. Keep one independent refresh worker alive and let callers
    // await it, so navigating away does not cancel every URLSession request.
    private static var activeRefresh: Task<[String], Never>?
    private static var lastStarted: TimeInterval =
        UserDefaults.standard.double(forKey: "native.home.lastAttempt")

    static func refresh(force: Bool = false) async -> [String] {
        if let activeRefresh {
            return await activeRefresh.value
        }
        let interval = TimeInterval(RefreshPolicy.minutes) * 60
        let now = Date().timeIntervalSince1970
        guard force || now - lastStarted >= interval else { return [] }

        lastStarted = now
        UserDefaults.standard.set(now, forKey: "native.home.lastAttempt")
        // An unstructured Task does not inherit the view task's cancellation.
        let worker = Task { @MainActor () -> [String] in
            let results = await performRefresh(force: force)
            activeRefresh = nil
            return results
        }
        activeRefresh = worker
        return await worker.value
    }

    private static func isCancelledRequest(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private static func performRefresh(force: Bool) async -> [String] {
        var results: [String] = []
        var interrupted: [String] = []

        ParcelRunLog.record("前台同步", force ? "手动刷新开始" : "按刷新间隔检查")
        for id in NativeParcelSync.platforms {
            if id == "mi" {
                guard NativeMiExpress.hasSession else { continue }
                do {
                    let result = try await NativeParcelSync.run("mi", force: force)
                    ParcelRunLog.record("小米", "发现 \(result.found) 件，合并 \(result.imported) 件")
                    results.append(result.description)
                } catch {
                    ParcelRunLog.record("小米", "原生查询失败（详见平台同步结果）")
                    if force { results.append("小米：" + error.localizedDescription) }
                }
                continue
            }
            if id == "cainiao" &&
                (UserDefaults.standard.object(forKey: "native.platform.enabled.cainiao") as? Bool) == false {
                continue
            }
            if id == "pdd" && !PddAccountProtection.webAccessAllowed { continue }
            let kind = id == "cainiao" ? "taobao" : id
            let accounts = await ParcelAccounts.authorizedAccounts(for: kind)
            for account in accounts {
                do {
                    let result = try await NativeParcelSync.run(id, force: force,
                                                                 accountID: account.id)
                    ParcelRunLog.record(id, "原生接口：发现 \(result.found) 件，合并 \(result.imported) 件")
                    results.append(account.nickname + " · " + result.description)
                } catch {
                    if isCancelledRequest(error) {
                        ParcelRunLog.record(id, "原生接口请求被取消")
                        interrupted.append(id)
                    } else {
                        ParcelRunLog.record(id, "原生接口失败（详见平台同步结果）")
                        if force { results.append(account.nickname + "：" + error.localizedDescription) }
                    }
                }
            }
        }

        ParcelStore.shared.persist()
        ParcelRunLog.record("前台同步", "原生接口阶段结束；结果 \(results.count) 条，中断 \(interrupted.count) 条")
        // Only record a successful foreground refresh if a provider actually
        // succeeded. A failed or empty pass must not claim fresh logistics.
        // Provider-specific native.sync.success.* keys remain authoritative.
        if force && !interrupted.isEmpty {
            results.append("部分平台的网络同步被中断（\(interrupted.joined(separator: "、"))），可稍后重试；已有包裹数据不会因此被删除")
        }
        if force && results.isEmpty { return ["没有已授权且支持自动同步的平台"] }
        return results
    }
}

/// One manual action refreshes both the native APIs and authorized web orders.
/// WebKit readers run in a serialized queue; queued means started, not finished.
@MainActor enum ParcelManualSync {
    static func refreshAll() async -> [String] {
        var messages = await NativeHomeRefresh.refresh(force: true)
        var queued = 0
        for platform in ["taobao", "jd", "pdd"] {
            for account in await ParcelAccounts.authorizedAccounts(for: platform) {
                if await NativeWebAutoSync.shared.request(
                    platform, force: true, accountID: account.id) {
                    queued += 1
                }
            }
        }
        if queued > 0 {
            ParcelRunLog.record("前台同步", "网页读取已安排 \(queued) 个任务，尚未执行完毕")
            messages.append("已安排 \(queued) 个网页订单同步任务，结果稍后在账号授权页显示。")
        }
        return messages
    }
}
