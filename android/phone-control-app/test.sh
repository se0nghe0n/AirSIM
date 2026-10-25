#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-test"
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"
ANDROID_JAR="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platforms/android-35/android.jar"

assert_contains() {
  file=$1
  expected=$2
  message=$3
  if ! grep -Fq "$expected" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

assert_not_contains() {
  file=$1
  unexpected=$2
  message=$3
  if grep -Fq "$unexpected" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

MANIFEST="$ROOT/../../android-standalone/AndroidManifest.xml"
assert_contains "$MANIFEST" 'android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING' 'boot-safe foreground service permission is missing'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.StandaloneBridgeApplication' 'Standalone application entry point is missing'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.IncomingSMSReceiver' 'carrier SMS receiver is missing'

assert_contains "$ROOT/src/com/airsim/phonecontrol/MainActivity.java" \
  'Debug logging' \
  'the Android app has no user-visible debug log controls'
assert_contains "$ROOT/src/com/airsim/phonecontrol/MainActivity.java" \
  'BridgeLog.clear()' \
  'the Android app cannot clear captured diagnostics'

rm -rf "$OUT"
mkdir -p "$OUT"
"$JAVAC" --release 17 -d "$OUT" \
  "$ROOT"/test/android/Manifest.java \
  "$ROOT"/test/android/provider/Settings.java \
  "$ROOT"/test/android/content/SharedPreferences.java \
  "$ROOT"/test/android/content/ComponentName.java \
  "$ROOT"/test/android/content/pm/PackageManager.java \
  "$ROOT"/test/android/os/Bundle.java \
  "$ROOT"/test/android/os/Build.java \
  "$ROOT"/test/android/telecom/PhoneAccount.java \
  "$ROOT"/test/android/telecom/PhoneAccountHandle.java \
  "$ROOT"/test/android/telephony/TelephonyManager.java \
  "$ROOT"/test/android/telephony/SubscriptionManager.java \
  "$ROOT"/test/android/telephony/SubscriptionInfo.java \
  "$ROOT"/test/android/content/Context.java \
  "$ROOT"/test/android/net/Uri.java \
  "$ROOT"/test/android/os/Looper.java \
  "$ROOT"/test/android/os/Handler.java \
  "$ROOT"/test/android/telecom/Call.java \
  "$ROOT"/test/android/telecom/TelecomManager.java \
  "$ROOT"/test/android/telecom/VideoProfile.java \
  "$ROOT"/test/com/airsim/phonecontrol/AppConfig.java \
  "$ROOT"/test/com/airsim/phonecontrol/BridgeLog.java \
	"$ROOT"/test/com/airsim/phonecontrol/StandaloneAgentGateway.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentClient.java \
	"$ROOT"/src/com/airsim/phonecontrol/RuntimePermissionPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/SMSDeliveryIdentity.java \
	"$ROOT"/src/com/airsim/phonecontrol/SMSRecentDeliveryIDs.java \
	"$ROOT"/src/com/airsim/phonecontrol/SMSInboxCursor.java \
  "$ROOT"/src/com/airsim/phonecontrol/TelecomStateMapper.java \
	"$ROOT"/src/com/airsim/phonecontrol/TelecomRolePolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/DialerRoleSetupPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/ShizukuStartupPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/TelecomInvocation.java \
	"$ROOT"/src/com/airsim/phonecontrol/PrivilegedBridgeProtocol.java \
	"$ROOT"/src/com/airsim/phonecontrol/PrivilegedBridgeCoordinator.java \
	"$ROOT"/src/com/airsim/phonecontrol/PhoneAudioBridgeProcessPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/WireJson.java \
  "$ROOT"/src/com/airsim/phonecontrol/DebugRedactor.java \
  "$ROOT"/src/com/airsim/phonecontrol/CrashReportFormatter.java \
  "$ROOT"/src/com/airsim/phonecontrol/CrashReportStore.java \
  "$ROOT"/src/com/airsim/phonecontrol/CrashReportSharePayload.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentCommand.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallRepository.java \
  "$ROOT"/src/com/airsim/phonecontrol/CloudAnswerReplayPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallLifecycleConflict.java \
  "$ROOT"/src/com/airsim/phonecontrol/DefaultCallAccount.java \
	"$ROOT"/src/com/airsim/phonecontrol/CloudCallTarget.java \
	"$ROOT"/src/com/airsim/phonecontrol/CloudCallMedia.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentCommandDispatcher.java \
  "$ROOT"/src/com/airsim/phonecontrol/SMSPayloadPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/SMSConfirmation.java \
  "$ROOT"/src/com/airsim/phonecontrol/RetryPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/RelayHTTPException.java \
  "$ROOT"/src/com/airsim/phonecontrol/RelayRetryPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CommandPollingPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CommandRegistrationPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallEventDeduplicator.java \
  "$ROOT"/src/com/airsim/phonecontrol/PairingCrypto.java \
  "$ROOT"/src/com/airsim/phonecontrol/PairingSession.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANAuth.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANControlPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANAcceptLoop.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANPeerLifecycle.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANReplayCache.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANWebRTCControl.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANPortBinder.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANNetworkPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/StandaloneLongPoll.java \
	"$ROOT"/src/com/airsim/phonecontrol/MainScreenPresentation.java \
	"$ROOT"/src/com/airsim/phonecontrol/LiveStatusPoller.java \
	"$ROOT"/src/com/airsim/phonecontrol/PCMBridgeStatus.java \
	"$ROOT"/src/com/airsim/phonecontrol/MuteRequestRetrier.java \
	"$ROOT"/src/com/airsim/phonecontrol/NotificationUpdateGate.java \
	"$ROOT"/test/com/airsim/phonecontrol/CoreTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/NotificationUpdateGateTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/CallRepositoryTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/DefaultCallAccountTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/ShizukuStartupPolicyTests.java
"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/AndroidAgentIdentity.java \
  "$ROOT"/test/com/airsim/phonecontrol/AndroidAgentIdentityTests.java
sh "$ROOT/verify-io-api.sh" "$OUT"
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CoreTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.NotificationUpdateGateTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CallRepositoryTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.DefaultCallAccountTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.AndroidAgentIdentityTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.ShizukuStartupPolicyTests

# Keep the real diagnostics class ahead of the unrelated suite's BridgeLog test double.
DIAGNOSTICS_OUT="$OUT/diagnostics"
mkdir -p "$DIAGNOSTICS_OUT"
"$JAVAC" --release 17 -cp "$OUT" -d "$DIAGNOSTICS_OUT" \
  "$ROOT"/test/android/util/Log.java \
  "$ROOT"/src/com/airsim/phonecontrol/BridgeLog.java \
  "$ROOT"/test/com/airsim/phonecontrol/DiagnosticFileTests.java
sh "$ROOT/verify-io-api.sh" "$DIAGNOSTICS_OUT"
"$JAVA" -cp "$DIAGNOSTICS_OUT:$OUT" com.airsim.phonecontrol.DiagnosticFileTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/LocalOutputMuteController.java \
  "$ROOT"/test/com/airsim/phonecontrol/LocalOutputMuteControllerTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.LocalOutputMuteControllerTests

# Compile the actual executor against Android; replace only the telephony boundary at runtime.
SMS_OUT="$OUT/sms-compat"
mkdir -p "$SMS_OUT"
"$JAVAC" --release 17 -cp "$ANDROID_JAR:$DIAGNOSTICS_OUT:$OUT" -d "$SMS_OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/SMSCommandExecutor.java
"$JAVAC" --release 17 -cp "$SMS_OUT:$OUT:$ANDROID_JAR" -d "$SMS_OUT" \
  "$ROOT"/test/compat/android/telephony/SmsManager.java \
  "$ROOT"/test/com/airsim/phonecontrol/SMSCompatibilityTests.java
"$JAVA" -cp "$SMS_OUT:$OUT:$ANDROID_JAR" com.airsim.phonecontrol.SMSCompatibilityTests

"$JAVAC" --release 17 -cp "$ANDROID_JAR:$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/StandaloneWebSocket.java \
  "$ROOT"/test/com/airsim/phonecontrol/StandaloneWebSocketTests.java
"$JAVA" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.StandaloneWebSocketTests

assert_contains "$ROOT/src/com/airsim/phonecontrol/TelephonyWebRTCPeer.java" \
  'config.audioJitterBufferMaxPackets = WebRTCPlayout.JITTER_BUFFER_MAX_PACKETS' \
  'Android WebRTC peer does not cap NetEq'
assert_contains "$ROOT/src/com/airsim/phonecontrol/TelephonyWebRTCPeer.java" \
  'config.audioJitterBufferFastAccelerate = WebRTCPlayout.FAST_ACCELERATE' \
  'Android WebRTC peer does not enable NetEq fast accelerate'
assert_not_contains "$ROOT/src/com/airsim/phonecontrol/TelephonyWebRTCPeer.java" \
  'new Socket' \
  'Native carrier audio must remain in process'
"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/WebRTCPcmBuffer.java \
  "$ROOT"/src/com/airsim/phonecontrol/WebRTCPlayout.java \
  "$ROOT"/src/com/airsim/phonecontrol/WebRTCOpusSDP.java \
  "$ROOT"/test/com/airsim/phonecontrol/WebRTCMediaTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.WebRTCMediaTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/WebRTCReadiness.java \
  "$ROOT"/test/com/airsim/phonecontrol/WebRTCReadinessTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.WebRTCReadinessTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/WebRTCStatistics.java \
  "$ROOT"/test/com/airsim/phonecontrol/WebRTCStatisticsTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.WebRTCStatisticsTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/test/com/airsim/phonecontrol/CommandRegistrationPolicyTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CommandRegistrationPolicyTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/NativeCallHistoryRecord.java \
  "$ROOT"/test/com/airsim/phonecontrol/NativeCallHistoryTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.NativeCallHistoryTests

# Run the real IPC owner/state machine with a fake native peer, never a hardware audio route.
JSON_JAR="$ROOT/build/dependencies/json-test-20240303.jar"
mkdir -p "$(dirname "$JSON_JAR")"
if [ ! -f "$JSON_JAR" ]; then
  curl -fsSL https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar -o "$JSON_JAR"
fi
if [ "$(shasum -a 256 "$JSON_JAR" | awk '{print $1}')" != 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed ]; then
  echo 'FAIL: test JSON dependency checksum mismatch' >&2; exit 1
fi
MEDIA_OUT="$OUT/privileged-media"
mkdir -p "$MEDIA_OUT"
"$JAVAC" --release 17 -cp "$JSON_JAR" -d "$MEDIA_OUT" \
  "$ROOT"/test/media/android/content/Context.java \
  "$ROOT"/test/media/android/os/SystemClock.java \
  "$ROOT"/test/media/com/airsim/phonecontrol/TelephonyWebRTCPeer.java \
  "$ROOT"/src/com/airsim/phonecontrol/PrivilegedMediaProtocol.java \
  "$ROOT"/src/com/airsim/phonecontrol/PrivilegedMediaService.java \
  "$ROOT"/test/media/com/airsim/phonecontrol/PrivilegedMediaTests.java
"$JAVA" -cp "$MEDIA_OUT:$JSON_JAR" com.airsim.phonecontrol.PrivilegedMediaTests

# Compile the real Binder service against Android, then replace only host runtime boundaries.
"$JAVAC" --release 17 -cp "$ANDROID_JAR:$MEDIA_OUT:$OUT:$JSON_JAR" -d "$MEDIA_OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/ShizukuBridgeUserService.java
"$JAVAC" --release 17 -cp "$MEDIA_OUT:$OUT:$JSON_JAR:$ANDROID_JAR" -d "$MEDIA_OUT" \
  "$ROOT"/test/media/android/os/Binder.java \
  "$ROOT"/test/media/android/os/Process.java \
  "$ROOT"/test/android/util/Log.java \
  "$ROOT"/test/media/com/airsim/phonecontrol/PrivilegedBridgeDisposalTests.java
"$JAVA" -cp "$MEDIA_OUT:$OUT:$JSON_JAR:$ANDROID_JAR" com.airsim.phonecontrol.PrivilegedBridgeDisposalTests

# Readiness is a live admission signal, separate from the owner's continuing control channel.
"$JAVAC" --release 17 -cp "$ANDROID_JAR:$MEDIA_OUT:$OUT:$JSON_JAR" -d "$MEDIA_OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/StandaloneAgentStore.java
"$JAVAC" --release 17 -cp "$MEDIA_OUT:$OUT:$JSON_JAR:$ANDROID_JAR" -d "$MEDIA_OUT" \
  "$ROOT"/test/media/com/airsim/phonecontrol/PrivilegedMediaReadinessTests.java
"$JAVA" -cp "$MEDIA_OUT:$OUT:$JSON_JAR:$ANDROID_JAR" com.airsim.phonecontrol.PrivilegedMediaReadinessTests

# Real persistent stores reopen pre-upgrade records; only Android service launch is stubbed.
PERSISTENCE_OUT="$OUT/persistence"
mkdir -p "$PERSISTENCE_OUT"
"$JAVAC" --release 17 -cp "$OUT:$JSON_JAR" -d "$PERSISTENCE_OUT" \
  "$ROOT"/test/android/util/Base64.java \
  "$ROOT"/test/persistence/com/airsim/phonecontrol/StandaloneAgentService.java \
  "$ROOT"/src/com/airsim/phonecontrol/AppConfig.java \
  "$ROOT"/src/com/airsim/phonecontrol/StandaloneAgentStore.java \
  "$ROOT"/src/com/airsim/phonecontrol/StandaloneSMSStore.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANPairingStore.java \
  "$ROOT"/test/persistence/com/airsim/phonecontrol/StandalonePersistenceTests.java
"$JAVA" -cp "$PERSISTENCE_OUT:$OUT:$JSON_JAR" com.airsim.phonecontrol.StandalonePersistenceTests

# Credential preparation may overlap ringing, but never starts native/carrier media.
PREFETCH_OUT="$OUT/cloud-prefetch"
mkdir -p "$PREFETCH_OUT"
"$JAVAC" --release 17 -cp "$OUT:$JSON_JAR" -d "$PREFETCH_OUT" \
  "$ROOT"/test/cloud-prefetch/com/airsim/phonecontrol/BridgeLog.java \
  "$ROOT"/test/cloud-prefetch/com/airsim/phonecontrol/ShizukuBridgeManager.java \
  "$ROOT"/src/com/airsim/phonecontrol/PrivilegedMediaProtocol.java \
  "$ROOT"/src/com/airsim/phonecontrol/WebRTCCloudPeer.java \
  "$ROOT"/test/cloud-prefetch/com/airsim/phonecontrol/WebRTCICEPreparationTests.java
"$JAVA" -cp "$PREFETCH_OUT:$OUT:$JSON_JAR" com.airsim.phonecontrol.WebRTCICEPreparationTests
