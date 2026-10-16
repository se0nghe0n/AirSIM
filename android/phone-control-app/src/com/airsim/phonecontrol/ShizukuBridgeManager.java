package com.airsim.phonecontrol;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.IBinder;
import android.os.Handler;
import android.os.Looper;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import rikka.shizuku.Shizuku;

final class ShizukuBridgeManager {
    interface DialerRoleCallback {
        void onResult(boolean success, String detail);
    }

    static final int PERMISSION_REQUEST = 7301;
    static final String MANAGER_PACKAGE = "moe.shizuku.privileged.api";
    static final String DOWNLOAD_URL = "https://shizuku.rikka.app/zh-hans/download/";
    record StartupSnapshot(boolean installed, boolean running, boolean authorized) {}
    private static volatile ShizukuBridgeManager instance;

    private final Context app;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
    private final MuteRequestRetrier muteRetrier;
    private final AtomicBoolean statusRefreshInFlight = new AtomicBoolean();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object roleLock = new Object();
    private final Shizuku.UserServiceArgs serviceArgs;
    private volatile String status = "等待 Shizuku";
    private volatile boolean binding;
    private volatile PrivilegedBridgeClient privilegedClient;
    private DialerRoleCallback pendingRoleCallback;
    private boolean roleRequestInFlight;
    private int bindAttempt;

    private final Shizuku.OnBinderReceivedListener binderReceived = this::onBinderReceived;
    private final Shizuku.OnBinderDeadListener binderDead = this::onBinderDead;
    private final Shizuku.OnRequestPermissionResultListener permissionResult = (requestCode, grantResult) -> {
        if (requestCode != PERMISSION_REQUEST) return;
        if (grantResult == PackageManager.PERMISSION_GRANTED) {
            BridgeLog.info("shizuku_permission_granted");
            bindPrivilegedService();
        } else {
            status = "Shizuku 授权被拒绝";
            BridgeLog.info("shizuku_permission_denied");
            finishDialerRoleRequest(false, "Shizuku 授权被拒绝");
        }
    };

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            binding = false;
            worker.execute(() -> {
                try {
                    if (privilegedClient != null && privilegedClient.isProcessTransport()) return;
                    PrivilegedBridgeClient client = new PrivilegedBridgeClient(binder);
                    privilegedClient = client;
                    coordinator.connect(client);
                    status = "Shizuku 已连接 · " + client.status();
                    BridgeLog.info("shizuku_user_service_connected " + status);
                    runPendingDialerRoleRequest(client);
                } catch (Exception error) {
                    status = "Shizuku 服务启动失败";
                    privilegedClient = null;
                    coordinator.disconnect();
                    BridgeLog.error("shizuku_user_service_connect_failed", error);
                    finishDialerRoleRequest(false, "Shizuku 服务启动失败");
                }
            });
        }

        @Override public void onServiceDisconnected(ComponentName name) {
            if (privilegedClient != null && privilegedClient.isProcessTransport()) return;
            binding = false;
            privilegedClient = null;
            coordinator.disconnect();
            status = "Shizuku 服务已断开";
            BridgeLog.info("shizuku_user_service_disconnected");
            finishDialerRoleRequest(false, "Shizuku 服务已断开");
        }
    };

    private ShizukuBridgeManager(Context context) {
        app = context.getApplicationContext();
        muteRetrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
            @Override public void execute(Runnable task) { worker.execute(task); }
            @Override public void schedule(Runnable task, long delayMillis) {
                mainHandler.postDelayed(() -> worker.execute(task), delayMillis);
            }
        }, coordinator::setLocalOutputMuted, (muted, error) -> {
            if (error != null) {
                status = "本机通话静音失败";
                BridgeLog.error("shizuku_local_output_failed target_muted=" + muted, error);
            } else if (privilegedClient != null) {
                status = "Shizuku 已连接 · " + coordinator.lastResult();
                BridgeLog.info("shizuku_local_output target_muted=" + muted
                        + " result=" + coordinator.lastResult());
            } else {
                BridgeLog.info("shizuku_local_output_queued target_muted=" + muted);
            }
        });
        serviceArgs = new Shizuku.UserServiceArgs(new ComponentName(
                app.getPackageName(), ShizukuBridgeUserService.class.getName()))
                .daemon(true)
                .processNameSuffix("pcm_shell")
                .debuggable(true)
                .tag("airsim-pcm-v1")
                // Bump when the embedded bridge or its lifecycle changes so an
                // APK update cannot keep Vivo/Samsung running an old daemon.
                .version(8);
        Shizuku.addBinderReceivedListenerSticky(binderReceived);
        Shizuku.addBinderDeadListener(binderDead);
        Shizuku.addRequestPermissionResultListener(permissionResult);
    }

    static ShizukuBridgeManager initialize(Context context) {
        return get(context);
    }

    static ShizukuBridgeManager get(Context context) {
        ShizukuBridgeManager value = instance;
        if (value != null) return value;
        synchronized (ShizukuBridgeManager.class) {
            if (instance == null) instance = new ShizukuBridgeManager(context);
            return instance;
        }
    }

    private void onBinderReceived() {
        try {
            int uid = Shizuku.getUid();
            int version = Shizuku.getVersion();
            status = "Shizuku 在线 · UID " + uid;
            BridgeLog.info("shizuku_binder_received uid=" + uid + " version=" + version);
            if (Shizuku.isPreV11() || version < 13) {
                status = "Shizuku 版本过低，需要 v13+";
                return;
            }
            if (!PrivilegedBridgeProtocol.supportsUid(uid)) {
                status = "Shizuku 权限身份无效";
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                bindPrivilegedService();
            } else {
                status = "Shizuku 在线，等待授权";
            }
        } catch (RuntimeException error) {
            status = "Shizuku 检测失败";
            BridgeLog.error("shizuku_binder_check_failed", error);
        }
    }

    private void onBinderDead() {
        binding = false;
        if (privilegedClient != null) privilegedClient.close();
        privilegedClient = null;
        privilegedClient = null;
        coordinator.disconnect();
        status = "Shizuku 未运行";
        BridgeLog.info("shizuku_binder_dead");
        finishDialerRoleRequest(false, "Shizuku 未运行");
    }

    void requestPermission() {
        try {
            if (!Shizuku.pingBinder()) {
                status = "请先启动 Shizuku";
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                bindPrivilegedService();
            } else if (Shizuku.shouldShowRequestPermissionRationale()) {
                status = "请在 Shizuku 中允许 AirSIM";
            } else {
                Shizuku.requestPermission(PERMISSION_REQUEST);
                status = "等待 Shizuku 授权";
            }
        } catch (RuntimeException error) {
            status = "Shizuku 请求失败";
            BridgeLog.error("shizuku_permission_request_failed", error);
        }
    }

    void ensureStarted() {
        if (!Shizuku.pingBinder()) {
            status = "Shizuku 未运行";
            return;
        }
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            status = "Shizuku 在线，等待授权";
            return;
        }
        bindPrivilegedService();
    }

    boolean dialerRoleAutomationAuthorized() {
        try {
            return Shizuku.pingBinder()
                    && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
        } catch (RuntimeException error) {
            return false;
        }
    }

    boolean dialerRoleAutomationAvailable() {
        try { return Shizuku.pingBinder(); }
        catch (RuntimeException error) { return false; }
    }

    StartupSnapshot startupSnapshot() {
        boolean installed = false;
        try {
            app.getPackageManager().getPackageInfo(MANAGER_PACKAGE, 0);
            installed = true;
        } catch (PackageManager.NameNotFoundException ignored) {
            // Both APK manifests declare package visibility for the manager.
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_package_check_failed", error);
        }
        boolean running = dialerRoleAutomationAvailable();
        return new StartupSnapshot(installed || running, running,
                running && dialerRoleAutomationAuthorized());
    }

    void ensureDialerRole(boolean requestPermission, DialerRoleCallback callback) {
        synchronized (roleLock) {
            pendingRoleCallback = callback;
        }
        try {
            if (!Shizuku.pingBinder()) {
                finishDialerRoleRequest(false, "Shizuku 未运行");
                return;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                PrivilegedBridgeClient client = privilegedClient;
                if (client != null) runPendingDialerRoleRequest(client);
                else bindPrivilegedService();
                return;
            }
            if (!requestPermission) {
                finishDialerRoleRequest(false, "Shizuku 尚未授权");
            } else if (Shizuku.shouldShowRequestPermissionRationale()) {
                finishDialerRoleRequest(false, "请在 Shizuku 中允许 AirSIM");
            } else {
                status = "等待 Shizuku 授权";
                Shizuku.requestPermission(PERMISSION_REQUEST);
            }
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_dialer_role_prepare_failed", error);
            finishDialerRoleRequest(false, "Shizuku 请求失败");
        }
    }

    private void runPendingDialerRoleRequest(PrivilegedBridgeClient client) {
        DialerRoleCallback callback;
        synchronized (roleLock) {
            if (pendingRoleCallback == null || roleRequestInFlight) return;
            roleRequestInFlight = true;
            callback = pendingRoleCallback;
        }
        worker.execute(() -> {
            try {
                String result = client.ensureDialerRole();
                BridgeLog.info("shizuku_dialer_role_applied result=" + result);
                finishDialerRoleRequest(callback, true, result);
            } catch (Exception error) {
                BridgeLog.error("shizuku_dialer_role_failed", error);
                finishDialerRoleRequest(callback, false, "系统未接受默认电话角色");
            }
        });
    }

    private void finishDialerRoleRequest(boolean success, String detail) {
        DialerRoleCallback callback;
        synchronized (roleLock) {
            callback = pendingRoleCallback;
        }
        if (callback != null) finishDialerRoleRequest(callback, success, detail);
    }

    private void finishDialerRoleRequest(
            DialerRoleCallback callback, boolean success, String detail) {
        boolean deliver;
        synchronized (roleLock) {
            deliver = pendingRoleCallback == callback;
            if (deliver) pendingRoleCallback = null;
            roleRequestInFlight = false;
        }
        if (deliver) mainHandler.post(() -> callback.onResult(success, detail));
    }

    void setLocalOutputMuted(boolean muted) {
        muteRetrier.request(muted);
    }

    private void bindPrivilegedService() {
        if (binding || privilegedClient != null) return;
        binding = true;
        int attempt = ++bindAttempt;
        status = "正在启动 Shizuku PCM 服务";
        try {
            Shizuku.bindUserService(serviceArgs, connection);
            mainHandler.postDelayed(() -> {
                if (binding && bindAttempt == attempt) worker.execute(() -> bindProcessFallback(attempt));
            }, 5000);
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_user_service_bind_failed", error);
            worker.execute(() -> bindProcessFallback(attempt));
        }
    }

    private void bindProcessFallback(int attempt) {
        if (!binding || bindAttempt != attempt || privilegedClient != null) return;
        PrivilegedBridgeClient client = null;
        try {
            client = PrivilegedBridgeClient.openProcess(app);
            coordinator.connect(client);
            privilegedClient = client;
            status = "Shizuku 已连接 · Q25 process · " + client.status();
            BridgeLog.info("shizuku_q25_process_connected " + status);
            runPendingDialerRoleRequest(client);
        } catch (Exception error) {
            if (client != null) client.close();
            coordinator.disconnect();
            status = "Shizuku Q25 服务启动失败";
            BridgeLog.error("shizuku_q25_process_failed", error);
            finishDialerRoleRequest(false, "Shizuku Q25 服务启动失败");
        } finally {
            binding = false;
        }
    }

    String status() {
        return status;
    }

    boolean bridgeRunning() {
        return coordinator.bridgeRunning();
    }

    void refreshBridgeStatus() {
        if (privilegedClient == null || !statusRefreshInFlight.compareAndSet(false, true)) return;
        worker.execute(() -> {
            try {
                if (privilegedClient != null) {
                    status = "Shizuku 已连接 · " + coordinator.refreshStatus();
                }
            } catch (Exception error) {
                status = "Shizuku PCM 状态检查失败";
                BridgeLog.error("shizuku_pcm_status_refresh_failed", error);
            } finally {
                statusRefreshInFlight.set(false);
            }
        });
    }

    void openShizuku() {
        Intent launch = app.getPackageManager().getLaunchIntentForPackage(MANAGER_PACKAGE);
        if (launch == null) {
            status = "未安装 Shizuku";
            return;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { app.startActivity(launch); }
        catch (RuntimeException error) {
            status = "无法打开 Shizuku";
            BridgeLog.error("shizuku_open_failed", error);
        }
    }
}
