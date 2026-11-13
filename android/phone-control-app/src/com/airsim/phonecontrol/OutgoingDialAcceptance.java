package com.airsim.phonecontrol;

/** Dial invocation completion, never proof that Telecom bound or answered the call. */
final class OutgoingDialAcceptance {
    static final String STATUS = "outgoing_dial_accepted";

    private OutgoingDialAcceptance() {}

    static boolean completed(String commandType, String resultStatus) {
        return "dial".equals(commandType) && "completed".equals(resultStatus);
    }

    static boolean mayAnnounce(String direction, boolean running, boolean currentSocket, boolean blocked) {
        return "outgoing".equals(direction) && running && currentSocket && !blocked;
    }

    static boolean replayFor(String status, String role, String action) {
        return "peer_connected".equals(status) && "iphone".equals(role) && "".equals(action);
    }
}
