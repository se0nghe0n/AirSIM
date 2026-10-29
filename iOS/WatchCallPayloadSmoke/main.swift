import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

do {
    let now = ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z")!
    let call = try WatchVoIPCall(userInfo: [
        "event": "incoming_call",
        "call_id": "local-incoming-watch",
        "call_uuid": "D9B59660-05BB-4EA8-9AEB-4505B35C93F9",
        "number": "10086",
        "expires_at": "2026-09-27T10:00:45Z",
    ], now: now)
    check(call.callID == "local-incoming-watch", "Wrong local call ID")
    check(call.media == .pendingLocal, "Local incoming media must be obtained from iPhone")
    let outgoing = try WatchVoIPCall(outgoingReply: [
        "call_id": "local-outgoing-watch", "call_uuid": UUID().uuidString,
        "number": "10086", "media_route": "vowlan", "media_transport": "webrtc",
    ])
    check(outgoing.isOutgoing, "Expected Watch outgoing call")
    check(outgoing.media == .iphoneWebRTC && outgoing.endsOnVoWLAN, "Local audio stays on iPhone")
    check(outgoing.authenticatedMediaURL == nil, "Local media cannot use cloud URL")
    let cloudSecret = String(repeating: "c", count: 32)
    let cloud = try WatchVoIPCall(userInfo: [
        "event": "incoming_call", "call_id": "cloud-watch",
        "call_uuid": UUID().uuidString,
        "media_url": "wss://relay.example/v1/calls/test/connect",
        "call_secret": cloudSecret,
    ])
    check(cloud.media == .iphoneWebRTC, "Cloud audio stays on the iPhone")
    check(cloud.authenticatedMediaURL == nil, "Watch cloud payload must not carry a PCM socket")
    check(!cloud.opensBinaryPCMWebSocket, "Watch cloud payload must not open a PCM WebSocket")
    check(cloudSecret.count >= 24, "Fixture secret must stay a realistic bearer length")
    do {
        _ = try WatchVoIPCall(outgoingReply: [
            "call_id": "retired-local", "call_uuid": UUID().uuidString,
            "media_route": "vowlan", "pcm_host": "192.168.43.1", "pcm_port": 7591,
        ])
        fatalError("Legacy PCM endpoint must be rejected")
    } catch WatchVoIPPayloadError.legacyPCMNotCarrier {}

} catch {
    fatalError("Watch local incoming payload rejected: \(error)")
}
