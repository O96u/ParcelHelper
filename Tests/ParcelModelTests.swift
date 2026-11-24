import Foundation

/// Run with: swiftc -parse-as-library Shared/Models.swift
/// Tests/ParcelModelTests.swift -o /tmp/parcel-model-tests && /tmp/parcel-model-tests
@main
struct ParcelModelTests {
    static func main() {
        var incoming = Parcel()
        precondition(incoming.hasSyncedContentChange(comparedTo: nil),
                     "First import must write")
        let initial = incoming
        precondition(!incoming.hasSyncedContentChange(comparedTo: initial),
                     "Unchanged parcel should not rewrite")
        incoming.trackUpdatedAt = 12345
        precondition(!incoming.hasSyncedContentChange(comparedTo: initial),
                     "Fetch timestamp alone must not rewrite")
        incoming.itemTitle = "新增商品名称"
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "Item title change must persist")
        incoming = initial
        incoming.eta = "明日送达"
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "ETA change must persist")
        incoming = initial
        incoming.orderId = "taobao:order123"
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "Order association must persist")
        incoming = initial
        incoming.srcApp = SourceApp(id: "douyin", name: "抖音")
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "Platform source icon must persist")
        incoming = initial
        incoming.arrivedAt = 42
        incoming.code = "8-8-22054"
        precondition(incoming.isPending, "Arrived parcel must remain pending")
        incoming.trackLatest = "驿站代签收"
        precondition(!incoming.isDone && !incoming.isSigned,
                     "Station signature is not personal collection")
        incoming.trackLatest = "您已取走"
        precondition(incoming.isDone && !incoming.isPending,
                     "Confirmed collection closes the pickup item")
        incoming = initial
        incoming.trackLatest = "您的订单已送达，如有疑问您可以联系配送员确认。"
        precondition(incoming.isSigned && !incoming.isTransit && incoming.displayStatus == "已送达",
                     "JD delivered order must not appear in transit")
        incoming.trackLatest = "您的订单已送达菜鸟驿站，请凭码取件"
        precondition(!incoming.isSigned,
                     "Station arrival must not be mistaken for final delivery")
        incoming.trackLatest = "订单已送达收件人"
        precondition(incoming.isSigned, "Recipient delivery should be completed")
        incoming.trackLatest = "快递员正在派送中，预计今日送达"
        precondition(!incoming.isSigned, "Out for delivery is not delivered")
        incoming = initial
        let newest = TrackNode(time: "2026-11-24 13:50:00", text: "运输中，最新位置")
        let older = TrackNode(time: "2026-11-24 07:50:00", text: "运输中，旧位置")
        TrackMerge.apply(to: &incoming, nodes: [newest], summary: newest.text)
        TrackMerge.apply(to: &incoming, nodes: [older, older], summary: older.text)
        precondition(incoming.trackLatest == newest.text && incoming.trackNodes == [newest, older])
        let signed = TrackNode(time: "2026-11-23 09:00:00", text: "已签收")
        TrackMerge.apply(to: &incoming, nodes: [signed], summary: signed.text)
        precondition(!incoming.isSigned, "Historical signature must not override current transit")
        incoming = initial
        incoming.arrivedAt = 42
        incoming.trackLatest = "派送异常，退回寄件人"
        precondition(incoming.hasDeliveryException && !incoming.isPending && incoming.displayStatus == "物流异常")
        print("PASS: parcel content, pickup classification, exceptions and stale tracking merge")
    }
}
