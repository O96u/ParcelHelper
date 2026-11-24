import Foundation

// Deterministic data, no fragile absolute timing threshold. Print timings so
// developers can compare like-for-like builds; device UI performance is separate.
@main struct ParcelPerformanceTests {
    static func main() {
        let events = (0..<60).map { i in
            TrackNode(time: String(format: "2026-11-24 12:%02d:00", i),
                      text: i == 59 ? "已到站" : "运输中")
        }
        let parcels: [Parcel] = (0..<250).map { _ in
            var parcel = Parcel()
            TrackMerge.apply(to: &parcel, nodes: events, summary: "已到站")
            return parcel
        }
        let start = ProcessInfo.processInfo.systemUptime
        var total = 0
        for _ in 0..<10 {
            total += parcels.filter(\.isPending).count
            total += parcels.filter(\.isTransit).count
        }
        precondition(total == 2500)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "PASS: 250 parcels × 60 events × 10 passes, %.3f s", elapsed))
    }
}
