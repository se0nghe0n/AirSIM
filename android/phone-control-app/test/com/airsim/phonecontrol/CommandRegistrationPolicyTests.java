package com.airsim.phonecontrol;

public final class CommandRegistrationPolicyTests {
    public static void main(String[] args) {
        CommandRegistrationPolicy policy = new CommandRegistrationPolicy();
        check(!policy.isCurrent(policy.generation()), "unpaired work is never current");
        check(policy.update(true, "https://relay", "phone-a", "secret-a"), "pairing opens a generation");
        long firstConnection = policy.generation();
        check(policy.isCurrent(firstConnection), "paired connection may execute");

        // Push token, capabilities and heartbeat updates do not enter the command identity.
        check(!policy.update(true, "https://relay", "phone-a", "secret-a"),
                "metadata refresh must preserve the command connection");
        check(policy.isCurrent(firstConnection), "metadata refresh preserves in-flight results");

        check(policy.update(true, "https://relay", "phone-b", "secret-a"), "new owner reconnects");
        check(!policy.isCurrent(firstConnection), "old connect, commands and results must be fenced");
        long secondConnection = policy.generation();
        check(policy.update(true, "https://relay", "phone-b", "secret-b"), "secret rotation reconnects");
        check(!policy.isCurrent(secondConnection), "old secret must be fenced");
        long rotatedConnection = policy.generation();
        check(policy.update(true, "https://other-relay", "phone-b", "secret-b"), "relay migration reconnects");
        check(!policy.isCurrent(rotatedConnection), "old relay must be fenced");

        long beforeDisable = policy.generation();
        check(policy.update(false, "https://other-relay", "phone-b", "secret-b"), "disable closes channel");
        check(!policy.isCurrent(beforeDisable), "disable fences pending work");
        check(!policy.isCurrent(policy.generation()), "disabled generation cannot execute");
        check(!policy.update(false, "", "", ""), "unpaired/disabled updates do not churn");
        check(policy.update(true, "https://relay", "phone-a", "secret-a"), "re-enable reconnects");
        check(!policy.isCurrent(firstConnection), "returning to the same owner cannot revive stale work");
        check(policy.isCurrent(policy.generation()), "new connection can execute after re-enable");
        System.out.println("CommandRegistrationPolicyTests passed");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
