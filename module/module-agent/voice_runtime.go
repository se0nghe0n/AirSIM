package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	voiceHelperName       = "mavo-pcm-bridge.armv7"
	voiceHelperSHA256     = "13d034205664071db51120f349af7f785df58e269eeb07f531af5be18d0af228"
	voiceRoutePIDFile     = "/run/mavo-voice-route.pid"
	voiceSessionPIDFile   = "/run/mavo-voice-session.pid"
	voiceRouteLogMaxBytes = 1024 * 1024
	voiceNetworkListen    = "192.168.225.1:7580"
	voiceMediaRouteFIFO   = "/run/voc_svr"
	voiceCalibrationLog   = "/run/mavo-alsaucm.log"
	voiceCalibrationFIFO  = "/run/alsaucm_test"
	voiceAudioEnablePath  = "/sys/class/android_usb/f_audio/audio_enable"
	voiceExpectedKernel   = "3.18.44"
	voiceExpectedCardName = "mdm9607-tomtom-i2s-snd-card"
	// After the helper starts, wait only for the TCP listener. The client handshake
	// is confirmed by a separate observer and must not block inside the start
	// function on a Dial that has not run yet.
	voiceListenerReadyTimeout = 5 * time.Second
)

var (
	voiceRouteLogFile   = agentDataDirectory + "/log/voice-route.log"
	voiceRouteLogBackup = agentDataDirectory + "/log/voice-route.log.1"
)

var voiceRuntimeFiles = map[string]string{
	"qdc507_aprv3.ko": "3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a",
	"qdc507_voice.ko": "ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c",
	voiceHelperName:   voiceHelperSHA256,
}

var voiceRequiredDevices = []string{
	"/dev/snd/controlC0", "/dev/snd/pcmC0D4p", "/dev/snd/pcmC0D4c",
	"/dev/snd/pcmC0D5p", "/dev/snd/pcmC0D6c",
}

type voiceRuntimeValidator struct {
	once      sync.Once
	installed bool
	err       error
}

var cachedVoiceRuntimeValidator voiceRuntimeValidator

type voiceTracker struct {
	// lifecycleMu serializes start and stop, but must never guard HTTP status
	// snapshots. The same mutex used to be held for up to 15 seconds during cold
	// start, which blocked /audio/host/config and stalled App polling.
	lifecycleMu       sync.Mutex
	mu                sync.Mutex
	command           *exec.Cmd
	routeCommand      *exec.Cmd
	listening         bool
	ready             bool
	routeReady        bool
	starting          bool
	stopping          bool
	mediaRouteStarted bool
	hostEnabled       bool
	lastError         string
	startedAt         time.Time
	logOffset         int64
}

type voiceRouteSnapshot struct {
	Command           *exec.Cmd
	RouteCommand      *exec.Cmd
	Listening         bool
	Ready             bool
	RouteReady        bool
	Starting          bool
	Stopping          bool
	MediaRouteStarted bool
	HostEnabled       bool
	LastError         string
	StartedAt         time.Time
	LogOffset         int64
}

func (tracker *voiceTracker) snapshot() voiceRouteSnapshot {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	return voiceRouteSnapshot{
		Command: tracker.command, RouteCommand: tracker.routeCommand,
		Listening: tracker.listening,
		Ready:     tracker.ready, RouteReady: tracker.routeReady,
		Starting: tracker.starting, Stopping: tracker.stopping,
		MediaRouteStarted: tracker.mediaRouteStarted,
		HostEnabled:       tracker.hostEnabled, LastError: tracker.lastError,
		StartedAt: tracker.startedAt, LogOffset: tracker.logOffset,
	}
}

// beginRouteStart obtains the long-running lifecycle lease while keeping the
// small state mutex free for health, diagnostics and hangup decisions.
func (tracker *voiceTracker) beginRouteStart(now time.Time) (func(), bool) {
	if !tracker.lifecycleMu.TryLock() {
		return func() {}, false
	}
	tracker.mu.Lock()
	if tracker.stopping || tracker.listening || tracker.ready || tracker.starting ||
		tracker.command != nil || tracker.routeCommand != nil {
		tracker.mu.Unlock()
		tracker.lifecycleMu.Unlock()
		return func() {}, false
	}
	tracker.starting = true
	tracker.startedAt = now
	tracker.mu.Unlock()
	return func() {
		tracker.mu.Lock()
		tracker.starting = false
		tracker.mu.Unlock()
		tracker.lifecycleMu.Unlock()
	}, true
}

type voicePCMStats struct {
	UplinkBytes          uint64 `json:"uplink_bytes"`
	UplinkFrames         uint64 `json:"uplink_frames"`
	UplinkPeak           uint64 `json:"uplink_peak"`
	DownlinkBytes        uint64 `json:"downlink_bytes"`
	DownlinkFrames       uint64 `json:"downlink_frames"`
	DownlinkPeak         uint64 `json:"downlink_peak"`
	DownlinkDroppedFrame uint64 `json:"downlink_dropped_frames"`
}

var voiceDiagnosticLogMu sync.Mutex
var voiceRuntimePrepareMu sync.Mutex
var voiceAudioGateMu sync.Mutex
var voiceAudioGateReady bool

// initializeVoiceAudioGateAtStartup prepares the vendor audio gate once during
// Agent startup. Network PCM never disables it at hangup, because toggling a
// function inside the USB composite can force iOS to rediscover the sibling ECM
// interface and temporarily lose 192.168.225.1.
func (a *agent) initializeVoiceAudioGateAtStartup() {
	if !a.usesLocalVoiceRuntime() {
		return
	}
	installed, err := validateVoiceRuntime()
	if err != nil || !installed {
		if err != nil {
			appendVoiceDiagnosticEvent("Failed to check voice runtime at startup: " + err.Error())
		}
		return
	}
	appendVoiceSystemSnapshot("audio-gate-before")
	if err := a.ensureVoiceAudioGate(); err != nil {
		appendVoiceDiagnosticEvent("Failed to retain f_audio/audio_enable at startup: " + err.Error())
		return
	}
	appendVoiceSystemSnapshot("audio-gate-after")
}

func (a *agent) ensureVoiceAudioGate() error {
	voiceAudioGateMu.Lock()
	defer voiceAudioGateMu.Unlock()

	if voiceAudioGateReady {
		return nil
	}

	current, err := os.ReadFile(voiceAudioEnablePath)
	if err != nil {
		return fmt.Errorf("Failed to read %s: %w", voiceAudioEnablePath, err)
	}
	if strings.TrimSpace(string(current)) != "1" {
		if err := os.WriteFile(voiceAudioEnablePath, []byte("1\n"), 0o600); err != nil {
			return fmt.Errorf("Failed to enable %s: %w", voiceAudioEnablePath, err)
		}
		appendVoiceDiagnosticEvent("f_audio/audio_enable fixed at 1 for this Agent session")
	}
	voiceAudioGateReady = true
	return nil
}

// ensureVoiceRuntimeWarm only loads kernel modules and runs ACDB calibration.
// It does not start the call media route. Warmup does not occupy 7580 or send a
// media-start command to the baseband, even when the user has not answered yet.
func (a *agent) ensureVoiceRuntimeWarm() {
	if !a.usesLocalVoiceRuntime() {
		return
	}
	appendVoiceDiagnosticEvent("Warming up voice runtime")
	if err := prepareVoiceRuntime(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Voice runtime warmup failed: " + err.Error())
		return
	}
	a.voice.mu.Lock()
	a.voice.lastError = ""
	a.voice.mu.Unlock()
	appendVoiceDiagnosticEvent("Voice runtime warmup complete")
}

// validateVoiceRuntime checks the pinned upstream files before any kernel module runs, and refuses a replaced binary.
func validateVoiceRuntime() (bool, error) {
	return cachedVoiceRuntimeValidator.validate(voiceRuntimePath, voiceRuntimeFiles)
}

func (v *voiceRuntimeValidator) validate(directory string, files map[string]string) (bool, error) {
	v.once.Do(func() {
		v.installed, v.err = validateVoiceRuntimeFiles(directory, files)
	})
	return v.installed, v.err
}

func validateVoiceRuntimeFiles(directory string, files map[string]string) (bool, error) {
	for name, expected := range files {
		path := filepath.Join(directory, name)
		file, err := os.Open(path)
		if os.IsNotExist(err) {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("Failed to read voice runtime %s: %w", name, err)
		}
		digest := sha256.New()
		_, copyErr := io.CopyBuffer(digest, file, make([]byte, 32*1024))
		closeErr := file.Close()
		if copyErr != nil {
			return false, fmt.Errorf("Failed to verify voice runtime %s: %w", name, copyErr)
		}
		if closeErr != nil {
			return false, fmt.Errorf("Failed to close voice runtime %s: %w", name, closeErr)
		}
		if hex.EncodeToString(digest.Sum(nil)) != expected {
			return false, fmt.Errorf("SHA-256 verification failed for voice runtime %s", name)
		}
	}
	return true, nil
}

func (a *agent) ensureVoiceRoute() {
	_ = a.ensureVoiceRouteListening()
}

func (a *agent) ensureVoiceRouteListening() error {
	if !a.usesLocalVoiceRuntime() {
		_, err := a.voicePCMEndpoint()
		a.voice.mu.Lock()
		a.voice.listening = err == nil
		a.voice.ready = false
		a.voice.lastError = errorText(err)
		a.voice.mu.Unlock()
		if err != nil {
			a.debug.add("voice-backend", "error", "Samsung PCM backend unavailable", err.Error(), nil)
			return err
		}
		a.debug.add("voice-backend", "configured", "Samsung PCM endpoint configured; waiting for media handshake", "", map[string]string{
			"backend": string(a.voiceBackend.kind),
		})
		return nil
	}
	release, started := a.voice.beginRouteStart(time.Now().UTC())
	if !started {
		return nil
	}
	defer release()

	// The previous call may still be exiting asynchronously. Returning while the
	// old process holds 7580 leaves the new call waiting forever for AIRSIMREADY.
	// That race is the usual case where a call dials, then a callback after answer fails.
	a.voice.mu.Lock()
	if a.voice.command != nil || a.voice.routeCommand != nil {
		oldCommand := a.voice.command
		oldRouteCommand := a.voice.routeCommand
		oldMediaRouteStarted := a.voice.mediaRouteStarted
		a.voice.command = nil
		a.voice.routeCommand = nil
		a.voice.listening = false
		a.voice.routeReady = false
		a.voice.mediaRouteStarted = false
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Cleaning up incomplete previous network PCM session")
		terminateVoiceProcess(oldCommand)
		terminateVoiceProcess(oldRouteCommand)
		if oldMediaRouteStarted {
			stopVoiceMediaRouteForLifecycle()
		}
	} else {
		a.voice.mu.Unlock()
	}
	appendVoiceDiagnosticEvent("Voice bridge start request received")
	if err := prepareVoiceRuntime(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Voice runtime preparation failed: " + err.Error())
		return err
	}
	if err := a.ensureVoiceAudioGate(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Voice audio gate preparation failed: " + err.Error())
		return err
	}

	helper := filepath.Join(voiceRuntimePath, voiceHelperName)
	if output, err := exec.Command(helper, "--check").CombinedOutput(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = commandFailure("Voice bridge self-test failed", output, err).Error()
		lastError := a.voice.lastError
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent(lastError)
		return errors.New(lastError)
	}
	if err := prepareVoiceDiagnosticLog(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		return err
	}
	startedAt := time.Now().UTC()
	appendVoiceDiagnosticEvent("Starting new network PCM session")
	logOffset := voiceDiagnosticLogSize()
	a.voice.mu.Lock()
	a.voice.startedAt = startedAt
	a.voice.logOffset = logOffset
	a.voice.mu.Unlock()
	if err := a.startVoiceRouteSession(helper, logOffset); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Failed to start VoLTE route session: " + err.Error())
		return err
	}
	// D4 only sets up the AFE hostless route. The voc_svr S command starts the baseband media clock. Both are required.
	if err := startVoiceMediaRoute(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		routeCommand := a.voice.routeCommand
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Failed to start modem voice media route: " + err.Error())
		terminateVoiceProcess(routeCommand)
		return err
	}
	a.voice.mu.Lock()
	a.voice.mediaRouteStarted = true
	a.voice.mu.Unlock()
	appendVoiceDiagnosticEvent("Modem voice media route started")
	logFile, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		routeCommand := a.voice.routeCommand
		mediaRouteStarted := a.voice.mediaRouteStarted
		a.voice.mu.Unlock()
		terminateVoiceProcess(routeCommand)
		if mediaRouteStarted {
			stopVoiceMediaRouteForLifecycle()
			a.voice.mu.Lock()
			a.voice.mediaRouteStarted = false
			a.voice.mu.Unlock()
		}
		return err
	}
	// D5 is host-to-baseband playback and D6 is baseband-to-host capture. Audio no longer goes through USB UAC D4.
	command := exec.Command(
		helper,
		"--tcp-listen", voiceNetworkListen,
		"--playback-device", "hw:0,5",
		"--capture-device", "hw:0,6",
		"--no-mixers",
		"--verbose",
	)
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		routeCommand := a.voice.routeCommand
		mediaRouteStarted := a.voice.mediaRouteStarted
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Failed to start voice bridge process: " + err.Error())
		terminateVoiceProcess(routeCommand)
		if mediaRouteStarted {
			stopVoiceMediaRouteForLifecycle()
			a.voice.mu.Lock()
			a.voice.mediaRouteStarted = false
			a.voice.mu.Unlock()
		}
		return err
	}
	a.voice.mu.Lock()
	a.voice.command = command
	a.voice.mu.Unlock()
	_ = os.WriteFile(voiceRoutePIDFile, []byte(strconv.Itoa(command.Process.Pid)+"\n"), 0o600)
	appendVoiceDiagnosticEvent(fmt.Sprintf("Voice bridge process started pid=%d", command.Process.Pid))

	done := make(chan error, 1)
	go func() {
		waitErr := command.Wait()
		done <- waitErr
		_ = logFile.Close()
		var routeCommand *exec.Cmd
		mediaRouteStarted := false
		a.voice.mu.Lock()
		if a.voice.command == command {
			a.voice.command = nil
			a.voice.listening = false
			a.voice.ready = false
			routeCommand = a.voice.routeCommand
			mediaRouteStarted = a.voice.mediaRouteStarted
			a.voice.mediaRouteStarted = false
			_ = os.Remove(voiceRoutePIDFile)
		}
		a.voice.mu.Unlock()
		// When the main PCM bridge exits, release D4 and voc_svr in the same step. A leftover routeCommand stops the call watchdog from starting them again.
		if routeCommand != nil {
			terminateVoiceProcess(routeCommand)
			if mediaRouteStarted {
				stopVoiceMediaRouteForLifecycle()
			}
			_ = os.Remove(voiceSessionPIDFile)
		}
		exitDetail := errorText(waitErr)
		if exitDetail == "" {
			exitDetail = "Exited normally"
		}
		appendVoiceDiagnosticEvent("Voice bridge process exited: " + exitDetail)
	}()

	deadline := time.Now().Add(voiceListenerReadyTimeout)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			a.voice.mu.Lock()
			a.voice.command = nil
			a.voice.lastError = errorText(waitErr)
			routeCommand := a.voice.routeCommand
			mediaRouteStarted := a.voice.mediaRouteStarted
			a.voice.mu.Unlock()
			terminateVoiceProcess(routeCommand)
			if mediaRouteStarted {
				stopVoiceMediaRouteForLifecycle()
				a.voice.mu.Lock()
				a.voice.mediaRouteStarted = false
				a.voice.mu.Unlock()
			}
			return fmt.Errorf("Voice bridge exited before listening: %s", errorText(waitErr))
		default:
		}
		if voiceRouteListeningFrom(logOffset) {
			a.voice.mu.Lock()
			if a.voice.command == command {
				a.voice.listening = true
			}
			a.voice.lastError = ""
			a.voice.mu.Unlock()
			appendVoiceDiagnosticEvent("Network PCM listening; waiting for client handshake")
			go a.observeVoiceRouteHandshake(command, logOffset)
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = command.Process.Signal(syscall.SIGTERM)
	a.voice.mu.Lock()
	routeCommand := a.voice.routeCommand
	a.voice.listening = false
	a.voice.lastError = "Network PCM listener did not become ready in time"
	lastError := a.voice.lastError
	mediaRouteStarted := a.voice.mediaRouteStarted
	a.voice.mu.Unlock()
	terminateVoiceProcess(routeCommand)
	appendVoiceDiagnosticEvent(lastError)
	if mediaRouteStarted {
		stopVoiceMediaRouteForLifecycle()
		a.voice.mu.Lock()
		a.voice.mediaRouteStarted = false
		a.voice.mu.Unlock()
	}
	return errors.New(lastError)
}

func (a *agent) markVoiceBackendHandshakeReady() {
	if a.usesLocalVoiceRuntime() {
		return
	}
	a.voice.mu.Lock()
	if a.voice.listening {
		a.voice.ready = true
		a.voice.lastError = ""
	}
	a.voice.mu.Unlock()
}

func (a *agent) observeVoiceRouteHandshake(command *exec.Cmd, logOffset int64) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		a.voice.mu.Lock()
		current := a.voice.command == command && a.voice.listening
		a.voice.mu.Unlock()
		if !current {
			return
		}
		if !voiceRouteReadyFrom(logOffset) {
			continue
		}
		a.voice.mu.Lock()
		if a.voice.command == command && a.voice.listening {
			a.voice.ready = true
			a.voice.lastError = ""
		}
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("Network PCM handshake and bidirectional workers ready")
		return
	}
}

func (a *agent) ensureVoiceRouteIfHostEnabled() {
	a.voice.mu.Lock()
	hostEnabled := a.voice.hostEnabled
	a.voice.mu.Unlock()
	if hostEnabled {
		a.ensureVoiceRoute()
	}
}

// maintainVoiceRoute recovers only when a call is already connected and the voice bridge is not running.
// It does not start the voice bridge outside a call, so idle time does not load kernel audio modules or hold PCM devices.
func (a *agent) maintainVoiceRoute() {
	a.mu.RLock()
	active := a.calls.Active != nil && a.calls.Active.State == "active"
	a.mu.RUnlock()
	if !active {
		return
	}

	snapshot := a.voice.snapshot()
	hostEnabled := snapshot.HostEnabled
	running := snapshot.Starting || snapshot.Stopping || snapshot.Ready ||
		snapshot.Command != nil || snapshot.RouteCommand != nil
	if hostEnabled && !running {
		go a.ensureVoiceRoute()
	}
}

// startVoiceRouteSession starts the D4 hostless session and attaches D5/D6 AFE PCM to the baseband call.
func (a *agent) startVoiceRouteSession(helper string, logOffset int64) error {
	logFile, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command(helper, "--voice-route-session", "--verbose")
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	a.voice.mu.Lock()
	a.voice.routeCommand = command
	a.voice.routeReady = false
	a.voice.mu.Unlock()
	_ = os.WriteFile(voiceSessionPIDFile, []byte(strconv.Itoa(command.Process.Pid)+"\n"), 0o600)
	appendVoiceDiagnosticEvent(fmt.Sprintf("VoLTE route session started pid=%d", command.Process.Pid))

	done := make(chan error, 1)
	go func() {
		waitErr := command.Wait()
		done <- waitErr
		_ = logFile.Close()
		a.voice.mu.Lock()
		if a.voice.routeCommand == command {
			a.voice.routeCommand = nil
			a.voice.routeReady = false
			a.voice.listening = false
			a.voice.ready = false
			_ = os.Remove(voiceSessionPIDFile)
		}
		a.voice.mu.Unlock()
		exitDetail := errorText(waitErr)
		if exitDetail == "" {
			exitDetail = "Exited normally"
		}
		appendVoiceDiagnosticEvent("VoLTE route session exited: " + exitDetail)
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			a.voice.mu.Lock()
			a.voice.routeCommand = nil
			a.voice.mu.Unlock()
			return fmt.Errorf("VoLTE route session exited early: %s", errorText(waitErr))
		default:
		}
		if voiceRouteSessionReadyFrom(logOffset) {
			a.voice.mu.Lock()
			a.voice.routeReady = true
			a.voice.mu.Unlock()
			appendVoiceDiagnosticEvent("VoLTE D4 route and AFE mixer ready")
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	terminateVoiceProcess(command)
	return errors.New("VoLTE D4 route session did not become ready in time")
}

func stopVoiceMediaRoute() {
	_ = writeVoiceMediaRoute(voiceMediaRouteFIFO, "T\nT\nB\n")
}

var stopVoiceMediaRouteForLifecycle = stopVoiceMediaRoute

func startVoiceMediaRoute() error {
	if err := writeVoiceMediaRoute(voiceMediaRouteFIFO, "S\n"); err != nil {
		return fmt.Errorf("Failed to start module D5/D6 modem media route: %w", err)
	}
	return nil
}

func writeVoiceMediaRoute(path string, command string) error {
	fifo, err := os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("Failed to open voice route FIFO: %w", err)
	}
	_, writeErr := fifo.WriteString(command)
	closeErr := fifo.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

// prepareVoiceRuntime serializes warmup and the real voice-bridge start so a fast answer cannot insmod or calibrate concurrently.
func prepareVoiceRuntime() error {
	voiceRuntimePrepareMu.Lock()
	defer voiceRuntimePrepareMu.Unlock()
	return prepareVoiceRuntimeUnlocked()
}

func prepareVoiceRuntimeUnlocked() error {
	installed, err := validateVoiceRuntime()
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("Module voice runtime not installed")
	}
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil || !strings.Contains(string(release), voiceExpectedKernel) {
		return fmt.Errorf("Module kernel mismatch: requires %s; found %s", voiceExpectedKernel, strings.TrimSpace(string(release)))
	}
	modules, _ := os.ReadFile("/proc/modules")
	for _, item := range []struct{ file, module string }{{"qdc507_aprv3.ko", "qdc507_aprv3"}, {"qdc507_voice.ko", "qdc507_voice"}} {
		if strings.Contains(string(modules), item.module+" ") {
			continue
		}
		output, commandErr := exec.Command("/sbin/insmod", filepath.Join(voiceRuntimePath, item.file)).CombinedOutput()
		if errors.Is(commandErr, exec.ErrNotFound) {
			output, commandErr = exec.Command("insmod", filepath.Join(voiceRuntimePath, item.file)).CombinedOutput()
		}
		if commandErr != nil {
			return commandFailure("Loading "+item.file+" failed", output, commandErr)
		}
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if voiceDevicesReady() {
			return ensureVoiceCalibration()
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("Voice driver loaded, but ALSA D4/D5/D6 devices did not appear")
}

func voiceDevicesReady() bool {
	for _, device := range voiceRequiredDevices {
		if !fileExists(device) {
			return false
		}
	}
	cards, err := os.ReadFile("/proc/asound/cards")
	return err == nil && strings.Contains(string(cards), voiceExpectedCardName)
}

func ensureVoiceCalibration() error {
	if logContains(voiceCalibrationLog, "ACDB -> Sent VocProc Cal!") {
		return nil
	}
	logFile, err := os.OpenFile(voiceCalibrationLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command("/usr/bin/alsaucm_test")
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		return fmt.Errorf("Failed to start VoLTE ACDB calibration service: %w", err)
	}
	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && !fileExists(voiceCalibrationFIFO) {
		time.Sleep(100 * time.Millisecond)
	}
	if !fileExists(voiceCalibrationFIFO) {
		return errors.New("VoLTE ACDB calibration FIFO did not appear")
	}
	fifo, err := os.OpenFile(voiceCalibrationFIFO, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("Failed to open VoLTE ACDB calibration FIFO: %w", err)
	}
	_, writeErr := fifo.WriteString("open snd_soc_msm_9x07_Tomtom_I2S\nset _verb VoLTE\nset _enadev Auxpcm Rx\nset _enadev Auxpcm Tx\n")
	_ = fifo.Close()
	if writeErr != nil {
		return writeErr
	}
	deadline = time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if logContains(voiceCalibrationLog, "ACDB -> Sent VocProc Cal!") {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("VoLTE ACDB calibration did not confirm completion")
}

func voiceRouteReadyFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteLogReady(data)
}

func voiceRouteListeningFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteListeningLogReady(data)
}

func voiceRouteSessionReadyFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteSessionLogReady(data)
}

func voiceRouteLogReady(data []byte) bool {
	return voiceRouteListeningLogReady(data) &&
		strings.Contains(string(data), "network PCM client connected") &&
		strings.Contains(string(data), "bridge active on 192.168.225.1:7580")
}

func voiceRouteListeningLogReady(data []byte) bool {
	return voiceRouteSessionLogReady(data) &&
		strings.Contains(string(data), "network PCM listening on 192.168.225.1:7580")
}

func voiceRouteSessionLogReady(data []byte) bool {
	return strings.Contains(string(data), "VoLTE route session active on hw:0,4")
}

func (a *agent) stopVoiceRoute() {
	if !a.usesLocalVoiceRuntime() {
		a.voice.mu.Lock()
		a.voice.ready = false
		a.voice.listening = false
		a.voice.routeReady = false
		a.voice.mediaRouteStarted = false
		a.voice.lastError = ""
		a.voice.mu.Unlock()
		a.debug.add("voice-backend", "stopped", "Samsung PCM Agent session released", "", map[string]string{
			"backend": string(a.voiceBackend.kind),
		})
		return
	}
	appendVoiceSystemSnapshot("voice-stop-before")
	// This waits in line with the cold-start lifecycle, but status snapshots use a
	// separate short lock, so /health and /audio/host/config still respond while cleanup waits.
	a.voice.lifecycleMu.Lock()
	a.voice.mu.Lock()
	if a.voice.stopping {
		a.voice.mu.Unlock()
		a.voice.lifecycleMu.Unlock()
		return
	}
	command := a.voice.command
	routeCommand := a.voice.routeCommand
	mediaRouteStarted := a.voice.mediaRouteStarted
	a.voice.ready = false
	a.voice.listening = false
	a.voice.routeReady = false
	a.voice.mediaRouteStarted = false
	a.voice.stopping = true
	// Remove the old process from state first. The next ensureVoiceRoute sees
	// stopping and waits, so the old and new helpers do not both claim port 7580.
	a.voice.command = nil
	a.voice.routeCommand = nil
	a.voice.mu.Unlock()
	// Disconnect the D5/D6 data bridge first, then let the D4 route session roll
	// back the mixer. voc_svr may be written only after a media route actually
	// started. Rejecting a call that never connected must not touch it.
	terminateVoiceProcess(command)
	terminateVoiceProcess(routeCommand)
	if mediaRouteStarted {
		stopVoiceMediaRouteForLifecycle()
	}
	_ = os.Remove(voiceRoutePIDFile)
	_ = os.Remove(voiceSessionPIDFile)
	a.voice.mu.Lock()
	a.voice.stopping = false
	hostEnabled := a.voice.hostEnabled
	a.voice.mu.Unlock()
	appendVoiceSystemSnapshot("voice-stop-after")
	// Release the lifecycle lease before restarting. beginRouteStart uses TryLock,
	// so starting while that lock is still held would treat this required recovery as a duplicate start.
	a.voice.lifecycleMu.Unlock()
	// If a new call connected while stopping, bring the voice bridge back immediately instead of waiting for the next poll.
	a.mu.RLock()
	active := a.calls.Active != nil && a.calls.Active.State == "active"
	a.mu.RUnlock()
	if active && hostEnabled {
		go a.ensureVoiceRoute()
	}
}

func appendVoiceSystemSnapshot(label string) {
	values := []string{
		"pid=" + strconv.Itoa(os.Getpid()),
		"ecm_operstate=" + readSystemState("/sys/class/net/ecm0/operstate"),
		"ecm_carrier=" + readSystemState("/sys/class/net/ecm0/carrier"),
		"ecm_address=" + readSystemState("/sys/class/net/ecm0/address"),
		"usb_state=" + readSystemState("/sys/class/android_usb/android0/state"),
		"usb_enable=" + readSystemState("/sys/class/android_usb/android0/enable"),
		"usb_functions=" + readSystemState("/sys/class/android_usb/android0/functions"),
		"audio_enable=" + readSystemState(voiceAudioEnablePath),
	}
	appendVoiceDiagnosticEvent("System snapshot[" + label + "]: " + strings.Join(values, " "))
}

func readSystemState(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "missing"
		}
		return "error:" + err.Error()
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "empty"
	}
	if len(value) > 160 {
		value = value[:160]
	}
	return strings.Join(strings.Fields(value), ",")
}

func terminateVoiceProcess(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	pid := command.Process.Pid
	_ = command.Process.Signal(syscall.SIGTERM)
	for attempt := 0; attempt < 30; attempt++ {
		if err := syscall.Kill(pid, 0); err != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func logContains(path, marker string) bool {
	data, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(data), marker)
}

// prepareVoiceDiagnosticLog caps the persistent log so a long call cannot fill the module /data partition.
func prepareVoiceDiagnosticLog() error {
	voiceDiagnosticLogMu.Lock()
	defer voiceDiagnosticLogMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(voiceRouteLogFile), 0o700); err != nil {
		return fmt.Errorf("Failed to create voice diagnostics directory: %w", err)
	}
	info, err := os.Stat(voiceRouteLogFile)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("Failed to read voice diagnostics log: %w", err)
	}
	if info.Size() < voiceRouteLogMaxBytes {
		return nil
	}
	if err := os.Rename(voiceRouteLogFile, voiceRouteLogBackup); err != nil {
		return fmt.Errorf("Failed to rotate voice diagnostics log: %w", err)
	}
	return nil
}

// appendVoiceDiagnosticEvent writes control-plane events with UTC timestamps. It does not record phone numbers or raw audio.
func appendVoiceDiagnosticEvent(message string) {
	voiceDiagnosticLogMu.Lock()
	defer voiceDiagnosticLogMu.Unlock()
	if os.MkdirAll(filepath.Dir(voiceRouteLogFile), 0o700) != nil {
		return
	}
	file, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(file, "qdc507-agent[event]: time=%s %s\n", time.Now().UTC().Format(time.RFC3339Nano), message)
	_ = file.Close()
}

func voiceDiagnosticLogSize() int64 {
	info, err := os.Stat(voiceRouteLogFile)
	if err != nil {
		return 0
	}
	return info.Size()
}

func readVoiceDiagnosticLog(offset int64) ([]byte, error) {
	data, err := os.ReadFile(voiceRouteLogFile)
	if err != nil {
		return nil, err
	}
	if offset <= 0 {
		return data, nil
	}
	if offset >= int64(len(data)) {
		return []byte{}, nil
	}
	return data[offset:], nil
}

// parseVoicePCMStats parses the helper's latest cumulative stats for both HTTP and unit tests.
func parseVoicePCMStats(data []byte) (voicePCMStats, bool) {
	lines := strings.Split(string(data), "\n")
	for lineIndex := len(lines) - 1; lineIndex >= 0; lineIndex-- {
		marker := "mavo-pcm-bridge[stats]: "
		markerIndex := strings.Index(lines[lineIndex], marker)
		if markerIndex < 0 {
			continue
		}
		values := make(map[string]uint64)
		for _, field := range strings.Fields(lines[lineIndex][markerIndex+len(marker):]) {
			parts := strings.SplitN(field, "=", 2)
			if len(parts) != 2 {
				continue
			}
			value, err := strconv.ParseUint(parts[1], 10, 64)
			if err == nil {
				values[parts[0]] = value
			}
		}
		return voicePCMStats{
			UplinkBytes:          values["uplink_bytes"],
			UplinkFrames:         values["uplink_frames"],
			UplinkPeak:           values["uplink_peak"],
			DownlinkBytes:        values["downlink_bytes"],
			DownlinkFrames:       values["downlink_frames"],
			DownlinkPeak:         values["downlink_peak"],
			DownlinkDroppedFrame: values["downlink_dropped_frames"],
		}, true
	}
	return voicePCMStats{}, false
}

func voiceDiagnosticSnapshot(offset int64) (voicePCMStats, bool, []string) {
	data, err := os.ReadFile(voiceRouteLogFile)
	if err != nil {
		return voicePCMStats{}, false, []string{}
	}
	statsData := data
	if offset > 0 && offset < int64(len(data)) {
		statsData = data[offset:]
	}
	stats, available := parseVoicePCMStats(statsData)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) > 24 {
		lines = lines[len(lines)-24:]
	}
	if len(lines) == 1 && lines[0] == "" {
		lines = []string{}
	}
	return stats, available, lines
}

func commandFailure(prefix string, output []byte, err error) error {
	detail := strings.TrimSpace(string(output))
	if len(detail) > 1000 {
		detail = detail[len(detail)-1000:]
	}
	if detail == "" {
		return fmt.Errorf("%s: %w", prefix, err)
	}
	return fmt.Errorf("%s: %s (%v)", prefix, detail, err)
}
