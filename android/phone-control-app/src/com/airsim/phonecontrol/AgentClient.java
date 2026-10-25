package com.airsim.phonecontrol;

import android.content.Context;

/** Local API facade. Agent state and commands stay in the installed application. */
public final class AgentClient {
    public record ForwardResponse(int status, String payload) {}
    private final StandaloneAgentGateway standalone;

    public AgentClient(Context context) {
        standalone = StandaloneAgentGateway.get(context.getApplicationContext());
    }

    public String status() throws Exception { return standalone.status(); }
    public String health() throws Exception { return standalone.health(); }
    public String pushStatus() throws Exception { return standalone.pushStatus(); }
    public String debugSnapshot() throws Exception { return standalone.debugSnapshot(); }
    public void sendEvent(String json) throws Exception { standalone.sendCallEvent(json); }
    public void sendSMSEvent(String json) throws Exception { standalone.sendSMSEvent(json); }
    public String registerPairing(String json) throws Exception { return standalone.registerPairing(json); }

    public ForwardResponse forwardVoWLAN(String method, String path, String body) throws Exception {
        if (!VoWLANControlPolicy.allowed(method, path) || "/v1/health".equals(path)) {
            throw new IllegalArgumentException("VoWLAN route not allowed");
        }
        return standalone.forward(method, path, body);
    }
}
