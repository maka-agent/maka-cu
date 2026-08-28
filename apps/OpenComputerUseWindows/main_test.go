package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestToolDefinitionCount(t *testing.T) {
	if got := len(toolDefinitions()); got != 9 {
		t.Fatalf("toolDefinitions() count = %d, want 9", got)
	}
}

func TestClickMethodSchemaAndParser(t *testing.T) {
	tool := findToolDefinition(t, "click")
	properties := tool.InputSchema["properties"].(map[string]any)
	method := properties["click_method"].(map[string]any)
	values := method["enum"].([]string)
	if strings.Join(values, ",") != "auto,accessibility,app_post,sky_click,global" {
		t.Fatalf("click_method enum = %#v", values)
	}

	for input, want := range map[string]string{
		"":              "auto",
		" AUTO ":        "auto",
		"Accessibility": "accessibility",
		"app_post":      "app_post",
		"SKY_CLICK":     "sky_click",
		"GLOBAL":        "global",
	} {
		got, err := parseClickMethod(input)
		if err != nil {
			t.Fatalf("parseClickMethod(%q): %v", input, err)
		}
		if got != want {
			t.Fatalf("parseClickMethod(%q) = %q, want %q", input, got, want)
		}
	}

	for _, input := range []string{"physical", "targeted"} {
		if _, err := parseClickMethod(input); err == nil || !strings.Contains(err.Error(), "Expected one of: auto, accessibility, app_post, sky_click, global") {
			t.Fatalf("parseClickMethod(%s) error = %v", input, err)
		}
	}
}

func TestWindowsRejectsUnsupportedGlobalClickBeforeSnapshotLookup(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click("Notepad", "", &x, &y, 1, "left", "global")
	if !result.IsError || result.Content[0].Text != "click_method 'global' is not supported on Windows" {
		t.Fatalf("global click result = %#v", result)
	}
}

func TestWindowsRejectsUnsupportedSkyClickBeforeSnapshotLookup(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click("Notepad", "", &x, &y, 1, "left", "sky_click")
	if !result.IsError || result.Content[0].Text != "click_method 'sky_click' is not supported on Windows" {
		t.Fatalf("sky_click result = %#v", result)
	}
}

func TestGetAppStateSchemaIncludesTextLimit(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	if _, ok := properties["show_full_text"]; ok {
		t.Fatal("get_app_state schema should not expose show_full_text")
	}
	textLimit := properties["text_limit"].(map[string]any)
	anyOf := textLimit["anyOf"].([]any)
	integerLimit := anyOf[0].(map[string]any)
	if got := integerLimit["type"]; got != "integer" {
		t.Fatalf("text_limit integer type = %v, want integer", got)
	}
	if got := integerLimit["minimum"]; got != 1 {
		t.Fatalf("text_limit integer minimum = %v, want 1", got)
	}
	maxLimit := anyOf[1].(map[string]any)
	if got := maxLimit["type"]; got != "string" {
		t.Fatalf("text_limit max type = %v, want string", got)
	}
	enum := maxLimit["enum"].([]string)
	if len(enum) != 1 || enum[0] != "max" {
		t.Fatalf("text_limit enum = %#v, want [max]", enum)
	}
	maxTreeNodes := properties["max_tree_nodes"].(map[string]any)
	if got := maxTreeNodes["type"]; got != "integer" {
		t.Fatalf("max_tree_nodes type = %v, want integer", got)
	}
	if got := maxTreeNodes["minimum"]; got != 1 {
		t.Fatalf("max_tree_nodes minimum = %v, want 1", got)
	}
	maxTreeDepth := properties["max_tree_depth"].(map[string]any)
	if got := maxTreeDepth["type"]; got != "integer" {
		t.Fatalf("max_tree_depth type = %v, want integer", got)
	}
	if got := maxTreeDepth["minimum"]; got != 1 {
		t.Fatalf("max_tree_depth minimum = %v, want 1", got)
	}
	required := tool.InputSchema["required"].([]string)
	if len(required) != 1 || required[0] != "app" {
		t.Fatalf("required = %#v, want [app]", required)
	}
}

func TestParseSnapshotArgsSupportsTextLimit(t *testing.T) {
	app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs([]string{"--text-limit", "1000", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != 1000 || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs = (%q, %#v, %v, %v), want (Notepad, 1000, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad", "--text-limit", "max"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != "max" || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs max = (%q, %#v, %v, %v), want (Notepad, max, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs default = (%q, %#v, %v, %v), want (Notepad, nil, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"--max-tree-nodes", "3000", "--max-tree-depth", "96", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes == nil || *maxTreeNodes != 3000 || maxTreeDepth == nil || *maxTreeDepth != 96 {
		t.Fatalf("parseSnapshotArgs custom tree budget = (%q, %#v, %v, %v), want (Notepad, nil, 3000, 96)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}
}

func TestParseSnapshotArgsRejectsInvalidTextLimit(t *testing.T) {
	for _, value := range []string{"0", "-1", "1.5", "full"} {
		if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit", value, "Notepad"}); err == nil || err.Error() != "--text-limit must be a positive integer or max" {
			t.Fatalf("invalid text_limit %q error = %v", value, err)
		}
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit"}); err == nil || err.Error() != "--text-limit requires a positive integer or max value" {
		t.Fatalf("missing text_limit error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--show-full-text", "Notepad"}); err == nil || err.Error() != "unknown snapshot option: --show-full-text" {
		t.Fatalf("old show_full_text flag error = %v", err)
	}
}

func TestParseSnapshotArgsRejectsInvalidTreeBudget(t *testing.T) {
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes", "0", "Notepad"}); err == nil || err.Error() != "--max-tree-nodes must be a positive integer" {
		t.Fatalf("invalid max_tree_nodes error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-depth", "1.5", "Notepad"}); err == nil || err.Error() != "--max-tree-depth must be a positive integer" {
		t.Fatalf("invalid max_tree_depth error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes"}); err == nil || err.Error() != "--max-tree-nodes requires a positive integer value" {
		t.Fatalf("missing max_tree_nodes error = %v", err)
	}
}

func TestCallSequenceStopsAfterFirstToolError(t *testing.T) {
	output, hasError, err := runCallCommand([]string{
		"--calls",
		`[{"tool":"not_a_tool"},{"tool":"list_apps"}]`,
	}, newService())
	if err != nil {
		t.Fatal(err)
	}
	if !hasError {
		t.Fatal("expected hasError")
	}
	items, ok := output.([]map[string]any)
	if !ok {
		t.Fatalf("output type = %T", output)
	}
	if len(items) != 1 {
		t.Fatalf("sequence output count = %d, want 1", len(items))
	}
}

func TestReadArgumentsAcceptsJSONObject(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","pages":2}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if args["app"] != "Notepad" {
		t.Fatalf("app = %v", args["app"])
	}
	if args["pages"].(json.Number).String() != "2" {
		t.Fatalf("pages = %v", args["pages"])
	}
}

func TestElementIndexAcceptsStringAndJSONNumber(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","element_index":0}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := optionalElementIndex(args); got != "0" {
		t.Fatalf("numeric element_index = %q, want 0", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": "14"}); got != "14" {
		t.Fatalf("string element_index = %q, want 14", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": json.Number("1.5")}); got != "" {
		t.Fatalf("fractional element_index = %q, want empty", got)
	}
}

func TestMCPInitializeResponseContainsToolsCapability(t *testing.T) {
	request := map[string]any{
		"jsonrpc": "2.0",
		"id":      float64(1),
		"method":  "initialize",
		"params":  map[string]any{},
	}
	response := handleMCPRequest(request, newService())
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing result: %#v", response)
	}
	capabilities := result["capabilities"].(map[string]any)
	if _, ok := capabilities["tools"]; !ok {
		t.Fatalf("missing tools capability: %#v", capabilities)
	}
}

func TestCLIHelpMentionsWindowsRuntime(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI([]string{"--help"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Open Computer Use for Windows") {
		t.Fatalf("help text did not mention Windows runtime:\n%s", out.String())
	}
}

func TestWindowsHostProtocolHandshakeDeclaresSemanticOnlyCapabilities(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		t.Fatalf("unexpected PowerShell request: %+v", request)
		return nil, nil
	})
	result, rpcError := server.hello(map[string]any{
		"protocol": windowsHostProtocolVersion,
		"imageDir": t.TempDir(),
	})
	if rpcError != nil {
		t.Fatalf("hello failed: %+v", rpcError)
	}
	capabilities := result["capabilities"].(map[string]any)
	if got := capabilities["elementActions"]; !reflect.DeepEqual(
		got,
		[]string{"click", "set_value", "secondary_action", "scroll"},
	) {
		t.Fatalf("unexpected element actions: %#v", got)
	}
	if got := capabilities["pointActions"]; !reflect.DeepEqual(got, []string{}) {
		t.Fatalf("point actions must remain disabled: %#v", got)
	}
	if got := capabilities["keyActions"]; !reflect.DeepEqual(got, []string{}) {
		t.Fatalf("key actions must remain disabled: %#v", got)
	}
}

func TestWindowsHostProtocolObserveAndDispatchSpendSnapshot(t *testing.T) {
	var calls []psRequest
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		calls = append(calls, request)
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
		case "click":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("after")}, nil
		default:
			return nil, fmt.Errorf("unexpected tool %q", request.Tool)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	if observed["ok"] != true {
		t.Fatalf("observe failed: %#v", observed)
	}
	if calls[1].WindowID != 99 {
		t.Fatalf("observe did not preserve exact window id: %+v", calls[1])
	}
	wire := observed["snapshot"].(map[string]any)
	snapshotID := wire["snapshotId"].(string)
	element := wire["elements"].([]map[string]any)[0]
	params := map[string]any{
		"session":             "s1",
		"snapshotId":          snapshotID,
		"toolCallId":          "call-1",
		"elementToken":        element["token"],
		"expectElementDigest": element["digest"],
		"action":              map[string]any{"kind": "click"},
	}
	dispatched := server.dispatchElement(params)
	if dispatched["ok"] != true || dispatched["effect"] != "unverifiable" {
		t.Fatalf("dispatch failed: %#v", dispatched)
	}
	verification := dispatched["verification"].(map[string]any)
	if verification["method"] != "none" || verification["observedChange"] != false {
		t.Fatalf("dispatch without settle used observation evidence: %#v", verification)
	}
	if calls[2].WindowID != 99 {
		t.Fatalf("dispatch did not preserve exact window id: %+v", calls[2])
	}
	replayed := server.dispatchElement(params)
	if replayed["ok"] != false {
		t.Fatalf("spent snapshot replay succeeded: %#v", replayed)
	}
	errorBody := replayed["error"].(map[string]any)
	if errorBody["code"] != "snapshot_spent" {
		t.Fatalf("unexpected replay error: %#v", errorBody)
	}
}

func TestWindowsHostProtocolRejectsUnsupportedDispatchFamilies(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		return nil, fmt.Errorf("unexpected PowerShell request: %+v", request)
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	response := server.handle(hostRPCRequest{
		JSONRPC: "2.0",
		ID:      3,
		Method:  "dispatch.key",
		Params:  map[string]any{"session": "s1"},
	})
	if response.Result["ok"] != false {
		t.Fatalf("unsupported dispatch succeeded: %#v", response.Result)
	}
	errorBody := response.Result["error"].(map[string]any)
	if errorBody["code"] != "not_implemented" {
		t.Fatalf("unexpected error: %#v", errorBody)
	}
}

func TestWindowsHostProtocolRejectsTokenOutsideSnapshotNamespace(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
		default:
			return nil, fmt.Errorf("unexpected tool %q", request.Tool)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	wire := observed["snapshot"].(map[string]any)
	element := wire["elements"].([]map[string]any)[0]
	result := server.dispatchElement(map[string]any{
		"session":             "s1",
		"snapshotId":          wire["snapshotId"],
		"toolCallId":          "call-forged-token",
		"elementToken":        "0",
		"expectElementDigest": element["digest"],
		"action":              map[string]any{"kind": "click"},
	})
	errorBody := result["error"].(map[string]any)
	if errorBody["code"] != "element_unknown" {
		t.Fatalf("unexpected error: %#v", errorBody)
	}
}

func TestWindowsHostProtocolUsesRPCErrorForUnknownSession(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		return nil, fmt.Errorf("unexpected PowerShell request: %+v", request)
	})
	handshakeWindowsHost(t, server)
	response := server.handle(hostRPCRequest{
		JSONRPC: "2.0",
		ID:      4,
		Method:  "observe",
		Params:  map[string]any{"session": "missing"},
	})
	if response.Error == nil || response.Error.Code != -32002 {
		t.Fatalf("unknown session did not use JSON-RPC error: %#v", response)
	}
}

func TestWindowsHostProtocolMapsLiveElementChange(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
		case "click":
			return &psResponse{
				OK:        false,
				ErrorCode: "element_changed",
				Error:     "the bound UI Automation element changed: value,frame",
			}, nil
		default:
			return nil, fmt.Errorf("unexpected PowerShell request: %+v", request)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	wire := observed["snapshot"].(map[string]any)
	element := wire["elements"].([]map[string]any)[0]
	result := server.dispatchElement(map[string]any{
		"session":             "s1",
		"snapshotId":          wire["snapshotId"],
		"toolCallId":          "call-2",
		"elementToken":        element["token"],
		"expectElementDigest": element["digest"],
		"action":              map[string]any{"kind": "click"},
	})
	errorBody := result["error"].(map[string]any)
	if errorBody["code"] != "element_changed" {
		t.Fatalf("unexpected error: %#v", errorBody)
	}
	detail := errorBody["detail"].(map[string]any)
	if !reflect.DeepEqual(detail["changed"], []string{"value", "frame"}) {
		t.Fatalf("unexpected changed fields: %#v", detail)
	}
}

func TestWindowsHostProtocolPreservesDispatchFailureMessage(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
		case "set_value":
			return &psResponse{
				OK:    false,
				Error: "ValuePattern.SetValue failed for this provider",
			}, nil
		default:
			return nil, fmt.Errorf("unexpected tool %q", request.Tool)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	wire := observed["snapshot"].(map[string]any)
	element := wire["elements"].([]map[string]any)[0]
	result := server.dispatchElement(map[string]any{
		"session":             "s1",
		"snapshotId":          wire["snapshotId"],
		"toolCallId":          "call-refused",
		"elementToken":        element["token"],
		"expectElementDigest": element["digest"],
		"action": map[string]any{
			"kind":  "set_value",
			"value": "replacement",
		},
	})
	errorBody := result["error"].(map[string]any)
	if errorBody["code"] != "dispatch_refused" {
		t.Fatalf("unexpected error code: %#v", errorBody)
	}
	if errorBody["message"] != "ValuePattern.SetValue failed for this provider" {
		t.Fatalf("runtime failure message was lost: %#v", errorBody)
	}
}

func TestWindowsHostProtocolQuiescesAndReadsBackSetValue(t *testing.T) {
	after := windowsHostTestSnapshot("updated")
	getStateCalls := 0
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			getStateCalls++
			if getStateCalls == 1 {
				return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
			}
			return &psResponse{OK: true, Snapshot: after}, nil
		case "set_value":
			return &psResponse{OK: true, Snapshot: after}, nil
		default:
			return nil, fmt.Errorf("unexpected tool %q", request.Tool)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	wire := observed["snapshot"].(map[string]any)
	element := wire["elements"].([]map[string]any)[0]
	result := server.dispatchElement(map[string]any{
		"session":             "s1",
		"snapshotId":          wire["snapshotId"],
		"toolCallId":          "call-set",
		"elementToken":        element["token"],
		"expectElementDigest": element["digest"],
		"action": map[string]any{
			"kind":  "set_value",
			"value": "updated",
		},
		"observeAfter": map[string]any{
			"includeImage": false,
			"settle":       "quiesce",
		},
	})
	if result["effect"] != "confirmed" {
		t.Fatalf("set_value was not confirmed: %#v", result)
	}
	verification := result["verification"].(map[string]any)
	if verification["method"] != "value_readback" || verification["observedChange"] != true {
		t.Fatalf("unexpected verification: %#v", verification)
	}
	settle := result["settle"].(map[string]any)
	if settle["quiesced"] != true || settle["reason"] != "quiesced" {
		t.Fatalf("unexpected settle: %#v", settle)
	}
	if getStateCalls != 2 {
		t.Fatalf("get_app_state calls = %d, want initial observe plus one settle sample", getStateCalls)
	}
}

func TestWindowsHostProtocolSecondaryActionUsesActionResult(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
		case "perform_secondary_action":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("after")}, nil
		default:
			return nil, fmt.Errorf("unexpected tool %q", request.Tool)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	wire := observed["snapshot"].(map[string]any)
	element := wire["elements"].([]map[string]any)[0]
	result := server.dispatchElement(map[string]any{
		"session":             "s1",
		"snapshotId":          wire["snapshotId"],
		"toolCallId":          "call-secondary",
		"elementToken":        element["token"],
		"expectElementDigest": element["digest"],
		"action": map[string]any{
			"kind":   "secondary_action",
			"action": "press",
		},
	})
	if result["effect"] != "confirmed" {
		t.Fatalf("secondary action was not confirmed: %#v", result)
	}
	verification := result["verification"].(map[string]any)
	if verification["method"] != "action_result" || verification["observedChange"] != false {
		t.Fatalf("unexpected verification: %#v", verification)
	}
}

func TestWindowsActionsPreserveAvailableScrollDirections(t *testing.T) {
	got := windowsActions([]string{"ScrollDown", "ScrollRight"})
	want := []string{"scroll_down", "scroll_right"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("windowsActions() = %#v, want %#v", got, want)
	}
}

func TestWindowsVerificationDetectsToggleStateChange(t *testing.T) {
	before := windowsHostTestSnapshot("same")
	after := windowsHostTestSnapshot("same")
	beforeSelected := false
	afterSelected := true
	before.Elements[0].Selected = &beforeSelected
	after.Elements[0].Selected = &afterSelected

	effect, verification := windowsVerification(
		before,
		after,
		before.Elements[0],
		map[string]any{"kind": "click"},
		"quiesce",
	)
	if effect != "confirmed" {
		t.Fatalf("toggle state change effect = %q, want confirmed", effect)
	}
	if verification["method"] != "tree_delta" || verification["observedChange"] != true {
		t.Fatalf("unexpected verification: %#v", verification)
	}
}

func TestWindowsHostProtocolAppIDsAreWindowSpecific(t *testing.T) {
	first := *windowsHostTestSnapshot("first")
	second := *windowsHostTestSnapshot("second")
	second.WindowID = 100
	if windowsAppID(first) == windowsAppID(second) {
		t.Fatalf("windows sharing a process must not share app ids: %q", windowsAppID(first))
	}
}

func TestWindowsHostProtocolAppListIncludesWindowIdentity(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		if request.Tool != "host_inventory" {
			return nil, fmt.Errorf("unexpected PowerShell request: %+v", request)
		}
		return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
	})
	result := server.listApps()
	apps := result["apps"].([]map[string]any)
	windows := apps[0]["windows"].([]map[string]any)
	if windows[0]["windowId"] != int64(99) || windows[0]["title"] != "Untitled" {
		t.Fatalf("unexpected app window identity: %#v", windows[0])
	}
}

func TestWindowsHostProtocolRejectsMissingExactWindow(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		if request.Tool != "host_inventory" {
			return nil, fmt.Errorf("unexpected PowerShell request: %+v", request)
		}
		return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	result := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind":     "window",
			"pid":      41,
			"windowId": 100,
		},
	})
	errorBody := result["error"].(map[string]any)
	if errorBody["code"] != "window_gone" {
		t.Fatalf("unexpected error: %#v", errorBody)
	}
}

func TestWindowsHostProtocolMapsWindowGoneDuringDispatch(t *testing.T) {
	server := newTestWindowsHostServer(t, func(request psRequest) (*psResponse, error) {
		switch request.Tool {
		case "host_inventory":
			return &psResponse{OK: true, Apps: []appSnapshot{*windowsHostTestSnapshot("before")}}, nil
		case "get_app_state":
			return &psResponse{OK: true, Snapshot: windowsHostTestSnapshot("before")}, nil
		case "click":
			return &psResponse{
				OK: false, ErrorCode: "window_gone", Error: "the bound window no longer exists",
			}, nil
		default:
			return nil, fmt.Errorf("unexpected PowerShell request: %+v", request)
		}
	})
	handshakeWindowsHost(t, server)
	if _, rpcError := server.beginSession(map[string]any{"session": "s1"}); rpcError != nil {
		t.Fatal(rpcError)
	}
	observed := server.observe(map[string]any{
		"session": "s1",
		"target": map[string]any{
			"kind": "app",
			"app":  windowsAppID(*windowsHostTestSnapshot("before")),
		},
	})
	wire := observed["snapshot"].(map[string]any)
	element := wire["elements"].([]map[string]any)[0]
	result := server.dispatchElement(map[string]any{
		"session":             "s1",
		"snapshotId":          wire["snapshotId"],
		"toolCallId":          "call-window-gone",
		"elementToken":        element["token"],
		"expectElementDigest": element["digest"],
		"action":              map[string]any{"kind": "click"},
	})
	errorBody := result["error"].(map[string]any)
	if errorBody["code"] != "window_gone" {
		t.Fatalf("unexpected error: %#v", errorBody)
	}
}

func newTestWindowsHostServer(t *testing.T, run powerShellRunner) *windowsHostServer {
	t.Helper()
	server, err := newWindowsHostServer(run)
	if err != nil {
		t.Fatal(err)
	}
	return server
}

func handshakeWindowsHost(t *testing.T, server *windowsHostServer) {
	t.Helper()
	_, rpcError := server.hello(map[string]any{
		"protocol": windowsHostProtocolVersion,
		"imageDir": t.TempDir(),
	})
	if rpcError != nil {
		t.Fatalf("hello failed: %+v", rpcError)
	}
}

func windowsHostTestSnapshot(value string) *appSnapshot {
	selected := false
	return &appSnapshot{
		App:         appDescriptor{Name: "notepad", BundleIdentifier: "notepad", PID: 41},
		WindowID:    99,
		WindowTitle: "Untitled",
		WindowBounds: &frame{
			X: 10, Y: 20, Width: 640, Height: 480,
		},
		Elements: []elementRecord{{
			Index:       0,
			ParentIndex: -1,
			Depth:       0,
			RuntimeID:   []int{1, 2, 3},
			Name:        "Document",
			ControlType: "ControlType.Document",
			Value:       value,
			Frame:       &frame{X: 0, Y: 0, Width: 640, Height: 480},
			Actions:     []string{"Invoke", "SetValue"},
			Enabled:     true,
			Focused:     true,
			Selected:    &selected,
		}},
	}
}

func TestWindowsRuntimeForegroundActionsRequireOptIn(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
		t.Fatal("Windows app launch fallback must remain opt-in")
	}
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS") {
		t.Fatal("Windows SetFocus action must remain opt-in")
	}
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK") {
		t.Fatal("Windows UIA text fallback must remain opt-in")
	}
	if !strings.Contains(serverInstructions, "does not auto-launch apps, perform SetFocus, or use UIA text fallback by default") {
		t.Fatal("MCP instructions must document the Windows background-focus policy")
	}
}

func TestUTF8EncodingInPowerShellScript(t *testing.T) {
	// Verify that the PowerShell script sets UTF-8 encoding
	if !strings.Contains(windowsRuntimeScript, "$OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set $OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
	if !strings.Contains(windowsRuntimeScript, "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set [Console]::OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
}

func TestWindowsRuntimeTextLimitSupportsMaxMode(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$DefaultTextLimit = 500") {
		t.Fatal("Windows runtime should define the shared 500 character text limit")
	}
	if !strings.Contains(windowsRuntimeScript, "Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit)") {
		t.Fatal("Windows get_app_state should pass text_limit into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq \"max\"") {
		t.Fatal("Windows runtime should support max text limit mode")
	}
	if !strings.Contains(windowsRuntimeScript, "([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth)") {
		t.Fatal("Windows get_app_state should pass tree budget into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }") {
		t.Fatal("Windows selected text should use full UIA text only in max text mode")
	}
}

func TestWindowsRuntimeTreeBudgetDefaultsMatchMacOS(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxNodeCount = 1200") {
		t.Fatal("Windows runtime should default to the shared 1200 node tree budget")
	}
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxDepth = 64") {
		t.Fatal("Windows runtime should default to the shared 64 level tree depth")
	}
	if !strings.Contains(windowsRuntimeScript, "$script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth") {
		t.Fatal("Windows runtime should use shared tree budget constants while rendering")
	}
}

func TestWindowsRuntimeNamesApplicationFrameWindowsFromUIA(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, `$appName -ieq "ApplicationFrameHost"`) {
		t.Fatal("Windows inventory should replace the generic UWP frame-host name")
	}
	if !strings.Contains(windowsRuntimeScript, `$appName = $window.Current.Name`) {
		t.Fatal("Windows inventory should expose the user-visible UWP app name")
	}
	if !strings.Contains(windowsRuntimeScript, `$appName = $windowTitle`) {
		t.Fatal("Windows observations should expose the user-visible UWP app name")
	}
}

func findToolDefinition(t *testing.T, name string) toolDefinition {
	t.Helper()
	for _, tool := range toolDefinitions() {
		if tool.Name == name {
			return tool
		}
	}
	t.Fatalf("missing tool definition %q", name)
	return toolDefinition{}
}
