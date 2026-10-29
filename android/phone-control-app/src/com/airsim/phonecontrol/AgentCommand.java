package com.airsim.phonecontrol;

public final class AgentCommand {
    public final String id;
    public final String action;
    public final String callId;
    public final String number;
	public final String message;

    AgentCommand(String id, String action, String callId, String number) {
		this(id, action, callId, number, "");
	}

	AgentCommand(String id, String action, String callId, String number, String message) {
        this.id = id;
        this.action = action;
        this.callId = callId;
        this.number = number;
		this.message = message;
    }

    public boolean isSupported() {
        return !id.isEmpty() && switch (action) {
            case "answer", "reject", "end", "dial", "dtmf", "send_sms" -> true;
            default -> false;
        };
    }

}
