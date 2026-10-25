package com.airsim.phonecontrol;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.role.RoleManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CountDownTimer;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.telecom.TelecomManager;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;
import org.json.JSONArray;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int ROLE_REQUEST = 100;
    private static final int DEFAULT_APPS_REQUEST = 102;
    private static final int OPTIONAL_SMS_REQUEST = 103;
    private static final int OPTIONAL_CALL_HISTORY_REQUEST = 106;
    private static final int CALL_ACCOUNT_PERMISSION_REQUEST = 104;
    private static final int SHIZUKU_SETUP_REQUEST = 105;
    private static final String SHIZUKU_STARTUP_CHECKED = "shizuku_startup_checked";
    private static final String OPTIONAL_SMS_PROMPTED = "optional_sms_prompted";
    private static final java.util.concurrent.ExecutorService SMS_SCAN_WORKER =
            Executors.newSingleThreadExecutor();

    private static final int BG = Color.rgb(8, 14, 20);
    private static final int SURFACE = Color.rgb(17, 28, 39);
    private static final int SURFACE_HIGH = Color.rgb(23, 36, 49);
    private static final int BORDER = Color.rgb(42, 58, 73);
    private static final int PRIMARY = Color.rgb(52, 229, 170);
    private static final int CYAN = Color.rgb(73, 231, 224);
    private static final int BLUE = Color.rgb(47, 128, 237);
    private static final int TEXT = Color.rgb(244, 247, 250);
    private static final int MUTED = Color.rgb(166, 179, 193);
    private static final int WARNING = Color.rgb(255, 184, 77);
    private static final int DANGER = Color.rgb(255, 99, 99);

    private enum Page { STATUS, CALLS, DEBUG, SETTINGS }
    private enum Feature { VOWLAN, AGENT, MEDIA, PUSH, SHIZUKU }

    private FrameLayout contentHost;
    private LinearLayout bottomBar;
    private final List<TextView> navigationItems = new ArrayList<>();
    private Page currentPage = Page.STATUS;
    private HealthTile mediaHealthTile;
    private LiveStatusPoller mediaStatusPoller;
    private boolean resumed;

    private EditText endpoint;
    private EditText token;
    private EditText number;
    private String selectedMode;
    private TextView status;
    private TextView shizukuStatus;
	private TextView installerStatus;
    private TextView pairingStatus;
    private TextView pairingCodeView;
    private TextView pairingCountdownView;
    private LinearLayout debugRows;
    private String lastRenderedDebugLog;
    private String lastRenderedDebugFilter;
    private TextView agentRefreshResult;
    private String agentRefreshMessage = "Tap Refresh to view the latest Agent response";
    private int agentRefreshColor = MUTED;
    private int agentRefreshGeneration;
    private String activeDebugFilter = "All";
    private boolean realtimeLogging = true;
    private boolean agentOnline;
    private String agentDetail = "Not checked";
    private boolean pushConfigured;
    private String pushDetail = "Not checked";
    private String pushDiagnostic = "Agent push status has not been checked";
	private boolean cloudEnabled;
	private boolean cloudRelayConfigured;
	private String cloudLastError = "";
	private boolean avfStartupPromptShown;
	private boolean crashPromptShown;
    private ShizukuStartupPolicy shizukuStartupPolicy;
    private boolean startupSetupPending;
    private boolean startupSetupInFlight;
    private boolean startupSetupCompleted;
    private AlertDialog shizukuStartupDialog;
    private final Runnable startupSetup = () -> {
        if (startupSetupPending) continueStartupSetup();
    };

    private PairingServer pairingServer;
    private CountDownTimer pairingCountdown;
    private String pairingCode = "";
    private long pairingExpiresAt;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable debugRefresh = new Runnable() {
        @Override public void run() {
            if (currentPage == Page.DEBUG && realtimeLogging) {
                refreshDebugLog();
                handler.postDelayed(this, 2_000);
            }
        }
    };
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        shizukuStartupPolicy = new ShizukuStartupPolicy(
                state != null && state.getBoolean(SHIZUKU_STARTUP_CHECKED, false));
        mediaStatusPoller = new LiveStatusPoller(() -> {
            ShizukuBridgeManager bridge = ShizukuBridgeManager.get(this);
            bridge.refreshBridgeStatus();
            return bridge.bridgeRunning();
        }, this::renderMediaStatus, new LiveStatusPoller.Scheduler() {
            @Override public void postDelayed(Runnable task, long delayMillis) {
                handler.postDelayed(task, delayMillis);
            }
            @Override public void removeCallbacks(Runnable task) {
                handler.removeCallbacks(task);
            }
        }, 1_000);
        configureWindow();
        setContentView(buildShell());
        showPage(Page.STATUS);
        Uri data = getIntent().getData();
        if (Intent.ACTION_DIAL.equals(getIntent().getAction()) && data != null) {
            showPage(Page.CALLS);
            if (number != null) number.setText(data.getSchemeSpecificPart());
        }
        refreshStatus();
        refreshAgent();
		String[] missingPermissions = RuntimePermissionPolicy.missingPermissions(
				Build.VERSION.SDK_INT,
				checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS) == PackageManager.PERMISSION_GRANTED,
				Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
						== PackageManager.PERMISSION_GRANTED);
		if (missingPermissions.length > 0) {
            requestPermissions(missingPermissions, 101);
		} else {
			requestOptionalSMSPermission();
		}
    }

	@Override public void onRequestPermissionsResult(
			int requestCode, String[] permissions, int[] grantResults) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults);
		if (requestCode == 101) requestOptionalSMSPermission();
		if (requestCode == OPTIONAL_SMS_REQUEST) {
			startSMSInboxBaselineIfAuthorized();
			requestOptionalCallHistoryPermission();
			if (currentPage == Page.SETTINGS) showPage(Page.SETTINGS);
		}
        if (requestCode == OPTIONAL_CALL_HISTORY_REQUEST) continueStartupSetup();
		if (requestCode == CALL_ACCOUNT_PERMISSION_REQUEST && currentPage == Page.SETTINGS) {
			showPage(Page.SETTINGS);
		}
	}

	private void requestOptionalSMSPermission() {
		boolean granted = checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED;
		boolean prompted = getPreferences(MODE_PRIVATE).getBoolean(OPTIONAL_SMS_PROMPTED, false);
		String[] missing = RuntimePermissionPolicy.optionalInboxPermissions(granted, prompted);
		if (missing.length == 0) {
			requestOptionalCallHistoryPermission();
			return;
		}
		getPreferences(MODE_PRIVATE).edit().putBoolean(OPTIONAL_SMS_PROMPTED, true).apply();
		requestPermissions(missing, OPTIONAL_SMS_REQUEST);
	}

    private void requestOptionalCallHistoryPermission() {
        String key = "optional_call_history_prompted";
        String[] missing = RuntimePermissionPolicy.optionalCallHistoryPermissions(
                checkSelfPermission(Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED,
                getPreferences(MODE_PRIVATE).getBoolean(key, false));
        if (missing.length == 0) {
            continueStartupSetup();
            return;
        }
        getPreferences(MODE_PRIVATE).edit().putBoolean(key, true).apply();
        requestPermissions(missing, OPTIONAL_CALL_HISTORY_REQUEST);
    }

	private void startSMSInboxBaselineIfAuthorized() {
		if (checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
			SMS_SCAN_WORKER.execute(() -> SMSInboxScanner.scanIfDue(getApplicationContext()));
		}
	}

    private void configureWindow() {
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        getWindow().getDecorView().setSystemUiVisibility(0);
    }

    private View buildShell() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        root.setFitsSystemWindows(false);

        contentHost = new FrameLayout(this);
        root.addView(contentHost, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        bottomBar = buildBottomBar();
        root.addView(bottomBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(78)));

        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                view.setPadding(0, bars.top, 0, bars.bottom);
            } else {
                view.setPadding(0, insets.getSystemWindowInsetTop(), 0,
                        insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        return root;
    }

    private LinearLayout buildBottomBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER);
        bar.setPadding(dp(10), dp(6), dp(10), dp(8));
        bar.setBackground(rounded(SURFACE, 28, BORDER, 1));
        navigationItems.clear();
        bar.addView(navigationItem("Status", android.R.drawable.presence_online, Page.STATUS), weighted());
        bar.addView(navigationItem("Calls", android.R.drawable.sym_action_call, Page.CALLS), weighted());
        bar.addView(navigationItem("Debug", android.R.drawable.ic_menu_info_details, Page.DEBUG), weighted());
        bar.addView(navigationItem("Settings", android.R.drawable.ic_menu_preferences, Page.SETTINGS), weighted());
        return bar;
    }

    private TextView navigationItem(String title, int icon, Page page) {
        TextView item = label(title, 12, MUTED, Gravity.CENTER);
        item.setCompoundDrawablesWithIntrinsicBounds(0, icon, 0, 0);
        item.setCompoundDrawableTintList(ColorStateList.valueOf(MUTED));
        item.setCompoundDrawablePadding(dp(3));
        item.setPadding(dp(4), dp(4), dp(4), dp(4));
        item.setOnClickListener(ignored -> showPage(page));
        item.setTag(page);
        navigationItems.add(item);
        return item;
    }

    private void showPage(Page page) {
        if (mediaStatusPoller != null) mediaStatusPoller.stop();
        mediaHealthTile = null;
        currentPage = page;
        handler.removeCallbacks(debugRefresh);
        bottomBar.setVisibility(View.VISIBLE);
        contentHost.removeAllViews();
        View content;
        switch (page) {
        case CALLS: content = callsPage(); break;
        case DEBUG: content = debugPage(); break;
        case SETTINGS: content = settingsPage(); break;
        case STATUS:
        default: content = statusPage(); break;
        }
        contentHost.addView(content, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        updateNavigation();
        if (page == Page.DEBUG && realtimeLogging) handler.post(debugRefresh);
        if (page == Page.STATUS && resumed) mediaStatusPoller.start();
    }

    private void updateNavigation() {
        for (TextView item : navigationItems) {
            boolean selected = item.getTag() == currentPage;
            int color = selected ? PRIMARY : MUTED;
            item.setTextColor(color);
            item.setTypeface(Typeface.DEFAULT, selected ? Typeface.BOLD : Typeface.NORMAL);
            item.setCompoundDrawableTintList(ColorStateList.valueOf(color));
        }
    }

    private View statusPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("AirSIM Bridge", "Running"));

        boolean paired = VoWLANPairingStore.configured(this);
        LinearLayout hero = card(SURFACE_HIGH, 24);
        hero.setOrientation(LinearLayout.HORIZONTAL);
        hero.setGravity(Gravity.CENTER_VERTICAL);
        hero.setPadding(dp(18), dp(20), dp(18), dp(20));
        ImageView wifi = icon(android.R.drawable.ic_menu_share, CYAN, 54);
        wifi.setBackground(rounded(Color.rgb(20, 80, 73), 28, Color.TRANSPARENT, 0));
        wifi.setPadding(dp(14), dp(14), dp(14), dp(14));
        hero.addView(wifi, new LinearLayout.LayoutParams(dp(58), dp(58)));
        LinearLayout heroCopy = column(dp(14));
        TextView heroTitle = label(
                paired ? (vowlanReady() ? "VoWLAN ready" : "Preparing VoWLAN") : "VoWLAN not paired",
                25, vowlanReady() ? CYAN : WARNING, Gravity.START);
        heroTitle.setTypeface(Typeface.DEFAULT_BOLD);
        heroCopy.addView(heroTitle);
        heroCopy.addView(label(vowlanNetworkLine(), 14, MUTED, Gravity.START));
        hero.addView(heroCopy, weighted());
        hero.setClickable(true);
        hero.setOnClickListener(ignored -> showFeatureDetails(Feature.VOWLAN));
        root.addView(hero, matchWithTop(16));

        String connectionMode = MainScreenPresentation.connectionModeTitle(
                vowlanReady(), cloudEnabled, cloudRelayConfigured, cloudLastError);
        String connectionDetail = MainScreenPresentation.connectionModeDetail(
                vowlanReady(), cloudEnabled, cloudRelayConfigured, cloudLastError);
        int connectionColor = vowlanReady() ? CYAN
                : cloudEnabled && cloudRelayConfigured && cloudLastError.isEmpty() ? BLUE : WARNING;
        LinearLayout connectionCard = card(SURFACE, 18);
        connectionCard.setOrientation(LinearLayout.VERTICAL);
        connectionCard.setPadding(dp(16), dp(14), dp(16), dp(14));
        connectionCard.addView(overline("Current connection mode"));
        TextView connectionTitle = label(connectionMode, 18, connectionColor, Gravity.START);
        connectionTitle.setTypeface(Typeface.DEFAULT_BOLD);
        connectionCard.addView(connectionTitle, matchWithTop(5));
        connectionCard.addView(label(connectionDetail, 13, MUTED, Gravity.START), matchWithTop(5));
        root.addView(connectionCard, matchWithTop(12));

        LinearLayout firstHealthRow = row();
        HealthTile agentTile = healthTile(
                RuntimeMode.agentLabel(this), agentOnline ? "Online" : agentDetail,
                android.R.drawable.ic_menu_manage, agentOnline);
        agentTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.AGENT));
        firstHealthRow.addView(agentTile.view, weightedWithEnd(5));
        mediaHealthTile = healthTile(
                "WebRTC media service", mediaServiceReady() ? "Running" : "Not running",
                android.R.drawable.ic_media_play, mediaServiceReady());
        mediaHealthTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.MEDIA));
        firstHealthRow.addView(mediaHealthTile.view, weightedWithStart(5));
        root.addView(firstHealthRow, matchWithTop(12));

        LinearLayout secondHealthRow = row();
        HealthTile pushTile = healthTile(
                "Push / Relay", pushDetail,
                android.R.drawable.stat_notify_sync, pushConfigured);
        pushTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.PUSH));
        secondHealthRow.addView(pushTile.view, weightedWithEnd(5));
        HealthTile shizukuTile = healthTile(
                "Shizuku", shizukuReady() ? "Authorized" : "Authorization required",
                android.R.drawable.ic_lock_idle_lock, shizukuReady());
        shizukuTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.SHIZUKU));
        secondHealthRow.addView(shizukuTile.view, weightedWithStart(5));
        root.addView(secondHealthRow, matchWithTop(10));

        root.addView(modeSelector(), matchWithTop(14));

        TextView pairing = primaryButton(paired ? "Pair iPhone again" : "Pair a new iPhone", BLUE);
        pairing.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_input_add, 0, 0, 0);
        pairing.setCompoundDrawableTintList(ColorStateList.valueOf(Color.WHITE));
        pairing.setCompoundDrawablePadding(dp(8));
        pairing.setOnClickListener(ignored -> openPairingPage());
        root.addView(pairing, matchWithTop(14));

        root.addView(sectionTitle("Recent activity"), matchWithTop(22));
        LinearLayout recent = card(SURFACE, 18);
        recent.setPadding(dp(16), dp(14), dp(16), dp(14));
        recent.setOrientation(LinearLayout.HORIZONTAL);
        recent.setGravity(Gravity.CENTER_VERTICAL);
        View dot = new View(this);
        dot.setBackground(rounded(PRIMARY, 7, Color.TRANSPARENT, 0));
        recent.addView(dot, new LinearLayout.LayoutParams(dp(10), dp(10)));
        TextView activity = label(latestActivity(), 14, TEXT, Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams activityParams = weighted();
        activityParams.leftMargin = dp(12);
        recent.addView(activity, activityParams);
        recent.setOnClickListener(ignored -> showPage(Page.DEBUG));
        root.addView(recent, matchWithTop(10));

        status = label("", 12, MUTED, Gravity.START);
        status.setVisibility(View.GONE);
        root.addView(status);
        return scroll(root);
    }

    private View callsPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("Call control", null));
        root.addView(description("Local Android Telecom control. iPhone calls use VoWLAN when available, then fall back to the cloud relay."), matchWithTop(8));

        LinearLayout dialCard = card(SURFACE, 24);
        dialCard.setOrientation(LinearLayout.VERTICAL);
        dialCard.setPadding(dp(18), dp(18), dp(18), dp(18));
        dialCard.addView(overline("Phone number"));
        number = input("Enter phone number", InputType.TYPE_CLASS_PHONE);
        dialCard.addView(number, matchWithTop(8));
        TextView call = primaryButton("Call via system Telecom", PRIMARY);
        call.setTextColor(BG);
        call.setOnClickListener(ignored -> placeSystemCall());
        dialCard.addView(call, matchWithTop(14));
        root.addView(dialCard, matchWithTop(18));

        root.addView(sectionTitle("Current call"), matchWithTop(22));
        LinearLayout actions = row();
        TextView answer = secondaryButton("Answer on Android");
        answer.setOnClickListener(ignored -> localCall("answer"));
        TextView hangup = secondaryButton("End call");
        hangup.setTextColor(DANGER);
        hangup.setOnClickListener(ignored -> localCall("end"));
        actions.addView(answer, weightedWithEnd(5));
        actions.addView(hangup, weightedWithStart(5));
        root.addView(actions, matchWithTop(10));

        LinearLayout roleCard = card(SURFACE, 20);
        roleCard.setOrientation(LinearLayout.VERTICAL);
        roleCard.setPadding(dp(16), dp(14), dp(16), dp(14));
        roleCard.addView(label(roleText(), 15, TEXT, Gravity.START));
        roleCard.addView(description("Emergency calls are always handled by the system dialer."), matchWithTop(4));
        roleCard.setOnClickListener(ignored -> requestDialerRole());
        root.addView(roleCard, matchWithTop(18));
        return scroll(root);
    }

    private View debugPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("Debug diagnostics", null));
		if (CrashReportStore.hasReport(getFilesDir())) {
			LinearLayout crashCard = card(Color.rgb(57, 31, 36), 22);
			crashCard.setOrientation(LinearLayout.VERTICAL);
			crashCard.setPadding(dp(16), dp(15), dp(16), dp(15));
			TextView title = label("Previous crash detected", 16, DANGER, Gravity.START);
			title.setTypeface(Typeface.DEFAULT_BOLD);
			crashCard.addView(title);
			crashCard.addView(label("The redacted report is stored on this device. It is only shared when you tap Send.",
					12, MUTED, Gravity.START), matchWithTop(4));
			LinearLayout crashActions = row();
			TextView send = secondaryButton("Send crash report");
			send.setTextColor(PRIMARY);
			send.setOnClickListener(ignored -> shareCrashReport());
			TextView remove = secondaryButton("Delete report");
			remove.setTextColor(DANGER);
			remove.setOnClickListener(ignored -> {
				CrashReportStore.clear(getFilesDir());
				toast("Crash report deleted");
				showPage(Page.DEBUG);
			});
			crashActions.addView(send, weightedWithEnd(5));
			crashActions.addView(remove, weightedWithStart(5));
			crashCard.addView(crashActions, matchWithTop(12));
			root.addView(crashCard, matchWithTop(12));
		}
        root.addView(debugFilters(), matchWithTop(14));

        LinearLayout logCard = card(SURFACE, 22);
        logCard.setOrientation(LinearLayout.VERTICAL);
        logCard.setPadding(dp(12), dp(4), dp(12), dp(4));
        debugRows = column(0);
        lastRenderedDebugLog = null;
        lastRenderedDebugFilter = null;
        logCard.addView(debugRows);
        root.addView(logCard, matchWithTop(14));

        LinearLayout actions = row();
        TextView copy = secondaryButton("Copy logs");
        copy.setOnClickListener(ignored -> copyDebugLog());
        TextView export = secondaryButton("Export diagnostics");
        export.setOnClickListener(ignored -> exportDebugLog());
        actions.addView(copy, weightedWithEnd(5));
        actions.addView(export, weightedWithStart(5));
        root.addView(actions, matchWithTop(12));

        LinearLayout live = card(SURFACE, 20);
        live.setOrientation(LinearLayout.HORIZONTAL);
        live.setGravity(Gravity.CENTER_VERTICAL);
        live.setPadding(dp(16), dp(14), dp(12), dp(14));
        LinearLayout liveCopy = column(0);
        liveCopy.addView(label("Live logging", 15, TEXT, Gravity.START));
        liveCopy.addView(label("Automatically refresh the latest logs", 12, MUTED, Gravity.START));
        live.addView(liveCopy, weighted());
        Switch toggle = new Switch(this);
        toggle.setChecked(realtimeLogging);
        toggle.setThumbTintList(ColorStateList.valueOf(PRIMARY));
        toggle.setOnCheckedChangeListener((ignored, enabled) -> {
            realtimeLogging = enabled;
            handler.removeCallbacks(debugRefresh);
            if (enabled) handler.post(debugRefresh);
        });
        live.addView(toggle);
        root.addView(live, matchWithTop(12));

        LinearLayout destructive = row();
        TextView refresh = secondaryButton("Refresh now");
        refresh.setOnClickListener(ignored -> refreshDebugLog());
        TextView clear = secondaryButton("Clear logs");
        clear.setTextColor(DANGER);
        clear.setOnClickListener(ignored -> { BridgeLog.clear(); refreshDebugLog(); });
        destructive.addView(refresh, weightedWithEnd(5));
        destructive.addView(clear, weightedWithStart(5));
        root.addView(destructive, matchWithTop(10));
        refreshDebugLog();
        return scroll(root);
    }

    private View settingsPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("Settings", null));

        boolean standaloneRuntime = RuntimeMode.isStandalone(this);
        root.addView(sectionTitle(RuntimeMode.agentLabel(this)), matchWithTop(18));
        LinearLayout agentCard = card(SURFACE, 22);
        agentCard.setOrientation(LinearLayout.VERTICAL);
        agentCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        if (standaloneRuntime) {
            agentCard.addView(label("The Agent runs in this app's foreground service. It does not use AVF, Linux Terminal, or ports 8575 and 8576.",
                    14, TEXT, Gravity.START));
        } else {
            endpoint = input("Agent address", InputType.TYPE_CLASS_TEXT);
            endpoint.setText(AppConfig.endpoint(this));
            agentCard.addView(endpoint);
            token = input("Control token", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
            token.setText(AppConfig.token(this));
            agentCard.addView(token, matchWithTop(10));
        }
        selectedMode = AppConfig.mode(this);
        agentCard.addView(modeSelector(), matchWithTop(12));
        TextView save = primaryButton(standaloneRuntime ? "Save mode and start built-in Agent" : "Save settings and start watchdog", BLUE);
        save.setOnClickListener(ignored -> saveConfiguration());
        agentCard.addView(save, matchWithTop(12));
        root.addView(agentCard, matchWithTop(10));

        root.addView(sectionTitle("Default calling SIM"), matchWithTop(22));
        LinearLayout callAccountCard = card(SURFACE, 22);
        callAccountCard.setOrientation(LinearLayout.VERTICAL);
        callAccountCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        DefaultCallAccount.Snapshot accounts = DefaultCallAccount.snapshot(this);
        String accountKey = DefaultCallAccount.selectedKey(this);
        boolean available = accountKey.isEmpty() || accounts.accounts().stream()
                .anyMatch(account -> account.key().equals(accountKey));
        callAccountCard.addView(label(DefaultCallAccount.selectedLabel(this)
                + (available ? "" : " · Currently unavailable"), 14, available ? TEXT : WARNING, Gravity.START));
        callAccountCard.addView(description("Used for AirSIM VoWLAN and cloud calls. Does not change the system calling or SMS SIM."
                + "If the selected SIM is disabled or removed, calling stops until you select another SIM."), matchWithTop(6));
        if (!accounts.error().isEmpty()) {
            callAccountCard.addView(description(accounts.error()), matchWithTop(6));
        } else if (accounts.accounts().isEmpty()) {
            callAccountCard.addView(description("No enabled calling SIMs"), matchWithTop(6));
        }
        TextView chooseAccount = secondaryButton("Choose default calling SIM");
        chooseAccount.setOnClickListener(ignored -> chooseDefaultCallAccount());
        callAccountCard.addView(chooseAccount, matchWithTop(10));
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            TextView grantAccountPermission = secondaryButton("Allow access to calling SIMs");
            grantAccountPermission.setOnClickListener(ignored -> requestPermissions(
                    new String[] {Manifest.permission.READ_PHONE_STATE}, CALL_ACCOUNT_PERMISSION_REQUEST));
            callAccountCard.addView(grantAccountPermission, matchWithTop(10));
        }
        root.addView(callAccountCard, matchWithTop(10));

		root.addView(sectionTitle("SMS inbox fallback"), matchWithTop(22));
		LinearLayout smsCard = card(SURFACE, 22);
		smsCard.setOrientation(LinearLayout.VERTICAL);
		smsCard.setPadding(dp(16), dp(16), dp(16), dp(16));
		boolean inboxGranted = checkSelfPermission(Manifest.permission.READ_SMS)
				== PackageManager.PERMISSION_GRANTED;
		smsCard.addView(label(inboxGranted ? "Authorized · Scans newly received messages only"
				: "Not authorized · SMS broadcasts are still used", 14, TEXT, Gravity.START));
		smsCard.addView(description("Optional permission to retrieve new messages when broadcasts are missed. Existing messages are not imported."), matchWithTop(6));
		if (!inboxGranted) {
			TextView permissionAction = secondaryButton("Allow SMS access in system settings");
			permissionAction.setOnClickListener(ignored -> startActivity(new Intent(
					Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
					Uri.parse("package:" + getPackageName()))));
			smsCard.addView(permissionAction, matchWithTop(10));
		}
		root.addView(smsCard, matchWithTop(10));

		if (!standaloneRuntime) {
		root.addView(sectionTitle("Initial AVF Linux setup"), matchWithTop(22));
		LinearLayout bootstrapCard = card(SURFACE, 22);
		bootstrapCard.setOrientation(LinearLayout.VERTICAL);
		bootstrapCard.setPadding(dp(16), dp(16), dp(16), dp(16));
		AVFEnvironmentDetector.Snapshot avf = AVFEnvironmentDetector.inspect(this);
		bootstrapCard.addView(label(avfEnvironmentSummary(avf), 14, TEXT, Gravity.START));
		TextView installCommand = label(AVFStartupPolicy.installCommand(), 12, MUTED, Gravity.START);
		installCommand.setTextIsSelectable(true);
		installCommand.setPadding(0, dp(10), 0, dp(4));
		bootstrapCard.addView(installCommand);
		LinearLayout bootstrapActions = row();
		TextView copyInstall = secondaryButton("Copy installation command");
		copyInstall.setOnClickListener(ignored -> copyAVFInstallCommand());
		TextView openLinux = secondaryButton(avf.state() == AVFStartupPolicy.State.RUNNING
				? "Open Linux Terminal" : "Start Linux Terminal");
		openLinux.setOnClickListener(ignored -> openAVFTerminalOrSettings());
		bootstrapActions.addView(copyInstall, weightedWithEnd(5));
		bootstrapActions.addView(openLinux, weightedWithStart(5));
		bootstrapCard.addView(bootstrapActions, matchWithTop(10));
		TextView developerOptions = secondaryButton("Open developer options");
		developerOptions.setOnClickListener(ignored -> AVFEnvironmentActions.openDeveloperOptions(this));
		bootstrapCard.addView(developerOptions, matchWithTop(10));
		root.addView(bootstrapCard, matchWithTop(10));

		root.addView(sectionTitle("AVF Agent management"), matchWithTop(22));
		LinearLayout installerCard = card(SURFACE, 22);
		installerCard.setOrientation(LinearLayout.VERTICAL);
		installerCard.setPadding(dp(16), dp(16), dp(16), dp(16));
		installerStatus = label("Reading installerd status…", 13, MUTED, Gravity.START);
		installerCard.addView(installerStatus);
		TextView updateAgent = primaryButton("Check and install latest Agent", BLUE);
		updateAgent.setOnClickListener(ignored -> runAgentMaintenance("update"));
		installerCard.addView(updateAgent, matchWithTop(12));
		LinearLayout installerActions = row();
		TextView repairAgent = secondaryButton("Repair current version");
		repairAgent.setOnClickListener(ignored -> runAgentMaintenance("repair"));
		TextView rollbackAgent = secondaryButton("Roll back to previous version");
		rollbackAgent.setTextColor(WARNING);
		rollbackAgent.setOnClickListener(ignored -> runAgentMaintenance("rollback"));
		installerActions.addView(repairAgent, weightedWithEnd(5));
		installerActions.addView(rollbackAgent, weightedWithStart(5));
		installerCard.addView(installerActions, matchWithTop(10));
		root.addView(installerCard, matchWithTop(10));
		refreshInstallerStatus();
		}

        root.addView(sectionTitle("Shizuku permission and WebRTC service"), matchWithTop(22));
        LinearLayout shizukuCard = card(SURFACE, 22);
        shizukuCard.setOrientation(LinearLayout.VERTICAL);
        shizukuCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        shizukuStatus = label("", 14, TEXT, Gravity.START);
        shizukuCard.addView(shizukuStatus);
        shizukuCard.addView(description("Start Shizuku with wireless debugging and authorize AirSIM once. AirSIM then restores the WebRTC service automatically."), matchWithTop(6));
        LinearLayout shizukuActions = row();
        TextView authorize = secondaryButton("Authorize and start");
        authorize.setOnClickListener(ignored -> {
            ShizukuBridgeManager.get(this).requestPermission();
            refreshShizukuStatus();
        });
        TextView open = secondaryButton("Open Shizuku");
        open.setOnClickListener(ignored -> {
            ShizukuBridgeManager.get(this).openShizuku();
            refreshShizukuStatus();
        });
        shizukuActions.addView(authorize, weightedWithEnd(5));
        shizukuActions.addView(open, weightedWithStart(5));
        shizukuCard.addView(shizukuActions, matchWithTop(12));
        root.addView(shizukuCard, matchWithTop(10));

        root.addView(sectionTitle("Dialer role and diagnostics"), matchWithTop(22));
        TextView dialer = secondaryButton("Set as default phone app");
        dialer.setOnClickListener(ignored -> requestDialerRole());
        root.addView(dialer, matchWithTop(10));
        TextView agent = secondaryButton("Refresh Agent status");
        agent.setOnClickListener(ignored -> refreshAgent(true));
        root.addView(agent, matchWithTop(10));
        agentRefreshResult = label(agentRefreshMessage, 12, agentRefreshColor, Gravity.START);
        agentRefreshResult.setPadding(dp(12), dp(8), dp(12), dp(8));
        agentRefreshResult.setBackground(rounded(SURFACE, 12, BORDER, 1));
        root.addView(agentRefreshResult, matchWithTop(6));

        CheckBox debugEnabled = new CheckBox(this);
        debugEnabled.setText("Enable debug mode");
        debugEnabled.setTextColor(TEXT);
        debugEnabled.setButtonTintList(ColorStateList.valueOf(PRIMARY));
        debugEnabled.setChecked(AppConfig.debugEnabled(this));
        debugEnabled.setOnCheckedChangeListener((ignored, enabled) -> {
            BridgeLog.setDebugEnabled(this, enabled);
            toast(enabled ? "Debug logging enabled" : "Debug logging disabled");
        });
        root.addView(debugEnabled, matchWithTop(14));
        refreshShizukuStatus();
        return scroll(root);
    }

    private void openPairingPage() {
        handler.removeCallbacks(debugRefresh);
        bottomBar.setVisibility(View.GONE);
        contentHost.removeAllViews();
        contentHost.addView(pairingPage(), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        startPairing();
    }




    private View pairingPage() {
        LinearLayout root = pageRoot();
        TextView back = label("‹", 40, TEXT, Gravity.START);
        back.setContentDescription("Back");
        back.setOnClickListener(ignored -> {
            stopPairingServer();
            showPage(Page.STATUS);
        });
        root.addView(back, new LinearLayout.LayoutParams(dp(56), dp(52)));

        TextView title = label("One-time pairing", 30, TEXT, Gravity.START);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title, matchWithTop(8));
        root.addView(description("Connect iPhone and Android to the same Wi-Fi or Android hotspot"), matchWithTop(6));

        LinearLayout pairingCard = card(SURFACE, 28);
        pairingCard.setOrientation(LinearLayout.VERTICAL);
        pairingCard.setGravity(Gravity.CENTER_HORIZONTAL);
        pairingCard.setPadding(dp(20), dp(24), dp(20), dp(24));
        pairingCard.addView(label("Pairing code (one-time)", 14, MUTED, Gravity.CENTER));
        pairingCodeView = label(
                MainScreenPresentation.formatPairingCode(pairingCode), 42, TEXT, Gravity.CENTER);
        pairingCodeView.setTypeface(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD));
        pairingCodeView.setLetterSpacing(0.05f);
        pairingCodeView.setBackground(rounded(Color.rgb(20, 32, 45), 18, BORDER, 1));
        pairingCodeView.setPadding(dp(18), dp(18), dp(18), dp(18));
        pairingCard.addView(pairingCodeView, matchWithTop(18));

        pairingCountdownView = label("Generating secure key…", 14, Color.rgb(135, 183, 238), Gravity.CENTER);
        pairingCard.addView(pairingCountdownView, matchWithTop(16));

        ImageView link = icon(android.R.drawable.ic_menu_share, CYAN, 92);
        link.setPadding(dp(22), dp(22), dp(22), dp(22));
        pairingCard.addView(link, new LinearLayout.LayoutParams(dp(112), dp(112)));

        pairingStatus = label("Checking local network and generating temporary key…", 15, TEXT, Gravity.CENTER);
        pairingStatus.setMaxLines(4);
        pairingCard.addView(pairingStatus, matchWithTop(10));
        root.addView(pairingCard, matchWithTop(20));

        TextView cancel = secondaryButton("Cancel pairing");
        cancel.setTextColor(DANGER);
        cancel.setOnClickListener(ignored -> {
            stopPairingServer();
            showPage(Page.STATUS);
        });
        root.addView(cancel, matchWithTop(18));

        TextView note = label("Temporary key · Single use only", 13, MUTED, Gravity.CENTER);
        note.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_lock_idle_lock, 0, 0, 0);
        note.setCompoundDrawableTintList(ColorStateList.valueOf(MUTED));
        note.setCompoundDrawablePadding(dp(8));
        root.addView(note, matchWithTop(20));
        return scroll(root);
    }

    private LinearLayout debugFilters() {
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        LinearLayout filterRow = row();
        String[] filters = {"All", "Agent", "VoWLAN", "WebRTC", "Telecom"};
        for (String filter : filters) {
            boolean selected = filter.equals(activeDebugFilter);
            TextView chip = label(filter, 13, selected ? BG : TEXT, Gravity.CENTER);
            chip.setTypeface(Typeface.DEFAULT, selected ? Typeface.BOLD : Typeface.NORMAL);
            chip.setPadding(dp(16), dp(9), dp(16), dp(9));
            chip.setBackground(rounded(selected ? PRIMARY : SURFACE_HIGH, 18, selected ? PRIMARY : BORDER, 1));
            LinearLayout.LayoutParams chipParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            chipParams.rightMargin = dp(8);
            filterRow.addView(chip, chipParams);
            chip.setOnClickListener(ignored -> {
                activeDebugFilter = filter;
                showPage(Page.DEBUG);
            });
        }
        scroll.addView(filterRow);
        LinearLayout holder = column(0);
        holder.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return holder;
    }

    private View modeSelector() {
        selectedMode = selectedMode == null ? AppConfig.mode(this) : selectedMode;
        LinearLayout segment = row();
        segment.setPadding(dp(3), dp(3), dp(3), dp(3));
        segment.setBackground(rounded(SURFACE_HIGH, 24, BORDER, 1));
        segment.addView(segmentItem("Remote only", AppConfig.MODE_REMOTE_SILENT), weighted());
        segment.addView(segmentItem("Show on this device", AppConfig.MODE_LOCAL_AND_PUSH), weighted());
        return segment;
    }

    private TextView segmentItem(String title, String mode) {
        boolean selected = mode.equals(selectedMode);
        TextView item = label(title, 14, selected ? PRIMARY : MUTED, Gravity.CENTER);
        item.setTypeface(Typeface.DEFAULT, selected ? Typeface.BOLD : Typeface.NORMAL);
        item.setPadding(dp(8), dp(12), dp(8), dp(12));
        item.setBackground(rounded(selected ? Color.rgb(19, 70, 61) : Color.TRANSPARENT,
                20, selected ? PRIMARY : Color.TRANSPARENT, 1));
        item.setOnClickListener(ignored -> {
            selectedMode = mode;
            if (currentPage == Page.STATUS || currentPage == Page.SETTINGS) showPage(currentPage);
        });
        return item;
    }

    private static final class HealthTile {
        final LinearLayout view;
        final ImageView icon;
        final TextView state;

        HealthTile(LinearLayout view, ImageView icon, TextView state) {
            this.view = view;
            this.icon = icon;
            this.state = state;
        }
    }

    private HealthTile healthTile(String title, String value, int iconResource, boolean healthy) {
        LinearLayout tile = card(SURFACE, 18);
        tile.setOrientation(LinearLayout.HORIZONTAL);
        tile.setGravity(Gravity.CENTER_VERTICAL);
        tile.setPadding(dp(12), dp(15), dp(12), dp(15));
        ImageView icon = icon(iconResource, healthy ? PRIMARY : WARNING, 42);
        icon.setBackground(rounded(healthy ? Color.rgb(17, 66, 57) : Color.rgb(76, 58, 25), 21,
                Color.TRANSPARENT, 0));
        icon.setPadding(dp(10), dp(10), dp(10), dp(10));
        tile.addView(icon, new LinearLayout.LayoutParams(dp(44), dp(44)));
        LinearLayout copy = column(dp(10));
        TextView heading = label(title, 13, TEXT, Gravity.START);
        heading.setSingleLine(true);
        heading.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(heading);
        TextView state = label(value, 13, healthy ? PRIMARY : WARNING, Gravity.START);
        state.setTypeface(Typeface.DEFAULT_BOLD);
        state.setSingleLine(true);
        state.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(state, matchWithTop(4));
        tile.addView(copy, weighted());
        return new HealthTile(tile, icon, state);
    }

    private void renderMediaStatus(boolean running) {
        HealthTile tile = mediaHealthTile;
        if (tile == null || currentPage != Page.STATUS) return;
        int color = running ? PRIMARY : WARNING;
        tile.state.setText(running ? "Running" : "Not running");
        tile.state.setTextColor(color);
        tile.icon.setImageTintList(ColorStateList.valueOf(color));
        tile.icon.setBackground(rounded(running ? Color.rgb(17, 66, 57) : Color.rgb(76, 58, 25),
                21, Color.TRANSPARENT, 0));
    }

    private LinearLayout pageTitle(String title, String badge) {
        LinearLayout block = column(0);
        TextView heading = label(title, 30, TEXT, Gravity.START);
        heading.setTypeface(Typeface.DEFAULT_BOLD);
        block.addView(heading);
        if (badge != null) {
            TextView chip = label(badge, 13, PRIMARY, Gravity.CENTER);
            chip.setTypeface(Typeface.DEFAULT_BOLD);
            chip.setPadding(dp(12), dp(5), dp(12), dp(5));
            chip.setBackground(rounded(Color.rgb(15, 66, 56), 16, Color.TRANSPARENT, 0));
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            params.topMargin = dp(6);
            block.addView(chip, params);
        }
        return block;
    }

    private void placeSystemCall() {
        String value = number == null ? "" : number.getText().toString().trim();
        if (value.isEmpty()) { toast("Enter a phone number"); return; }
        if (!dialerRoleHeld()) {
            toast("Set AirSIM as the default phone app first");
            requestDialerRole();
            return;
        }
        try {
            getSystemService(TelecomManager.class).placeCall(Uri.parse("tel:" + value),
                    DefaultCallAccount.dialExtras(this));
        } catch (RuntimeException error) {
            toast(error.getMessage() == null ? "System call failed" : error.getMessage());
        }
    }

    private void chooseDefaultCallAccount() {
        DefaultCallAccount.Snapshot snapshot = DefaultCallAccount.snapshot(this);
        String[] choices = new String[snapshot.accounts().size() + 1];
        choices[0] = "Use system default";
        String key = DefaultCallAccount.selectedKey(this);
        int checked = key.isEmpty() ? 0 : -1;
        for (int i = 0; i < snapshot.accounts().size(); i++) {
            DefaultCallAccount.Account account = snapshot.accounts().get(i);
            choices[i + 1] = account.label() + (account.number().isEmpty() ? "" : "\n" + account.number());
            if (key.equals(account.key())) checked = i + 1;
        }
        new AlertDialog.Builder(this).setTitle("Default calling SIM")
                .setSingleChoiceItems(choices, checked, (dialog, which) -> {
                    if (which == 0) DefaultCallAccount.followSystem(this);
                    else DefaultCallAccount.select(this, snapshot.accounts().get(which - 1));
                    dialog.dismiss();
                    showPage(Page.SETTINGS);
                    toast("Default calling SIM saved");
                }).setNegativeButton("Cancel", null).show();
    }

    private void continueStartupSetup() {
        if (isFinishing() || isDestroyed() || startupSetupInFlight) return;
        startupSetupPending = true;
        if (!resumed) return;
        ShizukuBridgeManager shizuku = ShizukuBridgeManager.get(this);
        ShizukuBridgeManager.StartupSnapshot snapshot = shizuku.startupSnapshot();
        ShizukuStartupPolicy.Prompt prompt = shizukuStartupPolicy.inspect(
                snapshot.installed(), snapshot.running(), snapshot.authorized(), true);
        startupSetupInFlight = true;
        startupSetupPending = false;
        if (prompt != ShizukuStartupPolicy.Prompt.NONE) {
            showShizukuStartupPrompt(prompt);
            return;
        }
        switch (DialerRoleSetupPolicy.initial(
                dialerRoleHeld(), shizuku.dialerRoleAutomationAuthorized())) {
            case COMPLETE -> checkAVFEnvironmentAtStartup();
            case SHIZUKU -> attemptPrivilegedDialerRole(false);
            case SYSTEM_ROLE -> requestDialerRole();
            case SETTINGS -> openDefaultAppsSettings();
        }
    }

    private void scheduleStartupSetup() {
        handler.removeCallbacks(startupSetup);
        handler.postDelayed(startupSetup, 500);
    }

    private void showShizukuStartupPrompt(ShizukuStartupPolicy.Prompt prompt) {
        String title;
        String message;
        String action;
        switch (prompt) {
            case INSTALL -> {
                title = "Shizuku installation required";
                message = "AirSIM's call audio bridge requires Shizuku. Install it, start its service, and authorize AirSIM."
                        + "\n\nOfficial download:\n" + ShizukuBridgeManager.DOWNLOAD_URL;
                action = "Download Shizuku";
            }
            case START -> {
                title = "Shizuku is not running";
                message = "Shizuku is installed but its service has not started. Open Shizuku, start it using wireless debugging or Root, then return to AirSIM."
                        + "\n\nCall audio cannot be forwarded to iPhone until it is ready.";
                action = "Open Shizuku";
            }
            case AUTHORIZE -> {
                title = "Shizuku authorization required";
                message = "Shizuku is running, but AirSIM is not authorized. Allow AirSIM to use Shizuku to start the call audio bridge."
                        + "\n\nIf previously denied, allow AirSIM under Authorized applications in Shizuku.";
                action = "Authorize";
            }
            default -> throw new IllegalArgumentException("No Shizuku prompt to present");
        }
        boolean[] awaitingAction = {false};
        shizukuStartupDialog = new AlertDialog.Builder(this).setTitle(title).setMessage(message)
                .setPositiveButton(action, (dialog, which) -> {
                    if (prompt == ShizukuStartupPolicy.Prompt.AUTHORIZE) {
                        awaitingAction[0] = true;
                        attemptPrivilegedDialerRole(true);
                    } else {
                        awaitingAction[0] = openShizukuStartupAction(prompt);
                    }
                })
                .setNegativeButton("Later", null).create();
        shizukuStartupDialog.setOnDismissListener(dialog -> {
            shizukuStartupDialog = null;
            if (!awaitingAction[0] && !isFinishing() && !isDestroyed()) {
                startupSetupInFlight = false;
                startupSetupPending = true;
                scheduleStartupSetup();
            }
        });
        shizukuStartupDialog.show();
        if (prompt == ShizukuStartupPolicy.Prompt.INSTALL) {
            TextView text = shizukuStartupDialog.findViewById(android.R.id.message);
            if (text != null) {
                // Selectable URL remains usable even if no browser is installed.
                text.setTextIsSelectable(true);
            }
        }
    }

    private boolean openShizukuStartupAction(ShizukuStartupPolicy.Prompt prompt) {
        try {
            Intent intent = prompt == ShizukuStartupPolicy.Prompt.INSTALL
                    ? new Intent(Intent.ACTION_VIEW, Uri.parse(ShizukuBridgeManager.DOWNLOAD_URL))
                    : getPackageManager().getLaunchIntentForPackage(ShizukuBridgeManager.MANAGER_PACKAGE);
            if (intent == null) {
                toast("Unable to open Shizuku. Install it from the official download page.");
                return false;
            }
            // Keep the return callback in this Activity's task, even if the
            // package manager's launch intent originally had NEW_TASK set.
            intent.setFlags(intent.getFlags() & ~Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivityForResult(intent, SHIZUKU_SETUP_REQUEST);
            return true;
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_startup_action_failed", error);
            toast("Unable to open page. Copy the official download address from the dialog.");
            return false;
        }
    }

    private void completeStartupSetup() {
        startupSetupInFlight = false;
        startupSetupPending = false;
        startupSetupCompleted = true;
        handler.post(this::maybeShowCrashReportPrompt);
    }

    private void requestDialerRole() {
        RoleManager manager = getSystemService(RoleManager.class);
        if (manager == null || !manager.isRoleAvailable(RoleManager.ROLE_DIALER)) {
            toast("This device does not support the default dialer role");
            continueAfterSystemRoleRequest();
            return;
        }
        try {
            startActivityForResult(manager.createRequestRoleIntent(RoleManager.ROLE_DIALER), ROLE_REQUEST);
        } catch (RuntimeException error) {
            BridgeLog.error("dialer_role_system_request_failed", error);
            continueAfterSystemRoleRequest();
        }
    }

    private void continueAfterSystemRoleRequest() {
        ShizukuBridgeManager shizuku = ShizukuBridgeManager.get(this);
        switch (DialerRoleSetupPolicy.afterSystemRequest(
                dialerRoleHeld(), shizuku.dialerRoleAutomationAvailable())) {
            case COMPLETE -> checkAVFEnvironmentAtStartup();
            case SHIZUKU -> attemptPrivilegedDialerRole(true);
            case SETTINGS -> openDefaultAppsSettings();
            case SYSTEM_ROLE -> requestDialerRole();
        }
    }

    private void attemptPrivilegedDialerRole(boolean requestPermission) {
        ShizukuBridgeManager.get(this).ensureDialerRole(requestPermission, (success, detail) -> {
            if (isFinishing() || isDestroyed()) return;
            refreshStatus();
            DialerRoleSetupPolicy.Action next = DialerRoleSetupPolicy.afterPrivilegedAttempt(
                    success && dialerRoleHeld());
            if (next == DialerRoleSetupPolicy.Action.COMPLETE) {
                toast("System enabled the default phone role");
                checkAVFEnvironmentAtStartup();
            } else {
                toast(detail + ". Select AirSIM in default apps.");
                openDefaultAppsSettings();
            }
        });
    }

    private void openDefaultAppsSettings() {
        Intent settings = new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS);
        try {
            startActivityForResult(settings, DEFAULT_APPS_REQUEST);
        } catch (RuntimeException error) {
            BridgeLog.error("default_apps_settings_open_failed", error);
            Intent details = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + getPackageName()));
            startActivityForResult(details, DEFAULT_APPS_REQUEST);
        }
    }

    private void localCall(String action) {
        if (!dialerRoleHeld()) {
            toast("This call belongs to another default phone app. Select AirSIM first.");
            requestDialerRole();
            return;
        }
        String callId = CallRepository.idForAction(action);
        if (callId.isEmpty()) { toast("No call available to control"); return; }
        Executors.newSingleThreadExecutor().execute(() -> {
            CallRepository.ActionResult result = CallRepository.execute(
                    MainActivity.this, new AgentCommand(UUID.randomUUID().toString(), action, callId, ""));
            runOnUiThread(() -> toast(result.success ? "Telecom confirmed" : result.error));
        });
    }

    private void refreshAgent() {
        refreshAgent(false);
    }

    private void refreshAgent(boolean showResult) {
        final int generation = ++agentRefreshGeneration;
        agentDetail = "Checking";
        if (showResult) setAgentRefreshMessage("Requesting " + AppConfig.endpoint(this)
                + " Agent status…", MUTED);
        updateVisibleStatus();
        Executors.newSingleThreadExecutor().execute(() -> {
            String address = AppConfig.endpoint(this);
            String path = AppConfig.configured(this) ? "/api/android/status" : "/api/health";
            try {
                boolean paired = AppConfig.configured(this);
                AgentClient client = new AgentClient(this);
                String payload = paired ? client.status() : client.health();
                JSONObject result = new JSONObject(payload);
                boolean healthy = result.optBoolean("ok", false);
                String profile = result.optString("runtime_profile", "Unknown");
                String detail = paired
                        ? "Endpoint: GET " + path + " · HTTP 200\nAgent: " + address
                                + "\nRuntime mode: " + profile
                                + " · Pending commands: " + result.optInt("pending_commands", 0)
                                + "\nLast active: " + result.optString("last_seen", "Not recorded")
                        : "Endpoint: GET " + path + " · HTTP 200\nAgent: " + address
                                + "\nVersion: " + result.optString("version", "Unknown")
                                + " · Runtime mode: " + profile
                                + "\nControl token: not configured";
                BridgeLog.info("agent_status_refresh path=" + path + " ok=" + healthy
                        + " profile=" + profile + " endpoint=" + address);
                runOnUiThread(() -> {
                    if (generation != agentRefreshGeneration) return;
                    agentOnline = paired && healthy;
                    agentDetail = healthy
                            ? (paired ? "Online" : "Reachable · Control token not paired")
                            : "Reachable · Agent reports not ready";
                    if (showResult) setAgentRefreshMessage(
                            (healthy ? "Refresh successful" : "Agent not ready") + "\n" + detail,
                            healthy ? PRIMARY : WARNING);
                    updateVisibleStatus();
                });
                try {
                    JSONObject pushStatus = new JSONObject(client.pushStatus());
                    runOnUiThread(() -> {
                        if (generation != agentRefreshGeneration) return;
                        updatePushStatus(pushStatus);
                        updateVisibleStatus();
                    });
                } catch (Exception error) {
                    BridgeLog.error("push_status_refresh_failed endpoint=" + address, error);
                    String pushError = error.getClass().getSimpleName() + " · " + error.getMessage();
                    runOnUiThread(() -> {
                        if (generation != agentRefreshGeneration) return;
                        pushConfigured = false;
                        pushDetail = "Status unavailable";
                        cloudRelayConfigured = false;
                        cloudLastError = DebugRedactor.sanitize(pushError);
                        pushDiagnostic = "Failed to read /api/push/status: "
                                + DebugRedactor.sanitize(pushError);
                        updateVisibleStatus();
                    });
                }
            } catch (Exception error) {
                BridgeLog.error("agent_status_refresh_failed path=" + path + " endpoint=" + address, error);
                runOnUiThread(() -> {
                    if (generation != agentRefreshGeneration) return;
                    agentOnline = false;
                    agentDetail = "Offline · " + error.getClass().getSimpleName();
                    pushConfigured = false;
                    pushDetail = "Agent unreachable";
                    cloudRelayConfigured = false;
                    cloudLastError = RuntimeMode.agentLabel(this) + " unreachable";
                    pushDiagnostic = "Restore " + RuntimeMode.agentLabel(this)
                            + "; /api/push/status cannot currently be queried.";
                    if (showResult) setAgentRefreshMessage("Refresh failed · GET " + path
                            + "\nAgent: " + address + "\nReason: "
                            + DebugRedactor.sanitize(error.getClass().getSimpleName() + " · "
                                    + String.valueOf(error.getMessage())), DANGER);
                    updateVisibleStatus();
                });
            }
        });
    }

    private void setAgentRefreshMessage(String message, int color) {
        agentRefreshMessage = message;
        agentRefreshColor = color;
        if (agentRefreshResult != null) {
            agentRefreshResult.setText(message);
            agentRefreshResult.setTextColor(color);
        }
    }

    private void updatePushStatus(JSONObject result) {
        boolean enabled = result.optBoolean("cloud_enabled", false);
        boolean calls = result.optBoolean("call_push_ready", false);
        boolean messages = result.optBoolean("message_push_ready", false);
        String relay = result.optString("relay_url", "");
        String lastError = result.optString("last_error", "");
        cloudEnabled = enabled;
        cloudRelayConfigured = enabled && result.optBoolean("configured", false) && !relay.isEmpty();
        cloudLastError = DebugRedactor.sanitize(lastError);
        pushConfigured = enabled && calls && messages;
        pushDetail = !enabled ? "Cloud disabled" : pushConfigured ? "Push configured" : "Configuration incomplete";
        pushDiagnostic = "Cloud: " + (enabled ? "On" : "Off")
                + "\nIncoming call push: " + (calls ? "Configured" : "Not ready")
                + " · SMS push: " + (messages ? "Configured" : "Not ready")
                + "\nRelay: " + (relay.isEmpty() ? "Not configured" : relay)
                + "\nAPNs environment: " + result.optString("environment", "Unknown")
                + " · WAN: " + result.optString("wan_interface", "Not detected")
                + (lastError.isEmpty() ? "" : "\nLatest error: " + DebugRedactor.sanitize(lastError))
                + "\nNote: configured does not mean the public Relay is verified reachable.";
    }

    private void showFeatureDetails(Feature feature) {
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(featureTitle(feature))
                .setMessage(featureDetails(feature, ""))
                .setPositiveButton("Close", null)
                .setNeutralButton("Check again", (ignored, which) -> showFeatureDetails(feature))
                .create();
        dialog.show();
        if (feature != Feature.AGENT && feature != Feature.PUSH) return;
        Executors.newSingleThreadExecutor().execute(() -> {
            String live;
            try {
                AgentClient client = new AgentClient(this);
                JSONObject result = new JSONObject(feature == Feature.PUSH
                        ? client.pushStatus()
                        : AppConfig.configured(this) ? client.status() : client.health());
                if (feature == Feature.PUSH) {
                    String cloudLogs;
                    try {
                        cloudLogs = cloudAgentLogs(new JSONObject(client.debugSnapshot()));
                    } catch (Exception error) {
                        cloudLogs = "Failed to read Agent cloud events: " + DebugRedactor.sanitize(
                                error.getClass().getSimpleName() + " · " + error.getMessage());
                    }
                    String liveCloudLogs = cloudLogs;
                    runOnUiThread(() -> {
                        updatePushStatus(result);
                        updateVisibleStatus();
                        if (dialog.isShowing()) dialog.setMessage(featureDetails(feature,
                                "Live query: /api/push/status · HTTP 200\n\nAgent cloud events (newest first)\n"
                                        + liveCloudLogs));
                    });
                    return;
                }
                live = "Live query: " + (AppConfig.configured(this) ? "/api/android/status" : "/api/health")
                        + " · HTTP 200\nResponse: ok=" + result.optBoolean("ok", false)
                        + " · runtime_profile=" + result.optString("runtime_profile", "Unknown")
                        + (AppConfig.configured(this)
                            ? " · pending_commands=" + result.optInt("pending_commands", 0)
                            : " · version=" + result.optString("version", "Unknown"));
            } catch (Exception error) {
                live = "Live query failed: " + DebugRedactor.sanitize(
                        error.getClass().getSimpleName() + " · " + error.getMessage());
                BridgeLog.error("feature_diagnostic_failed feature=" + feature, error);
            }
            String outcome = live;
            runOnUiThread(() -> {
                if (dialog.isShowing()) dialog.setMessage(featureDetails(feature, outcome));
            });
        });
    }

    private String cloudAgentLogs(JSONObject snapshot) {
        JSONArray events = snapshot.optJSONArray("events");
        if (events == null) return "Agent returned no event list";
        StringBuilder output = new StringBuilder();
        int count = 0;
        for (int index = events.length() - 1; index >= 0 && count < 10; index--) {
            JSONObject event = events.optJSONObject(index);
            if (event == null) continue;
            String category = event.optString("category", "");
            if (!category.equals("push") && !category.startsWith("cloud")) continue;
            if (output.length() > 0) output.append('\n');
            output.append(DebugRedactor.sanitize(event.optString("timestamp", "")))
                    .append(" · ").append(category)
                    .append(" · ").append(DebugRedactor.sanitize(event.optString("summary", "")));
            String payload = event.optString("payload", "");
            if (!payload.isEmpty()) output.append("\n  ").append(
                    payload.contains("://") ? "[Link omitted because it may contain media credentials]"
                            : DebugRedactor.sanitize(payload));
            count++;
        }
        return output.length() == 0 ? "No push / cloud events" : output.toString();
    }

    private String featureTitle(Feature feature) {
        return switch (feature) {
            case VOWLAN -> "VoWLAN connection details";
            case AGENT -> RuntimeMode.agentLabel(this) + " details";
            case MEDIA -> "WebRTC media service details";
            case PUSH -> "Push / Relay details";
            case SHIZUKU -> "Shizuku details";
        };
    }

    private String featureDetails(Feature feature, String live) {
        String log = BridgeLog.read();
        String latestVoWLAN = MainScreenPresentation.latestContaining(log, "vowlan_state");
        String currentVoWLAN = VoWLANGatewayService.currentDiagnosticState();
        String details;
        String[] keywords;
        switch (feature) {
            case VOWLAN -> {
                boolean paired = VoWLANPairingStore.configured(this);
                String address = localVoWLANAddress();
                String mediaBackend = RuntimeMode.isStandalone(this) ? "Privileged WebRTC service" : "AVF voice upgrade required";
                String reason = !paired ? "Not paired with iPhone"
                        : address.isEmpty() ? "No address available on the same Wi-Fi or Android hotspot"
                        : currentVoWLAN.contains("avf=missing") ? "AVF virtual network interface not found"
                        : currentVoWLAN.contains("agent_ready=false") ? "Agent failed the VoWLAN readiness check"
                        : currentVoWLAN.contains("media_ready=false") ? mediaBackend + "Not ready"
                        : !vowlanReady() ? "VoWLAN service has not completed the current check: " + currentVoWLAN
                        : "Current checks pass; an actual call is still needed to verify";
                details = "Pairing: " + (paired ? "Key saved" : "Not paired")
                        + "\nLocal network: " + (address.isEmpty() ? "Not found" : address)
                        + "\nStatus reason: " + reason
                        + "\nCurrent check: " + currentVoWLAN
                        + "\nLatest check: " + (latestVoWLAN.isEmpty() ? "None" : latestVoWLAN);
                keywords = new String[]{"vowlan", "pairing"};
            }
            case AGENT -> {
                boolean standalone = RuntimeMode.isStandalone(this);
                details = "Status: " + agentDetail
                        + (standalone ? "\nRuns in: this app's foreground service"
                                : "\nAddress: " + AppConfig.endpoint(this)
                                + "\nControl token: " + (AppConfig.configured(this) ? "Configured" : "Not configured"))
                        + "\nReason: " + (agentOnline ? "Latest status check passed"
                            : standalone ? "Check the foreground service, notification permission, and battery restrictions"
                            : "Check AVF Linux is running, address uses :8575, and control token matches")
                        + "\n" + agentRefreshMessage;
                keywords = new String[]{"agent", "watchdog", "http_request", "avf"};
            }
            case MEDIA -> {
                String shizuku = ShizukuBridgeManager.get(this).status();
                String mediaBackend = RuntimeMode.isStandalone(this) ? "Privileged WebRTC service" : "AVF voice upgrade required";
                String reason = !shizukuReady() ? "Shizuku is disconnected or unauthorized; WebRTC user service unavailable"
                        : currentVoWLAN.contains("media_ready=false") ? mediaBackend + " did not respond"
                        : !mediaServiceReady() ? "Native WebRTC service is unavailable"
                        : "Current checks pass; verify two-way audio with an actual call";
                details = "Shizuku: " + shizuku + "\nBridge status: " + (mediaServiceReady() ? "Running" : "Not running")
                        + "\nStatus reason: " + reason
                        + "\nCurrent VoWLAN check: " + currentVoWLAN
                        + "\nLatest VoWLAN check: " + (latestVoWLAN.isEmpty() ? "None" : latestVoWLAN);
                keywords = new String[]{"webrtc", "shizuku", "vowlan_state"};
            }
            case PUSH -> {
                details = "Status: " + pushDetail + "\n" + pushDiagnostic
                        + "\nReason: " + (agentOnline ? "Check settings, Relay address, APNs token, and latest errors"
                            : "Cannot verify cloud registration or heartbeat while Agent is unreachable");
                keywords = new String[]{"push", "relay", "pairing"};
            }
            case SHIZUKU -> {
                String shizuku = ShizukuBridgeManager.get(this).status();
                details = "Status: " + shizuku + "\nReason: " + (shizukuReady()
                        ? "Binder connected; check carrier audio routing to verify audio"
                        : "Check Shizuku is running, AirSIM is authorized, and WebRTC user service is bound");
                keywords = new String[]{"shizuku", "local_output"};
            }
            default -> throw new IllegalStateException("Unknown feature");
        }
        String recent = MainScreenPresentation.recentMatchingLogLines(log, 12, keywords);
        return details + (live.isEmpty() ? "" : "\n\n" + live)
                + "\n\nRelated logs (newest first)\n" + recent;
    }

	private void checkAVFEnvironmentAtStartup() {
		if (RuntimeMode.isStandalone(this)) {
			StandaloneAgentService.start(this);
			completeStartupSetup();
			return;
		}
		if (avfStartupPromptShown) { completeStartupSetup(); return; }
		AVFEnvironmentDetector.Snapshot snapshot = AVFEnvironmentDetector.inspect(this);
		boolean agentConfigured = AppConfig.configured(this);
		if (!AVFStartupPolicy.shouldPrompt(snapshot.state(), agentConfigured)) {
            completeStartupSetup();
            return;
        }
		avfStartupPromptShown = true;
		boolean needsInstall = snapshot.state() == AVFStartupPolicy.State.RUNNING && !agentConfigured;
		boolean canLaunch = snapshot.state() == AVFStartupPolicy.State.READY_TO_START;
		AlertDialog dialog = new AlertDialog.Builder(this)
				.setTitle(needsInstall ? "Set up AirSIM AVF Agent" : "Start the AVF Linux environment")
				.setMessage(avfEnvironmentSummary(snapshot)
						+ (needsInstall
						? "\n\nIf not installed, copy the initial installation command into Linux Terminal. " +
								"If the Agent is running, run sudo airsim-avf-pair to pair and check installerd."
						: "\n\nAfter starting Linux, paste the AirSIM installation command into Terminal."))
				.setPositiveButton(needsInstall ? "Copy initial installation command"
						: canLaunch ? "Start Linux Terminal" : "Open developer options",
						(ignored, which) -> {
							if (needsInstall) copyAVFInstallCommand();
							else if (canLaunch) openAVFTerminalOrSettings();
							else AVFEnvironmentActions.openDeveloperOptions(this);
						})
				.setNeutralButton(needsInstall ? "Open Linux Terminal" : "Copy installation command",
						(ignored, which) -> {
							if (needsInstall) openAVFTerminalOrSettings();
							else copyAVFInstallCommand();
						})
				.setNegativeButton("Later", null)
				.create();
		dialog.setOnDismissListener(ignored -> completeStartupSetup());
		dialog.show();
	}

	private String avfEnvironmentSummary(AVFEnvironmentDetector.Snapshot snapshot) {
		return switch (snapshot.state()) {
			case RUNNING -> "AVF Linux is running and ready to connect to Agent.";
			case READY_TO_START -> "AVF and Linux Terminal are available, but the Linux VM has not started.";
			case TERMINAL_DISABLED -> "Linux Terminal is included but disabled in developer options.";
			case TERMINAL_MISSING -> snapshot.restrictedChinaOEM()
					? "This ROM does not include AOSP Linux Terminal. AirSIM cannot install or enable it with normal app permissions."
					: "The system declares AVF support but AOSP Linux Terminal is not installed.";
			case AVF_UNSUPPORTED -> snapshot.restrictedChinaOEM()
					? "This ROM does not expose AVF Linux to third-party apps. AirSIM cannot force it on."
					: "This system does not expose AVF. Check the system version and manufacturer support.";
		};
	}

	private void openAVFTerminalOrSettings() {
		if (!AVFEnvironmentActions.openTerminal(this)) {
			AVFEnvironmentActions.openDeveloperOptions(this);
			toast("No launchable Linux Terminal found. Enable it in developer options.");
		}
	}

	private void copyAVFInstallCommand() {
		getSystemService(ClipboardManager.class).setPrimaryClip(
				ClipData.newPlainText("AirSIM AVF installation", AVFStartupPolicy.installCommand()));
		toast("AVF installation command copied");
	}

	private void refreshInstallerStatus() {
		if (installerStatus == null) return;
		if (!AppConfig.configured(this)) {
			installerStatus.setText("Control token not paired. Complete the initial signed installation in AVF Linux Terminal, " +
					"then run sudo airsim-avf-pair and save the token above." +
					"If Agent is installed but the installer service is unavailable, check airsim-installerd in Terminal. Do not clear Linux data.");
			return;
		}
		Executors.newSingleThreadExecutor().execute(() -> {
			try {
				String value = new AgentReleaseManager(this).status();
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("installerd online\n" + value);
				});
			} catch (Exception error) {
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("installerd unavailable · " +
							error.getClass().getSimpleName() +
							". In Linux Terminal, run sudo systemctl status airsim-installerd; " +
							"do not clear Linux data.");
				});
			}
		});
	}

	private void runAgentMaintenance(String action) {
		if (!AppConfig.configured(this)) {
			if (installerStatus != null) installerStatus.setText(
					"Not paired. Complete initial AVF Linux setup and run sudo airsim-avf-pair, " +
					"then save the control token before updating, repairing, or rolling back.");
			return;
		}
		if (installerStatus != null) installerStatus.setText("Agent operation in progress · " + action);
		Executors.newSingleThreadExecutor().execute(() -> {
			try {
				AgentReleaseManager manager = new AgentReleaseManager(this);
				String result = switch (action) {
					case "repair" -> manager.repairLatest();
					case "rollback" -> manager.rollback();
					default -> manager.installLatest();
				};
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("Agent operation completed\n" + result);
					toast("AVF Agent operation completed");
					refreshAgent();
				});
			} catch (Exception error) {
				BridgeLog.error("avf_agent_maintenance_failed action=" + action, error);
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("Agent operation failed · " + error.getMessage());
					toast("AVF Agent operation failed");
				});
			}
		});
	}

    private void updateVisibleStatus() {
        if (status != null) status.setText(roleText() + "\nAgent: " + agentDetail);
        if (currentPage == Page.STATUS && contentHost != null
                && bottomBar.getVisibility() == View.VISIBLE) showPage(Page.STATUS);
    }

    private void startPairing() {
        stopPairingServer();
        if (pairingStatus != null) pairingStatus.setText("Checking local network and generating temporary key…");
        pairingServer = new PairingServer(this, new PairingServer.Listener() {
            @Override public void onStarted(String code, String address, long expiresAtMillis) {
                BridgeLog.info("pairing_started address=" + address + " expires_at=" + expiresAtMillis);
                pairingCode = code;
                pairingExpiresAt = expiresAtMillis;
                runOnUiThread(() -> {
                    if (pairingCodeView != null) pairingCodeView.setText(
                            MainScreenPresentation.formatPairingCode(code));
                    if (pairingStatus != null) pairingStatus.setText("Waiting for iPhone to connect…\n" + address);
                    startPairingCountdown();
                });
            }

            @Override public void onSucceeded(String agentResponse) {
                BridgeLog.info("pairing_completed");
                boolean localMode = false;
                try {
                    localMode = new JSONObject(agentResponse).optBoolean("local_mode", false);
                } catch (Exception ignored) {
                    // Older Agent responses do not carry a mode marker.
                }
                boolean pairedLocally = localMode;
                runOnUiThread(() -> {
                    cancelPairingCountdown();
                    if (pairingCodeView != null) {
                        pairingCodeView.setText("Pairing successful");
                        pairingCodeView.setTextSize(28);
                    }
                    if (pairingCountdownView != null) pairingCountdownView.setText("VoWLAN key securely saved");
                    if (pairingStatus != null) pairingStatus.setText(pairedLocally
                            ? "Local mode enabled; Relay and push are not used"
                            : "iOS push identity saved to Android Agent");
                    refreshAgent();
                });
            }

            @Override public void onFailed(String message) {
                BridgeLog.error("pairing_failed", new IllegalStateException(message));
                runOnUiThread(() -> {
                    cancelPairingCountdown();
                    if (pairingCountdownView != null) pairingCountdownView.setText("Pairing window closed");
                    if (pairingStatus != null) pairingStatus.setText("Pairing failed: " + message);
                });
            }
        });
        pairingServer.start();
    }

    private void startPairingCountdown() {
        cancelPairingCountdown();
        long remaining = Math.max(0, pairingExpiresAt - System.currentTimeMillis());
        pairingCountdown = new CountDownTimer(remaining, 1_000) {
            @Override public void onTick(long millisUntilFinished) {
                long seconds = millisUntilFinished / 1_000;
                if (pairingCountdownView != null) pairingCountdownView.setText(
                        String.format(java.util.Locale.US, "%02d:%02d until expiry", seconds / 60, seconds % 60));
            }

            @Override public void onFinish() {
                if (pairingCountdownView != null) pairingCountdownView.setText("Pairing window expired");
            }
        }.start();
    }

    private void cancelPairingCountdown() {
        if (pairingCountdown != null) pairingCountdown.cancel();
        pairingCountdown = null;
    }

    private void stopPairingServer() {
        cancelPairingCountdown();
        PairingServer active = pairingServer;
        pairingServer = null;
        if (active != null) {
            try { active.close(); }
            catch (Exception error) { BridgeLog.error("pairing_close", error); }
        }
    }

    private void refreshStatus() {
        refreshShizukuStatus();
    }

    private void refreshShizukuStatus() {
        if (shizukuStatus != null) shizukuStatus.setText(ShizukuBridgeManager.get(this).status());
    }

    private void refreshDebugLog() {
        if (debugRows == null) return;
        String log = BridgeLog.read();
        if (log.equals(lastRenderedDebugLog) && activeDebugFilter.equals(lastRenderedDebugFilter)) return;
        lastRenderedDebugLog = log;
        lastRenderedDebugFilter = activeDebugFilter;
        debugRows.removeAllViews();
        String visible = MainScreenPresentation.recentLogLines(
                log, activeDebugFilter, 60);
        if (visible.startsWith("No debug logs") || visible.startsWith("No logs in this category")) {
            TextView empty = description(visible);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(dp(8), dp(28), dp(8), dp(28));
            debugRows.addView(empty);
            return;
        }
        String[] lines = visible.split("\\R");
        for (int index = 0; index < lines.length; index++) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.TOP);
            row.setPadding(dp(2), dp(6), dp(2), dp(6));

            View dot = new View(this);
            dot.setBackground(rounded(MainScreenPresentation.isErrorLog(lines[index]) ? DANGER : PRIMARY,
                    4, Color.TRANSPARENT, 0));
            LinearLayout.LayoutParams dotParams = new LinearLayout.LayoutParams(dp(7), dp(7));
            dotParams.topMargin = dp(5);
            row.addView(dot, dotParams);

            LinearLayout copy = column(dp(9));
            TextView metadata = label(MainScreenPresentation.logMetadata(lines[index]),
                    10, MUTED, Gravity.START);
            copy.addView(metadata);
            TextView title = label(MainScreenPresentation.activitySummary(lines[index]),
                    13, TEXT, Gravity.START);
            title.setTypeface(Typeface.DEFAULT_BOLD);
            copy.addView(title, matchWithTop(1));
            TextView detail = label(MainScreenPresentation.eventBody(lines[index]),
                    11, MUTED, Gravity.START);
            detail.setTypeface(Typeface.MONOSPACE);
            copy.addView(detail, matchWithTop(1));
            row.addView(copy, weighted());
            debugRows.addView(row);

            if (index < lines.length - 1) {
                View divider = new View(this);
                divider.setBackgroundColor(BORDER);
                LinearLayout.LayoutParams dividerParams = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(1));
                dividerParams.leftMargin = dp(18);
                debugRows.addView(divider, dividerParams);
            }
        }
    }

    private void copyDebugLog() {
        String value = BridgeLog.read();
        getSystemService(ClipboardManager.class).setPrimaryClip(
                ClipData.newPlainText("AirSIM Debug Log", value));
        toast("Logs copied");
    }

    private void exportDebugLog() {
        Intent share = new Intent(Intent.ACTION_SEND);
        share.setType("text/plain");
        share.putExtra(Intent.EXTRA_SUBJECT, "AirSIM Android diagnostics");
        share.putExtra(Intent.EXTRA_TEXT, BridgeLog.read());
        startActivity(Intent.createChooser(share, "Export diagnostics"));
    }

	private void shareCrashReport() {
		String payload = CrashReportSharePayload.compose(
				CrashReportStore.read(getFilesDir()), BridgeLog.read());
		if (payload.isBlank()) {
			toast("No crash report");
			return;
		}
		Intent share = new Intent(Intent.ACTION_SEND);
		share.setType("text/plain");
		share.putExtra(Intent.EXTRA_SUBJECT, "AirSIM Android crash report");
		share.putExtra(Intent.EXTRA_TEXT, payload);
		startActivity(Intent.createChooser(share, "Send crash report"));
	}

	private void maybeShowCrashReportPrompt() {
		if (crashPromptShown || !resumed || startupSetupInFlight || isFinishing() || isDestroyed()
                || !CrashReportStore.hasReport(getFilesDir())) return;
		crashPromptShown = true;
		new AlertDialog.Builder(this)
				.setTitle("Previous crash detected")
				.setMessage("AirSIM saved a redacted report on this device. It is not uploaded automatically. Send it to the developer now?")
				.setPositiveButton("Send", (ignored, which) -> shareCrashReport())
				.setNeutralButton("View", (ignored, which) -> showPage(Page.DEBUG))
				.setNegativeButton("Later", null)
				.show();
	}

    private void saveConfiguration() {
        try {
            if (RuntimeMode.isStandalone(this)) {
                AppConfig.save(this, "", "", selectedMode);
            } else {
                AppConfig.save(this, endpoint.getText().toString(), token.getText().toString(), selectedMode);
            }
            AgentWatchdogService.start(this);
            toast(RuntimeMode.isStandalone(this)
                    ? "Mode saved; starting built-in Agent" : "Settings saved; starting watchdog service");
            refreshAgent();
        } catch (IllegalArgumentException error) {
            toast(error.getMessage());
        }
    }

    private String roleText() {
        return "Default phone role: " + (dialerRoleHeld() ? "Enabled" : "Disabled");
    }

    private boolean dialerRoleHeld() {
        RoleManager manager = getSystemService(RoleManager.class);
        return manager != null && manager.isRoleAvailable(RoleManager.ROLE_DIALER)
                && manager.isRoleHeld(RoleManager.ROLE_DIALER);
    }

    private String vowlanNetworkLine() {
        String host = localVoWLANAddress();
        return host.isEmpty() ? "Same Wi-Fi / Android hotspot" : "Same Wi-Fi · " + host;
    }

    private boolean vowlanReady() {
        String state = VoWLANGatewayService.currentDiagnosticState();
        return dialerRoleHeld() && VoWLANPairingStore.configured(this) && !localVoWLANAddress().isEmpty()
                && state.contains("paired=true") && state.contains("agent_ready=true")
                && state.contains("pcm_ready=true") && state.contains("dialer_role=true")
                && !state.contains("avf=missing");
    }

    private String localVoWLANAddress() {
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            while (interfaces.hasMoreElements()) {
                NetworkInterface item = interfaces.nextElement();
                if (!item.isUp() || item.isLoopback()) continue;
                Enumeration<InetAddress> addresses = item.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    InetAddress address = addresses.nextElement();
                    if (address instanceof Inet4Address
                            && VoWLANNetworkPolicy.isVoWLANInterface(item.getName(), address.getHostAddress())) {
                        return address.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {}
        return "";
    }

    private boolean shizukuReady() {
        String value = ShizukuBridgeManager.get(this).status();
        return value.contains("Shizuku connected");
    }

    private boolean mediaServiceReady() {
        return ShizukuBridgeManager.get(this).bridgeRunning();
    }

    private String latestActivity() {
        String line = MainScreenPresentation.recentLogLines(BridgeLog.read(), "", 1);
        return "No debug logs".equals(line)
                ? "Waiting for connection activity"
                : "Just now · " + MainScreenPresentation.activitySummary(line);
    }

    private LinearLayout pageRoot() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(18), dp(20), dp(18), dp(30));
        root.setBackgroundColor(BG);
        return root;
    }

    private ScrollView scroll(View content) {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(false);
        scroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        scroll.addView(content, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return scroll;
    }

    private LinearLayout card(int color, int radius) {
        LinearLayout card = new LinearLayout(this);
        card.setBackground(rounded(color, radius, BORDER, 1));
        return card;
    }

    private LinearLayout row() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        return row;
    }

    private LinearLayout column(int startPadding) {
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        if (startPadding > 0) column.setPadding(startPadding, 0, 0, 0);
        return column;
    }

    private TextView sectionTitle(String value) {
        TextView title = label(value, 18, TEXT, Gravity.START);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        return title;
    }

    private TextView overline(String value) {
        TextView text = label(value, 12, MUTED, Gravity.START);
        text.setLetterSpacing(0.04f);
        return text;
    }

    private TextView description(String value) {
        TextView text = label(value, 13, MUTED, Gravity.START);
        text.setLineSpacing(dp(2), 1f);
        return text;
    }

    private TextView label(String value, int sp, int color, int gravity) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setGravity(gravity);
        view.setFontFeatureSettings("kern");
        return view;
    }

    private EditText input(String hint, int type) {
        EditText view = new EditText(this);
        view.setHint(hint);
        view.setHintTextColor(MUTED);
        view.setTextColor(TEXT);
        view.setTextSize(15);
        view.setInputType(type);
        view.setSingleLine(true);
        view.setPadding(dp(14), dp(11), dp(14), dp(11));
        view.setBackground(rounded(SURFACE_HIGH, 15, BORDER, 1));
        return view;
    }

    private TextView primaryButton(String title, int color) {
        TextView button = label(title, 16, Color.WHITE, Gravity.CENTER);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setMinHeight(dp(54));
        button.setPadding(dp(16), dp(13), dp(16), dp(13));
        button.setBackground(rounded(color, 20, color, 1));
        button.setClickable(true);
        button.setFocusable(true);
        return button;
    }

    private TextView secondaryButton(String title) {
        TextView button = label(title, 14, TEXT, Gravity.CENTER);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setMinHeight(dp(50));
        button.setPadding(dp(12), dp(12), dp(12), dp(12));
        button.setBackground(rounded(SURFACE_HIGH, 18, BORDER, 1));
        button.setClickable(true);
        button.setFocusable(true);
        return button;
    }

    private ImageView icon(int resource, int tint, int contentSize) {
        ImageView view = new ImageView(this);
        view.setImageResource(resource);
        view.setImageTintList(ColorStateList.valueOf(tint));
        view.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        view.setMinimumWidth(dp(contentSize));
        view.setMinimumHeight(dp(contentSize));
        return view;
    }

    private GradientDrawable rounded(int color, int radius, int strokeColor, int strokeWidth) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(dp(radius));
        if (strokeWidth > 0 && strokeColor != Color.TRANSPARENT) {
            drawable.setStroke(dp(strokeWidth), strokeColor);
        }
        return drawable;
    }

    private LinearLayout.LayoutParams weighted() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
    }

    private LinearLayout.LayoutParams weightedWithStart(int start) {
        LinearLayout.LayoutParams params = weighted();
        params.leftMargin = dp(start);
        return params;
    }

    private LinearLayout.LayoutParams weightedWithEnd(int end) {
        LinearLayout.LayoutParams params = weighted();
        params.rightMargin = dp(end);
        return params;
    }

    private LinearLayout.LayoutParams matchWithTop(int top) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(top);
        return params;
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        refreshStatus();
        if (request == ROLE_REQUEST) {
            continueAfterSystemRoleRequest();
        } else if (request == DEFAULT_APPS_REQUEST) {
            if (dialerRoleHeld()) checkAVFEnvironmentAtStartup();
            else {
                toast("AirSIM still does not have the default phone role");
                completeStartupSetup();
            }
        } else if (request == SHIZUKU_SETUP_REQUEST) {
            startupSetupInFlight = false;
            startupSetupPending = true;
            scheduleStartupSetup();
        }
    }

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        if (startupSetupPending) scheduleStartupSetup();
        if (currentPage == Page.STATUS && mediaStatusPoller != null) mediaStatusPoller.start();
        refreshShizukuStatus();
		startSMSInboxBaselineIfAuthorized();
        if (startupSetupCompleted && !startupSetupPending && !startupSetupInFlight) {
            handler.post(this::maybeShowCrashReportPrompt);
        }
    }

    @Override protected void onPause() {
        resumed = false;
        if (mediaStatusPoller != null) mediaStatusPoller.stop();
        super.onPause();
    }

    @Override public void onBackPressed() {
        if (bottomBar != null && bottomBar.getVisibility() == View.GONE) {
            stopPairingServer();
            showPage(Page.STATUS);
            return;
        }
        if (currentPage != Page.STATUS) {
            showPage(Page.STATUS);
            return;
        }
        super.onBackPressed();
    }

    @Override protected void onDestroy() {
        handler.removeCallbacks(startupSetup);
        if (shizukuStartupDialog != null) {
            shizukuStartupDialog.setOnDismissListener(null);
            shizukuStartupDialog.dismiss();
        }
        if (mediaStatusPoller != null) mediaStatusPoller.stop();
        handler.removeCallbacks(debugRefresh);
        stopPairingServer();
        super.onDestroy();
    }

    @Override protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean(SHIZUKU_STARTUP_CHECKED, shizukuStartupPolicy.checked());
        super.onSaveInstanceState(outState);
    }
}
