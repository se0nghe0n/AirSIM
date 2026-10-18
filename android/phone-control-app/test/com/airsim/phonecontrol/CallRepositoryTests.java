package com.airsim.phonecontrol;

import android.telecom.Call;

public final class CallRepositoryTests {
    public static void main(String[] args) {
        answerNeverTargetsAnActiveCallWithoutRinging();
        cloudRejectTargetsOnlyItsAuthenticatedCall();
        localRejectUsesPublishedCallIdentity();
        answeredCallCanConfirmMediaWithoutAnsweringAgain();
        pendingAnswerDoesNotPoisonCompletedReplay();
        outgoingDialingWaitsInsteadOfAnswering();
        endedCallAcceptsHangupAfterTelecomRemoval();
        stuckRelayCallYieldsToTheNextConnectingCall();
        System.out.println("call repository tests passed");
    }

    private static void answeredCallCanConfirmMediaWithoutAnsweringAgain() {
        Call active = new Call(Call.STATE_ACTIVE) {
            @Override public void answer(int videoState) {
                throw new AssertionError("Do not answer an already active call again");
            }
        };
        String id = CallRepository.add(active);
        try {
            assertTrue(CallRepository.execute(null,
                    new AgentCommand("media-join", "answer", id, "")).success);
            assertTrue(!CallRepository.execute(null,
                    new AgentCommand("stale-join", "answer", "missing", "")).success);
        } finally { CallRepository.remove(active); }
    }

    private static void pendingAnswerDoesNotPoisonCompletedReplay() {
        String timeout = "Telecom state confirmation timeout";
        assertTrue(!CloudAnswerReplayPolicy.isFinal("answer", false, timeout));
        assertTrue(CloudAnswerReplayPolicy.isFinal("answer", true, ""));
        assertTrue(!CloudAnswerReplayPolicy.isFinal("answer", false, "active call id mismatch"));
        assertTrue(!CloudAnswerReplayPolicy.isFinal("answer", false, "cloud call not bound"));
        assertTrue(CloudAnswerReplayPolicy.isFinal("end", false, timeout));
        assertTrue(CloudAnswerReplayPolicy.isFinal("send_sms", false, timeout));
    }

    private static void outgoingDialingWaitsInsteadOfAnswering() {
        boolean[] answered = {false};
        Call dialing = new Call(Call.STATE_DIALING) {
            @Override public void answer(int videoState) { answered[0] = true; }
        };
        String id = CallRepository.add(dialing);
        try {
            CallRepository.ActionResult result = CallRepository.execute(
                    null, new AgentCommand("media-join", "answer", id, ""));
            assertTrue(!result.success);
            assertEquals("Telecom state confirmation timeout", result.error);
            assertTrue(!answered[0]);
            assertTrue(!CloudAnswerReplayPolicy.isFinal("answer", false, result.error));
        } finally { CallRepository.remove(dialing); }
    }

    private static void endedCallAcceptsHangupAfterTelecomRemoval() {
        Call active = new Call(Call.STATE_ACTIVE);
        String id = CallRepository.add(active);
        CallRepository.remove(active);
        assertTrue(!CallRepository.contains(id));
        CallRepository.ActionResult ended = CallRepository.execute(
                null, new AgentCommand("hangup", "end", id, ""));
        assertTrue(ended.success);
        CallRepository.ActionResult answer = CallRepository.execute(
                null, new AgentCommand("late-answer", "answer", id, ""));
        assertTrue(!answer.success);
        assertEquals("active call id mismatch", answer.error);
    }

    private static void stuckRelayCallYieldsToTheNextConnectingCall() {
        assertEquals(CallLifecycleConflict.Action.END_THEN_RETRY.name(),
                CallLifecycleConflict.decide(true, "connecting", "outgoing-new",
                        "11111111-1111-1111-1111-111111111111",
                        "outgoing-old", "22222222-2222-2222-2222-222222222222", "active").name());
        assertEquals(CallLifecycleConflict.Action.END_OPEN_THEN_RETRY.name(),
                CallLifecycleConflict.decide(true, "active", "outgoing-new",
                        "11111111-1111-1111-1111-111111111111",
                        "outgoing-old", "22222222-2222-2222-2222-222222222222", "active").name());
        assertEquals(CallLifecycleConflict.Action.END_THEN_DROP.name(),
                CallLifecycleConflict.decide(true, "ended", "outgoing-new",
                        "11111111-1111-1111-1111-111111111111",
                        "outgoing-old", "22222222-2222-2222-2222-222222222222", "active").name());
        assertEquals(CallLifecycleConflict.Action.RETHROW.name(),
                CallLifecycleConflict.decide(true, "ended", "outgoing-old",
                        "22222222-2222-2222-2222-222222222222",
                        "outgoing-old", "22222222-2222-2222-2222-222222222222", "active").name());
    }

    private static void answerNeverTargetsAnActiveCallWithoutRinging() {
        Call active = new Call(Call.STATE_ACTIVE);
        Call ringing = new Call(Call.STATE_RINGING);
        String activeID = CallRepository.add(active);
        String ringingID = CallRepository.add(ringing);
        try {
            assertEquals(ringingID, CallRepository.idForAction("answer"));
            CallRepository.remove(ringing);
            assertEquals("", CallRepository.idForAction("answer"));
            assertEquals(activeID, CallRepository.idForAction("end"));
        } finally {
            CallRepository.remove(ringing);
            CallRepository.remove(active);
        }
    }

    private static void cloudRejectTargetsOnlyItsAuthenticatedCall() {
        Call other = new Call(Call.STATE_RINGING);
        Call target = new Call(Call.STATE_RINGING);
        String otherID = CallRepository.add(other);
        String targetID = CallRepository.add(target);
        try {
            CloudCallTarget identity = new CloudCallTarget(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3, targetID);
            String selected = identity.resolve(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3);
            assertEquals(targetID, selected);
            CallRepository.ActionResult result = CallRepository.execute(
                    null, new AgentCommand("command-7", "reject", selected, ""));
            assertTrue(result.success);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            assertEquals("", identity.resolve(
                    "relay-call-previous", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3));
            assertEquals("", identity.resolve(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 2));
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void localRejectUsesPublishedCallIdentity() {
        Call other = new Call(Call.STATE_RINGING);
        Call target = new Call(Call.STATE_RINGING);
        String otherID = CallRepository.add(other);
        String targetID = CallRepository.add(target);
        try {
            String selected = CallRepository.idForPublishedAction(
                    "reject", "visible-target", "visible-target", targetID);
            assertEquals(targetID, selected);
            assertTrue(CallRepository.execute(
                    null, new AgentCommand("local-reject", "reject", selected, "")).success);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            assertEquals("", CallRepository.idForPublishedAction(
                    "reject", "stale-visible-call", "visible-target", targetID));
            assertEquals("", CallRepository.idForPublishedAction(
                    "answer", "visible-target", "visible-target", targetID));
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }

    private static void assertEquals(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected <" + expected + "> but was <" + actual + ">");
        }
    }
}
