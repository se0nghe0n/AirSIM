package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var cloudCommandIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,36}$`)

type cloudCommandCall struct {
	CallID         string `json:"call_id"`
	CallUUID       string `json:"call_uuid"`
	Generation     uint64 `json:"generation,omitempty"`
	CallSecret     string `json:"call_secret"`
	RelayURL       string `json:"relay_url"`
	Direction      string `json:"direction"`
	MediaTransport string `json:"media_transport,omitempty"`
}

type cloudDeviceCommand struct {
	CommandID string            `json:"command_id"`
	Type      string            `json:"type"`
	Action    string            `json:"action,omitempty"`
	TraceID   string            `json:"trace_id,omitempty"`
	Owner     string            `json:"owner,omitempty"`
	ExpiresAt string            `json:"expires_at"`
	Number    string            `json:"number"`
	Message   string            `json:"message,omitempty"`
	Call      *cloudCommandCall `json:"call,omitempty"`
}

type cloudCommandResult struct {
	CommandID string         `json:"command_id"`
	Status    string         `json:"status"`
	Result    map[string]any `json:"result,omitempty"`
	Error     string         `json:"error,omitempty"`
}

func cloudCommandURL(registration pushRegistration) (string, error) {
	relay, err := url.Parse(strings.TrimSpace(registration.RelayURL))
	if err != nil || relay.Scheme != "https" || relay.Host == "" || relay.User != nil {
		return "", errors.New("Cloud commands require a credential-free HTTPS Relay")
	}
	if registration.DeviceID == "" || registration.DeviceSecret == "" {
		return "", errors.New("Invalid cloud command device identity")
	}
	relay.Scheme = "wss"
	relay.Path = "/v1/devices/" + url.PathEscape(registration.DeviceID) + "/commands/connect"
	relay.RawQuery = ""
	return relay.String(), nil
}

func cloudCommandReconnectDelay(failures int) time.Duration {
	if failures < 1 {
		failures = 1
	}
	delay := 3 * time.Second
	for attempt := 1; attempt < failures && delay < 15*time.Second; attempt++ {
		delay *= 2
	}
	if delay > 15*time.Second {
		return 15 * time.Second
	}
	return delay
}

func (a *agent) cloudCommandLoop() {
	failures := 0
	for {
		registration, ready := a.push.commandRegistration()
		if !ready {
			failures = 0
			time.Sleep(3 * time.Second)
			continue
		}
		endpoint, err := cloudCommandURL(registration)
		if err != nil {
			a.debug.add("cloud-command", "error", "Invalid cloud command address", err.Error(), nil)
			failures++
			time.Sleep(cloudCommandReconnectDelay(failures))
			continue
		}
		if err := a.syncCloudCommandsOnce(); err != nil {
			a.debug.add("cloud-command", "pull_failed", "Failed to fetch pending commands before WebSocket connection", err.Error(), nil)
		}
		ctx, cancel := context.WithCancel(context.Background())
		socket, err := dialCloudWebSocketAuthorized(ctx, endpoint, registration.DeviceSecret)
		if err != nil {
			cancel()
			a.debug.add("cloud-command", "error", "Failed to connect cloud command channel", err.Error(), nil)
			failures++
			time.Sleep(cloudCommandReconnectDelay(failures))
			continue
		}
		connectedAt := time.Now()
		a.debug.add("cloud-command", "event", "Cloud dialing and SMS channel connected", "", nil)
		a.serveCloudCommands(ctx, socket)
		_ = socket.Close()
		cancel()
		if time.Since(connectedAt) >= time.Minute {
			failures = 0
		} else {
			failures++
		}
		time.Sleep(cloudCommandReconnectDelay(failures))
	}
}

func (a *agent) syncCloudCommandsOnce() error {
	commands, err := a.push.pullCommands()
	if err != nil {
		return err
	}
	for _, command := range commands {
		result := a.executeCloudCommand(command)
		if err := a.push.completeCommand(result); err != nil {
			return fmt.Errorf("Failed to report result for command %s: %w", command.CommandID, err)
		}
	}
	return nil
}

func (a *agent) serveCloudCommands(ctx context.Context, socket *cloudWebSocket) {
	keepaliveDone := make(chan struct{})
	go func() {
		ticker := time.NewTicker(20 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-keepaliveDone:
				return
			case <-ticker.C:
				if err := socket.writeMessage(cloudOpcodePing, []byte("command-keepalive")); err != nil {
					_ = socket.Close()
					return
				}
			}
		}
	}()
	defer close(keepaliveDone)
	for ctx.Err() == nil {
		opcode, payload, err := socket.ReadMessage()
		if err != nil {
			return
		}
		if opcode != cloudOpcodeText {
			continue
		}
		var command cloudDeviceCommand
		if err := json.Unmarshal(payload, &command); err != nil {
			continue
		}
		result := a.executeCloudCommand(command)
		encoded, _ := json.Marshal(result)
		if err := socket.WriteText(encoded); err != nil {
			return
		}
	}
}

func (a *agent) executeCloudCommand(command cloudDeviceCommand) cloudCommandResult {
	a.cloudCommandExecMu.Lock()
	defer a.cloudCommandExecMu.Unlock()
	if !cloudCommandIDPattern.MatchString(command.CommandID) {
		return cloudCommandResult{CommandID: command.CommandID, Status: "failed", Error: "Invalid cloud command ID"}
	}
	if result, exists := a.cachedCloudCommandResult(command.CommandID); exists {
		return result
	}

	if expiry, err := time.Parse(time.RFC3339Nano, command.ExpiresAt); err != nil || time.Now().After(expiry) {
		return a.rememberCloudCommandResult(cloudCommandResult{
			CommandID: command.CommandID, Status: "failed", Error: "Cloud command expired",
		})
	}
	result := cloudCommandResult{CommandID: command.CommandID, Status: "completed"}
	switch command.Type {
	case "dial":
		value, err := a.dialNumber(command.Number)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		result.Result = value
		if command.Call == nil || command.Call.Direction != "outgoing" {
			result.Status, result.Error = "failed", "Cloud outgoing-call media credentials missing"
			break
		}
		a.startCloudCall(cloudCallDescriptor{
			CallID: command.Call.CallID, CallUUID: command.Call.CallUUID,
			Generation: command.Call.Generation,
			CallSecret: command.Call.CallSecret, RelayURL: command.Call.RelayURL,
			Direction: "outgoing", MediaTransport: command.Call.MediaTransport, StartedAt: time.Now(),
		})
	case "send_sms":
		segments, err := a.sendSMSMessage(command.Number, command.Message)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		result.Result = map[string]any{"sent": true, "segments": segments}
	case "dtmf":
		if err := a.sendDTMFDigit(command.Number); err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		result.Result = map[string]any{"sent": true}
	case "call_control":
		descriptor, err := a.validateCloudCallCommand(command)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		fields := cloudCallTraceFields(descriptor, cloudCallAction{
			Action: command.Action, CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
			Generation: descriptor.Generation, CommandID: command.CommandID,
			TraceID: command.TraceID, Owner: command.Owner,
		})
		a.debug.add("cloud-call-control", "received", "Call command received on independent control channel", "", fields)
		if a.profile.AndroidTelecom {
			androidAction := command.Action
			if androidAction == "rescue_hangup" {
				androidAction = "end"
			}
			androidResult := a.executeAndroidCallCommandForID(command.CommandID, androidAction, descriptor.CallID)
			if !androidResult.Success {
				result.Status, result.Error = "failed", androidResult.Error
				a.debug.add("cloud-call-control", "failed", "Android Telecom command failed", androidResult.Error, fields)
				break
			}
			switch command.Action {
			case "answer":
				result.Result = map[string]any{"answered": true, "android_confirmed": true}
			case "end", "reject", "rescue_hangup":
				result.Result = map[string]any{"ended": true, "android_confirmed": true}
				a.retireCloudCallDescriptor(descriptor)
				if a.push != nil {
					go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, command.Owner, "ended") }()
				}
			default:
				result.Status, result.Error = "failed", "Unsupported cloud call control action"
			}
			break
		}
		switch command.Action {
		case "end", "reject", "rescue_hangup":
			a.debug.add("cloud-call-control", "modem_executing", "Ending call and confirming modem state", "ATH (fallback to AT+CHUP on failure) -> AT+CLCC", fields)
			attempts, lastCLCC, hangupErr := a.hangupCallConfirmed()
			if hangupErr != nil {
				result.Status, result.Error = "failed", hangupErr.Error()
				a.debug.add("cloud-call-control", "failed", "Independent-channel end-call not confirmed by CLCC", hangupErr.Error(), fields)
				break
			}
			fields["clcc_attempts"] = fmt.Sprintf("%d", attempts)
			result.Result = map[string]any{
				"ended": true, "modem_confirmed": true,
				"clcc_attempts": attempts, "last_clcc": lastCLCC,
			}
			a.debug.add("cloud-call-control", "completed", "Independent-channel end-call confirmed by CLCC", lastCLCC, fields)
			a.retireCloudCallDescriptor(descriptor)
			if a.push != nil {
				go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, command.Owner, "ended") }()
			}
		case "answer":
			if err := a.answerCall(); err != nil {
				result.Status, result.Error = "failed", err.Error()
				break
			}
			result.Result = map[string]any{"answered": true}
		default:
			result.Status, result.Error = "failed", "Unsupported cloud call control action"
		}
	default:
		result.Status, result.Error = "failed", fmt.Sprintf("Unsupported cloud command: %s", command.Type)
	}
	return a.rememberCloudCommandResult(result)
}

func (a *agent) executeAndroidCallCommand(commandID, action string) androidCommandResult {
	return a.executeAndroidCallCommandWithNumber(commandID, action, "")
}

func (a *agent) executeAndroidCallCommandForID(commandID, action, expectedID string) androidCommandResult {
	return a.executeAndroidCallCommandWithNumberForID(commandID, action, "", expectedID)
}

func (a *agent) executeAndroidCallCommandWithNumber(commandID, action, number string) androidCommandResult {
	return a.executeAndroidCallCommandWithNumberForID(commandID, action, number, "")
}

func (a *agent) executeAndroidCallCommandWithNumberForID(commandID, action, number, expectedID string) androidCommandResult {
	switch action {
	case "answer", "reject", "end", "dtmf":
	default:
		return androidCommandResult{ID: commandID, Error: "unsupported Android Telecom action"}
	}
	a.mu.RLock()
	callID := ""
	if a.calls.Active != nil {
		if expectedID != "" && a.calls.Active.ID != expectedID {
			a.mu.RUnlock()
			return androidCommandResult{ID: commandID, Error: "Call ID is no longer valid"}
		}
		callID = a.calls.Active.AndroidID
	}
	a.mu.RUnlock()
	if callID == "" {
		return androidCommandResult{ID: commandID, Error: "Android Telecom active call unavailable"}
	}
	result := a.android.execute(context.Background(), androidCommand{
		ID: commandID, Action: action, CallID: callID, Number: number,
	}, 12*time.Second)
	if action == "answer" && result.Success {
		if err := a.waitForAndroidCallState(callID, "active", 8*time.Second); err != nil {
			result.Success = false
			result.Error = err.Error()
		}
	}
	return result
}

func (a *agent) waitForAndroidCallState(androidCallID, expectedState string, timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		a.mu.RLock()
		active := a.calls.Active
		changed := a.callChanged
		if active != nil && active.AndroidID == androidCallID && active.State == expectedState {
			a.mu.RUnlock()
			return nil
		}
		callStillExists := active != nil && active.AndroidID == androidCallID
		a.mu.RUnlock()
		if !callStillExists {
			return errors.New("Android Telecom call ended before state confirmation")
		}
		select {
		case <-changed:
		case <-timer.C:
			return fmt.Errorf("Android Telecom did not confirm call state %s", expectedState)
		}
	}
}

func (a *agent) cachedCloudCommandResult(commandID string) (cloudCommandResult, bool) {
	a.cloudCommandMu.Lock()
	defer a.cloudCommandMu.Unlock()
	result, exists := a.cloudCommandResults[commandID]
	if !exists {
		return cloudCommandResult{}, false
	}
	if expiry, ok := a.cloudCommandExpiry[commandID]; !ok || !expiry.After(time.Now()) {
		delete(a.cloudCommandResults, commandID)
		delete(a.cloudCommandExpiry, commandID)
		return cloudCommandResult{}, false
	}
	return result, true
}

func (a *agent) validateCloudCallCommand(command cloudDeviceCommand) (cloudCallDescriptor, error) {
	if command.Call == nil {
		return cloudCallDescriptor{}, errors.New("Cloud call control is missing call identity")
	}
	current, ok := a.currentCloudCallDescriptor()
	if !ok {
		return cloudCallDescriptor{}, errors.New("No controllable cloud call")
	}
	if command.Call.CallID != current.CallID ||
		!strings.EqualFold(command.Call.CallUUID, current.CallUUID) {
		return cloudCallDescriptor{}, errors.New("Cloud call control does not belong to the current call")
	}
	expectedGeneration := current.Generation
	if expectedGeneration == 0 {
		expectedGeneration = 1
	}
	generation := command.Call.Generation
	if generation == 0 {
		generation = 1
	}
	if generation != expectedGeneration {
		return cloudCallDescriptor{}, errors.New("Cloud call control generation has expired")
	}
	if command.Owner != "iphone" && command.Owner != "watch" {
		return cloudCallDescriptor{}, errors.New("Invalid cloud call control owner")
	}
	if len(command.TraceID) > 128 {
		return cloudCallDescriptor{}, errors.New("Cloud call control trace_id is too long")
	}
	return current, nil
}

func (a *agent) rememberCloudCommandResult(result cloudCommandResult) cloudCommandResult {
	a.cloudCommandMu.Lock()
	defer a.cloudCommandMu.Unlock()
	if a.cloudCommandResults == nil {
		a.cloudCommandResults = make(map[string]cloudCommandResult)
	}
	if a.cloudCommandExpiry == nil {
		a.cloudCommandExpiry = make(map[string]time.Time)
	}
	now := time.Now()
	for commandID, expiry := range a.cloudCommandExpiry {
		if !expiry.After(now) {
			delete(a.cloudCommandExpiry, commandID)
			delete(a.cloudCommandResults, commandID)
		}
	}
	if len(a.cloudCommandResults) >= 256 {
		oldestID := ""
		oldestExpiry := time.Time{}
		for commandID, expiry := range a.cloudCommandExpiry {
			if oldestID == "" || expiry.Before(oldestExpiry) {
				oldestID, oldestExpiry = commandID, expiry
			}
		}
		if oldestID != "" {
			delete(a.cloudCommandExpiry, oldestID)
			delete(a.cloudCommandResults, oldestID)
		}
	}
	a.cloudCommandResults[result.CommandID] = result
	a.cloudCommandExpiry[result.CommandID] = now.Add(10 * time.Minute)
	return result
}
