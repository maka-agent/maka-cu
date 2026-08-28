package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"time"
)

const windowsHostProtocolVersion = "maka.cu/2"

const windowsSettleCeiling = 2500 * time.Millisecond

type powerShellRunner func(psRequest) (*psResponse, error)

type hostRPCRequest struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      any            `json:"id,omitempty"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params,omitempty"`
}

type hostRPCError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

type hostRPCResponse struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      any            `json:"id,omitempty"`
	Result  map[string]any `json:"result,omitempty"`
	Error   *hostRPCError  `json:"error,omitempty"`
}

type windowsHostSnapshot struct {
	wire    map[string]any
	raw     *appSnapshot
	digests map[string]string
	state   string
	created time.Time
}

type windowsHostSession struct {
	snapshots map[string]*windowsHostSnapshot
}

type windowsHostServer struct {
	run        powerShellRunner
	handshaken bool
	imageDir   string
	nonce      string
	nextID     uint64
	sessions   map[string]*windowsHostSession
}

func runHostProtocol(stdin io.Reader, stdout io.Writer, run powerShellRunner) error {
	server, err := newWindowsHostServer(run)
	if err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdin)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	for scanner.Scan() {
		var request hostRPCRequest
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			if err := encoder.Encode(hostRPCResponse{
				JSONRPC: "2.0",
				Error:   &hostRPCError{Code: -32700, Message: "parse_error"},
			}); err != nil {
				return err
			}
			continue
		}
		if request.Method == "$/cancel" {
			continue
		}
		response := server.handle(request)
		if err := encoder.Encode(response); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func newWindowsHostServer(run powerShellRunner) (*windowsHostServer, error) {
	if run == nil {
		return nil, errors.New("Windows host protocol requires a PowerShell runner")
	}
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return &windowsHostServer{
		run:      run,
		nonce:    hex.EncodeToString(nonce),
		sessions: map[string]*windowsHostSession{},
	}, nil
}

func (s *windowsHostServer) handle(request hostRPCRequest) hostRPCResponse {
	response := hostRPCResponse{JSONRPC: "2.0", ID: request.ID}
	if request.JSONRPC != "2.0" || request.Method == "" {
		response.Error = &hostRPCError{Code: -32600, Message: "invalid_request"}
		return response
	}
	if request.Method != "host.hello" && !s.handshaken {
		response.Error = &hostRPCError{Code: -32001, Message: "handshake_required"}
		return response
	}
	if methodNeedsSession(request.Method) && s.sessions[stringParam(request.Params, "session")] == nil {
		response.Error = &hostRPCError{Code: -32002, Message: "session_unknown"}
		return response
	}

	var result map[string]any
	var rpcError *hostRPCError
	switch request.Method {
	case "host.hello":
		result, rpcError = s.hello(request.Params)
	case "session.begin":
		result, rpcError = s.beginSession(request.Params)
	case "session.end":
		result, rpcError = s.endSession(request.Params)
	case "permissions.check":
		result = map[string]any{"ok": true, "accessibility": true, "screenRecording": true}
	case "apps.list":
		result = s.listApps()
	case "window.list":
		result = s.listWindows(request.Params)
	case "observe":
		result = s.observe(request.Params)
	case "dispatch.element":
		result = s.dispatchElement(request.Params)
	case "dispatch.point", "dispatch.key", "screen.capture", "apps.launch",
		"capture.start", "capture.next", "capture.stop":
		result = domainFailure("not_implemented")
	default:
		rpcError = &hostRPCError{Code: -32601, Message: "method_not_found"}
	}
	response.Result = result
	response.Error = rpcError
	return response
}

func (s *windowsHostServer) hello(params map[string]any) (map[string]any, *hostRPCError) {
	if s.handshaken {
		return nil, &hostRPCError{Code: -32600, Message: "invalid_request"}
	}
	if stringParam(params, "protocol") != windowsHostProtocolVersion {
		return nil, &hostRPCError{
			Code:    -32000,
			Message: "protocol_version_mismatch",
			Data:    map[string]any{"supported": []string{windowsHostProtocolVersion}},
		}
	}
	imageDir := stringParam(params, "imageDir")
	if imageDir == "" || !filepath.IsAbs(imageDir) {
		return nil, &hostRPCError{Code: -32602, Message: "invalid_params"}
	}
	if err := os.MkdirAll(imageDir, 0o700); err != nil {
		return nil, &hostRPCError{Code: -32602, Message: "invalid_params"}
	}
	probe := filepath.Join(imageDir, ".maka-cu-write-probe")
	if err := os.WriteFile(probe, []byte("ok"), 0o600); err != nil {
		return nil, &hostRPCError{Code: -32602, Message: "invalid_params"}
	}
	_ = os.Remove(probe)
	s.imageDir = imageDir
	s.handshaken = true
	return map[string]any{
		"ok":       true,
		"protocol": windowsHostProtocolVersion,
		"executor": map[string]any{
			"name":    "maka-cu-windows",
			"version": version,
		},
		"pid": os.Getpid(),
		"capabilities": map[string]any{
			"captureStream": false,
			"elementActions": []string{
				"click", "set_value", "secondary_action", "scroll",
			},
			"pointActions": []string{},
			"keyActions":   []string{},
			"imageFormats": []string{},
		},
		"limits": map[string]any{
			"snapshotsPerSession": 8,
			"snapshotTtlMs":       120000,
			"maxElements":         1200,
			"maxDepth":            64,
			"maxTextChars":        500,
			"maxResponseBytes":    4 * 1024 * 1024,
			"settleCeilingMs":     2500,
			"shutdownGraceMs":     3000,
			"imageDirBudgetBytes": 64 * 1024 * 1024,
		},
	}, nil
}

func (s *windowsHostServer) beginSession(params map[string]any) (map[string]any, *hostRPCError) {
	sessionID := stringParam(params, "session")
	if sessionID == "" {
		return nil, &hostRPCError{Code: -32602, Message: "invalid_params"}
	}
	if _, exists := s.sessions[sessionID]; exists {
		return nil, &hostRPCError{Code: -32602, Message: "invalid_params"}
	}
	s.sessions[sessionID] = &windowsHostSession{snapshots: map[string]*windowsHostSnapshot{}}
	return map[string]any{"ok": true}, nil
}

func (s *windowsHostServer) endSession(params map[string]any) (map[string]any, *hostRPCError) {
	sessionID := stringParam(params, "session")
	released := 0
	if session := s.sessions[sessionID]; session != nil {
		released = len(session.snapshots)
		delete(s.sessions, sessionID)
	}
	return map[string]any{
		"ok": true,
		"released": map[string]any{
			"snapshots": released,
			"images":    0,
			"streams":   0,
		},
	}, nil
}

func (s *windowsHostServer) listApps() map[string]any {
	inventory, err := s.inventory()
	if err != nil {
		return domainFailureWithMessage("capture_failed", err.Error())
	}
	apps := make([]map[string]any, 0, len(inventory))
	for _, item := range inventory {
		apps = append(apps, map[string]any{
			"appId":       windowsAppID(item),
			"pid":         item.App.PID,
			"name":        item.App.Name,
			"windowCount": 1,
			"running":     true,
		})
	}
	return map[string]any{"ok": true, "apps": apps}
}

func (s *windowsHostServer) listWindows(params map[string]any) map[string]any {
	if _, failure := s.requireSession(params); failure != nil {
		return failure
	}
	inventory, err := s.inventory()
	if err != nil {
		return domainFailureWithMessage("capture_failed", err.Error())
	}
	windows := make([]map[string]any, 0, len(inventory))
	for index, item := range inventory {
		windows = append(windows, map[string]any{
			"pid":      item.App.PID,
			"windowId": item.WindowID,
			"appId":    windowsAppID(item),
			"appName":  item.App.Name,
			"title":    item.WindowTitle,
			"bounds":   item.WindowBounds,
			"layer":    0,
			"zIndex":   len(inventory) - index,
			"onScreen": true,
		})
	}
	return map[string]any{"ok": true, "windows": windows}
}

func (s *windowsHostServer) observe(params map[string]any) map[string]any {
	session, failure := s.requireSession(params)
	if failure != nil {
		return failure
	}
	target, failure := s.resolveTarget(params)
	if failure != nil {
		return failure
	}
	includeScreenshot := false
	response, err := s.run(psRequest{
		Tool: "get_app_state", App: target.query, WindowID: target.windowID,
		IncludeScreenshot: &includeScreenshot,
	})
	if err != nil {
		return domainFailureWithMessage("capture_failed", err.Error())
	}
	if !response.OK || response.Snapshot == nil {
		code := response.ErrorCode
		if code != "window_gone" {
			code = "app_not_found"
		}
		return domainFailureWithMessage(code, response.Error)
	}
	snapshot := s.makeSnapshot(response.Snapshot)
	s.rememberSnapshot(session, snapshot)
	return map[string]any{"ok": true, "snapshot": snapshot.wire}
}

func (s *windowsHostServer) dispatchElement(params map[string]any) map[string]any {
	session, failure := s.requireSession(params)
	if failure != nil {
		return failure
	}
	snapshotID := stringParam(params, "snapshotId")
	snapshot := session.snapshots[snapshotID]
	if snapshot == nil {
		return dispatchFailure(params, "snapshot_unknown")
	}
	if time.Since(snapshot.created) > 120*time.Second && snapshot.state == "live" {
		snapshot.state = "expired"
	}
	if snapshot.state != "live" {
		return dispatchFailure(params, "snapshot_"+snapshot.state)
	}
	token := stringParam(params, "elementToken")
	expectedDigest := stringParam(params, "expectElementDigest")
	record, ok := recordForToken(snapshot, token)
	if !ok {
		return dispatchFailure(params, "element_unknown")
	}
	if snapshot.digests[token] != expectedDigest {
		return dispatchFailure(params, "element_digest_mismatch")
	}
	action, _ := params["action"].(map[string]any)
	request, failureCode := windowsElementAction(snapshot.raw, record, action)
	if failureCode != "" {
		return dispatchFailure(params, failureCode)
	}
	settleStarted := time.Now()
	response, err := s.run(request)
	if err != nil {
		return dispatchFailureWithMessage(params, "dispatch_refused", err.Error())
	}
	if !response.OK || response.Snapshot == nil {
		code := windowsDispatchErrorCode(response.ErrorCode)
		result := dispatchFailureWithMessage(params, code, response.Error)
		if code == "element_changed" {
			changed := strings.TrimPrefix(response.Error, "the bound UI Automation element changed: ")
			result["error"].(map[string]any)["detail"] = map[string]any{
				"changed": strings.Split(changed, ","),
			}
		}
		return result
	}
	postSnapshot := response.Snapshot
	var settle map[string]any
	var postObservationError map[string]any
	settleMode := requestedSettleMode(params)
	if settleMode == "quiesce" {
		postSnapshot, settle, postObservationError = s.settleWindow(request, postSnapshot, settleStarted)
		if postObservationError != nil {
			settle = nil
		}
	}
	snapshot.state = "spent"
	next := s.makeSnapshot(postSnapshot)
	s.rememberSnapshot(session, next)
	effect, verification := windowsVerification(snapshot.raw, postSnapshot, record, action, settleMode)
	result := map[string]any{
		"ok":           true,
		"toolCallId":   stringParam(params, "toolCallId"),
		"outcome":      "ok",
		"tier":         "ax",
		"path":         windowsDispatchPath(action),
		"effect":       effect,
		"verification": verification,
		"snapshot":     next.wire,
	}
	if settle != nil {
		result["settle"] = settle
	}
	if postObservationError != nil {
		result["postObservationError"] = postObservationError
	}
	return result
}

func requestedSettleMode(params map[string]any) string {
	observeAfter, _ := params["observeAfter"].(map[string]any)
	return stringParam(observeAfter, "settle")
}

func (s *windowsHostServer) settleWindow(
	request psRequest,
	initial *appSnapshot,
	started time.Time,
) (*appSnapshot, map[string]any, map[string]any) {
	previous := initial
	if waited := time.Since(started); waited >= windowsSettleCeiling {
		return previous, map[string]any{
			"waitedMs": waited.Milliseconds(),
			"quiesced": false,
			"reason":   "window_too_slow",
		}, nil
	}
	for {
		time.Sleep(60 * time.Millisecond)
		response, err := s.run(psRequest{
			Tool:              "get_app_state",
			App:               request.App,
			WindowID:          request.WindowID,
			IncludeScreenshot: request.IncludeScreenshot,
		})
		waited := time.Since(started)
		if err != nil {
			return previous, nil, domainFailureWithMessage("capture_failed", err.Error())["error"].(map[string]any)
		}
		if !response.OK || response.Snapshot == nil {
			code := response.ErrorCode
			if code == "" {
				code = "capture_failed"
			}
			return previous, nil, domainFailureWithMessage(code, response.Error)["error"].(map[string]any)
		}
		current := response.Snapshot
		if windowDigest(previous) == windowDigest(current) {
			return current, map[string]any{
				"waitedMs": waited.Milliseconds(),
				"quiesced": true,
				"reason":   "quiesced",
			}, nil
		}
		previous = current
		if waited >= windowsSettleCeiling {
			return current, map[string]any{
				"waitedMs": waited.Milliseconds(),
				"quiesced": false,
				"reason":   "ceiling",
			}, nil
		}
	}
}

func windowsVerification(
	before *appSnapshot,
	after *appSnapshot,
	record elementRecord,
	action map[string]any,
	settleMode string,
) (string, map[string]any) {
	kind := stringParam(action, "kind")
	if kind == "secondary_action" {
		return "confirmed", map[string]any{
			"method":         "action_result",
			"observedChange": false,
		}
	}
	if kind == "set_value" {
		expected := stringParam(action, "value")
		for _, current := range after.Elements {
			if sameElementIdentity(record, current) {
				confirmed := current.Value == expected
				observedChange := current.Value != record.Value
				effect := "unverifiable"
				if confirmed {
					effect = "confirmed"
				} else if !observedChange {
					effect = "suspected_noop"
				}
				return effect, map[string]any{
					"method":         "value_readback",
					"observedChange": observedChange,
				}
			}
		}
		return "unverifiable", map[string]any{
			"method":         "value_readback",
			"observedChange": false,
		}
	}
	if settleMode != "quiesce" {
		return "unverifiable", map[string]any{
			"method":         "none",
			"observedChange": false,
		}
	}
	observedChange := windowDigest(before) != windowDigest(after)
	effect := "unverifiable"
	if observedChange {
		effect = "confirmed"
	}
	return effect, map[string]any{
		"method":         "tree_delta",
		"observedChange": observedChange,
	}
}

func sameElementIdentity(left, right elementRecord) bool {
	if len(left.RuntimeID) > 0 && reflect.DeepEqual(left.RuntimeID, right.RuntimeID) {
		return true
	}
	if left.AutomationID != "" && left.AutomationID == right.AutomationID {
		return left.ControlType == right.ControlType
	}
	return left.Name != "" && left.Name == right.Name && left.ControlType == right.ControlType
}

func windowsDispatchErrorCode(code string) string {
	switch code {
	case "element_released", "element_changed", "window_changed", "window_gone":
		return code
	default:
		return "dispatch_refused"
	}
}

func (s *windowsHostServer) inventory() ([]appSnapshot, error) {
	response, err := s.run(psRequest{Tool: "host_inventory"})
	if err != nil {
		return nil, err
	}
	if !response.OK {
		return nil, errors.New(response.Error)
	}
	return response.Apps, nil
}

func (s *windowsHostServer) requireSession(params map[string]any) (*windowsHostSession, map[string]any) {
	sessionID := stringParam(params, "session")
	session := s.sessions[sessionID]
	if session == nil {
		return nil, domainFailure("session_unknown")
	}
	return session, nil
}

type windowsResolvedTarget struct {
	query    string
	windowID int64
}

func (s *windowsHostServer) resolveTarget(params map[string]any) (windowsResolvedTarget, map[string]any) {
	target, _ := params["target"].(map[string]any)
	if target == nil {
		return windowsResolvedTarget{}, domainFailure("target_missing")
	}
	inventory, err := s.inventory()
	if err != nil {
		return windowsResolvedTarget{}, domainFailureWithMessage("capture_failed", err.Error())
	}
	switch stringParam(target, "kind") {
	case "app":
		appID := stringParam(target, "app")
		if appID == "" {
			return windowsResolvedTarget{}, domainFailure("target_missing")
		}
		for _, item := range inventory {
			if windowsAppID(item) == appID {
				return windowsResolvedTarget{
					query: strconv.Itoa(item.App.PID), windowID: item.WindowID,
				}, nil
			}
		}
		return windowsResolvedTarget{}, domainFailure("app_not_found")
	case "window":
		pid := numberParam(target, "pid")
		windowID := int64(numberParam(target, "windowId"))
		for _, item := range inventory {
			if item.App.PID == pid && item.WindowID == windowID {
				return windowsResolvedTarget{
					query: strconv.Itoa(pid), windowID: windowID,
				}, nil
			}
		}
		return windowsResolvedTarget{}, domainFailure("window_gone")
	default:
		return windowsResolvedTarget{}, domainFailure("target_missing")
	}
}

func (s *windowsHostServer) makeSnapshot(raw *appSnapshot) *windowsHostSnapshot {
	s.nextID++
	snapshotID := fmt.Sprintf("snap_%s_%d", s.nonce, s.nextID)
	digests := map[string]string{}
	elements := make([]map[string]any, 0, len(raw.Elements))
	tokenByIndex := map[int]string{}
	for _, record := range raw.Elements {
		tokenByIndex[record.Index] = fmt.Sprintf("%s_el_%d", snapshotID, record.Index)
	}
	for _, record := range raw.Elements {
		token := tokenByIndex[record.Index]
		digest := recordDigest(record)
		digests[token] = digest
		element := map[string]any{
			"token":       token,
			"parentToken": nil,
			"depth":       record.Depth,
			"role":        windowsRole(record),
			"enabled":     record.Enabled,
			"focused":     record.Focused,
			"selected":    record.Selected,
			"actions":     windowsActions(record.Actions),
			"digest":      digest,
			"truncated":   []string{},
		}
		if record.ParentIndex >= 0 {
			element["parentToken"] = tokenByIndex[record.ParentIndex]
		}
		if record.Name != "" {
			element["label"] = record.Name
		}
		if record.AutomationID != "" {
			element["axIdentifier"] = record.AutomationID
		}
		if record.Value != "" {
			element["value"] = record.Value
		}
		if record.Frame != nil {
			element["frame"] = record.Frame
		}
		elements = append(elements, element)
	}
	bounds := raw.WindowBounds
	if bounds == nil {
		bounds = &frame{}
	}
	focusedToken := any(nil)
	for _, record := range raw.Elements {
		if record.Focused {
			focusedToken = tokenByIndex[record.Index]
			break
		}
	}
	wire := map[string]any{
		"snapshotId": snapshotID,
		"capturedAt": time.Now().UnixMilli(),
		"target": map[string]any{
			"pid":       raw.App.PID,
			"windowId":  raw.WindowID,
			"appId":     windowsAppID(*raw),
			"appName":   raw.App.Name,
			"title":     raw.WindowTitle,
			"bounds":    bounds,
			"layer":     0,
			"zIndex":    1,
			"displayId": "virtual-screen",
		},
		"windowDigest":        windowDigest(raw),
		"focusedElementToken": focusedToken,
		"selectedText":        nil,
		"image":               nil,
		"displays": []map[string]any{{
			"displayId": "virtual-screen",
			"logicalBounds": map[string]any{
				"x": bounds.X, "y": bounds.Y, "width": bounds.Width, "height": bounds.Height,
			},
			"sourceBoundsPx": map[string]any{
				"x": bounds.X, "y": bounds.Y, "width": bounds.Width, "height": bounds.Height,
			},
			"scaleFactor": 1,
		}},
		"obscuringRects": []any{},
		"elements":       elements,
		"truncated": map[string]any{
			"elements": raw.TreeTruncated,
			"depth":    false,
		},
	}
	return &windowsHostSnapshot{
		wire: wire, raw: raw, digests: digests, state: "live", created: time.Now(),
	}
}

func (s *windowsHostServer) rememberSnapshot(session *windowsHostSession, snapshot *windowsHostSnapshot) {
	live := make([]*windowsHostSnapshot, 0, len(session.snapshots))
	for _, current := range session.snapshots {
		if sameWindow(current.raw, snapshot.raw) && current.state == "live" {
			current.state = "superseded"
		}
		if current.state == "live" {
			live = append(live, current)
		}
	}
	if len(live) >= 8 {
		oldest := live[0]
		for _, current := range live[1:] {
			if current.created.Before(oldest.created) {
				oldest = current
			}
		}
		oldest.state = "evicted"
	}
	session.snapshots[snapshot.wire["snapshotId"].(string)] = snapshot
}

func windowsElementAction(snapshot *appSnapshot, record elementRecord, action map[string]any) (psRequest, string) {
	kind := stringParam(action, "kind")
	includeScreenshot := false
	base := psRequest{
		App:               strconv.Itoa(snapshot.App.PID),
		WindowID:          snapshot.WindowID,
		Element:           &record,
		WindowBounds:      snapshot.WindowBounds,
		IncludeScreenshot: &includeScreenshot,
	}
	switch kind {
	case "click":
		if button := stringParam(action, "button"); button != "" && button != "left" {
			return psRequest{}, "unsupported_action"
		}
		if count := numberParam(action, "count"); count > 1 {
			return psRequest{}, "unsupported_action"
		}
		base.Tool = "click"
		base.MouseButton = "left"
		base.ClickCount = 1
		base.ClickMethod = "accessibility"
	case "set_value":
		base.Tool = "set_value"
		base.Value = stringParam(action, "value")
	case "secondary_action":
		base.Tool = "perform_secondary_action"
		base.Action = windowsSecondaryAction(stringParam(action, "action"))
		if base.Action == "" {
			return psRequest{}, "element_not_actionable"
		}
	case "scroll":
		base.Tool = "scroll"
		base.Direction = stringParam(action, "direction")
		base.Pages = floatParam(action, "pages")
	default:
		return psRequest{}, "not_implemented"
	}
	return base, ""
}

func windowsSecondaryAction(action string) string {
	switch action {
	case "press", "confirm":
		return "invoke"
	case "open", "show_menu":
		return "expand"
	case "cancel":
		return "collapse"
	case "pick":
		return "select"
	case "scroll_to_visible":
		return "scrollintoview"
	default:
		return ""
	}
}

func windowsDispatchPath(action map[string]any) string {
	if stringParam(action, "kind") == "set_value" {
		return "ax_attribute"
	}
	if stringParam(action, "kind") == "secondary_action" &&
		stringParam(action, "action") == "pick" {
		return "ax_select"
	}
	return "ax_action"
}

func windowsActions(actions []string) []string {
	result := make([]string, 0, len(actions))
	add := func(value string) {
		for _, existing := range result {
			if existing == value {
				return
			}
		}
		result = append(result, value)
	}
	for _, action := range actions {
		switch strings.ToLower(action) {
		case "invoke", "toggle":
			add("press")
		case "select":
			add("pick")
		case "expand":
			add("open")
		case "collapse":
			add("cancel")
		case "scrollintoview":
			add("scroll_to_visible")
		case "scroll":
			add("scroll_up")
			add("scroll_down")
			add("scroll_left")
			add("scroll_right")
		}
	}
	return result
}

func windowsRole(record elementRecord) string {
	role := strings.TrimPrefix(record.ControlType, "ControlType.")
	if role == "" {
		role = record.LocalizedControlType
	}
	if role == "" {
		return "UIAElement"
	}
	return "UIA" + role
}

func windowsAppID(snapshot appSnapshot) string {
	return fmt.Sprintf("win32:%d:%d", snapshot.App.PID, snapshot.WindowID)
}

func recordDigest(record elementRecord) string {
	data, _ := json.Marshal([]any{
		record.RuntimeID,
		record.AutomationID,
		record.Name,
		record.ControlType,
		record.ClassName,
		record.Value,
		record.Frame,
		record.Actions,
		record.ParentIndex,
		record.Depth,
	})
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func windowDigest(snapshot *appSnapshot) string {
	digests := make([]string, 0, len(snapshot.Elements))
	for _, record := range snapshot.Elements {
		digests = append(digests, recordDigest(record))
	}
	data, _ := json.Marshal([]any{snapshot.WindowID, snapshot.WindowTitle, snapshot.WindowBounds, digests})
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func recordForToken(snapshot *windowsHostSnapshot, token string) (elementRecord, bool) {
	prefix := snapshot.wire["snapshotId"].(string) + "_el_"
	if !strings.HasPrefix(token, prefix) {
		return elementRecord{}, false
	}
	suffix := strings.TrimPrefix(token, prefix)
	index, err := strconv.Atoi(suffix)
	if err != nil {
		return elementRecord{}, false
	}
	for _, record := range snapshot.raw.Elements {
		if record.Index == index {
			return record, true
		}
	}
	return elementRecord{}, false
}

func sameWindow(left, right *appSnapshot) bool {
	return left != nil && right != nil &&
		left.App.PID == right.App.PID && left.WindowID == right.WindowID
}

func dispatchFailure(params map[string]any, code string) map[string]any {
	return dispatchFailureWithMessage(params, code, windowsDomainMessage(code))
}

func dispatchFailureWithMessage(params map[string]any, code, message string) map[string]any {
	result := domainFailureWithMessage(code, message)
	result["toolCallId"] = stringParam(params, "toolCallId")
	result["outcome"] = "refused"
	result["tier"] = "ax"
	result["path"] = "none"
	result["effect"] = "unverifiable"
	result["verification"] = map[string]any{
		"method":         "none",
		"observedChange": false,
	}
	return result
}

func domainFailure(code string) map[string]any {
	return domainFailureWithMessage(code, windowsDomainMessage(code))
}

func domainFailureWithMessage(code, message string) map[string]any {
	if strings.TrimSpace(message) == "" {
		message = windowsDomainMessage(code)
	}
	return map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    code,
			"message": message,
		},
	}
}

func methodNeedsSession(method string) bool {
	switch method {
	case "window.list", "observe", "dispatch.element", "dispatch.point", "dispatch.key",
		"screen.capture", "apps.launch", "capture.start", "capture.next", "capture.stop":
		return true
	default:
		return false
	}
}

func windowsDomainMessage(code string) string {
	switch code {
	case "session_unknown":
		return "the session is not active"
	case "snapshot_unknown":
		return "the snapshot is not known to this executor"
	case "snapshot_spent":
		return "the snapshot has already been used by a mutating action"
	case "snapshot_superseded":
		return "a newer observation replaced this snapshot"
	case "snapshot_expired":
		return "the snapshot exceeded its lifetime"
	case "snapshot_evicted":
		return "the snapshot was evicted from the session budget"
	case "element_unknown":
		return "the element token is not part of this snapshot"
	case "element_digest_mismatch":
		return "the element digest does not match this snapshot"
	case "element_released":
		return "the element no longer exists"
	case "element_changed":
		return "the element no longer matches the snapshot it was bound to"
	case "window_changed":
		return "the target window changed after observation"
	case "element_not_actionable":
		return "the element does not expose the requested action"
	case "unsupported_action":
		return "the requested action is not supported by the Windows executor"
	case "window_gone":
		return "the target window no longer exists"
	case "target_missing":
		return "the requested target could not be resolved"
	case "app_not_found":
		return "the requested application is not running"
	case "capture_failed":
		return "the Windows UI Automation observation failed"
	case "dispatch_refused":
		return "Windows UI Automation refused the requested action"
	case "not_implemented":
		return "this action is not implemented by the Windows executor"
	default:
		return code
	}
}

func stringParam(params map[string]any, key string) string {
	value, _ := params[key].(string)
	return value
}

func numberParam(params map[string]any, key string) int {
	switch value := params[key].(type) {
	case float64:
		return int(value)
	case json.Number:
		number, _ := value.Int64()
		return int(number)
	case int:
		return value
	case int64:
		return int(value)
	default:
		return 0
	}
}

func floatParam(params map[string]any, key string) float64 {
	switch value := params[key].(type) {
	case float64:
		return value
	case json.Number:
		number, _ := value.Float64()
		return number
	case int:
		return float64(value)
	case int64:
		return float64(value)
	default:
		return 0
	}
}
