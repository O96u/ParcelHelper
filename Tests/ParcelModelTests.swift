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
        print("PASS: parcel content diff + pickup/signed classification (9 checks)")
    }
}
