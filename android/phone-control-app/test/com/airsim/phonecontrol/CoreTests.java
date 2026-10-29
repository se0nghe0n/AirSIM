package com.airsim.phonecontrol;

public final class CoreTests {
    public static void main(String[] args) throws Exception {
		testCloudCallDoesNotStartPCMPump();
		assertCrashReportIsSanitizedBoundedAndPersisted();
		assertCrashSharePayloadRequiresAReportAndSanitizesRecentLogs();
		assertTransientMuteFailureRetriesAndRestorationCancelsStaleRetry();
		assertMutedCallRecoversAfterThreeTransientAudioFailures();
		assertLiveStatusPollerUpdatesWithoutRebuildingPage();
		assertLiveStatusPollerRecoversAfterOneFailedRead();
		assertLiveStatusPollerRetriesFailedRender();
		assertPCMBridgeRunningUsesPrivilegedProcessStatus();
		assertPrivilegedBridgeStatusRefreshTracksProcessExit();
		assertMuteResultDoesNotHideRunningPCMBridge();
		testVoWLANControlCarriesOfferNotPCM();
		assertVoWLANFailedRejectPreservesCallOwnership();
		assertVoWLANClosedSocketStopsAcceptLoop();
		assertVoWLANIOExceptionStopsAcceptLoop();
		assertTrue(invokeIsStaleAudioBridge(
				11_414, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
						"--listen-port", "7580", "")));
		assertTrue(!invokeIsStaleAudioBridge(
				27_671, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
						"--listen-port", "7580", "")));
		assertTrue(!invokeIsStaleAudioBridge(
				11_415, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.example.UnrelatedService", "--listen-host", "127.0.0.1",
						"--listen-port", "7580", "")));
		assertTrue(!invokeIsStaleAudioBridge(
				11_416, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
						"--listen-port", "7581", "")));
		String bridgeCommand = String.join("\0", "/system/bin/app_process", "/system/bin",
				"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
				"--listen-port", "7580", "");
		assertTrue(!invokeIsStaleAudioBridgeForPackage(11_417, 27_671, bridgeCommand,
				"CLASSPATH=/data/app/~~x/com.airsim.phonecontrol-y/base.apk\0",
				"com.airsim.phonecontrol.standalone"));
		assertTrue(invokeIsStaleAudioBridgeForPackage(11_418, 27_671, bridgeCommand,
				"CLASSPATH=/data/app/~~x/com.airsim.phonecontrol.standalone-y/base.apk\0",
				"com.airsim.phonecontrol.standalone"));
		java.net.Inet4Address loopback = (java.net.Inet4Address) java.net.InetAddress.getByName("127.0.0.1");
		try (java.net.ServerSocket occupied = new java.net.ServerSocket(0, 1, loopback);
				java.net.ServerSocket fallback = VoWLANPortBinder.bind(loopback, occupied.getLocalPort(), 2)) {
			assertTrue(fallback.getLocalPort() != occupied.getLocalPort());
			assertEquals(loopback, fallback.getInetAddress());
		}
		try (java.net.ServerSocket preferred = VoWLANPortBinder.bind(loopback, 0, 2)) {
			assertTrue(preferred.getLocalPort() >= 1024);
			assertEquals(loopback, preferred.getInetAddress());
		}
		assertArrayEquals(new String[]{
				"android.permission.CALL_PHONE", "android.permission.SEND_SMS", "android.permission.RECEIVE_SMS",
				"android.permission.POST_NOTIFICATIONS"},
				invokeMissingRuntimePermissions(36, false, false, false));
		assertArrayEquals(new String[]{"android.permission.CALL_PHONE", "android.permission.SEND_SMS", "android.permission.RECEIVE_SMS"},
				invokeMissingRuntimePermissions(32, false, false, false));
		assertArrayEquals(new String[]{"android.permission.SEND_SMS", "android.permission.RECEIVE_SMS"},
				invokeMissingRuntimePermissions(36, true, false, true));
		assertArrayEquals(new String[0], invokeMissingRuntimePermissions(36, true, true, true));
		assertArrayEquals(new String[]{"android.permission.RECEIVE_SMS"},
				RuntimePermissionPolicy.missingPermissions(36, true, true, false, true, true, true));
		assertArrayEquals(new String[0], RuntimePermissionPolicy.missingPermissions(
				30, true, true, true, true, true, true));
		assertArrayEquals(new String[]{"android.permission.READ_SMS"},
				invokeOptionalInboxPermissions(false, false));
		assertArrayEquals(new String[0], invokeOptionalInboxPermissions(true, false));
		assertArrayEquals(new String[0], invokeOptionalInboxPermissions(false, true));
		String expectedSMSID = "android-sms-f50f6422425c2136f6732e6e5d469e780dc4a4ce4fcbc85645480531e263e8db";
		assertEquals(expectedSMSID, invokeSMSIdentity("+8613800000000", "Verification code 123456", 1_000L));
		assertTrue(!expectedSMSID.equals(invokeSMSIdentity("+8613800000000", "Verification code 123456", 2_000L)));
		assertEquals(1_000L, invokeProviderTimestamp(1_000L, 1_100L));
		assertEquals(1_100L, invokeProviderTimestamp(0L, 1_100L));
		assertRecentSMSIDsRetainBoundedDeliveryHistory();
		assertInboxCursorBaselinesExistingMessagesAndRetriesFailures();

		TrackingPeer failingPeer = new TrackingPeer();
		VoWLANPeerLifecycle.run(
				failingPeer,
				() -> { throw new IllegalStateException("forward failed"); },
				error -> failingPeer.writeErrorResponse());
		assertTrue(failingPeer.errorResponseWrittenWhileOpen);
		assertTrue(failingPeer.closed);

        assertEquals("dialing", TelecomStateMapper.toWireState(1));
        assertEquals("incoming", TelecomStateMapper.toWireState(2));
        assertEquals("held", TelecomStateMapper.toWireState(3));
        assertEquals("active", TelecomStateMapper.toWireState(4));
        assertEquals("ended", TelecomStateMapper.toWireState(7));
        assertEquals("unknown", TelecomStateMapper.toWireState(99));
		assertEquals("", invokeTelecomAction(() -> {}));
		assertContains(invokeTelecomAction(() -> {
			throw new SecurityException("CALL_PHONE permission required");
		}), "SecurityException: CALL_PHONE permission required");
		assertTrue(invokeSilencePolicy("remote_silent", "dialing"));
		assertTrue(invokeSilencePolicy("remote_silent", "incoming"));
		assertTrue(invokeSilencePolicy("remote_silent", "active"));
		assertTrue(invokeSilencePolicy("remote_silent", "held"));
		assertTrue(!invokeSilencePolicy("remote_silent", "ended"));
		assertTrue(!invokeSilencePolicy("local_and_push", "active"));
		assertArrayEquals(
				new String[]{"cmd", "audio", "adj-mute", "0"},
				PrivilegedBridgeProtocol.audioMuteCommand(true));
		assertArrayEquals(
				new String[]{"cmd", "audio", "adj-unmute", "0"},
				PrivilegedBridgeProtocol.audioMuteCommand(false));
		assertTrue(PrivilegedBridgeProtocol.isStreamMuted(
				"AudioManager.getStreamVolume(0) -> 0"));
		assertTrue(!PrivilegedBridgeProtocol.isStreamMuted(
				"AudioManager.getStreamVolume(0) -> 7"));
		assertTrue(PrivilegedBridgeProtocol.supportsUid(2000));
		assertTrue(PrivilegedBridgeProtocol.supportsUid(0));
		assertTrue(!PrivilegedBridgeProtocol.supportsUid(10123));
		java.util.List<String> privilegedCalls = new java.util.ArrayList<>();
		PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
		coordinator.setLocalOutputMuted(true);
		assertEquals(0, privilegedCalls.size());
		coordinator.connect(new PrivilegedBridgeCoordinator.Transport() {
			@Override public String startBridge() {
				privilegedCalls.add("start");
				return "bridge_running";
			}

			@Override public String status() {
				return "media=ready";
			}

			@Override public String setLocalOutputMuted(boolean muted) {
				privilegedCalls.add("mute=" + muted);
				return muted ? "muted" : "unmuted";
			}
		});
		assertEquals(java.util.List.of("start", "mute=true"), privilegedCalls);
		coordinator.setLocalOutputMuted(false);
		assertEquals(java.util.List.of("start", "mute=true", "mute=false"), privilegedCalls);
		coordinator.disconnect();
		coordinator.setLocalOutputMuted(true);
		assertEquals(3, privilegedCalls.size());

        String event = WireJson.callEvent("evt-1", "call-1", "incoming", "incoming", "+8613800138000", "remote_silent");
        assertContains(event, "\"event_id\":\"evt-1\"");
        assertContains(event, "\"number\":\"+8613800138000\"");
        assertEquals("[redacted]", DebugRedactor.safeNumber("+8613800138000"));
        assertEquals("call-1", DebugRedactor.safeIdentifier("call-1"));
        String redactedLog = DebugRedactor.sanitize(
                "Authorization: Bearer very-secret token=abc123456 number=+8613800138000 endpoint=10.177.99.25:7575");
        assertTrue(!redactedLog.contains("very-secret"));
        assertTrue(!redactedLog.contains("abc123456"));
        assertTrue(!redactedLog.contains("13800138000"));
        assertContains(redactedLog, "10.177.99.25:7575");

        AgentCommand command = new AgentCommand("cmd-7", "answer", "call-1", "");
        assertEquals("cmd-7", command.id);
        assertEquals("answer", command.action);
        assertEquals("call-1", command.callId);
        assertTrue(command.isSupported());
        assertTrue(!new AgentCommand("x", "wipe", "", "").isSupported());
		AgentCommand smsCommand = new AgentCommand(
				"sms-7", "send_sms", "", "+8613800138000", "Hello\nworld");
		assertTrue(smsCommand.isSupported());
		assertEquals("+8613800138000", smsCommand.number);
		assertEquals("Hello\nworld", smsCommand.message);
		java.util.concurrent.atomic.AtomicInteger telecomRuns = new java.util.concurrent.atomic.AtomicInteger();
		java.util.concurrent.atomic.AtomicInteger smsRuns = new java.util.concurrent.atomic.AtomicInteger();
		AgentCommandDispatcher.Result smsResult = AgentCommandDispatcher.execute(
				smsCommand, false,
				ignored -> {
					telecomRuns.incrementAndGet();
					return AgentCommandDispatcher.Result.success(0);
				},
				ignored -> {
					smsRuns.incrementAndGet();
					return AgentCommandDispatcher.Result.success(2);
				});
		assertTrue(smsResult.success());
		assertEquals(2, smsResult.segments());
		assertEquals(0, telecomRuns.get());
		assertEquals(1, smsRuns.get());
		assertTrue(SMSPayloadPolicy.validDestination("+86 13800138000"));
		assertTrue(!SMSPayloadPolicy.validDestination("tel:13800138000"));
		assertTrue(SMSPayloadPolicy.validBody("Test SMS"));
		assertTrue(!SMSPayloadPolicy.validBody("   \n"));
		SMSConfirmation confirmation = new SMSConfirmation(2);
		confirmation.record(0, -1);
		confirmation.record(0, -1);
		SMSConfirmation.Outcome partialSMS = confirmation.await(1);
		assertTrue(!partialSMS.complete());
		assertEquals(1, invokeConfirmedSMSSegments(partialSMS));
		confirmation.record(1, -1);
		assertTrue(confirmation.await(1).success());
		assertEquals(2, invokeConfirmedSMSSegments(confirmation.await(1)));
		SMSConfirmation failedConfirmation = new SMSConfirmation(1);
		failedConfirmation.record(0, 2);
		assertEquals(2, failedConfirmation.await(1).errorCode());
		SMSConfirmation failedMultipart = new SMSConfirmation(2);
		failedMultipart.record(0, 2);
		SMSConfirmation.Outcome failedEarly = failedMultipart.await(1);
		assertTrue(failedEarly.complete());
		assertTrue(!failedEarly.success());
		assertEquals(2, failedEarly.errorCode());
		SMSConfirmation cancelledConfirmation = new SMSConfirmation(1);
		cancelledConfirmation.record(0, 0);
		assertTrue(!cancelledConfirmation.await(1).success());
		String smsEvent = WireJson.smsEvent(
				"event-7", "android-sms-7", "10010", "Verification code \"246810\"", "2026-09-23T10:20:30Z");
		assertContains(smsEvent, "\"delivery_id\":\"android-sms-7\"");
		assertContains(smsEvent, "\"content\":\"Verification code \\\"246810\\\"\"");
		assertContains(WireJson.smsEvent("event-8", "android-sms-8", "  ",
				"Carrier reminder", "2026-10-12T06:00:00Z"), "\"sender\":\"Unknown number\"");

        assertEquals(1000L, RetryPolicy.delayMillis(0));
        assertEquals(8000L, RetryPolicy.delayMillis(3));
        assertEquals(15000L, RetryPolicy.delayMillis(20));
		assertRelayServerFailuresBackOffWithoutDelayingTransportRecovery();
        assertTrue(CommandPollingPolicy.shouldPoll(false, 0, 1_000));
        assertTrue(!CommandPollingPolicy.shouldPoll(false, 1_000, 10_000));
        assertTrue(CommandPollingPolicy.shouldPoll(false, 1_000, 16_000));
        assertTrue(!CommandPollingPolicy.shouldPoll(true, 1_000, 16_000));
        assertTrue(CommandPollingPolicy.shouldPoll(false, 16_000, 1_000));
		CallEventDeduplicator deduplicator = new CallEventDeduplicator();
		assertTrue(deduplicator.shouldSend("call-1", "incoming", "incoming", "+86138"));
		assertTrue(!deduplicator.shouldSend("call-1", "incoming", "incoming", "+86138"));
		assertTrue(deduplicator.shouldSend("call-1", "incoming", "active", "+86138"));
		deduplicator.remove("call-1");
		assertTrue(deduplicator.shouldSend("call-1", "incoming", "incoming", "+86138"));

		byte[] alicePrivate = PairingCrypto.hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
		byte[] bobPublic = PairingCrypto.hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
		assertEquals("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
				PairingCrypto.hex(PairingCrypto.sharedSecret(alicePrivate, bobPublic)));
		byte[] key = PairingCrypto.deriveKey(
				PairingCrypto.hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
				"9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", "266145");
		assertEquals("a01f0098a807d3923ac6930169d7bd73ebaba0f9cb8a31381d88f576cfef7a8d", PairingCrypto.hex(key));
		byte[] sealed = PairingCrypto.hex("000102030405060708090a0b75c99492c4401dcfc20a6a6f866ccf092fef1cf95cdce42915b5d24efa51fd61134af0e9f488d4bb0bd3b1bcad3265595a84229eaa120de59e4076434505756dad54e1aa5f1ede1d30");
		assertEquals("{\"device_id\":\"device-test\",\"device_secret\":\"secret-test\"}",
				new String(PairingCrypto.open(sealed, key, "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145"), java.nio.charset.StandardCharsets.UTF_8));
		assertEquals("AAEC_v8", PairingCrypto.base64URL(PairingCrypto.hex("000102feff")));
		try {
			sealed[20] ^= 1;
			PairingCrypto.open(sealed, key, "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145");
			throw new AssertionError("altered ciphertext must fail");
		} catch (java.security.GeneralSecurityException expected) {
			// Expected authentication failure.
		}

		PairingSession session = PairingSession.create(1_000L);
		PairingCrypto.KeyMaterial client = PairingCrypto.generateKeyMaterial();
		byte[] sessionShared = PairingCrypto.sharedSecret(client.privateRaw, session.publicKey());
		byte[] sessionKey = PairingCrypto.deriveKey(sessionShared, session.id(), session.code());
		byte[] claim = PairingCrypto.seal("registration".getBytes(java.nio.charset.StandardCharsets.UTF_8), sessionKey, session.id());
		assertEquals("registration", new String(session.claim(client.publicRaw, claim, 2_000L), java.nio.charset.StandardCharsets.UTF_8));
		try {
			session.claim(client.publicRaw, claim, 2_001L);
			throw new AssertionError("pairing replay must fail");
		} catch (java.security.GeneralSecurityException expected) {
			assertContains(expected.getMessage(), "used");
		}
		PairingSession expired = PairingSession.create(1_000L);
		try {
			expired.claim(client.publicRaw, claim, 121_001L);
			throw new AssertionError("expired pairing must fail");
		} catch (java.security.GeneralSecurityException expected) {
			assertContains(expected.getMessage(), "expired");
		}
		assertTrue(session.code().matches("[0-9]{6}"));
		assertEquals(121_000L, session.expiresAtMillis());
		byte[] vowlanSecret = PairingCrypto.hex(
				"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
		String vowlanCanonical = VoWLANAuth.canonicalRequest(
				"GET", "/v1/health", new byte[0], 1789090000L, "nonce-1");
		assertEquals("GET\n/v1/health\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n1789090000\nnonce-1",
				vowlanCanonical);
		assertEquals("xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE",
				VoWLANAuth.sign(vowlanSecret, vowlanCanonical));
		assertTrue(VoWLANAuth.verify(vowlanSecret,
				"xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE",
				vowlanCanonical, 1789090000L, 1789090001L));
		assertTrue(!VoWLANAuth.verify(vowlanSecret,
				"xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE",
				vowlanCanonical, 1789090000L, 1789090040L));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/health"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/v1/health"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/calls/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/calls/events?after=1"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/answer"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/audio/host/register"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/push/register"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/push/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/sms"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/sms/status"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/sms/send"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/sms/ack"));
		assertTrue(!VoWLANControlPolicy.allowed("POST", "/api/at"));
		assertTrue(!VoWLANControlPolicy.allowed("POST", "/api/system/update"));
		VoWLANReplayCache replayCache = new VoWLANReplayCache(30);
		assertTrue(replayCache.accept("nonce-1", 1_000L));
		assertTrue(!replayCache.accept("nonce-1", 1_001L));
		assertTrue(replayCache.accept("nonce-1", 1_031L));
		assertTrue(VoWLANControlPolicy.allowed("POST", VoWLANWebRTCControl.PATH));
		assertTrue(VoWLANNetworkPolicy.isHotspotInterface("swlan0", "10.172.46.225"));
		assertTrue(VoWLANNetworkPolicy.isHotspotInterface("ap0", "192.168.43.1"));
		assertTrue(!VoWLANNetworkPolicy.isHotspotInterface("wlan0", "192.168.2.86"));
		assertTrue(!VoWLANNetworkPolicy.isHotspotInterface("swlan0", "8.8.8.8"));
		assertTrue(VoWLANNetworkPolicy.isVoWLANInterface("wlan0", "192.168.31.203"));
		assertTrue(VoWLANNetworkPolicy.isVoWLANInterface("swlan0", "10.172.46.225"));
		assertTrue(!VoWLANNetworkPolicy.isVoWLANInterface("avf_tap_fixed", "10.177.99.12"));
		assertTrue(!VoWLANNetworkPolicy.isVoWLANInterface("rmnet0", "10.20.30.40"));
		assertTrue(VoWLANNetworkPolicy.shouldAdvertise(true, true, true, true, true));
		assertTrue(!VoWLANNetworkPolicy.shouldAdvertise(true, true, false, true, true));
		assertTrue(!VoWLANNetworkPolicy.shouldAdvertise(true, true, true, true, false));
		StandaloneLongPoll.Request eventWait = StandaloneLongPoll.parse(
				"/api/events?after=7&timeout_ms=15000", 15_000);
		assertEquals(7L, eventWait.after());
		assertEquals(15_000, eventWait.timeoutMillis());
		assertEquals(25_000, StandaloneLongPoll.parse(
				"/api/calls/events?after=0", 25_000).timeoutMillis());
		try {
			StandaloneLongPoll.parse("/api/events?after=0&timeout_ms=99", 15_000);
			throw new AssertionError("too-short event timeout must fail");
		} catch (IllegalArgumentException expected) {
			assertContains(expected.getMessage(), "timeout_ms");
		}
		StandaloneLongPoll cursor = new StandaloneLongPoll();
		java.util.concurrent.ExecutorService eventExecutor = java.util.concurrent.Executors.newSingleThreadExecutor();
		try {
			java.util.concurrent.Future<Long> waiting = eventExecutor.submit(() -> cursor.awaitChange(0, 2_000));
			long waitDeadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(1);
			while (!waiting.isDone() && cursor.waiterCount() == 0 && System.nanoTime() < waitDeadline) {
				Thread.onSpinWait();
			}
			assertEquals(1, cursor.waiterCount());
			assertEquals(1L, cursor.advance());
			assertEquals(1L, waiting.get(1, java.util.concurrent.TimeUnit.SECONDS));
		} finally {
			eventExecutor.shutdownNow();
		}
		assertTrue(TelecomRolePolicy.canExecuteCallCommand(true, "dial"));
		assertTrue(TelecomRolePolicy.canExecuteCallCommand(true, "end"));
		assertTrue(!TelecomRolePolicy.canExecuteCallCommand(false, "dial"));
		assertTrue(!TelecomRolePolicy.canExecuteCallCommand(false, "end"));
		assertTrue(TelecomRolePolicy.requiresDialerRole("dial"));
		assertTrue(TelecomRolePolicy.requiresDialerRole("end"));
		assertTrue(!TelecomRolePolicy.requiresDialerRole("send_sms"));
		assertEquals(DialerRoleSetupPolicy.Action.COMPLETE,
				DialerRoleSetupPolicy.initial(true, false));
		assertEquals(DialerRoleSetupPolicy.Action.SHIZUKU,
				DialerRoleSetupPolicy.initial(false, true));
		assertEquals(DialerRoleSetupPolicy.Action.SYSTEM_ROLE,
				DialerRoleSetupPolicy.initial(false, false));
		assertEquals(DialerRoleSetupPolicy.Action.COMPLETE,
				DialerRoleSetupPolicy.afterSystemRequest(true, false));
		assertEquals(DialerRoleSetupPolicy.Action.SHIZUKU,
				DialerRoleSetupPolicy.afterSystemRequest(false, true));
		assertEquals(DialerRoleSetupPolicy.Action.SETTINGS,
				DialerRoleSetupPolicy.afterSystemRequest(false, false));
		assertEquals(DialerRoleSetupPolicy.Action.COMPLETE,
				DialerRoleSetupPolicy.afterPrivilegedAttempt(true));
		assertEquals(DialerRoleSetupPolicy.Action.SETTINGS,
				DialerRoleSetupPolicy.afterPrivilegedAttempt(false));
		assertArrayEquals(new String[]{"cmd", "role", "add-role-holder",
				"android.app.role.DIALER", "com.airsim.phonecontrol.standalone"},
				PrivilegedBridgeProtocol.dialerRoleGrantCommand(
						"com.airsim.phonecontrol.standalone"));
		assertArrayEquals(new String[]{"cmd", "role", "get-role-holders",
				"android.app.role.DIALER"}, PrivilegedBridgeProtocol.dialerRoleQueryCommand());
		assertTrue(PrivilegedBridgeProtocol.isDialerRoleHolder(
				"com.android.contacts\ncom.airsim.phonecontrol.standalone\n",
				"com.airsim.phonecontrol.standalone"));
		assertTrue(!PrivilegedBridgeProtocol.isDialerRoleHolder(
				"com.airsim.phonecontrol.standalone.debug\n",
				"com.airsim.phonecontrol.standalone"));
		try {
			PrivilegedBridgeProtocol.dialerRoleGrantCommand("com.airsim;id");
			throw new AssertionError("unsafe package name must fail");
		} catch (IllegalArgumentException expected) {
			assertContains(expected.getMessage(), "package");
		}
		assertEquals("266 145", MainScreenPresentation.formatPairingCode("266145"));
		assertEquals(
				"22:45 VoWLAN health check passed\n22:43 VoWLAN broadcast discovered",
				MainScreenPresentation.recentLogLines(
						"22:42 Agent heartbeat normal\n22:43 VoWLAN broadcast discovered\n22:44 PCM bridge ready\n22:45 VoWLAN health check passed",
						"VoWLAN",
						2));
		assertEquals("Built-in Agent status ready",
				MainScreenPresentation.activitySummary(
						"2026-10-25T10:11:12Z standalone_status_refresh ok=true"));
		assertEquals("VoWLAN pairing complete",
				MainScreenPresentation.activitySummary("pairing_completed peer=iphone"));
		assertEquals("Shizuku WebRTC service connected",
				MainScreenPresentation.activitySummary("shizuku_user_service_connected uid=2000"));
		assertEquals("Built-in Agent started",
				MainScreenPresentation.activitySummary("standalone_agent_created"));
		assertEquals("VoWLAN service started",
				MainScreenPresentation.activitySummary("vowlan_service_created"));
		assertEquals("vowlan_state", MainScreenPresentation.activitySummary(
				"vowlan_state paired=true agent_ready=false media_ready=true"));
		assertEquals("unrecognized",
				MainScreenPresentation.activitySummary("unrecognized verbose internal entry"));
		String detailed = "2026-10-07T10:11:12Z ERROR [pool-1] "
				+ "http_request_failed method=GET path=/api/android/status duration_ms=3002 error=SocketTimeoutException";
		assertEquals("2026-10-07T10:11:12Z · ERROR · [pool-1]",
				MainScreenPresentation.logMetadata(detailed));
		assertEquals("http_request_failed method=GET path=/api/android/status duration_ms=3002 error=SocketTimeoutException",
				MainScreenPresentation.eventBody(detailed));
		assertTrue(MainScreenPresentation.isErrorLog(detailed));
		assertEquals("plain log entry", MainScreenPresentation.eventBody("plain log entry"));
		assertEquals("VoWLAN mode", MainScreenPresentation.connectionModeTitle(
				true, true, true, ""));
		assertEquals("Cloud mode", MainScreenPresentation.connectionModeTitle(
				false, true, true, ""));
		assertEquals("Cloud connection error", MainScreenPresentation.connectionModeTitle(
				false, true, true, "Push relay returned HTTP 401"));
		assertEquals("Cloud Relay configured; waiting for Agent heartbeat verification",
				MainScreenPresentation.connectionModeDetail(false, true, true, ""));
		assertEquals("vowlan_state paired=true pcm_ready=false",
				MainScreenPresentation.latestContaining(
						"push_status ok=true\nvowlan_state paired=true pcm_ready=false",
						"vowlan_state"));
		assertEquals("shizuku_binder_dead\npcm_probe_failed port=7580",
				MainScreenPresentation.recentMatchingLogLines(
						"push_status ok=true\npcm_probe_failed port=7580\nshizuku_binder_dead",
						3, "pcm", "shizuku"));
        System.out.println("phone-control core tests passed");
    }

	private static void assertRelayServerFailuresBackOffWithoutDelayingTransportRecovery() throws Exception {
		Throwable serverFailure = new RelayHTTPException(500, "relay internal error");
		assertEquals(500, RelayHTTPException.fromHandshakeStatusLine(
				"HTTP/1.1 500 Internal Server Error").statusCode());
		assertEquals(15_000L, RelayRetryPolicy.delayMillis(1, serverFailure));
		assertEquals(30_000L, RelayRetryPolicy.delayMillis(2, serverFailure));
		assertEquals(60_000L, RelayRetryPolicy.delayMillis(3, serverFailure));
		assertEquals(300_000L, RelayRetryPolicy.delayMillis(7, serverFailure));
		assertEquals(300_000L, RelayRetryPolicy.delayMillis(100, serverFailure));
		assertEquals(30_000L, RelayRetryPolicy.delayMillis(2,
				new RelayHTTPException(429, "rate limited")));
		assertEquals(2_000L, RelayRetryPolicy.delayMillis(2,
				new java.io.IOException("temporary network failure")));
	}







	private static byte[] filledBytes(int count, int value) {
		byte[] result = new byte[count];
		java.util.Arrays.fill(result, (byte) value);
		return result;
	}

	private static void assertTransientMuteFailureRetriesAndRestorationCancelsStaleRetry() {
		java.util.ArrayDeque<Runnable> immediate = new java.util.ArrayDeque<>();
		java.util.ArrayDeque<Runnable> delayed = new java.util.ArrayDeque<>();
		java.util.List<Boolean> attempts = new java.util.ArrayList<>();
		MuteRequestRetrier retrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
			@Override public void execute(Runnable task) { immediate.add(task); }
			@Override public void schedule(Runnable task, long delayMillis) { delayed.add(task); }
		}, muted -> {
			attempts.add(muted);
			if (muted && attempts.size() == 1) throw new IllegalStateException("transient binder error");
		}, (muted, error) -> {});
		retrier.request(true);
		immediate.remove().run();
		assertEquals(java.util.List.of(true), attempts);
		assertEquals(1, delayed.size());
		delayed.remove().run();
		assertEquals(java.util.List.of(true, true), attempts);

		java.util.List<Boolean> superseded = new java.util.ArrayList<>();
		MuteRequestRetrier second = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
			@Override public void execute(Runnable task) { immediate.add(task); }
			@Override public void schedule(Runnable task, long delayMillis) { delayed.add(task); }
		}, muted -> {
			superseded.add(muted);
			if (muted) throw new IllegalStateException("mute failed");
		}, (muted, error) -> {});
		second.request(true);
		immediate.remove().run();
		second.request(false);
		immediate.remove().run();
		delayed.remove().run();
		assertEquals(java.util.List.of(true, false), superseded);
	}

	private static void assertMutedCallRecoversAfterThreeTransientAudioFailures() {
		java.util.ArrayDeque<Runnable> immediate = new java.util.ArrayDeque<>();
		java.util.ArrayDeque<Runnable> delayed = new java.util.ArrayDeque<>();
		java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
		java.util.List<String> results = new java.util.ArrayList<>();
		MuteRequestRetrier retrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
			@Override public void execute(Runnable task) { immediate.add(task); }
			@Override public void schedule(Runnable task, long delayMillis) { delayed.add(task); }
		}, muted -> {
			if (!muted) throw new AssertionError("this test only requests muting");
			if (calls.incrementAndGet() <= 3) throw new IllegalStateException("temporary Shizuku failure");
		}, (muted, error) -> results.add(error == null ? "muted" : "failed"));
		retrier.request(true);
		immediate.remove().run();
		delayed.remove().run();
		delayed.remove().run();
		assertTrue(!delayed.isEmpty());
		delayed.remove().run();
		assertEquals(4, calls.get());
		assertEquals("muted", results.get(results.size() - 1));
	}

	private static void testCloudCallDoesNotStartPCMPump() throws Exception {
		boolean[] started = {false};
		CloudCallMedia.start("legacy_pcm", () -> started[0] = true);
		assertTrue(!started[0]);
		CloudCallMedia.start("", () -> started[0] = true);
		assertTrue(!started[0]);
		CloudCallMedia.start("webrtc", () -> started[0] = true);
		assertTrue(started[0]);
		assertEquals("webrtc", CloudCallMedia.WEBRTC);

		String manager = java.nio.file.Files.readString(phoneControlSource("StandaloneCloudMediaManager.java"));
		assertTrue(!manager.contains("CloudPCM"));
		assertTrue(!manager.contains("runPCM"));
		assertTrue(!manager.contains("legacy_pcm"));
		assertTrue(!manager.contains("7580"));
		assertTrue(!manager.contains("new Socket"));
		assertTrue(manager.contains("if (message.opcode() == 2) continue;"));
		assertTrue(manager.contains("startCloudCallMedia"));
		String storeSource = java.nio.file.Files.readString(phoneControlSource("StandaloneAgentStore.java"));
		String serviceSource = java.nio.file.Files.readString(phoneControlSource("StandaloneAgentService.java"));
		assertTrue(!storeSource.contains("legacy_pcm"));
		assertTrue(storeSource.contains("CloudCallMedia.start(mediaTransport, startWebRTC)"));
		assertTrue(storeSource.contains("new JSONArray().put(CloudCallMedia.WEBRTC)"));
		assertTrue(!serviceSource.contains("legacy_pcm"));
		assertTrue(serviceSource.contains("StandaloneAgentStore.applyMediaHeartbeat(identity(registration), mediaReady)"));
        assertTrue(storeSource.contains("ready ? mediaCapabilities() : new JSONArray()"));
        String bridgeSource = java.nio.file.Files.readString(phoneControlSource("ShizukuBridgeManager.java"));
        assertTrue(bridgeSource.contains("return coordinator.mediaAvailable();"));
		String peer = java.nio.file.Files.readString(phoneControlSource("WebRTCCloudPeer.java"));
        assertTrue(!peer.contains("connectPCM"));
        assertTrue(!peer.contains("7580"));
        assertTrue(!peer.contains("AIRSIMPCM1"));
        assertTrue(peer.contains("mediaRequest"));
        String nativePeer = java.nio.file.Files.readString(phoneControlSource("TelephonyWebRTCPeer.java"));
        assertTrue(nativePeer.contains("TelephonyAudioDevice"));
        assertTrue(nativePeer.contains("readiness.deviceReady()"));
        assertTrue(!nativePeer.contains("new Socket"));
	}

	private static java.nio.file.Path phoneControlSource(String name) {
		java.nio.file.Path cursor = java.nio.file.Path.of("").toAbsolutePath();
		for (int depth = 0; depth < 6 && cursor != null; depth++) {
			java.nio.file.Path nested = cursor.resolve("android/phone-control-app/src/com/airsim/phonecontrol").resolve(name);
			if (java.nio.file.Files.isRegularFile(nested)) return nested;
			java.nio.file.Path direct = cursor.resolve("src/com/airsim/phonecontrol").resolve(name);
			if (java.nio.file.Files.isRegularFile(direct)) return direct;
			cursor = cursor.getParent();
		}
		throw new AssertionError("missing " + name);
	}

	private static void assertContains(String value, String expected) {
        if (!value.contains(expected)) throw new AssertionError(value + " missing " + expected);
    }

    private static void assertEquals(Object expected, Object actual) {
        if (!expected.equals(actual)) throw new AssertionError("expected=" + expected + " actual=" + actual);
    }

    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }

	private static void assertArrayEquals(String[] expected, String[] actual) {
		if (!java.util.Arrays.equals(expected, actual)) {
			throw new AssertionError("expected=" + java.util.Arrays.toString(expected)
					+ " actual=" + java.util.Arrays.toString(actual));
		}
	}

	private static boolean invokeSilencePolicy(String mode, String state) throws Exception {
		try {
			return (boolean) TelecomStateMapper.class
					.getMethod("shouldSilenceLocalOutput", String.class, String.class)
					.invoke(null, mode, state);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("remote_silent local-output policy is missing", error);
		}
	}

	private static void testVoWLANControlCarriesOfferNotPCM() throws Exception {
		String gateway = java.nio.file.Files.readString(phoneControlSource("VoWLANGatewayService.java"));
		if (gateway.contains("VoWLANPCMRelay") || gateway.contains("PCM_PORT") || gateway.contains("7593")) {
			throw new AssertionError("VoWLAN gateway still listens for PCM");
		}
		String bridge = java.nio.file.Files.readString(phoneControlSource("VoWLANWebRTCBridge.java"));
		if (bridge.contains("AIRSIMVWL1") || bridge.contains("PCM_PORT") || bridge.contains("7593")) {
			throw new AssertionError("VoWLAN signaling bridge still speaks PCM");
		}
		String peer = java.nio.file.Files.readString(phoneControlSource("WebRTCCloudPeer.java"));
		if (peer.contains("AIRSIMPCM1") || peer.contains("127.0.0.1") || peer.contains("7580")) {
            throw new AssertionError("telephony samples must not cross a socket");
        }
        assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/webrtc/status"));
        assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/webrtc/stop"));
		assertTrue(VoWLANWebRTCControl.CONTROL_PORT == 7592);
		assertTrue(!VoWLANWebRTCControl.LISTENS_ON_PCM_PORT);
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/webrtc"));
	}

	private static String[] invokeMissingRuntimePermissions(
			int sdk, boolean callPhoneGranted, boolean sendSMSGranted,
			boolean notificationsGranted) throws Exception {
		try {
			Class<?> policy = Class.forName("com.airsim.phonecontrol.RuntimePermissionPolicy");
			return (String[]) policy.getDeclaredMethod(
					"missingPermissions", int.class, boolean.class, boolean.class, boolean.class)
					.invoke(null, sdk, callPhoneGranted, sendSMSGranted, notificationsGranted);
		} catch (ClassNotFoundException error) {
			throw new AssertionError("CALL_PHONE runtime permission policy is missing", error);
		}
	}

	private static String[] invokeOptionalInboxPermissions(
			boolean readSMSGranted, boolean alreadyPrompted) throws Exception {
		try {
			return (String[]) RuntimePermissionPolicy.class.getDeclaredMethod(
					"optionalInboxPermissions", boolean.class, boolean.class)
					.invoke(null, readSMSGranted, alreadyPrompted);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("optional READ_SMS permission policy is missing", error);
		}
	}

	private static int invokeConfirmedSMSSegments(SMSConfirmation.Outcome outcome) throws Exception {
		try {
			return (int) outcome.getClass().getDeclaredMethod("confirmedSegments").invoke(outcome);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("SMS send outcome does not expose confirmed segment count", error);
		}
	}

	private static String invokeSMSIdentity(String sender, String body, long timestamp) throws Exception {
		try {
			Class<?> identity = Class.forName("com.airsim.phonecontrol.SMSDeliveryIdentity");
			return (String) identity.getDeclaredMethod("id", String.class, String.class, long.class)
					.invoke(null, sender, body, timestamp);
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("shared broadcast/inbox SMS delivery identity is missing", error);
		}
	}

	private static long invokeProviderTimestamp(long sent, long received) throws Exception {
		try {
			Class<?> identity = Class.forName("com.airsim.phonecontrol.SMSDeliveryIdentity");
			return (long) identity.getDeclaredMethod("providerTimestamp", long.class, long.class)
					.invoke(null, sent, received);
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("SMS provider timestamp fallback is missing", error);
		}
	}

	private static void assertRecentSMSIDsRetainBoundedDeliveryHistory() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.SMSRecentDeliveryIDs");
			Object recent = type.getDeclaredConstructor(java.util.Collection.class)
					.newInstance(java.util.List.of("first"));
			java.lang.reflect.Method contains = type.getDeclaredMethod("contains", String.class);
			java.lang.reflect.Method remember = type.getDeclaredMethod("remember", String.class);
			assertTrue((boolean) contains.invoke(recent, "first"));
			for (int index = 0; index < 512; index++) remember.invoke(recent, "later-" + index);
			assertTrue(!(boolean) contains.invoke(recent, "first"));
			assertTrue((boolean) contains.invoke(recent, "later-511"));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("completed SMS delivery history is missing", error);
		}
	}

	private static void assertLiveStatusPollerUpdatesWithoutRebuildingPage() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.LiveStatusPoller");
			Class<?> schedulerType = Class.forName("com.airsim.phonecontrol.LiveStatusPoller$Scheduler");
			java.util.concurrent.atomic.AtomicBoolean ready = new java.util.concurrent.atomic.AtomicBoolean(false);
			java.util.List<Boolean> rendered = new java.util.ArrayList<>();
			Runnable[] scheduled = new Runnable[1];
			Object scheduler = java.lang.reflect.Proxy.newProxyInstance(
					schedulerType.getClassLoader(), new Class<?>[]{schedulerType},
					(proxy, method, arguments) -> {
						if ("postDelayed".equals(method.getName())) scheduled[0] = (Runnable) arguments[0];
						if ("removeCallbacks".equals(method.getName()) && scheduled[0] == arguments[0]) {
							scheduled[0] = null;
						}
						return null;
					});
			Object poller = type.getDeclaredConstructor(
					java.util.function.BooleanSupplier.class, java.util.function.Consumer.class,
					schedulerType, long.class)
					.newInstance((java.util.function.BooleanSupplier) ready::get,
							(java.util.function.Consumer<Boolean>) rendered::add, scheduler, 1_000L);
			java.lang.reflect.Method start = type.getDeclaredMethod("start");
			java.lang.reflect.Method stop = type.getDeclaredMethod("stop");
			start.invoke(poller);
			assertEquals(java.util.List.of(false), rendered);
			assertTrue(scheduled[0] != null);
			ready.set(true);
			Runnable oldTick = scheduled[0];
			oldTick.run();
			assertEquals(java.util.List.of(false, true), rendered);
			assertTrue(scheduled[0] != null);
			stop.invoke(poller);
			assertTrue(scheduled[0] == null);
			ready.set(false);
			oldTick.run();
			assertEquals(java.util.List.of(false, true), rendered);
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("visible PCM status must refresh while active and stop when hidden", error);
		}
	}

	private static void assertLiveStatusPollerRecoversAfterOneFailedRead() {
		java.util.concurrent.atomic.AtomicInteger reads = new java.util.concurrent.atomic.AtomicInteger();
		java.util.List<Boolean> rendered = new java.util.ArrayList<>();
		Runnable[] scheduled = new Runnable[1];
		LiveStatusPoller poller = new LiveStatusPoller(() -> {
			if (reads.getAndIncrement() == 0) throw new IllegalStateException("transient status failure");
			return true;
		}, rendered::add, new LiveStatusPoller.Scheduler() {
			@Override public void postDelayed(Runnable task, long delayMillis) { scheduled[0] = task; }
			@Override public void removeCallbacks(Runnable task) {
				if (scheduled[0] == task) scheduled[0] = null;
			}
		}, 1_000L);
		poller.start();
		assertTrue(scheduled[0] != null);
		scheduled[0].run();
		assertEquals(java.util.List.of(true), rendered);
		poller.stop();
	}

	private static void assertLiveStatusPollerRetriesFailedRender() {
		java.util.concurrent.atomic.AtomicInteger renders = new java.util.concurrent.atomic.AtomicInteger();
		java.util.List<Boolean> rendered = new java.util.ArrayList<>();
		Runnable[] scheduled = new Runnable[1];
		LiveStatusPoller poller = new LiveStatusPoller(() -> true, value -> {
			if (renders.getAndIncrement() == 0) throw new IllegalStateException("view briefly unavailable");
			rendered.add(value);
		}, new LiveStatusPoller.Scheduler() {
			@Override public void postDelayed(Runnable task, long delayMillis) { scheduled[0] = task; }
			@Override public void removeCallbacks(Runnable task) {
				if (scheduled[0] == task) scheduled[0] = null;
			}
		}, 1_000L);
		poller.start();
		assertTrue(scheduled[0] != null);
		scheduled[0].run();
		assertEquals(java.util.List.of(true), rendered);
		poller.stop();
	}

	private static void assertPCMBridgeRunningUsesPrivilegedProcessStatus() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.PCMBridgeStatus");
			java.lang.reflect.Method running = type.getDeclaredMethod("isRunning", String.class);
			assertTrue((boolean) running.invoke(null, "uid=2000 media=ready local_output=normal"));
			assertTrue(!(boolean) running.invoke(null, "uid=2000 media=unavailable local_output=normal"));
			assertTrue(!(boolean) running.invoke(null, "uid=2000 media=readyish local_output=normal"));
			assertTrue(!(boolean) running.invoke(null, (String) null));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("PCM readiness must use the privileged bridge process status", error);
		}
	}

	private static void assertPrivilegedBridgeStatusRefreshTracksProcessExit() throws Exception {
		try {
			Class<?> coordinatorType = Class.forName("com.airsim.phonecontrol.PrivilegedBridgeCoordinator");
			Class<?> transportType = Class.forName(
					"com.airsim.phonecontrol.PrivilegedBridgeCoordinator$Transport");
			java.util.concurrent.atomic.AtomicBoolean processAlive = new java.util.concurrent.atomic.AtomicBoolean(true);
			Object transport = java.lang.reflect.Proxy.newProxyInstance(
					transportType.getClassLoader(), new Class<?>[]{transportType},
					(proxy, method, arguments) -> "uid=2000 media="
							+ (processAlive.get() ? "ready" : "unavailable") + " local_output=normal");
			Object coordinator = coordinatorType.getDeclaredConstructor().newInstance();
			coordinatorType.getDeclaredMethod("connect", transportType).invoke(coordinator, transport);
			java.lang.reflect.Method running = coordinatorType.getDeclaredMethod("bridgeRunning");
			java.lang.reflect.Method refresh = coordinatorType.getDeclaredMethod("refreshStatus");
			assertTrue((boolean) running.invoke(coordinator));
			processAlive.set(false);
			refresh.invoke(coordinator);
			assertTrue(!(boolean) running.invoke(coordinator));
			processAlive.set(true);
			refresh.invoke(coordinator);
			assertTrue((boolean) running.invoke(coordinator));
			coordinatorType.getDeclaredMethod("disconnect").invoke(coordinator);
			assertTrue(!(boolean) running.invoke(coordinator));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("privileged PCM process status must refresh after startup", error);
		}
	}

	private static void assertMuteResultDoesNotHideRunningPCMBridge() throws Exception {
		PrivilegedBridgeCoordinator.Transport transport = new PrivilegedBridgeCoordinator.Transport() {
			@Override public String startBridge() { return "uid=2000 media=ready local_output=normal"; }
			@Override public String status() { return "uid=2000 media=ready local_output=muted"; }
			@Override public String setLocalOutputMuted(boolean muted) {
				return "local_output_muted previous_muted=false verified=true";
			}
		};
		PrivilegedBridgeCoordinator connected = new PrivilegedBridgeCoordinator();
		connected.connect(transport);
		connected.setLocalOutputMuted(true);
		assertTrue(connected.bridgeRunning());

		PrivilegedBridgeCoordinator reconnecting = new PrivilegedBridgeCoordinator();
		reconnecting.setLocalOutputMuted(true);
		reconnecting.connect(transport);
		assertTrue(reconnecting.bridgeRunning());
	}

	private static void assertVoWLANFailedRejectPreservesCallOwnership() {
		assertTrue(VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/reject", 502, true));
		assertTrue(VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/hangup", 502, true));
		assertTrue(!VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/reject", 200, true));
		assertTrue(VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/answer", 200, false));
		assertTrue(!VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/answer", 502, false));
	}

	private static void assertVoWLANClosedSocketStopsAcceptLoop() throws Exception {
		java.util.concurrent.atomic.AtomicInteger attempts = new java.util.concurrent.atomic.AtomicInteger();
		try (java.net.ServerSocket broken = new java.net.ServerSocket() {
			@Override public java.net.Socket accept() throws java.io.IOException {
				if (attempts.incrementAndGet() > 1) {
					throw new AssertionError("closed VoWLAN listener was retried");
				}
				throw new java.net.SocketException("Socket closed");
			}
			@Override public boolean isClosed() { return false; }
		}) {
			try {
				Class<?> type = Class.forName("com.airsim.phonecontrol.VoWLANAcceptLoop");
				java.lang.reflect.Method run = type.getDeclaredMethod("run", java.net.ServerSocket.class,
						java.util.function.Consumer.class, java.util.function.Consumer.class);
				run.invoke(null, broken,
						(java.util.function.Consumer<java.net.Socket>) peer -> {},
						(java.util.function.Consumer<java.io.IOException>) error -> {});
				assertEquals(1, attempts.get());
			} catch (ClassNotFoundException | NoSuchMethodException error) {
				throw new AssertionError("VoWLAN listener must stop on terminal SocketException", error);
			}
		}
	}

	private static void assertVoWLANIOExceptionStopsAcceptLoop() throws Exception {
		java.util.concurrent.atomic.AtomicInteger attempts = new java.util.concurrent.atomic.AtomicInteger();
		try (java.net.ServerSocket broken = new java.net.ServerSocket() {
			@Override public java.net.Socket accept() throws java.io.IOException {
				if (attempts.incrementAndGet() > 1) {
					throw new AssertionError("failed VoWLAN listener was retried without a rebind");
				}
				throw new java.io.IOException("listener failure");
			}
			@Override public boolean isClosed() { return false; }
		}) {
			Class<?> type = Class.forName("com.airsim.phonecontrol.VoWLANAcceptLoop");
			type.getDeclaredMethod("run", java.net.ServerSocket.class,
					java.util.function.Consumer.class, java.util.function.Consumer.class)
					.invoke(null, broken,
							(java.util.function.Consumer<java.net.Socket>) peer -> {},
							(java.util.function.Consumer<java.io.IOException>) error -> {});
			assertEquals(1, attempts.get());
		}
	}

	private static void assertInboxCursorBaselinesExistingMessagesAndRetriesFailures() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.SMSInboxCursor");
			Object cursor = type.getDeclaredConstructor(long.class).newInstance(-1L);
			java.lang.reflect.Method initialized = type.getDeclaredMethod("initialized");
			java.lang.reflect.Method baseline = type.getDeclaredMethod("baseline", long.class);
			java.lang.reflect.Method shouldQueue = type.getDeclaredMethod("shouldQueue", long.class);
			java.lang.reflect.Method processed = type.getDeclaredMethod("processed", long.class);
			java.lang.reflect.Method value = type.getDeclaredMethod("value");
			assertTrue(!(boolean) initialized.invoke(cursor));
			baseline.invoke(cursor, 10L);
			assertTrue(!(boolean) shouldQueue.invoke(cursor, 10L));
			assertTrue((boolean) shouldQueue.invoke(cursor, 11L));
			assertEquals(10L, value.invoke(cursor));
			processed.invoke(cursor, 11L);
			assertTrue(!(boolean) shouldQueue.invoke(cursor, 11L));
			assertTrue((boolean) shouldQueue.invoke(cursor, 12L));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("new-message-only inbox cursor is missing", error);
		}
	}

	private static void assertCrashReportIsSanitizedBoundedAndPersisted() throws Exception {
		String repeated = "x".repeat(80_000);
		RuntimeException crash = new RuntimeException(
				"number=+8613800000000 token=super-secret-value " + repeated);
		String report = CrashReportFormatter.format(
				"0.9.6", "com.airsim.phonecontrol.standalone",
				"samsung", "SM-F766U", 35, "main", crash);
		assertContains(report, "AirSIM Android Crash Report");
		assertContains(report, "RuntimeException");
		assertContains(report, "[truncated]");
		assertTrue(report.length() <= CrashReportFormatter.MAX_REPORT_CHARS);
		assertTrue(!report.contains("+8613800000000"));
		assertTrue(!report.contains("super-secret-value"));

		java.nio.file.Path directory = java.nio.file.Files.createTempDirectory("airsim-crash-test");
		try {
			CrashReportStore.write(directory.toFile(), report);
			assertTrue(CrashReportStore.hasReport(directory.toFile()));
			assertEquals(report, CrashReportStore.read(directory.toFile()));
			CrashReportStore.clear(directory.toFile());
			assertTrue(!CrashReportStore.hasReport(directory.toFile()));
			assertEquals("", CrashReportStore.read(directory.toFile()));
		} finally {
			java.nio.file.Files.walk(directory)
					.sorted(java.util.Comparator.reverseOrder())
					.forEach(path -> { try { java.nio.file.Files.deleteIfExists(path); } catch (Exception ignored) {} });
		}
	}

	private static void assertCrashSharePayloadRequiresAReportAndSanitizesRecentLogs() {
		assertEquals("", CrashReportSharePayload.compose("", "debug line"));
		String payload = CrashReportSharePayload.compose(
				"AirSIM Android Crash Report\nRuntimeException: failure",
				"number=+8613800000000 token=private-value " + "d".repeat(80_000));
		assertContains(payload, "AirSIM Android Crash Report");
		assertContains(payload, "Recent sanitized debug log");
		assertTrue(payload.length() <= CrashReportSharePayload.MAX_SHARE_CHARS);
		assertTrue(!payload.contains("+8613800000000"));
		assertTrue(!payload.contains("private-value"));
	}

	private static String invokeTelecomAction(Runnable action) throws Exception {
		try {
			Class<?> invocation = Class.forName("com.airsim.phonecontrol.TelecomInvocation");
			java.util.concurrent.Executor direct = Runnable::run;
			return (String) invocation.getDeclaredMethod(
					"run", java.util.concurrent.Executor.class, Runnable.class, long.class)
					.invoke(null, direct, action, 1_000L);
		} catch (ClassNotFoundException error) {
			throw new AssertionError("Telecom runtime failures are not captured", error);
		}
	}

	private static boolean invokeIsStaleAudioBridge(
			int candidatePid, int ownerPid, String commandLine) throws Exception {
		return invokeIsStaleAudioBridgeForPackage(candidatePid, ownerPid, commandLine,
				"CLASSPATH=/data/app/~~x/com.airsim.phonecontrol.standalone-y/base.apk\0",
				"com.airsim.phonecontrol.standalone");
	}

	private static boolean invokeIsStaleAudioBridgeForPackage(
			int candidatePid, int ownerPid, String commandLine,
			String processEnvironment, String packageName) throws Exception {
		try {
			Class<?> policy = Class.forName(
					"com.airsim.phonecontrol.PhoneAudioBridgeProcessPolicy");
			return (boolean) policy.getDeclaredMethod(
					"isStaleBridge", int.class, int.class, String.class, String.class, String.class)
					.invoke(null, candidatePid, ownerPid, commandLine, processEnvironment, packageName);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("package-scoped stale PCM bridge policy is missing", error);
		}
	}

	private static final class TrackingPeer implements java.io.Closeable {
		boolean closed;
		boolean errorResponseWrittenWhileOpen;

		void writeErrorResponse() {
			errorResponseWrittenWhileOpen = !closed;
		}

		@Override public void close() {
			closed = true;
		}
	}
}
