package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type cloudCallDescriptor struct {
	CallID         string
	CallUUID       string
	Generation     uint64
	CallSecret     string
	RelayURL       string
	Direction      string
	MediaTransport string
	StartedAt      time.Time
}

func cloudMediaURL(relayURL, callUUID, callSecret string) (string, error) {
	relay, err := url.Parse(strings.TrimSpace(relayURL))
	if err != nil || relay.Scheme != "https" || relay.Host == "" || relay.User != nil {
		return "", errors.New("Cloud call control requires a credential-free HTTPS Relay")
	}
	if strings.TrimSpace(callUUID) == "" || len(callSecret) < 24 {
		return "", errors.New("Invalid cloud call control identity")
	}
	relay.Scheme = "wss"
	relay.Path = "/v1/calls/" + strings.ToLower(callUUID) + "/connect"
	relay.RawQuery = url.Values{"role": {"agent"}}.Encode()
	relay.RawPath, relay.Fragment = "", ""
	return relay.String(), nil
}

type cloudCallAction struct {
	Action     string `json:"action"`
	CallID     string `json:"call_id"`
	CallUUID   string `json:"call_uuid,omitempty"`
	Generation uint64 `json:"generation,omitempty"`
	CommandID  string `json:"command_id,omitempty"`
	TraceID    string `json:"trace_id,omitempty"`
	Owner      string `json:"owner"`
}

func decodeCloudCallAction(data []byte, expectedCallID string) (cloudCallAction, error) {
	return decodeCloudCallActionForDescriptor(data, cloudCallDescriptor{
		CallID: expectedCallID, Generation: 1,
	})
}

func decodeCloudCallActionForDescriptor(data []byte, descriptor cloudCallDescriptor) (cloudCallAction, error) {
	var value cloudCallAction
	if err := json.Unmarshal(data, &value); err != nil {
		return cloudCallAction{}, err
	}
	if value.CallID == "" || value.CallID != descriptor.CallID {
		return cloudCallAction{}, fmt.Errorf("Cloud control does not belong to the current call")
	}
	if value.CallUUID != "" && descriptor.CallUUID != "" &&
		!strings.EqualFold(value.CallUUID, descriptor.CallUUID) {
		return cloudCallAction{}, fmt.Errorf("Cloud control call_uuid does not belong to the current call")
	}
	expectedGeneration := descriptor.Generation
	if expectedGeneration == 0 {
		expectedGeneration = 1
	}
	if value.Generation == 0 {
		value.Generation = expectedGeneration
	} else if value.Generation != expectedGeneration {
		return cloudCallAction{}, fmt.Errorf("Cloud control generation has expired")
	}
	if value.CommandID != "" && !cloudCommandIDPattern.MatchString(value.CommandID) {
		return cloudCallAction{}, fmt.Errorf("Invalid cloud control command_id")
	}
	if len(value.TraceID) > 128 {
		return cloudCallAction{}, fmt.Errorf("Cloud control trace_id is too long")
	}
	// Compatible with Watch Relay sessions that are already up. Newer Relay overwrites owner with the authenticated WebSocket role.
	if value.Owner == "" {
		value.Owner = "watch"
	}
	if value.Owner != "watch" && value.Owner != "iphone" {
		return cloudCallAction{}, errors.New("Invalid cloud call media owner")
	}
	switch value.Action {
	case "answer", "reject", "end":
		return value, nil
	default:
		return cloudCallAction{}, errors.New("Unsupported cloud call action")
	}
}

func cloudCallTraceFields(descriptor cloudCallDescriptor, action cloudCallAction) map[string]string {
	generation := descriptor.Generation
	if generation == 0 {
		generation = 1
	}
	fields := map[string]string{
		"call_id": descriptor.CallID, "call_uuid": strings.ToLower(descriptor.CallUUID),
		"generation":   fmt.Sprintf("%d", generation),
		"media_status": "upgrade_required",
	}
	if action.Action != "" {
		fields["action"] = action.Action
	}
	if action.CommandID != "" {
		fields["command_id"] = strings.ToLower(action.CommandID)
	}
	if action.TraceID != "" {
		fields["trace_id"] = action.TraceID
	}
	if action.Owner != "" {
		fields["owner"] = action.Owner
	}
	return fields
}

func cloudStatusForAction(status, message string, descriptor cloudCallDescriptor, action cloudCallAction) []byte {
	generation := descriptor.Generation
	if generation == 0 {
		generation = 1
	}
	value := map[string]any{
		"status": status, "call_id": descriptor.CallID,
		"call_uuid": strings.ToLower(descriptor.CallUUID), "generation": generation,
	}
	if action.Action != "" {
		value["action"] = action.Action
	}
	if action.CommandID != "" {
		value["command_id"] = strings.ToLower(action.CommandID)
	}
	if action.TraceID != "" {
		value["trace_id"] = action.TraceID
	}
	if message != "" {
		value["message"] = message
	}
	if message == avfVoiceUpgradeMessage {
		value["code"] = "upgrade_required"
	}
	data, _ := json.Marshal(value)
	return data
}

func (a *agent) startCloudCall(descriptor cloudCallDescriptor) {
	descriptor.MediaTransport = ""
	if descriptor.Generation == 0 {
		descriptor.Generation = 1
	}
	if descriptor.StartedAt.IsZero() {
		descriptor.StartedAt = time.Now()
	}
	a.cloudCallMu.Lock()
	if a.cloudCallCancel != nil {
		a.cloudCallCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	a.cloudCallCancel = cancel
	current := descriptor
	a.cloudCallCurrent = &current
	a.cloudCallMu.Unlock()
	go a.runCloudCall(ctx, descriptor)
}

func (a *agent) currentCloudCallDescriptor() (cloudCallDescriptor, bool) {
	a.cloudCallMu.Lock()
	defer a.cloudCallMu.Unlock()
	if a.cloudCallCurrent == nil {
		return cloudCallDescriptor{}, false
	}
	return *a.cloudCallCurrent, true
}

func (a *agent) retireCloudCallDescriptor(descriptor cloudCallDescriptor) {
	a.cloudCallMu.Lock()
	defer a.cloudCallMu.Unlock()
	if a.cloudCallCurrent == nil ||
		a.cloudCallCurrent.CallID != descriptor.CallID ||
		!strings.EqualFold(a.cloudCallCurrent.CallUUID, descriptor.CallUUID) ||
		a.cloudCallCurrent.Generation != descriptor.Generation {
		return
	}
	if a.cloudCallCancel != nil {
		a.cloudCallCancel()
	}
	a.cloudCallCancel = nil
	a.cloudCallCurrent = nil
}

func (a *agent) runCloudCall(ctx context.Context, descriptor cloudCallDescriptor) {
	descriptor.MediaTransport = ""
	endpoint, err := cloudMediaURL(descriptor.RelayURL, descriptor.CallUUID, descriptor.CallSecret)
	if err != nil {
		a.debug.add("cloud-call", "error", "Invalid cloud call control address", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
		return
	}
	retries := 0
	deadline := time.Now().Add(3 * time.Minute)
	for ctx.Err() == nil && time.Now().Before(deadline) && a.cloudCallDescriptorAlive(descriptor) {
		socket, err := dialCloudWebSocketAuthorized(ctx, endpoint, descriptor.CallSecret)
		if err != nil {
			a.debug.add("cloud-call", "error", "Failed to connect cloud call control", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
			if retries >= 3 {
				a.debug.add(
					"cloud-call", "failed", "Cloud call control reached its reconnect limit", err.Error(),
					cloudCallTraceFields(descriptor, cloudCallAction{}),
				)
				return
			}
			retries++
			if !waitCloudRetry(ctx, 2*time.Second) {
				return
			}
			continue
		}
		a.debug.add("cloud-call", "connected", "Cloud call control connected", "", cloudCallTraceFields(descriptor, cloudCallAction{}))
		terminal := a.serveCloudCall(ctx, socket, descriptor)
		_ = socket.Close()
		if terminal {
			return
		}
		if retries >= 3 {
			a.debug.add(
				"cloud-call", "failed", "Cloud call control reached its reconnect limit", "",
				cloudCallTraceFields(descriptor, cloudCallAction{}),
			)
			return
		}
		retries++
		if !waitCloudRetry(ctx, time.Second) {
			return
		}
	}
}

func (a *agent) cloudCallDescriptorAlive(descriptor cloudCallDescriptor) bool {
	if descriptor.Direction != "outgoing" {
		return a.cloudCallStillExists(descriptor.CallID)
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.calls.Active != nil && a.calls.Active.Direction == "outgoing" {
		return true
	}
	// A short gap with no local call record is allowed between a successful ATD and the first CLCC/DSCI.
	return !descriptor.StartedAt.IsZero() && time.Since(descriptor.StartedAt) < 20*time.Second
}

func waitCloudRetry(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func (a *agent) cloudCallStillExists(callID string) bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.calls.Active != nil && a.calls.Active.ID == callID
}

func (a *agent) serveCloudCall(
	ctx context.Context,
	socket *cloudWebSocket,
	descriptor cloudCallDescriptor,
) bool {
	_ = socket.WriteText(cloudStatusForAction("upgrade_required", avfVoiceUpgradeMessage, descriptor, cloudCallAction{}))

	watchEnded := make(chan struct{})
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		seenOutgoing := false
		missingSince := time.Now()
		for {
			select {
			case <-ctx.Done():
				_ = socket.Close()
				return
			case <-watchEnded:
				return
			case <-ticker.C:
				alive := false
				if descriptor.Direction == "outgoing" {
					a.mu.RLock()
					alive = a.calls.Active != nil && a.calls.Active.Direction == "outgoing"
					a.mu.RUnlock()
					seenOutgoing = seenOutgoing || alive
					if !seenOutgoing && time.Since(missingSince) < 20*time.Second {
						continue
					}
				} else {
					alive = a.cloudCallStillExists(descriptor.CallID)
				}
				if alive {
					continue
				}
				_ = socket.WriteText(cloudStatus("remote_ended", ""))
				_ = socket.Close()
				return
			}
		}
	}()
	defer close(watchEnded)

	for ctx.Err() == nil {
		opcode, payload, err := socket.ReadMessage()
		if err != nil {
			a.debug.add("cloud-call", "disconnected", "Cloud call control disconnected", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
			return false
		}
		switch opcode {
		case cloudOpcodeBinary:
			a.debug.add("cloud-call", "rejected", "Binary media frames are not supported", "", cloudCallTraceFields(descriptor, cloudCallAction{}))
			return true
		case cloudOpcodeText:
			control, err := decodeCloudCallActionForDescriptor(payload, descriptor)
			if err != nil {
				_ = socket.WriteText(cloudStatus("action_error", err.Error()))
				a.debug.add("cloud-call-control", "rejected", "Cloud call control validation failed", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
				continue
			}
			fields := cloudCallTraceFields(descriptor, control)
			a.debug.add("cloud-call-control", "received", "Cloud call control received", "", fields)
			switch control.Action {
			case "answer":
				_ = socket.WriteText(cloudStatusForAction("action_error", avfVoiceUpgradeMessage, descriptor, control))
				a.debug.add("cloud-call-control", "rejected", avfVoiceUpgradeMessage, "", fields)
			case "reject":
				a.debug.add("cloud-call-control", "modem_executing", "Executing decline command", a.callControlBackendDescription(), fields)
				if err := a.executeIncomingCloudCallAction(control, "reject"); err != nil {
					_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
					a.debug.add("cloud-call-control", "failed", "Cloud decline failed", err.Error(), fields)
					continue
				}
				_ = socket.WriteText(cloudStatusForAction("rejected", "", descriptor, control))
				a.debug.add("cloud-call-control", "completed", "Cloud decline command executed", "", fields)
				go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "ended") }()
				return true
			case "end":
				if a.profile.AndroidTelecom {
					a.debug.add("cloud-call-control", "modem_executing", "Executing end-call command", a.callControlBackendDescription(), fields)
					if err := a.executeIncomingCloudCallAction(control, "end"); err != nil {
						_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
						a.debug.add("cloud-call-control", "failed", "Cloud end-call failed", err.Error(), fields)
						continue
					}
					_ = socket.WriteText(cloudStatusForAction("ended", "", descriptor, control))
					a.debug.add("cloud-call-control", "completed", "Cloud end-call accepted by Android Telecom", "", fields)
					go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "ended") }()
					return true
				}
				a.debug.add("cloud-call-control", "modem_executing", "Ending call and confirming modem state", "ATH (fallback to AT+CHUP on failure) -> AT+CLCC", fields)
				attempts, lastCLCC, err := a.hangupCallConfirmed()
				if err != nil {
					_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
					a.debug.add("cloud-call-control", "failed", "Cloud end-call failed", err.Error(), fields)
					continue
				}
				_ = socket.WriteText(cloudStatusForAction("ended", "", descriptor, control))
				fields["clcc_attempts"] = fmt.Sprintf("%d", attempts)
				a.debug.add("cloud-call-control", "completed", "Cloud end-call confirmed by CLCC", lastCLCC, fields)
				go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "ended") }()
				return true
			}
		}
	}
	return false
}

func (a *agent) callControlBackendDescription() string {
	if a.profile.AndroidTelecom {
		return "Android Telecom"
	}
	return "AT"
}

func (a *agent) executeIncomingCloudCallAction(control cloudCallAction, action string) error {
	if action == "answer" {
		return errAVFVoiceUpgradeRequired
	}
	if !a.profile.AndroidTelecom {
		switch action {
		case "reject":
			return a.rejectCall()
		default:
			return fmt.Errorf("Unsupported call action: %s", action)
		}
	}
	commandID := control.CommandID
	if commandID == "" {
		commandID = fmt.Sprintf("cloud-%d", time.Now().UnixNano())
	}
	result := a.executeAndroidCallCommandForID(commandID, action, control.CallID)
	if result.Success {
		return nil
	}
	if result.Error == "" {
		result.Error = "Android Telecom did not confirm command"
	}
	return errors.New(result.Error)
}

func cloudStatus(status, message string) []byte {
	value := map[string]string{"status": status}
	if message != "" {
		value["message"] = message
	}
	data, _ := json.Marshal(value)
	return data
}

const (
	cloudOpcodeText   = byte(1)
	cloudOpcodeBinary = byte(2)
	cloudOpcodeClose  = byte(8)
	cloudOpcodePing   = byte(9)
	cloudOpcodePong   = byte(10)
)

type cloudWebSocket struct {
	conn      net.Conn
	reader    *bufio.Reader
	writeMu   sync.Mutex
	closeOnce sync.Once
}

func dialCloudWebSocketAuthorized(ctx context.Context, endpoint, bearerToken string) (*cloudWebSocket, error) {
	target, err := url.Parse(endpoint)
	if err != nil || target.Scheme != "wss" || target.Host == "" || target.User != nil {
		return nil, errors.New("Invalid WSS address")
	}
	if bearerToken == "" || strings.ContainsAny(bearerToken, "\r\n") {
		return nil, errors.New("A valid bearer credential is required")
	}
	host := target.Host
	if !strings.Contains(host, ":") {
		host += ":443"
	}
	dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	configurePushDialer(dialer)
	rawConnection, err := dialPushAddress(ctx, dialer, "tcp", host)
	if err != nil {
		return nil, err
	}
	connection := tls.Client(rawConnection, &tls.Config{
		ServerName: target.Hostname(), MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"},
	})
	handshakeContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if err := connection.HandshakeContext(handshakeContext); err != nil {
		_ = rawConnection.Close()
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	} else {
		_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	}

	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		_ = connection.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	path := target.EscapedPath()
	if path == "" {
		path = "/"
	}
	if target.RawQuery != "" {
		path += "?" + target.RawQuery
	}
	authorization := ""
	if bearerToken != "" {
		authorization = "Authorization: Bearer " + bearerToken + "\r\n"
	}
	request := fmt.Sprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%sUser-Agent: AirSIM-AVF/%s\r\n\r\n",
		path, target.Host, key, authorization, agentVersion,
	)
	if _, err := io.WriteString(connection, request); err != nil {
		_ = connection.Close()
		return nil, err
	}
	reader := bufio.NewReader(connection)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		_ = connection.Close()
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusSwitchingProtocols ||
		!strings.EqualFold(response.Header.Get("Upgrade"), "websocket") ||
		response.Header.Get("Sec-WebSocket-Accept") != cloudWebSocketAccept(key) {
		_ = connection.Close()
		return nil, fmt.Errorf("Cloud WebSocket handshake returned HTTP %d", response.StatusCode)
	}
	_ = connection.SetDeadline(time.Time{})
	return &cloudWebSocket{conn: connection, reader: reader}, nil
}

func cloudWebSocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func (socket *cloudWebSocket) WriteText(data []byte) error {
	return socket.writeMessage(cloudOpcodeText, data)
}
func (socket *cloudWebSocket) writeMessage(opcode byte, payload []byte) error {
	if opcode == cloudOpcodeBinary {
		return errors.New("Binary media frames are not supported")
	}
	if len(payload) > 65_535 {
		return errors.New("WebSocket frame too large")
	}
	socket.writeMu.Lock()
	defer socket.writeMu.Unlock()
	header := []byte{0x80 | opcode}
	switch {
	case len(payload) < 126:
		header = append(header, 0x80|byte(len(payload)))
	default:
		header = append(header, 0x80|126, byte(len(payload)>>8), byte(len(payload)))
	}
	mask := make([]byte, 4)
	if _, err := rand.Read(mask); err != nil {
		return err
	}
	header = append(header, mask...)
	encoded := make([]byte, len(payload))
	for index := range payload {
		encoded[index] = payload[index] ^ mask[index%4]
	}
	if _, err := socket.conn.Write(header); err != nil {
		return err
	}
	_, err := socket.conn.Write(encoded)
	return err
}

func (socket *cloudWebSocket) ReadMessage() (byte, []byte, error) {
	for {
		first, err := socket.reader.ReadByte()
		if err != nil {
			return 0, nil, err
		}
		second, err := socket.reader.ReadByte()
		if err != nil {
			return 0, nil, err
		}
		opcode := first & 0x0f
		length := uint64(second & 0x7f)
		if length == 126 {
			var value uint16
			if err := binary.Read(socket.reader, binary.BigEndian, &value); err != nil {
				return 0, nil, err
			}
			length = uint64(value)
		} else if length == 127 {
			if err := binary.Read(socket.reader, binary.BigEndian, &length); err != nil {
				return 0, nil, err
			}
		}
		if length > 65_535 {
			return 0, nil, errors.New("Cloud WebSocket frame too large")
		}
		var mask [4]byte
		masked := second&0x80 != 0
		if masked {
			if _, err := io.ReadFull(socket.reader, mask[:]); err != nil {
				return 0, nil, err
			}
		}
		payload := make([]byte, int(length))
		if _, err := io.ReadFull(socket.reader, payload); err != nil {
			return 0, nil, err
		}
		if masked {
			for index := range payload {
				payload[index] ^= mask[index%4]
			}
		}
		switch opcode {
		case cloudOpcodePing:
			if err := socket.writeMessage(cloudOpcodePong, payload); err != nil {
				return 0, nil, err
			}
			continue
		case cloudOpcodePong:
			continue
		case cloudOpcodeClose:
			return 0, nil, io.EOF
		case cloudOpcodeText, cloudOpcodeBinary:
			return opcode, payload, nil
		default:
			return 0, nil, errors.New("Unsupported WebSocket frame")
		}
	}
}

func (socket *cloudWebSocket) Close() error {
	var err error
	socket.closeOnce.Do(func() {
		_ = socket.writeMessage(cloudOpcodeClose, nil)
		err = socket.conn.Close()
	})
	return err
}
