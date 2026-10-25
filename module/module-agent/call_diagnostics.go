package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const callDiagnosticLogMaxBytes = 1024 * 1024

var callDiagnosticLogMu sync.Mutex
var callDiagnosticLogFile = agentDataDirectory + "/log/call-control.log"

func appendCallSystemSnapshot(label string) {
	values := []string{
		"pid=" + strconv.Itoa(os.Getpid()),
		"ecm_operstate=" + readSystemState("/sys/class/net/ecm0/operstate"),
		"ecm_carrier=" + readSystemState("/sys/class/net/ecm0/carrier"),
		"ecm_address=" + readSystemState("/sys/class/net/ecm0/address"),
		"usb_state=" + readSystemState("/sys/class/android_usb/android0/state"),
		"usb_enable=" + readSystemState("/sys/class/android_usb/android0/enable"),
		"usb_functions=" + readSystemState("/sys/class/android_usb/android0/functions"),
	}
	appendCallDiagnosticEvent("System snapshot[" + label + "]: " + strings.Join(values, " "))
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

// Only bounded control-state diagnostics survive the retired audio runtime.
func appendCallDiagnosticEvent(message string) {
	callDiagnosticLogMu.Lock()
	defer callDiagnosticLogMu.Unlock()
	if os.MkdirAll(filepath.Dir(callDiagnosticLogFile), 0o700) != nil {
		return
	}
	if info, err := os.Stat(callDiagnosticLogFile); err == nil && info.Size() >= callDiagnosticLogMaxBytes {
		if os.Rename(callDiagnosticLogFile, callDiagnosticLogFile+".1") != nil {
			return
		}
	}
	if len(message) > 4096 {
		message = message[:4096]
	}
	file, err := os.OpenFile(callDiagnosticLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(file, "airsim-agent[event]: time=%s %s\n", time.Now().UTC().Format(time.RFC3339Nano), message)
	_ = file.Close()
}
