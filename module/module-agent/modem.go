package main

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// modemStatus exposes only the stable fields the iPad client needs. Raw AT responses are not written to logs or the network.
type modemStatus struct {
	IMEI             string `json:"imei,omitempty"`
	Firmware         string `json:"firmware,omitempty"`
	ICCID            string `json:"iccid,omitempty"`
	IMSI             string `json:"imsi,omitempty"`
	Operator         string `json:"operator,omitempty"`
	SIMInserted      bool   `json:"sim_inserted"`
	SignalDBM        *int   `json:"signal_dbm"`
	NetworkMode      string `json:"network_mode,omitempty"`
	RadioBand        string `json:"radio_band,omitempty"`
	RegistrationText string `json:"reg_status_text,omitempty"`
	CellularState    string `json:"cellular_state,omitempty"`
	RecoveryState    string `json:"cellular_recovery,omitempty"`
	LastRegisteredAt string `json:"last_registered_at,omitempty"`
	LastError        string `json:"-"`
}

var (
	csqPattern     = regexp.MustCompile(`\+CSQ:\s*(\d+),`)
	copsPattern    = regexp.MustCompile(`\+COPS:\s*\d+\s*,\s*\d+\s*,\s*"([^"]*)"`)
	regPattern     = regexp.MustCompile(`\+(?:CE)?REG:\s*(?:\d+\s*,\s*)?(\d+)`)
	qnwInfoPattern = regexp.MustCompile(`\+QNWINFO:\s*"([^"]*)"\s*,\s*"[^"]*"\s*,\s*"([^"]*)"`)
	digitsPattern  = regexp.MustCompile(`^[0-9]{5,22}$`)
)

// refreshModem remains the full refresh entry point. Background scheduling runs static and dynamic fields separately.
func (a *agent) refreshModem() {
	a.refreshModemStatic()
	a.refreshModemDynamic()
}

func (a *agent) refreshModemStatic() {
	type result struct {
		value string
		ok    bool
	}
	run := func(command string) result {
		response, err := a.at.command(command, 3*time.Second)
		return result{value: response, ok: err == nil}
	}

	firmware := run("ATI")
	cpin := run("AT+CPIN?")
	iccid := run("AT+QCCID")
	imsi := run("AT+CIMI")
	imei := run("AT+CGSN")
	// Registration-status URCs affect only the current session. On failure, the polling compatibility path stays in place.
	_, _ = a.at.command("AT+CEREG=1", 3*time.Second)

	a.mu.Lock()
	if firmware.ok {
		a.modem.Firmware = parseFirmware(firmware.value)
	}
	if cpin.ok {
		a.modem.SIMInserted = strings.Contains(strings.ToUpper(cpin.value), "READY")
	}
	if iccid.ok {
		a.modem.ICCID = commandValue(iccid.value, "+QCCID:")
	}
	if imsi.ok {
		a.modem.IMSI = firstNumericLine(imsi.value)
	}
	if imei.ok {
		a.modem.IMEI = firstNumericLine(imei.value)
	}
	a.mu.Unlock()
}

// refreshModemDynamic refreshes only radio state that can change, so identity and firmware are not read again.
func (a *agent) refreshModemDynamic() {
	var failures []string
	run := func(command string) (string, bool) {
		response, err := a.at.command(command, 2*time.Second)
		if err != nil {
			failures = append(failures, command+": "+err.Error())
			return response, false
		}
		return response, true
	}

	cpin, cpinOK := run("AT+CPIN?")
	operator, operatorOK := run("AT+COPS?")
	signal, signalOK := run("AT+CSQ")
	network, networkOK := run("AT+QNWINFO")
	registrationResponse, registrationOK := run("AT+CEREG?")
	registration := parseRegistration(registrationResponse)
	if !registrationOK {
		registrationResponse, registrationOK = run("AT+CREG?")
		registration = parseRegistration(registrationResponse)
	}

	a.mu.Lock()
	if cpinOK {
		a.modem.SIMInserted = strings.Contains(strings.ToUpper(cpin), "READY")
	}
	if operatorOK {
		a.modem.Operator = normalizeOperator(parseOperator(operator))
	}
	if signalOK {
		a.modem.SignalDBM = parseSignalDBM(signal)
	}
	if networkOK {
		a.modem.NetworkMode, a.modem.RadioBand = parseNetworkInfo(network)
	}
	if registrationOK {
		a.modem.RegistrationText = registrationText(registration)
	}
	if len(failures) > 0 {
		a.modem.LastError = strings.Join(failures, "; ")
	} else {
		a.modem.LastError = ""
	}
	a.mu.Unlock()
	if registrationOK {
		a.observeCellularRegistration(registration, "poll")
	}
}

func parseFirmware(response string) string {
	var useful []string
	for _, line := range strings.Split(response, "\n") {
		line = strings.TrimSpace(line)
		upper := strings.ToUpper(line)
		if line == "" || upper == "OK" || upper == "ATI" || strings.HasPrefix(upper, "AT+") {
			continue
		}
		useful = append(useful, line)
	}
	return strings.Join(useful, " · ")
}

func firstNumericLine(response string) string {
	for _, line := range strings.Split(response, "\n") {
		line = strings.TrimSpace(line)
		if digitsPattern.MatchString(line) {
			return line
		}
	}
	return ""
}

func parseSignalDBM(response string) *int {
	match := csqPattern.FindStringSubmatch(response)
	if len(match) != 2 {
		return nil
	}
	rssi, err := strconv.Atoi(match[1])
	if err != nil || rssi == 99 || rssi > 31 {
		return nil
	}
	value := -113 + 2*rssi
	return &value
}

func parseOperator(response string) string {
	match := copsPattern.FindStringSubmatch(response)
	if len(match) != 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func normalizeOperator(value string) string {
	upper := strings.ToUpper(strings.TrimSpace(value))
	switch {
	case strings.Contains(upper, "MOBILE") || upper == "CMCC" || upper == "46000" || upper == "46002" || upper == "46007":
		return "China Mobile"
	case strings.Contains(upper, "UNICOM") || upper == "46001" || upper == "46006" || upper == "46009":
		return "China Unicom"
	case strings.Contains(upper, "TELECOM") || upper == "CTCC" || upper == "46003" || upper == "46005" || upper == "46011":
		return "China Telecom"
	case strings.Contains(upper, "BROADNET") || upper == "46015":
		return "China Broadnet"
	default:
		return strings.TrimSpace(value)
	}
}

func parseNetworkInfo(response string) (string, string) {
	match := qnwInfoPattern.FindStringSubmatch(response)
	if len(match) != 3 {
		return "", ""
	}
	mode := strings.TrimSpace(match[1])
	band := strings.TrimSpace(match[2])
	band = strings.TrimPrefix(band, "LTE ")
	return mode, band
}

func parseRegistration(response string) int {
	match := regPattern.FindStringSubmatch(response)
	if len(match) != 2 {
		return 0
	}
	value, _ := strconv.Atoi(match[1])
	return value
}

func registrationText(value int) string {
	switch value {
	case 1:
		return "Registered"
	case 5:
		return "Registered (roaming)"
	case 2:
		return "Searching"
	case 3:
		return "Registration denied"
	default:
		return "Not registered"
	}
}
