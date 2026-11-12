package com.airsim.phonecontrol;

/**
 * Bounds carrier-route recovery for one call, independently of signaling sockets and ICE peers.
 * Rebuilding WebRTC cannot repair Android audio-policy state indefinitely. This does not infer a
 * particular OS bug, change a route, or end the carrier call. A new call gets a fresh budget.
 */
final class CloudCarrierRecovery {
    static final String RECOVERY_REQUIRED = "carrier_route_recovery_required";
    static final int MAX_ROUTE_FAILURES = 3;
    private int routeFailures;
    private boolean blocked;

    synchronized boolean isBlocked() { return blocked; }

    /** True means stop media retries but retain call controls. Ordinary network failures do not count. */
    synchronized boolean recordFailure(String reason) {
        if (blocked) return true;
        if (isCarrierRouteFailure(reason)) blocked = ++routeFailures >= MAX_ROUTE_FAILURES;
        return blocked;
    }

    private static boolean isCarrierRouteFailure(String reason) {
        if (reason == null) return false;
        return switch (reason) {
            case "carrier_route_unavailable", "carrier_route_rejected", "carrier_route_unverified",
                 "carrier_route_lost", "carrier_route_inactive" -> true;
            // A known non-telephony route also fails closed, never becomes a speaker fallback.
            default -> reason.matches("carrier_route_changed_type_[0-9]{1,3}");
        };
    }
}
