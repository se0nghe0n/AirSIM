package com.airsim.phonecontrol;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.app.role.RoleManager;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.IBinder;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.util.Enumeration;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class VoWLANGatewayService extends Service {
    // DJOneHub owns 7590/7591 on devices where both apps are installed.
    // AirSIM advertises these independent ports through Bonjour.
    public static final int CONTROL_PORT = 7592;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final NotificationUpdateGate notificationGate = new NotificationUpdateGate();
    private volatile boolean running;
    private VoWLANControlGateway control;
    private NsdManager.RegistrationListener advertisement;
    private String activeHotspot = "";
    private String lastDiagnosticState = "";
    private static volatile String currentDiagnosticState = "Not checked";

    static String currentDiagnosticState() {
        return currentDiagnosticState;
    }

    public static void start(Context context) {
        BridgeLog.debug("vowlan_service_start_requested");
        try { context.startForegroundService(new Intent(context, VoWLANGatewayService.class)); }
        catch (RuntimeException error) { BridgeLog.error("vowlan_service_start_failed", error); }
    }

    @Override public void onCreate() {
        super.onCreate();
        currentDiagnosticState = "Service starting";
        BridgeLog.info("vowlan_service_created");
        startForeground(BridgeNotification.VOWLAN_ID, BridgeNotification.vowlan(this, "Discovering VoWLAN network"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
        running = true;
        worker.execute(this::lifecycleLoop);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void lifecycleLoop() {
        while (running) {
            try {
                Inet4Address hotspot = findAddress();
                if (hotspot == null && hasVoWLANCall()) {
                    BridgeLog.info("hotspot_lost_no_midcall_handover action=end_current_call");
                    CallRepository.disconnectAll();
                }
                boolean paired = VoWLANPairingStore.configured(this);
                RoleManager roleManager = getSystemService(RoleManager.class);
                boolean dialerRoleHeld = roleManager != null
                        && roleManager.isRoleAvailable(RoleManager.ROLE_DIALER)
                        && roleManager.isRoleHeld(RoleManager.ROLE_DIALER);
                boolean agentReady = false;
                boolean mediaReady = false;
                if (hotspot != null && paired) {
                    boolean sameRunningGateway = hotspot.getHostAddress().equals(activeHotspot)
                            && control != null && control.localPort() > 0;
                    if (sameRunningGateway) {
                        agentReady = true;
                        mediaReady = ShizukuBridgeManager.get(this).mediaAvailable();
                    } else {
                        try {
                            String status = new AgentClient(this).status();
                            agentReady = status.contains("\"configured\":true") || status.contains("\"ok\":true");
                        } catch (Exception error) {
                            BridgeLog.error("vowlan_agent_probe_failed", error);
                        }
                        mediaReady = ShizukuBridgeManager.get(this).mediaAvailable();
                    }
                }
                diagnosticState(hotspot, paired, agentReady, mediaReady, dialerRoleHeld);
                if (VoWLANNetworkPolicy.shouldAdvertise(
                        hotspot != null, paired, agentReady, mediaReady, dialerRoleHeld)) {
                    ensureStarted(hotspot);
                    update("VoWLAN ready · " + hotspot.getHostAddress());
                } else {
                    stopGateways();
                    update(!dialerRoleHeld ? "Set AirSIM as the default phone app"
                            : !paired ? "VoWLAN not paired"
                            : hotspot == null ? "Waiting for the same Wi-Fi or Android hotspot"
                            : !agentReady ? "Built-in Agent not ready" : "Privileged WebRTC service not ready");
                }
                Thread.sleep(5_000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                currentDiagnosticState = "Service error: " + error.getClass().getSimpleName();
                BridgeLog.error("vowlan_lifecycle_failed", error);
                stopGateways();
                update("Restoring VoWLAN");
                try { Thread.sleep(2_000); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private synchronized void ensureStarted(Inet4Address hotspot) throws Exception {
        String host = hotspot.getHostAddress();
        if (host.equals(activeHotspot) && control != null && control.localPort() > 0 && advertisement != null) return;
        stopGateways();
        VoWLANControlGateway nextControl = new VoWLANControlGateway(this);
        nextControl.start(hotspot, CONTROL_PORT);
        control = nextControl;
        activeHotspot = host;
        if (control.localPort() != CONTROL_PORT) {
            BridgeLog.info("vowlan_preferred_port_occupied control_port=" + control.localPort());
        }
        advertise();
        BridgeLog.info("vowlan_ready hotspot=" + host + " control_port=" + control.localPort()
                + " audio=webrtc_host_ice carrier_device=in_process");
    }

    private void advertise() {
        NsdServiceInfo info = new NsdServiceInfo();
        String agentID = AndroidAgentIdentity.agentID(this);
        String kind = "standalone";
        info.setServiceName("AirSIM-" + kind + "-" + agentID.substring(Math.max(0, agentID.length() - 8)));
        info.setServiceType("_airsim-vowlan._tcp.");
        info.setPort(control.localPort());
        info.setAttribute("v", "1");
        info.setAttribute("agent_id", agentID);
        info.setAttribute("agent_kind", kind);
        info.setAttribute("device_name", AndroidAgentIdentity.deviceName());
        info.setAttribute("manufacturer", android.os.Build.MANUFACTURER);
        info.setAttribute("model", android.os.Build.MODEL);
        info.setAttribute("host", activeHotspot);
        info.setAttribute("control_port", Integer.toString(control.localPort()));
        info.setAttribute("caps", "control,webrtc");
        advertisement = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo ignored) {}
            @Override public void onRegistrationFailed(NsdServiceInfo ignored, int code) {
                BridgeLog.info("vowlan_advertisement_failed code=" + code);
            }
            @Override public void onServiceUnregistered(NsdServiceInfo ignored) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo ignored, int code) {}
        };
        getSystemService(NsdManager.class).registerService(info, NsdManager.PROTOCOL_DNS_SD, advertisement);
    }

    private synchronized void stopGateways() {
        if (advertisement != null) {
            try { getSystemService(NsdManager.class).unregisterService(advertisement); }
            catch (IllegalArgumentException ignored) {}
            advertisement = null;
        }
        try { if (control != null) control.close(); } catch (Exception ignored) {}
        control = null;
        activeHotspot = "";
    }

    private synchronized boolean hasVoWLANCall() {
        return control != null && control.ownsCall();
    }

    private void diagnosticState(Inet4Address hotspot, boolean paired,
                                 boolean agentReady, boolean mediaReady, boolean dialerRoleHeld) {
        String value = "hotspot=" + address(hotspot) + " paired=" + paired
                + " agent_ready=" + agentReady + " media_ready=" + mediaReady
                + " dialer_role=" + dialerRoleHeld;
        currentDiagnosticState = value;
        if (!value.equals(lastDiagnosticState)) {
            lastDiagnosticState = value;
            BridgeLog.info("vowlan_state " + value);
        }
    }

    private static String address(InetAddress address) {
        return address == null ? "missing" : address.getHostAddress();
    }

    private static Inet4Address findAddress() throws Exception {
        Inet4Address wifiFallback = null;
        Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
        while (interfaces.hasMoreElements()) {
            NetworkInterface item = interfaces.nextElement();
            if (!item.isUp() || item.isLoopback()) continue;
            Enumeration<InetAddress> addresses = item.getInetAddresses();
            while (addresses.hasMoreElements()) {
                InetAddress address = addresses.nextElement();
                if (!(address instanceof Inet4Address value)) continue;
                if (VoWLANNetworkPolicy.isHotspotInterface(item.getName(), value.getHostAddress())) return value;
                if (wifiFallback == null
                        && VoWLANNetworkPolicy.isVoWLANInterface(item.getName(), value.getHostAddress())) {
                    wifiFallback = value;
                }
            }
        }
        return wifiFallback;
    }



    private void update(String detail) {
        long now = System.currentTimeMillis();
        if (!notificationGate.shouldPublish(detail, now)) return;
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.VOWLAN_ID, BridgeNotification.vowlan(this, detail));
        notificationGate.published(detail, now);
    }

    @Override public void onDestroy() {
        BridgeLog.info("vowlan_service_destroyed");
        currentDiagnosticState = "Service stopped";
        running = false;
        worker.shutdownNow();
        stopGateways();
        super.onDestroy();
    }
}
