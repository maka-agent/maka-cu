# maka-cu Host Protocol (`maka.cu/2`)

The wire contract between the Maka Electron host (TypeScript) and `maka-cu`, the
native macOS executor (Swift). Both sides are ours. This protocol answers to
`CuDispatchBackend` in `packages/runtime/src/computer-use-types.ts` and to
nothing else.

It replaces `maka-cu`'s MCP surface (`MCPServer.swift`, `ToolDefinitions.swift`,
`ComputerUseToolDispatcher.swift`). It is not MCP, carries no tool schemas and no
model-facing prose: Maka's runtime owns every word the model reads.

Two engineers who cannot talk to each other should be able to build the two ends
from this document and have them interoperate. Where a rule exists because of a
specific bug or measurement, the rule says so.

### Why this is version 2

`maka.cu/1` was built twice from this document, once in Swift and once in
TypeScript, by engineers who could not talk to each other. The two ends did not
interoperate, and six of the disagreements were holes in this text rather than
bugs in either implementation: a refusal could not carry the fields §6.5 made
mandatory (§6.5), hashes were written two ways in one document (§1.3), the key
surface could not express what the caller actually holds (§6.4), apps were named
in two namespaces (§5.1), one error code covered two situations (§6.2), and
`element.frame` had one declared space and a different one in practice (§5.3).

Each is closed below, and each closure names the defect that produced it. Five of
them move the wire, so the version string moves with them: a `maka.cu/1` peer is
not compatible and must fail the handshake rather than degrade (§2). There is no
`maka.cu/1` peer worth interoperating with — no two of them agreed.

---

## 1. Framing

Line-delimited JSON-RPC 2.0 over the executor's stdin/stdout. One JSON value per
line, UTF-8, terminated by `\n`. No `Content-Length` headers. This is what
`MCPServer.swift:27-37` already reads and what
`packages/computer-use/src/cua-driver-service.ts:395-416` already parses; the new
protocol does not differ gratuitously in framing, only in payload.

- stdout carries JSON-RPC and nothing else. Any diagnostic, warning or panic goes
  to stderr. A non-JSON line on stdout is a protocol violation; the host drops it
  and counts it, and three in one process generation are grounds for teardown.
- Every request has an integer `id`. Notifications have no `id`.
- Responses MAY arrive out of order. The host correlates by `id` only. This is
  already true of the host implementation and is stated here so the executor is
  free to use lanes (§9) without a framing change when the capture stream lands.
- Maximum encoded message size is `limits.maxResponseBytes` (§2). A response that
  would exceed it MUST NOT be truncated silently — see §7.5.
- The executor MUST emit exactly one response per request `id` it has read, and
  MUST NOT emit a response for an `id` it never received.

### 1.1 Result envelope

Two error layers, deliberately separated.

**JSON-RPC `error`** means the *request* was unusable or the executor was not in a
state to consider it. It never describes the world.

| code | meaning |
| --- | --- |
| `-32700` | parse error |
| `-32600` | invalid request (not JSON-RPC 2.0) |
| `-32601` | unknown method |
| `-32602` | invalid params (missing field, wrong type, value outside a closed set) |
| `-32603` | internal executor error |
| `-32000` | `protocol_version_mismatch` (§2) |
| `-32001` | `handshake_required` — a method other than `host.hello` arrived first |
| `-32002` | `session_unknown` — `session` names a session that was never begun or has ended |
| `-32003` | `shutting_down` — SIGTERM received, no new work accepted |

**JSON-RPC `result`** carries everything about the world, as a tagged union:

```json
{ "ok": true,  ...method-specific fields }
{ "ok": false, "error": { "code": "<domain code>", "message": "<fixed sentence>", "detail": { } } }
```

Domain failures (snapshot spent, element changed, permission missing, dispatch
refused) are results, not JSON-RPC errors. They are expected outcomes the model
must see, they carry structured evidence, and a JSON-RPC error object has only
`code`/`message`/`data` — which invites exactly the free-form-field archaeology
this protocol exists to end.

**The `ok: false` arm of a dispatch result carries the declared dispatch fields
too.** `dispatch.element`, `dispatch.point` and `dispatch.key` answer with

```json
{ "ok": false, "toolCallId": "call_1",
  "outcome": "refused", "tier": "ax", "path": "none",
  "effect": "unverifiable",
  "verification": { "method": "none", "observedChange": false },
  "error": { "code": "…", "message": "…", "detail": { } } }
```

on both arms. `outcome`, `tier`, `path` and `effect` are required on the refusal
arm exactly as they are on the success arm. In `maka.cu/1`
this arm was `error` and nothing else, which put §6.5 ("four required fields on
every dispatch result") in direct contradiction with §1.1, and the two
implementations resolved it in opposite directions: the Swift executor's
`refused()` computed `path` and `tier` and then dropped them on the floor at
`emit(id:failure:)`, while the TypeScript host treated an `ok: true` result whose
`outcome` was not `ok` as a protocol violation and SIGKILLed the child. Both were
reading this document correctly. A refusal is an outcome the model must read, and
§6.3 already assigns it `path: none`, so it was always meant to be expressible.

No other method's `ok: false` arm carries these fields. `observe` refusing with
`capture_failed` dispatched nothing, so an `outcome` on it would be a field with
no producer.

### 1.2 No application text outside declared observation fields

`error.message` is a fixed sentence chosen by `error.code`. `error.detail`
contains enums and numbers only. The only fields in this protocol that may carry
text belonging to the observed application are `element.label`,
`element.value`, `element.placeholder`, `element.axIdentifier`,
`snapshot.target.title`, `snapshot.selectedText.text`, and the display names
`appName` / `apps.list[].name` — all of which the host already treats as
untrusted content, and none of which is ever used as a key (§5.1).

This is a change of posture. The current backend carries a comment that
`cua-driver does NOT redact secrets — the runtime redacts every backend-supplied
message upstream` (`cua-driver-backend.ts:15-16`). Under this protocol the
executor never puts application content in a diagnostic string, so there is no
message-redaction pass to get wrong.

### 1.3 One way to write a hash

Every hash on this wire is the string `"<algorithm>:<lowercase hex>"`. In
`maka.cu/2` the algorithm is always `sha256`, so every hash begins `sha256:`.

This applies without exception to `element.digest`, `snapshot.windowDigest`,
`image.sha256` — including the images in `screen.capture` (§6.6) and in the
reserved capture stream (§10). The field name `image.sha256` is kept: it declares
which algorithm the prefix is required to state, and renaming it would break the
wire to buy nothing.

Bare hex is not accepted anywhere. A host comparing hashes computes its own
digest and prefixes it before comparing; it MUST NOT strip a prefix, MUST NOT
accept both forms, and MUST NOT compare only the tail. A bare-hex value from the
executor is a protocol violation like any other undeclared shape (§8).

The rule exists because `maka.cu/1` wrote both forms in one document — bare hex
in §5, §6.6 and §8, `"sha256:c40f…"` in §4.3 and the element example — and both
implementations were consistent with the half they read. `maka-cu` emits the
prefixed form everywhere (`HostDigest.sha256` prefixes; `HostImageStore` uses it
for image bytes too), while the host verified an image with
`createHash('sha256').update(bytes).digest('hex')` and compared for exact
equality. Every screenshot therefore mismatched, and the host's response to a
mismatch is to declare the session compromised and kill the executor. The
executor is already correct; the host is the side that changes.

---

## 2. Handshake

`host.hello` MUST be the first message on the connection. Anything else gets
`-32001`.

**Request**

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "host.hello",
  "params": {
    "protocol": "maka.cu/2",
    "host": { "name": "maka", "version": "0.9.3" },
    "hostPid": 8123,
    "imageDir": "/var/folders/…/maka-cu-images-8123",
    "allowGlobalPointer": false
  }
}
```

- `protocol` — exact string. No negotiation, no "highest common version".
- `hostPid` — the executor polls `kill(hostPid, 0)` every 2s and exits if the
  host is gone. macOS has no `PDEATHSIG`; without this an orphaned executor
  holding Accessibility survives a host crash.
- `imageDir` — absolute, must already exist and be writable by the executor.
  Every image reference in this protocol is a path under this directory (§8).
  The executor MUST verify writability during the handshake and fail it
  otherwise; discovering the directory is read-only at first `observe` would
  turn a configuration error into a capture failure.
- `allowGlobalPointer` — when `false` (the only value Maka ships), the executor
  MUST NOT use any dispatch path that moves the system cursor or changes window
  z-order, and MUST refuse rather than fall back to one. See §6.3.

**Result**

```json
{
  "ok": true,
  "protocol": "maka.cu/2",
  "executor": { "name": "maka-cu", "version": "0.4.0", "commit": "1747868" },
  "pid": 8140,
  "capabilities": {
    "captureStream": false,
    "elementActions": ["click", "set_value", "select_text", "secondary_action", "scroll"],
    "pointActions": [],
    "keyActions": ["type", "key"],
    "imageFormats": ["png", "jpeg"]
  },
  "limits": {
    "snapshotsPerSession": 8,
    "snapshotTtlMs": 120000,
    "maxElements": 1500,
    "maxDepth": 64,
    "maxTextChars": 500,
    "maxResponseBytes": 1048576,
    "settleCeilingMs": 2500,
    "treeWalkCeilingMs": 6000,
    "shutdownGraceMs": 3000,
    "imageDirBudgetBytes": 268435456
  }
}
```

Every limit here has a host consumer: the host must not hardcode a bound the
executor enforces. Today the host duplicates all of them —
`MAX_OBSERVATIONS_PER_SESSION = 16`, `SETTLE_CEILING_MS = 2_500`,
`max_elements: 500` at four call sites — and nothing detects drift when the
executor's number changes.

**Version mismatch is fatal and loud.** If `params.protocol` is not a version the
executor implements, it MUST answer

```json
{ "jsonrpc": "2.0", "id": 1,
  "error": { "code": -32000, "message": "protocol_version_mismatch",
             "data": { "supported": ["maka.cu/2"] } } }
```

then flush stdout and exit with status `78` (`EX_CONFIG`). The host MUST classify
this as `service_mismatch` and MUST NOT retry — `CuaDriverService.startWithBudget`
already treats `service_mismatch` as non-retryable
(`cua-driver-service.ts:200-203`). Silent degradation to a subset is forbidden in
both directions.

`supported` lists `maka.cu/2` and nothing else. `maka.cu/1` is withdrawn, not
deprecated: the parts of it that moved are exactly the parts the two `maka.cu/1`
implementations disagreed about, so a peer still speaking it is a peer whose
behaviour on those points is unknown. Accepting it back would reintroduce every
split this version closes.

---

## 3. Sessions

A session is the host's unit of ownership: snapshots, images, keyboard target
and capture streams all belong to one. The host supplies the id, because Maka
already has one (`CuRunContext.sessionId`) and a second identity space would
have to be joined by hand.

### `session.begin`

```json
{ "method": "session.begin",
  "params": { "session": "s-01J…", "captureScope": "window" } }
```

`captureScope` ∈ `"window" | "desktop"`. It selects the ScreenCaptureKit content
filter for the life of the session and cannot be changed afterwards.

```json
{ "ok": true }
```

Beginning a session id that is already live is `-32602`, not an implicit reset:
an accidental reuse must not silently discard live snapshots.

### `session.end`

```json
{ "method": "session.end", "params": { "session": "s-01J…" } }
```

```json
{ "ok": true, "released": { "snapshots": 3, "images": 3, "streams": 0 } }
```

Drops every snapshot, deletes every image file the session produced, stops every
capture stream, releases the keyboard target, and removes any executor-drawn
cursor. `released` is reported because Maka has already been bitten by an agent
cursor outliving the run that drew it
(`cua-driver-service.ts:717-726`); a count the host can assert on is how that
regression gets a test.

Ending an unknown session is `ok: true` with zero counts, not an error —
teardown must be idempotent.

---

## 4. Frame binding

This is the reason the protocol exists. Upstream `cua-driver` re-resolves an
element *index* against a snapshot taken at action time, so "click element 7"
means "click whatever is 7 now". Maka compensates today by re-fetching the whole
window state and re-matching on role/label/value/frame/depth in TypeScript
(`cua-driver-target-resolution.ts:522-592`) — a check that costs an extra AX
tree walk per action and still cannot see anything the driver did not print.

Here the executor owns it.

### 4.1 Snapshot lifecycle

`observe` mints a snapshot: an id, a set of element tokens, and — held inside the
executor — the retained `AXUIElement` references and recorded digests.

A snapshot is in exactly one state:

| state | entered when | dispatch quoting it fails with |
| --- | --- | --- |
| `live` | created by `observe` or by a dispatch's post-observation | — |
| `spent` | a dispatch quoting it returned `ok:true` with a mutating method, or returned `outcome_unknown` | `snapshot_spent` |
| `superseded` | a later `observe` produced a snapshot of the same `(pid, windowId)` | `snapshot_superseded` |
| `expired` | `limits.snapshotTtlMs` elapsed since `capturedAt` | `snapshot_expired` |
| `evicted` | more than `limits.snapshotsPerSession` live snapshots in the session; oldest goes first | `snapshot_evicted` |
| unknown | never existed in this process | `snapshot_unknown` |

Five distinct codes, not one. They mean different things to the host: `spent` and
`superseded` mean *re-observe and retry*, `evicted` means *the host is holding
too many frames*, `unknown` after a restart means *the executor died*, and
collapsing them is how a retry loop becomes indistinguishable from a bug.

Notes:

- A refusal before `act` does not spend its snapshot. The host may fix the
  argument and retry against the same frame. Once `act` has spent the snapshot,
  even a platform-level refusal reports `error.detail.snapshotSpent: 1` and the
  host must discard that frame. `outcome_unknown` also spends it: we cannot prove
  the action did not land. `dispatch.element` reports `snapshotSpent: 0` for a
  pre-dispatch refusal and `1` after `act`; the value is numeric protocol detail.
- A **read** does not spend a snapshot. `screen.capture` and `window.list` never
  touch snapshot state.
- Supersession is scoped to `(pid, windowId)`. Observing window B does not
  invalidate a live snapshot of window A. **The executor is deliberately more
  permissive than the host here:** `CuaFrameState` keeps exactly one current
  frame globally and invalidates on every observe
  (`cua-frame-state.ts:47-56`). Host policy still binds; the executor does not
  re-implement it, so neither side should assume the other is enforcing the
  single-frame rule.
- Snapshot ids MUST contain a 128-bit per-process nonce. After a restart, an id
  minted by the previous generation must fail `snapshot_unknown` and must never
  collide with a fresh one.

### 4.2 Element tokens

Each element in a snapshot carries a `token`: an opaque string, unique within the
executor process, meaningful only inside its own snapshot.

The executor MUST look tokens up by exact string match in a per-snapshot
dictionary. It MUST NOT parse an index out of a token and re-walk the tree. An
index-derived token that survives a tree rebuild is precisely the defect being
removed.

Each element also carries a non-negative integer `stableId`. This is presentation
identity across revisions of the same `(session, pid, windowId)`, not dispatch
identity:

- the first observation assigns ids in depth-first tree order;
- a later observation gives structurally matched nodes their previous ids;
- a new node receives an id greater than every id in the baseline revision;
- removed ids are not reassigned inside that revision chain.

The host may expose `stableId` as the short model-facing element id, but it MUST
map that id back to the fresh snapshot's `token` before dispatch. Quoting a
stable id to `dispatch.element`, or resolving it against a later tree without
the current token, would recreate the index bug under a different name.

### 4.3 What "the same element" means

A token resolves to the same element at dispatch time if and only if all three
hold:

- **E1 — the reference is alive.** The retained `AXUIElement` answers an attribute
  read with something other than `kAXErrorInvalidUIElement`.
- **E2 — the process is the same process.** The recorded `pid` still exists and
  its start time (`proc_pidinfo` / `p_starttime`) is unchanged. A recycled pid
  fails.
- **E3 — the digest matches.** The recomputed element digest equals the digest
  recorded at observe time.

Element digest = SHA-256 over the canonical JSON array

```
[ role, subrole, axIdentifier, title, label, valueDigest,
  frameInWindow, sortedActionNames, ancestorRoles[0..7], siblingIndex ]
```

`valueDigest` is `null` when the element has no value, otherwise SHA-256 of the
**untruncated** value string. Digesting the untruncated value matters: the wire
value is capped at `limits.maxTextChars`, and digesting the capped copy would
make every edit past character 500 invisible to the check.

Ancestor roles are capped at 8 levels root-ward, and are read from the live
parent links rather than from the walk's own traversal: a walk elides wrapper
nodes and `AXParent` does not, so a chain taken from the traversal at observe
time cannot be reproduced at dispatch time on any tree that has wrappers in it.
Sibling index is the element's position among its parent's traversed children.

**The root of a snapshot has no ancestors and no siblings.** A snapshot is rooted
at the window it was taken of, so within the frame there is nothing above the
root: its `ancestorRoles` is `[]` and its `siblingIndex` is `0`, whatever the
application element above it would say. This is not a shortcut. A window's place
in its application's `AXWindows` is z-order in many applications, so a root that
took its identity from its live position would change identity whenever a
*different* window of the same application came forward.

**Recorded and recomputed must come from one code path.** The digest inputs are
recorded at observe time and recomputed at dispatch time, and every field of §4.3
has to be read the same way at both ends or the check fails on something nothing
touched — a false refusal that no amount of re-observing can clear, because
re-observing produces the same disagreement. An executor that assembles this
field list twice has two copies of §4.3 to keep in step; the reference executor
assembles it once, in `hostElementDigestInput`, and both ends call it.

The digest is exposed to the host as `element.digest` — written the one way §1.3
declares, like every other hash here — and the host MUST echo it in every element
dispatch (§6.1). Echoing is not redundant with the executor's own record: it
catches a host that has mixed up two elements from two snapshots, which the
executor's record by construction cannot. When the echo does not match, the
executor answers `element_digest_mismatch`, which is a different diagnosis from
both `element_unknown` and `element_changed` — see §6.2.

Window digest = SHA-256 over the sorted set of every element's digest, plus the
window bounds and title. Exposed as `snapshot.windowDigest` and echoed by point
dispatch (§6.3), which has no element to anchor to.

### 4.4 What this check cannot catch

Stated plainly, because a binding check that is trusted beyond its reach is worse
than none.

1. **Recycled views.** `NSTableView` and `NSOutlineView` reuse row views. One
   `AXUIElement` can come to represent a different data row after a scroll. If a
   list scrolls by exactly one row height and the new occupant has the same role,
   label, value and frame, E1–E3 all pass and the click lands on the wrong
   record. Nothing available through Accessibility distinguishes them. The host's
   only defence is `strictness: "window"` (§6.1), which refuses when anything in
   the window changed — correct for lists, far too strict for a window with a
   clock in its toolbar. The protocol makes it the host's declared choice rather
   than a guess by either side.

2. **Tree-rebuilding applications.** Chromium and Electron web areas mint fresh
   `AXUIElement`s per query. When E1 fails, the executor performs one bounded
   fresh walk and accepts a replacement only when it is unique, belongs to the
   same host and renderer process generations, has the same role/subrole, and
   preserves either the stable AX identifier or the full name/value/action
   signature. Geometry, ancestor wrappers and sibling position may change.
   Missing remains `element_released`; more than one match is
   `element_changed`. The old token is never reinterpreted as an index.

3. **Identity is not reachability.** All three checks pass on an element behind a
   sheet, in a hidden tab, or on another Space. Occlusion is a separate check
   with a separate code (§6.2).

4. **Value churn spends frames.** Including the value in the digest means a field
   the user is typing into invalidates the snapshot on every keystroke. That is
   intended — the state you observed is gone — but it makes `set_value` against a
   live-updating field unbindable. No mitigation is offered; the host re-observes.

5. **Identity says nothing about effect.** Whether the action did anything is
   `effect` / `verification` (§6.5), not this.

---

## 5. Observation

### 5.1 One namespace for naming an app

There is exactly one string that names an app on this wire, and it is called
`appId`.

- `appId` is the bundle identifier when the process has one, otherwise
  `pid:<n>`. That is the host's existing fallback (`cua-driver-backend.ts:1170`),
  moved to the side that knows.
- `apps.list`, `window.list`, `snapshot.target` and the `apps.launch` result all
  carry it, spelled the same way, for the same process.
- `{ "kind": "app", "app": … }` (§5.2) takes an `appId` and nothing else. The
  executor resolves it by exact string match against `appId`. It MUST NOT match
  against `appName`, against `snapshot.target.title`, or against any prefix or
  case-folded form of either.
- `appName` is a display string. It is untrusted application content (§1.2), it
  is localised, two apps may share one, and it is never a key.
- There is no `bundleId` field anywhere on this wire. It was a second spelling of
  the same fact, and a second spelling is what this section exists to remove; a
  caller that wants to know whether the process has a bundle id reads whether
  `appId` starts with `pid:`. The host MUST NOT hand the model two app identifier
  strings, because then the model has to guess which one to echo back.

The single exception is `apps.launch`'s **request** `app`, which may be a bundle
id or a human name, because an app that is not running has never appeared in
`apps.list` and so has no `appId` the caller could have learned. The executor
resolves it through LaunchServices and returns the resolved `appId`; every later
call uses that. This is what deletes the host's `isBundleId` regex sniff
(`cua-driver-backend.ts:1676-1682`), which guessed a namespace from the shape of
a string.

**Why the rule is stated this baldly.** In `maka.cu/1` `apps.list` returned
bundle ids, `window.list` carried only `appName`, and nothing said which of the
two a caller's `app` string was. The host built its `appId` as
`bundleId ?? appName ?? pid:<n>` and then resolved a caller's `app` against
`window.list`'s `appName` and `title` — so for every app that has a bundle id,
the string the host handed out could never match the strings it matched against,
and every `{app, windowId}` observation of such an app was refused. A reviewer
reproduced it on the first try. `cua-driver` never had this bug because it used
one namespace, the app *name*, in both places (`appIdForWindow` feeds both the
`apps.list` key and the window match). One namespace is the fix; bundle id is the
better one to standardise on, because a display name is neither unique nor stable
across locales.

Which side changes: both. The executor adds `appId` to `window.list` and
`snapshot.target` and resolves `{kind: "app"}` on it. The host stops matching on
`appName`/`title` and passes `appId` through unaltered.

When the host is given both an app string and a window id, it resolves the window
id — exact, numeric — and then requires that window's `appId` to equal the app
string. Disagreement is `target_missing`, because no window satisfies the pair;
honouring one input and discarding the other would be acting on a target the
caller did not name. This is not the old over-strict rule, which required both to
match when the caller had sent only one (§5.2).

### 5.2 `observe`

```json
{ "method": "observe",
  "params": {
    "session": "s-01J…",
    "target": { "kind": "window", "pid": 4711, "windowId": 90210 },
    "includeImage": true,
    "maxElements": 1500,
    "maxDepth": 64,
    "maxTextChars": 500
  } }
```

`target` is a **tagged union**, never a bag of optional fields:

```json
{ "kind": "app",    "app": "com.apple.Notes" }
{ "kind": "window", "pid": 4711, "windowId": 90210 }
```

`app` is an `appId` (§5.1). `{ "kind": "app" }` resolves to the app's frontmost
usable window and is ambiguous by design; `{ "kind": "window" }` is exact.
The frontmost inventory entry may be an AppKit sheet. `CGWindowList` reports a
sheet as a window, while Accessibility exposes it as an `AXSheet`/`AXDrawer`
child of the main `AXWindow`; the executor first matches ordinary AX windows by
frame, then matches those child roles by the same frame. It does not query a
fictional `AXSheets` attribute. Exact window targeting never falls back to the
main window when the requested secondary or sheet window cannot be matched.
Optional `app` *and* optional `windowId` in one object is how a real-machine
failure happened: the contract said "app **or** window\_id" while the harness
required both to match, so a compliant model could not pass. A tagged union
cannot express that disagreement.

The **executor** resolves `{ "kind": "app" }`. It owns the window inventory and
the z-order, and the host that tried to pre-resolve an app string against
`window.list` is the host that invented title matching to make it work (§5.1).

Omitted `maxElements` / `maxDepth` / `maxTextChars` mean the values in
`limits`. A value above the limit is `-32602`, not a silent clamp.

When the window server already lists a window but Accessibility has not exposed
its matching `AXWindow` / `AXSheet` yet, the executor retries that exact
PID/window/frame match for 250 ms before returning `window_gone`. A window absent
from the window inventory is still refused immediately. This covers the normal
creation race after a press opens a sheet or secondary AppKit window without
turning exact targeting into a fallback to another window.

**Result**

```json
{
  "ok": true,
  "snapshot": {
    "snapshotId": "snap_4e2c9a…",
    "capturedAt": 1753574400123,
    "target": {
      "pid": 4711,
      "windowId": 90210,
      "appId": "com.apple.Notes",
      "appName": "Notes",
      "title": "Untitled",
      "bounds": { "x": 0, "y": 25, "width": 1200, "height": 800 },
      "layer": 0,
      "zIndex": 3,
      "displayId": "69732928"
    },
    "windowDigest": "sha256:1f0c…",
    "focusedElementToken": "el_9b41…",
    "selectedText": { "text": "abc", "truncated": false },
    "image": {
      "path": "/var/folders/…/maka-cu-images-8123/snap_4e2c9a.png",
      "format": "png",
      "widthPx": 2400,
      "heightPx": 1600,
      "byteLength": 743210,
      "sha256": "sha256:9d81…",
      "scale": 2.0
    },
    "displays": [
      { "displayId": "69732928",
        "logicalBounds": { "x": 0, "y": 0, "width": 1512, "height": 982 },
        "sourceBoundsPx": { "x": 0, "y": 0, "width": 3024, "height": 1964 },
        "scaleFactor": 2.0 }
    ],
    "obscuringRects": [ { "x": 300, "y": 100, "width": 400, "height": 300 } ],
    "elements": [ … ],
    "truncated": { "elements": false, "depth": false },
    "difference": {
      "baseSnapshotId": "snap_4e2c99…",
      "presentation": "difference",
      "changes": [
        { "kind": "remove", "path": [0, 2], "stableId": 7, "token": null },
        { "kind": "update", "path": [0, 3], "stableId": 9, "token": "el_9b41…" }
      ],
      "removedStableIdRanges": [ { "start": 7, "end": 8 } ]
    }
  }
}
```

`focusedElementToken` and `selectedText` are `null` when absent — both exist in
`AppSnapshot` already (`AccessibilitySnapshot.swift:111-113`) and are what
`type_text` needs to be verifiable.

`obscuringRects` lists the layer-0 windows stacked above the target, in screen
points. Presentation only: the Maka agent cursor uses it to decide how *high* to
draw, never whether to draw (`computer-use-types.ts:161-175`). The executor MUST
exclude the titleless full-screen Dock surface — the host currently filters it
out by hand (`cua-driver-backend.ts:1120-1135`), and that filter belongs where
the window list is read.

**Element**

```json
{
  "token": "el_7f3ab2…",
  "stableId": 12,
  "parentToken": "el_1b0c55…",
  "depth": 4,
  "role": "AXButton",
  "subrole": "AXCloseButton",
  "axIdentifier": "sendButton",
  "title": null,
  "label": "Send",
  "value": null,
  "placeholder": null,
  "enabled": true,
  "focused": false,
  "selected": null,
  "frame": { "x": 1040, "y": 720, "width": 72, "height": 28 },
  "actions": ["press", "show_menu"],
  "digest": "sha256:c40f…",
  "truncated": []
}
```

- `parentToken` is `null` for the root. `null` and absent are the same on the
  wire; the executor SHOULD emit `null` for clarity.
- `stableId` follows §4.2. It is required on snapshots produced by this
  executor, while hosts MAY accept its absence from an older executor and fall
  back to snapshot-local ordering for compatibility.
- **`title` is `AXTitle` and `label` is `AXDescription`, and they are two
  fields.** Which one an element names itself with is the application's choice,
  not a shape the host may assume: measured on a background Calculator, 23 of 35
  window elements carry a `label` — AppKit's controls set `AXDescription`
  (`删除`, `清除`, `百分比`) — and 2 of 126 menu elements do, because menu items
  name themselves with `AXTitle` and set no description at all. A host that reads
  only one of the two sees an anonymous tree in whichever half of macOS chose the
  other.

  They are not merged into one field because §4.3 digests them separately and
  §6.2 reports `detail.changed: ["title"]`. `maka.cu/2` carried the digest input
  without carrying the field, so the executor could tell a host *the title
  changed* about something it had never sent — and the host's only possible reply
  was to re-observe and compare nothing.
- `actions` is a **closed set** of normalised names:
  `press`, `confirm`, `open`, `show_menu`, `raise`, `cancel`, `pick`,
  `increment`, `decrement`, `scroll_up`, `scroll_down`, `scroll_left`,
  `scroll_right`. The executor maps from raw AX action names; the host never
  sees `AXPress`. `secondary_action` (§6.1) takes one of these enums, which
  replaces `maka-cu`'s current free-form case-insensitive string matching
  (`ComputerUseService.swift:835-845`) and its "`X` is not a valid secondary
  action" class of error.
- `truncated` lists which of this element's text fields were cut at
  `maxTextChars`, from the closed set `title`, `label`, `value`, `placeholder`.
  An empty array is not omitted, so "was anything cut" is a field read, not a
  length comparison.

**Truncation is never silent.** `truncated.elements` is `true` when the tree hit
`maxElements`, `truncated.depth` when it hit `maxDepth`. A truncated tree is
still a valid snapshot with valid tokens; the host decides whether to re-observe
with a higher bound.

**The walk is bounded in time as well as in size.** `limits.treeWalkCeilingMs`
is how long one `observe` may spend reading the Accessibility tree, counted
across every attempt §7.5 makes rather than granted afresh to each of them. When
it runs out the executor stops descending and returns what it has, with
`truncated.elements: true`. The root element is always emitted: a snapshot with
no elements carries no tokens, so the host could not address the window it just
observed.

The bound exists because element count is not a proxy for time. Reading a node
costs a round trip into the observed process, and an application that hosts its
window in *another* process is a different order of expense: every open and save
panel on macOS is drawn by `com.apple.appkit.xpc.openAndSavePanelService`, so
each of its nodes crosses an XPC boundary. Measured — an ordinary window reads at
0.8–7.5 ms per element and finishes in under two seconds, while an open panel
reads at 23.6 ms per element and rising, and 1500 of them took 35 s. The host
gives a request 20 s (§7.3) and answers an overrun by cancelling it and tearing
the executor down, so an unbounded walk does not return late — it takes the
session with it. A file dialog is not an exotic window, either: it is what the
model is looking at whenever it does file work.

`truncated.elements` is the field a time cut raises, because what came back is
short of what the window holds and that is the fact the field states.
`truncated.depth` is not raised: it names a level the walk refused to go below,
and after a time cut no level was the reason. **Neither field says *why*, and
that is a known gap** — a host that reads `truncated.elements: true` and
re-observes with a higher `maxElements` will get another cut tree, because the
bound it raised was not the one that fired. What the wire must never do is stay
silent: a short tree returned as `{ "elements": false, "depth": false }` tells
the host it has seen the whole window, and every "the control is not there"
conclusion drawn from it is wrong.

### 5.2.1 Observation revisions

`snapshot.difference` is absent when no earlier snapshot of the same
`(session, pid, windowId)` can serve as a baseline. Otherwise it describes the
window tree's revision against `baseSnapshotId`. The full current `elements`
array is still present and authoritative; the difference is a bounded rendering
hint, never a patch the host must apply to reconstruct the tree.

`presentation` is a closed set:

- `no-change`: no effective accessibility change; `changes` and
  `removedStableIdRanges` are empty.
- `difference`: render the declared changes instead of repeating the whole tree.
- `full`: the difference would take more lines than the full tree, so render the
  full current `elements` array.

`changes` is ordered lexicographically by zero-based sibling `path`, then by
`remove < insert < update`. An insert or update carries the current snapshot's
token; a removal carries no token because that element is not dispatchable.
Removed stable ids are also compressed into inclusive
`removedStableIdRanges`, so a host can retire a contiguous run in one line.

Matching is sibling-scoped and structural. Matched nodes inherit their stable
ids even when fresh snapshot tokens change; new ids begin after the baseline's
maximum. A spent snapshot remains eligible as the next difference baseline,
because mutation consumes dispatch authority, not the executor's knowledge of
what the host just saw. Expired and evicted snapshots are never baselines.

The difference covers the window tree only. Menu observations retain their own
scope and continue to travel as the full `snapshot.menu` payload.

Hosts SHOULD render differences only for the immediate post-action observation.
An explicit user/model `observe` SHOULD render the full authoritative tree even
when the executor supplies a difference, so asking to look again never returns
only a delta whose base may no longer be in model context.

### 5.3 Coordinate spaces, declared once

| field | space |
| --- | --- |
| `element.frame` | window-local logical points, origin at the window's top-left |
| `snapshot.target.bounds`, `obscuringRects`, `displays[].logicalBounds` | screen logical points |
| `dispatch.element`'s `move_window.position` and `resize_window.size` (§6.1) | screen logical points |
| `image.widthPx` / `heightPx`, `displays[].sourceBoundsPx` | image pixels |

**Screen logical points are CoreGraphics global display coordinates: y grows
downward and the origin is the top-left of the *main* display.** They are not
AppKit's. This has always been the space `snapshot.target.bounds` is in — it
comes from `CGWindowListCopyWindowInfo` — and it is stated here because §6.1 now
lets a caller write a position back, and the two spaces disagree by more than a
sign on any machine with a second display. Measured on this one, whose second
display sits above the first:

| | display 1 (main) | display 2 |
| --- | --- | --- |
| `CGDisplayBounds` | `(0, 0, 1512, 982)` | `(-193, -1080, 1920, 1080)` |
| `NSScreen.frame` | `(0, 0, 1512, 982)` | `(-193, 982, 1920, 1080)` |

Same display, two origins 2062 points apart. A window moved to a y read off
`NSScreen` lands on the wrong screen, and it lands there silently because both
numbers are plausible.

`AXPosition` is in the CoreGraphics space, not the AppKit one, and that is the
fact `move_window` rests on. Measured across seventeen applications on this
machine, `AXPosition` equalled `CGWindowListCopyWindowInfo`'s origin to the point
on every one, including the four windows with a negative origin — iTerm2 at
`(80, -1049)`, a Chrome window at `(-193, -1049)`, Terminal at `(775, -964)`,
Music at `(277, -931)`. The executor was already relying on this without saying
so: `HostAX.window(pid:windowId:bounds:)` matches AX windows against the window
list's frame to within one point, because there is no public AX attribute
carrying a `CGWindowID`.

`image.scale` is `image.widthPx / target.bounds.width`, computed by the executor
from the image it actually captured — not from `NSScreen.backingScaleFactor`.
`screenshotPixelScale()` already does this division
(`ComputerUseService.swift:188-207`), and the host carries a comment that the
driver's own `scale_factor` is unreliable. Declaring the measured value removes
the host's derivation, and with it the class of bug where a click lands a quarter
of the way into a control. Measuring it is only half of the guarantee: the
bitmap it is measured against must be drawn edge to edge, and §6.7 says why that
is a rule and not an obvious consequence.

**`element.frame` stays window-local, and the host converts it exactly once.**
The wire is window-local because that is what `maka-cu` already computes
(`localFrame` / `windowRelativeFrame`) and because a window-local rectangle stays
correct when the window moves between observe and read.

The field it lands in on the host, `CuObservedElement.frame`, is **screen**
logical points, for every backend. `validateSemanticElementVisibility` compares
its centre against `window.bounds` and feeds it to `topWindowAtPoint`, both in
screen space; `bindCuaSemanticActionToObservation` subtracts the window origin
from it (`cua-frame-state.ts:171-190`); and the same rectangle is printed to the
model beside `snapshot.target.bounds`, which is screen space. Two spaces in one
field, chosen by whichever backend filled it, is the defect: the `cua-driver`
backend passes screen frames straight through, and a host that also passes
`maka.cu` window-local frames straight through makes every consumer wrong by the
window's origin — an agent cursor drawn at the wrong place, and an occlusion
check that refuses a visible control.

So: the conversion is `screen = element.frame + snapshot.target.bounds.origin`,
and it happens in the one function that turns a `snapshot` into a
`CuObservation`, where both values are in hand. Nowhere else.

**How the host knows which space it is holding: from the type, never from the
call site.** A rectangle inside the protocol's own element type is window-local;
a rectangle inside `CuObservedElement` is screen. No function may hold one and
treat it as the other, and the conversion function is the only place both types
appear. A comment claiming a space is not a mechanism — the `elementFrame`
parameter in `cua-frame-state.ts` is documented as "window-local screenshot
pixels" eight lines above the code that treats it as screen points, and both
statements shipped.

### 5.4 `window.list`

```json
{ "method": "window.list", "params": { "session": "s-01J…" } }
```

```json
{ "ok": true,
  "windows": [
    { "pid": 4711, "windowId": 90210, "appId": "com.apple.Notes",
      "appName": "Notes", "title": "Untitled",
      "bounds": { "x": 0, "y": 25, "width": 1200, "height": 800 },
      "layer": 0, "zIndex": 3, "onScreen": true, "displayId": "69732928" }
  ] }
```

Ordered front-to-back. `zIndex` is monotonically decreasing along the array; the
executor MUST NOT emit ties. `appId` is required and is the same namespace
`apps.list` returns (§5.1); its absence here is what made an app string
unresolvable against this list. The host uses this list for occlusion decisions
and for joining a window id to its pid — not for resolving `{ "kind": "app" }`,
which the executor does (§5.2).

### 5.5 `apps.list`

```json
{ "ok": true,
  "apps": [
    { "appId": "com.apple.Notes", "pid": 4711, "name": "Notes",
      "windowCount": 2, "running": true }
  ] }
```

Maps directly onto `CuAppSummary`. `appId` is defined once in §5.1; `name` is the
display string and is never matched against.

Note what is *not* here: `maka-cu`'s `listApps()` currently returns a rendered
text catalogue (`ComputerUseService.swift:420-426`). Rendered text is model-facing
prose. It goes.

The list is what is running **now**, not what was running when the executor
started. This is stated because it is not free on macOS: the obvious source,
`NSWorkspace.shared.runningApplications`, is a cache AppKit refreshes out of
notifications, and in a process whose main thread never runs a run loop that
refresh never lands on any other thread — which is every thread that answers a
request, since the reader parks the main one in `readLine`. Measured before it
was fixed: 91 applications at executor start, TextEdit started externally and
confirmed with `pgrep`, 91 applications and no TextEdit for the rest of the
process's life. The same freeze applies to the frontmost application, which stays
at whoever held the foreground when the executor launched.

An executor that answers from that cache is not merely out of date. It cannot
resolve an app it launched itself: `apps.launch` starts the process, the process
registers — measured at 4990 ms — and the poll searches a list that will never
contain it, so the call spends the caller's whole budget and answers `timeout`
for an app that is on screen. Read the running set from the kernel and the
frontmost pid from the window server, once per request.

### 5.6 `permissions.check`

```json
{ "method": "permissions.check", "params": { "prompt": false } }
```

```json
{ "ok": true, "accessibility": true, "screenRecording": true,
  "screenRecordingProbe": "capture_succeeded" }
```

`screenRecordingProbe` ∈ `"capture_succeeded" | "capture_failed" | "not_probed"`.
The host currently prefers a live ScreenCaptureKit probe over the cached boolean
and has to guess which it got (`cua-driver-backend.ts:1898-1899`); this says.

`prompt: false` MUST NOT raise a TCC dialog. The host calls this at every
action start because a user can revoke at any time
(`computer-use-types.ts:192-194`), and a prompt there would be a dialog storm.

### 5.7 `apps.launch`

```json
{ "method": "apps.launch",
  "params": { "session": "s-01J…", "app": "Notes", "waitForWindowMs": 8000 } }
```

```json
{ "ok": true,
  "pid": 4711, "appId": "com.apple.Notes", "name": "Notes",
  "foregroundTaken": false,
  "windows": [ { "windowId": 90210, "title": "Untitled" } ],
  "waited": { "ms": 3200, "reason": "window_appeared" }
}
```

- `params.app` is the one place a display name is legal (§5.1), because an app
  that is not running has no `appId` the caller could have learned. The result's
  `appId` is the resolved one, and every later call uses that.
- The executor MUST ask for a launch that does not activate. On macOS that is
  `NSWorkspace.OpenConfiguration.activates = false`, and it is not the default:
  the configuration is `activates = true` out of the box, so an executor that
  builds one and passes it unmodified has asked for the foreground on every
  launch. Measured — a cold Preview launched that way was frontmost before the
  call returned, and the same cold Preview launched with `activates = false`
  never owned the front layer-0 window at all. The executor also asks not to be
  recorded in Recent Items: a launch the model made is not something the user
  opened, and `apps.list` ranks its recent half on usage records of that kind.
- `foregroundTaken` remains an observation, and asking for a background launch
  does not turn it into a prediction. An application may call
  `activateIgnoringOtherApps` on its own way up; the executor cannot stop it and
  MUST NOT report the request it made in place of the two reads it took. An
  executor that answered `foregroundTaken: false` because it had asked for a
  background launch would be reporting its own intent as an observation of the
  machine, which is the whole failure this field exists to make impossible.
- `foregroundTaken` is declared, not inferred. `CuLaunchedApp.focusHeld` is
  currently absent when the driver simply did not check
  (`computer-use-types.ts:64-68`) — an absent boolean that means "unknown" is a
  three-valued field pretending to be two. It is a difference between two reads,
  one before the launch and one after, and both must be live (§5.5): answering
  both from a value cached at executor start makes the field a constant `false`,
  so an executor that did take the user's foreground reports that it did not.
- The executor MUST wait for a window rather than returning the empty array it
  sees at launch time. Measured: `launch_app` returns in 1.3–3.2 s and the window
  is mapped 2.3–4.5 s in, so the driver's `windows` array is empty on every real
  launch (`cua-driver-backend.ts:1704-1708`). `waited.reason` ∈
  `"window_appeared" | "timeout" | "not_requested"` says which happened.
- `waitForWindowMs` is a budget for the whole of "make this app usable", not just
  for the window wait at the end of it. The executor spends it on both phases in
  order: starting the application and waiting for the process to register, then
  waiting for a window. An executor that resolves the app against a clock of its
  own and applies the caller's budget only to the second phase refuses launches
  the caller had allowed time for — measured: a cold TextEdit on a loaded machine
  took 5571 ms to register, against a hardcoded five-second resolve and a
  declared budget of 8000 ms. With no `waitForWindowMs` the executor uses its own
  default, and `waited.reason` is `not_requested`.
- A cold launch that outlives the budget is `timeout`, never `app_not_found`.
  They are different facts and the caller acts on them differently:
  `app_not_found` means nothing on this machine answers to that name, and the
  model's move is to name something else; `timeout` means the application exists,
  was started, and had not registered in time, and the model's move is to wait or
  observe again. Answering `app_not_found` for a slow launch is a lie the model
  acts on — it goes off looking for other spellings of an app that is already
  starting, and the launch that did happen is invisible to it.
- An application the executor will not drive at all — the safety list, currently
  password managers — is `unsupported_action`, not `app_not_found` and not
  `permission_missing`. It is present, no macOS grant changes the answer, and
  another spelling of the name will not either.
- A launch the system itself refuses is `dispatch_refused`: it was attempted and
  did not happen. The app is not missing.
- A launch that takes the foreground when `foregroundTaken` was meant to be false
  is still `ok: true` with `foregroundTaken: true`. It happened; hiding it does
  not un-happen it.

### 5.8 The menu bar

`observe` takes a `menu` scope and answers with a second element array beside
`elements`:

```json
"menu": { "scope": "bar" }                    // the bar and its top-level items
"menu": { "scope": "menu", "title": "文件" }   // one menu opened, the rest listed
"menu": { "scope": "all" }                    // the whole tree
```


```json
{ "snapshot": {
    "elements": [ … ],
    "truncated": { "elements": false, "depth": false },
    "menu": {
      "elements": [ … ],
      "truncated": { "elements": false, "depth": false }
    } } }
```

The elements are the same `element` shape §5.2 defines, minted from the same
snapshot and resolved through the same dictionary, so `dispatch.element`
addresses `文件 > 导出为 PDF…` exactly as it addresses a button. There is no new
target kind, no new dispatch kind and no new method: a menu item exposes
`AXPress`, which normalises to `press`, which is what
`{ "kind": "click", "button": "left" }` already requires.

**Why this exists.** Before it, no observation this executor produced contained a
single menu element — not a truncated one, not a filtered one, *none*. `observe`
roots its walk at a window element and `kAXMenuBarAttribute` hangs off the
**application**, so the menu bar was never on any path the walk took. Measured:
Calculator 65 elements, TextEdit 1500, zero `AXMenuBar` / `AXMenuBarItem` /
`AXMenu` / `AXMenuItem` between them. Against a real-machine matrix of five
models and six tasks, three of the four tasks that failed for every model failed
on this one fact — *save as PDF*, *find in project*, *rotate image* are menu
commands and nothing else in the observation could reach them. The other route
is closed for a reason §14 already records: a main-menu key equivalent needs a
key window, a background application has none, and taking the foreground to give
it one is the invariant this executor does not trade.

**`menu` is absent unless asked for.** Not `null`, not an empty array: absent. A
menu costs a walk of its own and most observations do not need one, so "we did
not look" and "we looked and there is nothing" must be different reads. An
application with no menu bar answers `"menu": { "elements": [] }`; an application
whose menu bar is empty answers with one root element and no children, because
the walk always emits its root.

**A menu item names itself with `title`, not `label`.** This is the ordinary rule
of §5.2 rather than anything special about menus, but it is where the rule
bites: 2 of Calculator's 126 menu elements carry a `label` and every named one
carries a `title`. A consumer that reads `label` alone gets an anonymous tree.
`title` did not exist on this wire until the menu bar needed it; §5.2 records
why it was already missing.

**`elements` and `menu.elements` are separate, and `windowDigest` is over
`elements` only.** A menu folded into it would make the same window digest
differently depending on whether menus had been asked for, while charging every
settle for elements that cannot change when the window does.

#### Scope, because a menu bar is not one size

A whole menu bar is larger than most windows. Measured on this machine:

| | window | menu bar |
|---|---|---|
| TextEdit | 16 elements, 58 ms | 369 elements, 157 ms |
| Calculator | 39 elements | 204 elements |

Rendered for a model, TextEdit's observation goes from 215 tokens to 3,767 — the
menu is 94% of what the model reads and 90% of what the observation costs, to
answer a question that nine elements answer. `scope: "bar"` costs 5 ms and about
50 tokens, which is why an observation can afford to carry it every time; and it
must carry something, because a model that cannot see a menu bar at all does not
know to ask about one.

`scope: "menu"` still emits every top-level item and descends into the named one.
Listing the others is not a detail: an answer containing only the menu that was
asked for would cost a second observation to learn what else there is.

**A scope decides descent and nothing else.** `siblingIndex` is still taken from
the full child list and `ancestorRoles` from the live chain, so an element's
digest does not depend on how much of the menu was walked, and a host may narrow
or widen scope between observations without invalidating a binding. This is
stated because the alternative has already shipped once: filtering a *child list*
renumbers its siblings, which is precisely how the Apple-menu exclusion broke
every menu dispatch (`changed: ["siblingIndex"]`) until both sides of §4.3 were
made to share one function.

`truncated.depth` is `true` for `scope: "bar"` — the walk did stop at a depth and
there is more menu below. It is `false` for `scope: "menu"`, which is not a
truncation but the shape the host asked for; reporting it as one would present
the host's own request to the model as a limit of the machine.

`title` belongs to `menu` and is `-32602` on the other two. Ignoring it on `all`
would be indistinguishable from a menu name the host got wrong — both return the
whole tree — and ignoring its absence on `menu` returns every bar item with no
contents, which reads exactly like "that menu is empty". A `title` that names no
menu is *not* an error: it answers with the bar, which is what the host needs in
order to ask again.

#### A disabled menu item is disabled, and a background application's are mostly disabled

`AXPress` on a disabled menu item returns `kAXErrorSuccess` and does nothing.
Measured on TextEdit, background: `文件 > 页面设置…` reports `enabled: false`,
`AXPress` returns success, and no sheet appears. The same item with the
application in front reports `enabled: true`, returns the same success, and opens
the sheet. `AXPick` behaves identically. This is why §5.8 keeps the
`element_disabled` guard: without it every such press would be reported `ok`.

How much of a menu this affects is not marginal. TextEdit in the background:
52 of 250 menu items enabled. The same application in front: 168. The 116 that
change include `存储`, `存储为…`, `导出为PDF…`, `页面设置…`, `重新命名…` — the
commands a task is usually about.

The state is not stale and cannot be refreshed. AppKit validates menu items when
a menu is about to be displayed, a background application's menu never is, and
`AXPress` on its bar item does not open it (measured: pressed, `ok`, enabled
count unchanged at 54, frontmost unchanged). There is no non-activating route to
those commands — which is the same wall §14 records for main-menu key
equivalents, reached from the other side. The menu bar makes those commands
*visible* and does not make them *reachable*; a host that shows them to a model
owes it that sentence.

#### The Apple menu is not the application's menu

The first child of every `AXMenuBar` is the Apple menu, and it is excluded. This
is a stated scope, not a truncation: `truncated` stays `false` and nothing about
it is silent.

It is the system's menu rather than the application's — byte-identical under
every application — it is where `关机`, `重新启动` and `退出登录` live, and it
costs 59 of TextEdit's 346 menu elements. AppKit titles it `"Apple"` and does not
localise that title: measured on a fully Chinese-localised system, where every
other menu bar item came back translated (`文件`, `编辑`, `显示`), this one did
not, in all seven applications probed. The old renderer already dropped it
(`AccessibilitySnapshot.swift`, `shouldSkipChild`); this keeps the rule and
writes it down.

#### A menu element carries no `frame`

`frame` is `null` for every element under `menu`, and that is not a gap in the
read. Accessibility offers two rectangles here and both would be lies in this
field's declared space (§5.3):

- An **unopened menu item** reports a degenerate `(0, 982, 0, 0)` — measured
  identical for all 346 of TextEdit's, all 390 of Preview's and all 452 of VS
  Code's, on a display whose logical height is 982. It is a placeholder, not a
  position.
- A **menu bar item** reports a real rectangle, but in *screen* points. §5.3
  makes `element.frame` window-local, and the menu bar is not in the window: the
  conversion would put it at a negative offset outside every window, in an image
  the snapshot's own capture does not contain.

The second is the worse of the two, because `frame` is a digest input (§4.3): a
menu item whose frame was recorded relative to a window would change its digest
every time the window moved, and every menu dispatch would be refused
`element_changed` with `changed: ["frame"]` on an element nothing had touched.
The suppression is therefore applied at **both** ends of the binding check — the
walk and the dispatch-time probe — which is the seam that has already drifted
twice over `ancestorRoles`.

A host that wants to draw the agent cursor at a menu item has nothing to draw
with, and that is correct: the executor did not click a pixel, it performed an
accessibility action on an element that is not on screen.

#### `enabled` is trustworthy as read, and it is not what it looks like

`enabled` on a menu item is **live and exact**, and the executor neither refreshes
it nor qualifies it. What it answers, though, is a question about the *observed
application's current state*, not about whether the command exists — and for a
background application the answer is frequently `false`.

Three measurements, macOS 26.5, in order, because each one closes off a reading
of the one before:

1. **Opening the menu does not change it.** Every menu of TextEdit, Preview and
   Finder, read before opening and again while open: 0 items drifted out of 190.
2. **The menus really did open**, so (1) is not a vacuous comparison of the same
   read twice. Measured on the same call: the `AXMenu` frame went
   `(0, 982, 0, 0)` → `(112, 34, 239, 414)`, a layer-101 window appeared for the
   pid, and the menu bar item's `AXSelected` went `false` → `true`.
3. **Activating the application does change it, sweepingly.** TextEdit,
   background → foreground, 293 items compared: **110 flipped**, and 111 flipped
   back when the foreground was returned. `文件 > 导出为PDF…`, `存储`, `关闭`,
   `编辑 > 撤销`, `粘贴`, `全选` all went `false` → `true`; `编辑 > 查找` went
   `true` → `false`.

So this is not a stale cache that opening the menu would refresh. It is AppKit
answering `validateMenuItem:` against a responder chain with no key window in it
— the same fact §14 records about main-menu key equivalents, arriving through a
different door.

**And the executor's existing `element_disabled` refusal is load-bearing here.**
`AXUIElementPerformAction(item, "AXPress")` on a disabled menu item returns
`kAXErrorSuccess` and does nothing at all. Measured against a background
Calculator: `编辑 > 拷贝`, reported `enabled: false`, pressed — `AXPress` returned
success and the pasteboard changeCount did not move (253 → 253); `显示 > 基础`,
reported `enabled: true`, pressed through the identical call — the window went
674×408 → 230×408. Without the refusal every disabled menu item would come back
`outcome: "ok"`, and the model would be told a command had run that had not. The
refusal is `element_disabled`, `outcome: "refused"`, `path: "none"`, and it is
the one honest answer available: the item is there, it is named, and the
application will not run it in the state it is in.

The executor does **not** activate the application to make an item enabled. That
is the host's decision to take or not, with the fact in front of it.

#### An unexpanded submenu is reported as it is found

Some menus are populated by `menuNeedsUpdate:` when they are opened. The executor
does not open them: it reports the `AXMenu` node with the children it has, which
for such a menu is none.

This is rarer than it sounds. Measured across the same applications, counting
`AXMenu` nodes that came back with zero children before anything was opened:
Calculator 0 of 12, Finder 0 of 19, VS Code 0 of 31, TextEdit 1 of 31, Preview 1
of 26 — and both of the two are the same menu, *Import From Device*, the
Continuity Camera list. `打开最近使用` / *Open Recent*, the case this rule was
written expecting to lose, is fully populated before opening.

Expanding them was considered and rejected. Opening a menu is a visible,
stateful side effect on somebody else's application performed to satisfy a read,
and the measurement above prices the alternative honestly: it would open up to
31 menus per observation to recover, at most, a device list.

#### Budget

The menu has its own element bound, `limits.maxMenuElements` (500), and its own
share of the walk clock, `limits.menuWalkCeilingMs` (1500), taken out of
`limits.treeWalkCeilingMs` rather than added to it. Neither is a request
parameter.

A shared budget is wrong at both ends, and the numbers say so. Menu bars, Apple
menu excluded: Calculator 141, System Settings 164, Stickies 219, Obsidian 234,
Finder 274, TextEdit 287, Preview 331, VS Code 393. The same applications'
windows: TextEdit 13, Preview 25, Calculator 65, Finder **1711**. Folded into one
`maxElements` of 1500, TextEdit's observation would be 96% menu — burying the
thirteen elements the host asked about — while Finder's window already exceeds
the bound on its own, so its menu would be cut to nothing. Finder is the
application whose menu bar carries `前往`, `显示 > 排序方式` and every file
operation there is. **The applications with the most window to describe are the
ones whose menus matter most, which is exactly the case a shared budget starves.**

`maxMenuElements` is not a request parameter because half a menu tree is not half
as useful the way half a window tree is: a path the model cannot see the end of
is a path it cannot take. A host that wants less menu asks for none.

The menu is walked **first**, and **once**:

- *First*, because the two walks share one deadline and only one of them has a
  bounded cost. Every menu measured read in 118–522 ms cold and about half that
  warm — Finder 333 elements in 118 ms, VS Code 452 in 159 ms, Calculator 200 in
  265 ms, TextEdit 346 in 428 ms, Preview 390 in 522 ms — against a window walk
  with no ceiling of its own, where a Finder window measured 1711 elements in
  5.22 s and an open panel reads at 23.6 ms an element indefinitely. Walking the
  window first would mean the applications with the largest windows never got a
  menu.
- *Once*, because §7.5 may rebuild the payload four times to fit
  `maxResponseBytes`, and the menu does not depend on the budget that halving
  shrinks. Rebuilding it would spend four menu walks to produce four identical
  trees. The menu is not what overruns the byte limit either: 500 elements with
  no frame encode to roughly 125 KB against 1 MB, so shrinking the window is the
  whole of the remedy.

`menu.truncated` reports the menu's own cut and never the window's, and
`truncated` reports the window's and never the menu's. A menu cut by either bound
raises `menu.truncated.elements`, under the same rule and with the same known gap
§5.2 states: the field says *that* something was cut, not *why*. Silence is what
is forbidden — a host shown a short menu with `truncated: false` concludes the
command is not there, and stops looking.

#### `observeAfter.menu`

`dispatch.element` and `dispatch.key` take `menu` in `observeAfter` on the same
terms, absent meaning `false`. The legacy `dispatch.point` shape still parses
the field but never performs a post-action observation. The field exists because a
menu press changes what the rest of the menu will do: `文件 > 打开…` brings a
document up, and `存储`, `导出为PDF…` and `关闭` all move from disabled to
enabled with it. Without it the host would have to spend a second `observe` to
see that, and that observe would supersede the frame the dispatch had just handed
it (§4.1).

#### What the host still owns

Everything the model reads. The executor emits `role`, `label`, `enabled`,
`actions` and the parent links, and nothing else — no path string, no rendered
`文件 > 导出为 PDF…`, no note about what `enabled: false` means. §13 is unchanged:
the menu arrives as data, and Maka's runtime owns every word made out of it. In
particular, the host is the only side that may tell the model that a disabled
menu item might become available if its application were in front — that is a
statement about what the *user* would see, and the executor does not have one.

---

## 6. Dispatch

All dispatch methods share a request prefix:

```json
{ "session": "s-01J…", "snapshotId": "snap_4e2c9a…", "toolCallId": "call_…" }
```

`toolCallId` is opaque to the executor and echoed in the response. It is the only
concession to host bookkeeping and exists so a trace line can be joined to a tool
call without a side table.

### 6.1 `dispatch.element`

```json
{ "method": "dispatch.element",
  "params": {
    "session": "s-01J…",
    "snapshotId": "snap_4e2c9a…",
    "toolCallId": "call_1",
    "elementToken": "el_7f3ab2…",
    "expectElementDigest": "sha256:c40f…",
    "strictness": "element",
    "occlusionPolicy": "same_app",
    "action": { "kind": "click", "button": "left", "count": 1 },
    "observeAfter": { "includeImage": true, "settle": "quiesce" }
  } }
```

`action` is a tagged union:

```json
{ "kind": "click", "button": "left" | "right" | "middle", "count": 1 | 2 | 3 }
{ "kind": "set_value", "value": "hello" }
{ "kind": "select_text", "text": "hello" }
{ "kind": "secondary_action", "action": "show_menu" }
{ "kind": "scroll", "direction": "up" | "down" | "left" | "right", "pages": 1.0 }
{ "kind": "move_window", "position": { "x": 220, "y": 164 } }
{ "kind": "resize_window", "size": { "width": 800, "height": 600 } }
{ "kind": "minimize_window" }
```

#### WebContent and renderer elements

The retained binding records both the host application process generation and
the element's actual input-owner process generation. On macOS the latter is read
through the dynamically resolved `_AXUIElementGetActualPid` SPI; if it names a
WebContent/renderer process, a PID reuse or renderer restart is
`process_replaced`.

A fresh WKWebView may publish its XPC process before its AX subtree. The executor
uses XNU `PROC_PIDCOALITIONINFO` to require one WebKit WebContent process sharing
both resource and jetsam coalition IDs with the host. When that unique process
exists and the first walk has no `AXWebArea`, observe waits 250 ms and walks once
more. This is readiness evidence only: process name alone never selects an
element.

When the same snapshot contains a leaf host accessibility mirror and exactly one
renderer-owned element with equal role, stable identifier/name, compatible
actions and frame within two points, the mirror is omitted. Ambiguous and
non-leaf mirrors remain visible.

Web layout may move a renderer-owned AX object after observation while the
retained reference remains live. If E3 reports exactly `changed: ["frame"]`,
dispatch may run the same unique identity-preserving refetch used for a released
reference. The replacement must retain host and renderer process generations
and semantic identity; role, name/identifier, actions, ancestors, or sibling
identity changes still fail closed. Native AX bindings do not receive this
exception. A unique direct WebContent replacement continues through the trusted
renderer click path rather than falling back to AXPress.

A left click on a renderer-owned element uses the host window's exact
`CGWindowID`, a single private `SLEventPostToPid` channel, and the existing
synthetic-target-focus lifetime. WindowServer performs the renderer hop. The
public `CGEvent.postToPid` duplicate used by the general Chromium compatibility
recipe is disabled on this path, so one request produces one down/up pair.
The result declares `tier: "coordinate-background"` and
`path: "skylight_pid"`. No AXPress or JavaScript `.click()` fallback follows a
failure.

#### Numeric value and scroll semantics

`set_value` preserves the live AX scalar type. A numeric control that advertises
both increment and decrement is changed through those actions, not by a bare
attribute write that can alter the displayed value without running the
application callback. The executor measures one step, requires the target to be
an exact bounded number of steps away, and reverses the probe step before
failing when it is not.

`scroll` prefers the element's `AXScroll*ByPage` action. If that action is
advertised but refused before delivery, the executor next presses the matching
`AXIncrementPage` / `AXDecrementPage` descendant. Only when neither semantic
route exists does it use the PID-bound wheel path. Partial or unknown AX delivery
never falls through.

#### Window management

The last three address the window rather than something drawn in it. They are
members of this union rather than a method of their own because the window is
already addressable: the snapshot's tree is rooted at it, so it is the element at
`depth == 0` and it already carries a token, a digest and a binding. A
`window.move` method would have to re-derive all four, and pay §2's version and
conformance cost, to arrive back where `dispatch.element` already is. What the
union was missing is a member that carries geometry.

The rules that follow are all consequences of the subject being the window:

- **The target MUST be the snapshot root.** §5.3 puts `element.frame` in
  window-local points and a window's own position in screen points; a non-root
  target would put two spaces in one request field and leave the executor
  guessing which it was handed. A non-root token is `element_not_actionable`.
  Nothing usable is refused by this: `AXPosition` and `AXSize` are not settable
  on ordinary controls — measured `false` on every Calculator button sampled — so
  the rule only makes the refusal legible earlier.
- **`occlusionPolicy` does not apply and is not consulted.** The check asks
  whether the pixel about to be acted on belongs to somebody else, and these act
  on no pixel: they move the window and everything drawn in it, sheet included. A
  covered window is exactly the window a model wants to move, and an application
  started by `apps.launch` begins at the bottom of the z-order — so applying
  occlusion here would refuse window management on every freshly launched
  application, which is the defect §6.1 already had to fix once for `same_app`.
- **Not settable is refused, honestly.** The executor asks
  `AXUIElementIsAttributeSettable` before it writes, and a `false` is
  `element_not_actionable` — "the element does not expose the requested action".
  This is not hypothetical: **Calculator's window advertises `AXSize` and will
  not let anyone write it**, and the raw write comes back `kAXErrorFailure`,
  which reads as a fault rather than as an answer. Measured across seventeen
  applications, `AXPosition` was settable on all seventeen, `AXSize` on fourteen
  (Calculator, the iOS Simulator and a system alert refused), and `AXMinimized`
  on fifteen.
- **The executor does not clamp, and does not validate a position against the
  displays.** It writes what it was asked for, reads back what it got, and says
  which of the three things happened. Three reasons, in order of weight. macOS
  clamps already and to a rule that cannot be restated — measured, a request for
  `(99999, 300)` came back `(1687, -52)`, both coordinates changed, and a request
  for 10 × 10 came back 115 × 46 because the application has a minimum size. A
  second clamp on top of that one would disagree with it. Off-screen is also a
  legitimate request: negative coordinates are how the display above the main one
  is named on a two-display machine, and a window parked off the edge is a thing
  a model may reasonably want. And a refusal reads to a model as a bad argument,
  which is the failure §6.5 documents at length — it sent one model round seven
  times on `cmd+p`.
- **`minimize_window` has no inverse in this version.** Restoring a minimized
  window activates its application: measured on macOS 26.5 with no `AXMain` write
  anywhere near it, `AXMinimized = false` on Calculator moved the foreground from
  pid 774 to pid 30706 within 300 ms of the write, and TextEdit's did the same.
  §6 forbids an action that brings its target to the front, and a capability the
  host can read but never use is worse than a missing one, so `unminimize_window`
  is absent rather than advertised-and-always-refused. §14 carries the
  measurement and what closing it would cost.
- **`raise` is not new and is not here.** A window's only Accessibility action is
  `AXRaise` — measured, all seventeen advertised exactly `["AXRaise"]` and
  nothing else — and it has always been reachable as
  `{ "kind": "secondary_action", "action": "raise" }`. Measured, it does **not**
  activate the application: raising a background Preview window moved it from
  zIndex 22 to 24 and raising a background Stickies window moved it from 20 to
  24, with the frontmost pid unchanged at 774 across both. It is also the
  standing example of advertised-but-unreachable: **Calculator lists `AXRaise`
  and answers it with `kAXErrorAttributeUnsupported`**, which §6.5 reports as
  `outcome: "failed"`, `path: "ax_action"` — attempted, the OS said no.

**A geometry write is finished when the window server agrees, not when the
application acknowledges it.** The application answers `AXPosition` from its own
idea of the window straight away; the window server is told afterwards. Measured,
one write per row, polling the window list at 5 ms:

| application | `AXPosition` read back | window server agreed |
| --- | --- | --- |
| Calculator | 11 ms | 26 ms |
| TextEdit | 4 ms | 38 ms |
| Google Chrome | 15 ms | 106 ms |
| Visual Studio Code | 3 ms | 112 ms |
| Obsidian | 16 ms | 172 ms |

Everything else in this executor reads the window server: `observe` resolves its
target out of `CGWindowListCopyWindowInfo`, and matches the AX window against
that frame to within one point because there is no public AX attribute carrying a
`CGWindowID`. So an executor that returned the instant the write was
acknowledged would answer with a frame in which its own `observeAfter` cannot
find the window — the list still reporting the old origin, the application
already reporting the new one, no candidate within a point, and
`postObservationError: window_gone` for a window in plain sight. The host's next
`observe` would race the same way.

The executor therefore waits for the window server, bounded at 1000 ms — 5.8×
the slowest measured — and returns as soon as it agrees. Waiting the bound out
is not an error and does not change the verdict: the dispatch is judged by the
`AXPosition` readback either way, and a post-observation that then fails says so
through `postObservationError`.

For `minimize_window` the thing waited for is the window **leaving** the
on-screen list, which is all the window server has to say about a minimized
window. `observeAfter` then legitimately answers `postObservationError:
window_gone`, and that is the truth rather than a race: the window is not on
screen. The dispatch result beside it still reports the minimise as
`outcome: "ok"` with `effect: "confirmed"`.

**The attribute is read back after that wait, not before it**, and the verdict is
taken from the second read. The three attributes do not answer at the same speed
and the difference is not cosmetic: `AXPosition` is the new value within 3–16 ms
of the write, and `AXMinimized` is not — measured, it still read `false` on the
instant after a write that succeeded and a window that did minimise. An executor
that judged on the first read answers `suspected_noop` for an action that plainly
happened, which is the false noop §6.5 spends its length condemning, and it is
what this executor did until vector 58's live half said so.

`strictness` ∈ `"element" | "window"`:

- `"element"` (default) — E1–E3 on the target element only. An unrelated ticking
  label elsewhere in the window does not spend the frame.
- `"window"` — E1–E3 **and** `snapshot.windowDigest` must still match. The only
  defence against recycled row views (§4.4 item 1), at the cost of refusing on
  any change anywhere in the window.

`occlusionPolicy` ∈ `"same_app" | "any" | "none"`, default `"same_app"`:

- `"same_app"` — refuse only when another window **of the same pid** covers the
  element's centre. A semantic dispatch addresses an element, not a pixel, so a
  foreign window stacked above it has no bearing on whether `AXPress` reaches it.
  Treating foreign windows as occlusion made background operation impossible in
  the case that matters most: an app started by `apps.launch` begins at the
  bottom of the z-order, so every window on the user's screen sat above it and
  every semantic click was refused
  (`cua-driver-target-resolution.ts:238-250`). A same-app sheet is different and
  is still refused: the element underneath is not the thing to act on, whatever
  the AX tree says.
- `"any"` — refuse when any layer-0 window covers it.
- `"none"` — do not check.

`observeAfter.settle` ∈ `"none" | "quiesce"`. `"quiesce"` looks at the window
repeatedly, without an image, until two consecutive window digests match. The
executor owns settling because it can watch the tree without a round trip; the
host currently does it with one `get_window_state` call per poll.

**`settle.waitedMs` is the time the settle really spent.** It is measured from
the clock on every arm, and it MUST NOT be answered with `limits.settleCeilingMs`
or any other constant. It may exceed the ceiling — see below — and that is the
case it exists to report: it is the field the host traces to see overruns, so an
executor that answers it with the ceiling deletes the only evidence that anything
overran.

**`settle.reason` says why the executor stopped looking**, and the three ways it
can stop are three different facts:

| `reason` | `quiesced` | what is known |
| --- | --- | --- |
| `quiesced` | `true` | two consecutive looks agreed; the window had stopped |
| `ceiling` | `false` | two or more looks were compared, they differed, and the budget ran out — the window was still moving |
| `window_too_slow` | `false` | one look at this window costs more than the budget had left, so the second look that is the only way to prove quiescence was never affordable. Nothing is known about whether it settled, and waiting longer under this budget cannot change that |

`window_too_slow` is not a slower `ceiling`. Proving a window quiet takes two
looks, and a look costs one Accessibility round trip per element the quoted
snapshot recorded — a cost set by the observed application and by how much of it
was recorded, not by the executor. Measured on macOS 26.5, one look at:

| window | elements | one look |
| --- | --- | --- |
| TextEdit, a document | 13 | 32–49 ms |
| iTerm2 | 33 | 17–19 ms |
| Preview, an image | 25 | 79–90 ms |
| Calculator | 65 | 106–304 ms |
| System Settings, Accessibility pane | 337 | 2180–2219 ms |
| Finder, Applications | 1114–1225 | 3158–3619 ms |

Two runs, minutes apart, on a machine doing other work — the spread is what a
budget has to survive, not noise to average away.

Two looks at the Finder window is over 6 s against a 2.5 s budget, so that window
can never be reported `quiesced` — and the executor that shipped spent 3.67 s
against a 2.5 s budget rediscovering that on every dispatch, then reported
`ceiling` and `2500`. `ceiling` was a false claim there as well as a late one: it
says the window was compared and had moved, and nothing had been compared.
System Settings is the sibling case, where one look fits the budget and two do
not: the old loop began a second look at 2270 ms because it only tested the
clock at the top of the round, returned at 4310 ms, and reported `2500`.

The ceiling is therefore checked **before a look is begun**, against what the
costliest look so far cost, and not only after the wait between looks. The first
look is unconditional — there is no way to estimate what a window costs without
paying for one, and its digest is what §6.5 judges the dispatch by — so a settle
may overrun `limits.settleCeilingMs` by at most one look, and says by how much in
`waitedMs`.

Raising `settleCeilingMs` is not the answer to `window_too_slow`. The cost is
per look and it is the application's, so a higher ceiling moves the line without
removing the class, and it makes every ordinary dispatch slower to do it.

**Result**

```json
{
  "ok": true,
  "toolCallId": "call_1",
  "outcome": "ok",
  "tier": "ax",
  "path": "ax_action",
  "effect": "confirmed",
  "verification": { "method": "tree_delta", "observedChange": true },
  "settle": { "waitedMs": 947, "quiesced": true, "reason": "quiesced" },
  "snapshot": { … a full snapshot, exactly as §5 … }
}
```

The snapshot returned here is `live` and supersedes the one that was quoted. One
round trip replaces the host's current dispatch → settle → observe sequence.

`snapshot` is present when `observeAfter` was requested and the capture
succeeded. When `observeAfter` was requested and the capture failed, the result
is still the dispatch outcome, with `snapshot: null` and
`postObservationError: { "code": "capture_failed", … }` — the action happened and
must be reported even though the frame after it could not be.

### 6.2 Element dispatch refusals

```json
{ "ok": false,
  "toolCallId": "call_1",
  "outcome": "refused",
  "tier": "ax",
  "path": "none",
  "effect": "unverifiable",
  "verification": { "method": "none", "observedChange": false },
  "error": {
    "code": "element_changed",
    "message": "the element no longer matches the snapshot it was bound to",
    "detail": { "changed": ["value", "frame"] }
  } }
```

The four declared fields are here for the reason §1.1 gives: a refusal is an
outcome, and §6.5 requires them on every dispatch result, this arm included.

`detail.changed` is a subset of the closed set
`["role","subrole","axIdentifier","title","label","value","frame","actions","ancestors","siblingIndex"]`.
It exists so a host log can say *why* without parsing prose.

Codes, and what the host does with each:

| code | meaning | host response |
| --- | --- | --- |
| `snapshot_unknown` / `_spent` / `_superseded` / `_expired` / `_evicted` | §4.1 | re-observe |
| `element_unknown` | the token is not in that snapshot at all | host bug; fail the turn |
| `element_digest_mismatch` | the token is in that snapshot, but `expectElementDigest` is not the digest the snapshot recorded for it | host bug; discard the frame and re-observe, never re-send against it |
| `element_released` | E1 failed — the AX reference is dead | re-observe (§4.4 item 2) |
| `element_changed` | E3 failed — the element's *current* digest differs from the recorded one | re-observe |
| `process_replaced` | E2 failed — pid recycled | re-observe |
| `element_not_actionable` | resolves, but does not expose the requested action | tell the model |
| `element_disabled` | resolves and exposes it, but `enabled` is false | tell the model |
| `window_gone` | the target window no longer exists | re-observe |
| `window_changed` | window bounds or title changed | re-observe |
| `window_occluded` | per `occlusionPolicy` | re-observe |
| `permission_missing` | Accessibility or Screen Recording revoked mid-session | surface to the user |
| `screen_locked` | screen is locked | pause the session |
| `physical_input_active` | the user is typing or moving the mouse | wait, re-observe |
| `dispatch_refused` | attempted, the OS refused, nothing happened — or nothing was attempted because every path that could reach the target was forbidden (§6.3) | tell the model |
| `outcome_unknown` | attempted, cannot tell whether it landed | spend the frame, re-observe |
| `aborted` | cancelled before dispatch | none |
| `not_implemented` | reserved method, this version | feature-detect |

**Three situations, three codes, and why the third one is new.** The echoed
digest (§4.3) exists to catch a host that mixed up two elements from two
snapshots. `maka.cu/1` gave it nowhere to land: `element_unknown` was defined as
"token is not in that snapshot", so the executor folded a *matching token with a
mismatched echo* into it, and §7.1 sent both to `stale_frame`. The host then read
"stale frame", re-observed, echoed the same wrong digest, and refused again —
with no field anywhere in the exchange saying which of the two had happened. That
is the collapse §4.1 refuses for snapshot states ("five distinct codes, not
one"), applied one level down.

Separated:

- `element_unknown` — the host quoted a token this snapshot never minted.
- `element_digest_mismatch` — the token is real, the echo is not the one recorded
  for it. Almost always the host pairing a token from one snapshot with a digest
  from another.
- `element_changed` — both the token and the echo are right, and the element
  itself moved on since observe. A frame-only change may be recovered only by a
  unique identity-preserving refetch; every other changed-field set is refused.
  This is the only one of the three that describes the world; the other two
  describe the host.

The first two are host bookkeeping faults, so re-sending the same request against
the same frame cannot help and the host MUST NOT do it. Both still map to
`stale_frame` (§7.1) because that is the closest member of a closed set the
executor does not get to extend, and because a fresh `observe` does clear a
mixed-up pairing — but the host logs which code it received, since a repeated
`element_digest_mismatch` is a bug in the host and a repeated `element_changed`
is a busy screen. Which side changes: the executor, which today emits
`element_unknown` for both.

`dispatch_refused` covers both a path that was tried and an action that never
left the executor, and the declared fields tell them apart without a second code:
`path: "none"` with `detail.wouldRequirePath` means nothing was attempted, and a
concrete `path` means it was attempted and the OS said no. For
`dispatch.element`, `error.detail.snapshotSpent` is `0` before `act` and `1`
after `act`, even when the platform refuses. `outcome_unknown` keeps its
concrete `ax_action` or `ax_attribute` path, uses the existing
`effect: "unverifiable"`, and places its enum reason in `error.detail.reason`.
That distinction only became expressible when refusals started carrying `path`
(§1.1).

### 6.3 `dispatch.point`

```json
{ "method": "dispatch.point",
  "params": {
    "session": "s-01J…",
    "snapshotId": "snap_4e2c9a…",
    "toolCallId": "call_2",
    "expectWindowDigest": "sha256:1f0c…",
    "point":      { "x": 640, "y": 400 },
    "startPoint": { "x": 100, "y": 100 },
    "space": "image_px",
    "occlusionPolicy": "any",
    "action": { "kind": "left_click", "count": 1 },
    "observeAfter": { "includeImage": true, "settle": "quiesce" }
  } }
```

This method is retained only as a compatibility endpoint for a host that still
sends the old request shape. Point mutation is not an executor capability:
`host.hello.capabilities.pointActions` is always empty.

After the normal handshake and session checks, every structurally valid request
returns:

```json
{ "ok": false, "toolCallId": "call_2",
  "outcome": "refused", "tier": "coordinate-background", "path": "none",
  "effect": "unverifiable",
  "verification": { "method": "none", "observedChange": false },
  "error": { "code": "unsupported_action",
             "message": "The requested action is not supported by this executor." } }
```

The executor MUST NOT resolve or consume `snapshotId`, compare
`expectWindowDigest`, inspect window inventory, choose a dispatch path, post an
input event, or perform `observeAfter`. A stale, missing, or mismatched target
therefore does not replace `unsupported_action` with a target error. This keeps
old hosts on a typed domain refusal while making coordinate execution
unavailable on every platform.

The paths used by executable dispatch methods are:

| `path` | mechanism | permitted when |
| --- | --- | --- |
| `ax_action` | `AXUIElementPerformAction` on the bound element | always |
| `ax_attribute` | `AXUIElementSetAttributeValue` | always |
| `ax_select` | set `AXSelectedChildren` on the containing list | always |
| `cg_event_pid` | PID-bound key or element-scroll fallback | `dispatch.key` or bound `dispatch.element` only |
| `skylight_pid` | bound WebContent element activation | `dispatch.element` only |
| `cg_event_global` | global pointer dispatch path | never permitted by Maka |
| `none` | nothing was dispatched | refusals |

`tier` and `path` are both declared, and their pairing is fixed:

| `tier` | permitted `path` |
| --- | --- |
| `ax` | `ax_action`, `ax_attribute`, `ax_select` |
| `semantic-background` | reserved for a future page-level path (`cdp`) |
| `coordinate-background` | `cg_event_pid`, `skylight_pid`, `cg_event_global` |

The host MUST reject an inconsistent pair as a protocol violation rather than
prefer one. `tier` uses Maka's exact vocabulary (`COMPUTER_USE_DISPATCH_TIERS`)
so `normalizeCuaDriverOutcome`'s `dispatchTier(path)` guess
(`cua-driver-result.ts:42-46`) — which maps every unrecognised path to
`coordinate-background`, including paths that do not exist yet — is deleted, not
ported.

### 6.4 `dispatch.key`

```json
{ "method": "dispatch.key",
  "params": {
    "session": "s-01J…",
    "snapshotId": "snap_4e2c9a…",
    "toolCallId": "call_3",
    "focusToken": "el_9b41…",
    "expectElementDigest": "sha256:aa10…",
    "focusPolicy": "acquire",
    "action": { "kind": "type", "text": "hello" },
    "observeAfter": { "includeImage": false, "settle": "quiesce" }
  } }
```

```json
{ "kind": "type", "text": "hello" }
{ "kind": "key",  "key": "Return", "modifiers": ["command", "shift"] }
```

`modifiers` is a closed set: `command`, `shift`, `option`, `control`, `fn`.
`key` is one of the named keys below, or a single printable character in
U+0021–U+007E. The executor rejects anything else with `-32602` rather than
guessing.

```
Return  Tab  Space  Escape  Backspace  ForwardDelete
Up  Down  Left  Right  Home  End  PageUp  PageDown
F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12
```

Names are matched case-sensitively, exactly as spelled. The printable range
starts at U+0021 and not U+0020 because `Space` is the only spelling of the space
bar; two spellings of one key is the defect this whole section is about.

Two names were dropped from the `maka.cu/1` executor's set
(`hostNamedKeys`), each because it named a key ambiguously:

- `Enter` — a second name for `Return` with no stated difference between them.
- `Delete` — on a Mac keyboard the legend on the backspace key; in the
  xdotool vocabulary the *forward* delete. One string, two destructive meanings,
  no way to tell from the wire which the caller meant.

`Backspace` and `ForwardDelete` are unambiguous and are the only way to say it.

#### The event has to carry the character

An executor MUST set the characters on a `kind: "key"` event itself, rather than
posting the event the system built from the key code.

This is not a quality-of-implementation note. §6.4 posts to the target pid, and a
key code is only half an event: what an application acts on is the character.
An application that is frontmost translates the code itself and needs no help; an
application that is not does not, and the executor's own `dispatch.key` therefore
did nothing at all — measured in §14, one key press per row. `type` worked
throughout only because it sets the string, which is the whole of the difference
between the two kinds.

Nor is the layout's own answer good enough to pass along. Measured against the
current input source, the key code alone translates to the wrong character for
22 of the 26 named keys: the right arrow gives U+001D where AppKit binds U+F703,
`ForwardDelete` gives U+007F — which is the *backspace* key's character, so a key
named forward-delete would have deleted backwards — and all twelve function keys
collapse onto a single U+0010.

Which characters, exactly — the set is closed, so they are written down:

| key | character |
| --- | --- |
| `Return` `Tab` `Space` `Escape` | U+000D, U+0009, U+0020, U+001B |
| `Backspace` | U+007F, the character that key produces, not the U+0008 its name points at |
| `ForwardDelete` `Home` `End` `PageUp` `PageDown` | U+F728, U+F729, U+F72B, U+F72C, U+F72D |
| `Up` `Down` `Left` `Right` | U+F700 – U+F703 |
| `F1` … `F12` | U+F704 – U+F70F |
| a printable character | itself, and its shifted form when `modifiers` contains `shift` |

The private-use values are AppKit's `NSUpArrowFunctionKey` family, which is what
a real arrow key event carries; no keyboard layout produces them, so no layout
lookup can supply them either.

**A table and not the live layout.** The alternative is `UCKeyTranslate` against
whichever input source the user has selected, and this protocol declines it on
three counts: the current layout is global mutable state, so the same request
would mean different things depending on the menu bar; it does not have the
answer for the 26 named keys, as the paragraph above measures, so the table ships
either way; and it is stateful — a dead key returns nothing while arming the next
translation, which makes one key press depend on the one before it. What the
table gives up is the virtual **key code** on a non-US layout, where the ANSI
position names a different physical key than the character does. That costs
nothing where it matters, because the application acts on the character.

**One exception, and it is the whole of the exception: a stroke whose
`modifiers` contain `command` is posted without characters.** A command-modified
key is how macOS spells a menu command, `performKeyEquivalent:` matches it
against the application's own translation of the key code, and an event that
arrives with characters already on it is taken as text and never offered to that
path. Setting them does not improve a shortcut — it deletes one that worked.
Measured against a TextEdit document, resetting the selection through
Accessibility between rows so that no row can read as the one before it:

```
                   frontmost                background
cmd+a   plain      loc 0 → len 34           no effect
cmd+a   + "a"      no effect                no effect
cmd+←   plain      loc 0 → 33               no effect
cmd+←   + U+F703   loc 0 → 33               loc 0 → 33
→       plain      loc 0 → 1                no effect
→       + U+F703   loc 0 → 1                loc 0 → 1
shift+→ + U+F703   —                        len 0 → 1
opt+→   + U+F703   —                        loc 0 → 4
ctrl+e  + "e"      —                        loc 0 → 33
```

Every combination gains from the characters except `command`, which loses. Row
four is what the exception leaves on the table: `cmd+←` is a caret motion rather
than a menu command and would reach a background application if the characters
were there. The executor cannot tell the two apart — `cmd+↓` is caret motion in a
text view and *Open* in the Finder — and they need opposite events, so it takes
the rule that costs nothing and §14 carries the question.

The modifier flags carried are exactly the ones `modifiers` declared. Real arrow
key events additionally carry the numeric-pad and secondary-fn flags, and §14
measured that adding them changes nothing.

#### The host parses; the executor never sees a combination

Maka's callers do not hold this closed set. `CuAction.key` is
`{ type: 'key'; text: string }` and `CuSemanticAction.press_key` is
`{ key: string }` — free-form, xdotool-flavoured, `"cmd+a"` and `"shift+Tab"`
(`packages/core/src/computer-use.ts:161`,
`packages/runtime/src/computer-use-types.ts:143-147`). The `maka.cu/1` host
passed that string straight through as `key`, which the executor rejected with
`-32602`: a JSON-RPC error, which per §1.1 never describes the world, arriving in
answer to a request that described the world perfectly well.

**The host parses, before it sends.** The reasons are all one reason: Maka's
runtime owns every model-facing word (§13), so translating the model's dialect
into the protocol's vocabulary is its job, and an executor that accepts free-form
strings is an executor doing the loose parsing this protocol was written to
delete.

The grammar, exactly:

```
combo     := token ( "+" token )*
token     := modifier | key
modifier  := cmd | command | meta | super | ctrl | control
           | alt | opt | option | shift | fn | function
key       := named-key-alias | single character U+0021–U+007E
```

- Split on `"+"`. The **last** segment is the key; every earlier segment must be
  a modifier. A string with no `"+"` is a bare key.
- A trailing empty segment means the key is literally `"+"`: `"cmd++"` is
  command-plus, `"+"` is plus. Any other empty segment is unparseable.
- Modifier and alias matching is case-insensitive, and maps onto the wire's
  closed sets: `cmd`/`command`/`meta`/`super` → `command`;
  `ctrl`/`control` → `control`; `alt`/`opt`/`option` → `option`;
  `shift` → `shift`; `fn`/`function` → `fn`.
- Named-key aliases, also case-insensitive: `return`/`enter` → `Return`;
  `esc` → `Escape`; `spc`/`space` → `Space`; `pgup` → `PageUp`;
  `pgdn`/`pgdown` → `PageDown`; `up`/`arrowup` → `Up`, and the same for the other
  three arrows; `f1`…`f12` → `F1`…`F12`; every other named key is its own alias.
- A duplicated modifier is accepted once. Two non-modifier tokens is not a
  chord this protocol can express, and is unparseable.

**`delete` and `del` are deliberately unparseable.** They are the one alias a
reasonable parser would add and the one that must not exist: `delete` reads as
backspace to a Mac user and as forward-delete to xdotool, and picking either
deletes the wrong character. The host refuses and tells the model to say
`Backspace` or `ForwardDelete`.

**What an unparseable string does.** The host fails the action with
`unsupported_action` and a message naming the string it could not parse. It MUST
NOT drop the modifiers and send the key alone, MUST NOT pick a nearest match, and
MUST NOT send the raw string down and let the executor decide — a defaulted key
press is an action the user did not ask for and cannot see. Nothing reaches
`dispatch.key`.

An unparseable `key` arriving at the executor is therefore a host bug, and
`-32602` is the right answer to it.

Which side changes: the host, which gains the parser and stops forwarding
`action.key`/`action.text` verbatim. The executor drops `Enter` and `Delete` from
its named set and otherwise stays as it is — `KeyMapping.swift`'s xdotool parsing
remains an internal detail with no wire presence.

**`focusToken` is required and verified.** The executor MUST confirm that the
element currently focused in the target is the one named by `focusToken`, with a
matching digest, before posting any key event. `maka-cu` today types into
`snapshot.focusedElement` whatever that has become since the snapshot
(`ComputerUseService.swift:1366-1385`) — which is the same class of defect as
re-resolving an index. Focus mismatch is `focus_changed`, and it maps to
`target_changed`.

Key events are posted to the target pid. The executor MUST NOT activate the
application, raise its window, or change the frontmost app.

The two `kind`s are also verified differently, and §6.5 says why: `type` writes
into the element this section spends its length establishing the identity of, so
that element's value is what answers for it; a `key` is a command, and the value
of whatever holds focus answers for nothing it does.

#### `focusPolicy` — verify focus, or take it

```json
"focusPolicy": "require" | "acquire"
```

Optional; **absent means `require`**. A closed set of two, and an unknown value
is `-32602` rather than a fallback to the stricter one — a host asking for a
third behaviour has a bug, and quietly answering it as `require` hides that bug
behind a refusal the host will read as "the user moved focus".

- **`require`** — the check described above, unchanged: the element named by
  `focusToken` must *already* be focused, and `focus_changed` otherwise. It is
  the default because taking focus is an action on the user's machine, and an
  executor that takes it when nobody asked is an executor doing something the
  host never wrote down.
- **`acquire`** — the executor writes `kAXFocused` on the bound element, then
  **re-reads** the focused element and proceeds only if it is now the one named.

`acquire` exists because without it the host's only way to focus a control was to
click it first, and a click is not a focus operation: on a button it is a press,
on a menu it opens the menu, and the model paid for a side effect it never asked
for. Maka's `press_key` promises the model an optional `element_id` that focuses
the control before the key is posted; `require` alone cannot keep that promise.

Two rules make `acquire` safe to have at all:

- **Verify, then acquire — never the other way round.** The token, the digest and
  the binding probe (§4.3) are all checked *before* the `kAXFocused` write. An
  executor that focused first would hand focus to whatever now sits at that
  reference, including an element whose digest has already stopped matching, and
  would then report `element_changed` having moved the user's focus.
- **The write's own success is not evidence.** Applications answer
  `AXError.success` and leave focus where it was. The only accepted proof is the
  re-read, and a failed acquisition — write refused, or write accepted and focus
  did not move — is `focus_changed` with no key posted. There is no "focus is
  probably close enough, post it anyway" path: a key that lands somewhere the
  request did not name is exactly the defect this section exists to delete.

`acquire` changes focus and nothing else. It still MUST NOT activate the
application, raise its window, or change the frontmost app.

### 6.5 Outcome, path, effect — the fields that used to be inferred

Four required fields on every dispatch result, all closed sets, none optional —
on the `ok: true` arm and the `ok: false` arm alike (§1.1):

| field | values |
| --- | --- |
| `outcome` | `ok`, `refused`, `failed`, `unknown` |
| `tier` | `ax`, `semantic-background`, `coordinate-background` |
| `path` | table in §6.3 |
| `effect` | `confirmed`, `unverifiable`, `suspected_noop` |

`outcome` is what selects the arm, so the two can never disagree:

| `outcome` | means | arm | `path` |
| --- | --- | --- | --- |
| `ok` | dispatched, and it completed | `ok: true` | the path used |
| `refused` | nothing was dispatched; a precondition or a policy said no | `ok: false` | `none` |
| `failed` | dispatched, the OS rejected it, nothing happened | `ok: false` | the path attempted |
| `unknown` | dispatched, and we cannot prove whether it landed | `ok: false` | the path attempted |

`ok: true` with any `outcome` other than `ok`, or `ok: false` with `outcome: ok`,
is a protocol violation. Every `ok: false` arm also carries the `error` object
whose code says which refusal it was (§6.2), and the pairing is fixed:
`outcome_unknown` accompanies `unknown`; `dispatch_refused` accompanies `failed`
when a path was attempted and `refused` when none was permitted; every other code
accompanies `refused`.

`tier` on a refusal is the tier the executor would have used, which is why
`path: none` pairs with any tier — the §6.3 pairing table constrains only a path
that was actually taken.

`effect` on a refusal is `unverifiable` with `verification.method: "none"`:
nothing was attempted, so nothing was checked, and §6.5's own distinction between
*never checked* and *checked and inconclusive* has to hold here too. `failed` and
`unknown` MUST NOT report `confirmed`.

Plus `verification`, which is what makes `effect` readable:

```json
"verification": { "method": "value_readback", "observedChange": true }
```

`method` ∈ `"none" | "action_result" | "value_readback" | "selection_readback" |
"focus_readback" | "tree_delta"`.

This is the distinction the current shape cannot express: `effect: unverifiable`
with `method: "none"` means *never checked*; `effect: unverifiable` with
`method: "value_readback"` means *checked and inconclusive*. Today both collapse
to one enum, and the host cannot tell a driver that does not verify from a driver
that verified and could not confirm.

Rules the executor MUST follow:

- A bare `AXUIElementPerformAction` returning `.success` is **not** confirmation.
  It yields `effect: "unverifiable"`, `verification.method: "action_result"`.
  `AXPress` succeeding means the message was accepted, not that anything moved.
- A single left press, `press`, or `cancel` may create or close a window while
  `AXUIElementPerformAction` is still returning `cannotComplete`. The executor
  may upgrade that otherwise-unknown result to `ok` only when the exact set of
  on-screen window IDs owned by the target PID changes in two consecutive
  samples within 5 seconds, below the host's 20-second request deadline. The result reports
  `confirmed / action_result`; a
  requested post-observation of a closed target still reports `window_gone`.
  Double/triple click, value/text/scroll and window actions never use this
  recovery; without a stable topology change they remain `outcome_unknown`.
- The executor records the frontmost PID immediately before a delivered element
  action. If the target PID makes itself frontmost, the executor restores that
  exact previous PID. It does not intervene when the user moved to a third
  application, and it never activates the target. Activation completion and
  WindowServer z-order propagation are asynchronous, so neither rewrites the
  business outcome; the independent live foreground sentinel verifies this
  safety property.
- `set_value` MUST read the value back. Equal to the requested value →
  `confirmed` / `value_readback`. Equal to the *previous* value →
  `suspected_noop`. Anything else → `unverifiable`.
- `move_window`, `resize_window` and `minimize_window` are judged the same way,
  by reading back the attribute they wrote — `AXPosition`, `AXSize`,
  `AXMinimized` — and under the same three arms, because the attribute written
  **is** the subject of the action. Two things are worth stating about them
  rather than leaving to the rule:

  The comparison is at **whole logical points**, which is the resolution §4.3
  already compares a frame at. Two resolutions for one rectangle is how an
  executor ends up refusing a dispatch against a window nothing had moved.

  The third arm is the ordinary case here, not the exception. macOS clamps —
  measured, `(99999, 300)` came back `(1687, -52)` and a 10 × 10 resize came back
  115 × 46 against the application's own minimum — and a clamped write is
  `unverifiable` / `value_readback`. It is not `confirmed`, because the window is
  not where it was asked to be; it is not `suspected_noop`, because it moved.
  Where it actually landed is a fact about the window and is reported as one, in
  the post-observation's `snapshot.target.bounds` — not smuggled into the verdict.
- `select_text` MUST read `AXSelectedText` back → `selection_readback`.
- `click` with `observeAfter.settle: "quiesce"` MAY report `confirmed` /
  `tree_delta` when the post-action window digest differs from the pre-action
  one. With `settle: "none"` it MUST NOT: no time was given for a change to
  appear, so absence of change is not evidence.
- `secondary_action` gets `action_result` only. There is nothing generic to read
  back.
- `dispatch.key` with `kind: "type"` MUST read the focused element's value back
  → `value_readback`, with the same three outcomes as `set_value`.
- `dispatch.key` with `kind: "key"` MUST NOT be judged by that value. It is
  judged the way a click is — `tree_delta` under `settle: "quiesce"`, and
  `unverifiable` / `none` without one — and it MUST NOT report `suspected_noop`.

#### A method that does not apply is not a verification

`suspected_noop` is a sentence about a specific observation: *I looked at the
thing this action changes, and it did not change.* Only a method whose subject
**is** the thing the action changes may produce it. Every other method can
confirm and can never refute, because the absence of a change it was never going
to see is not evidence of anything.

That is the whole of the split between the two `dispatch.key` action kinds, and
it is not a split on modifiers. `type` writes text into the element the request
named and verified, so that element's `AXValue` is the subject of the action: a
value that did not move is a noop, stated. A `key` is a command the application
interprets. `cmd+p` opens a print sheet, `cmd+s` writes a file, `ctrl+f2` goes to
the menu bar, `cmd+w` closes the window, `Tab` moves focus off the element
altogether — the value of whatever held focus is identical either side of all of
them, whether the key landed or not.

An executor that read it anyway is the defect this section was rewritten for.
Measured on a real run: a model asked to export a document found the menu bar
unreachable in the observation and reached for the shortcut, which is the correct
move. It got

```
computer.press_key ok via coordinate-background (verified=false);
  dispatch path=cg_event_pid, effect=suspected_noop, reason=dispatch.key:value_readback
```

seven times for `cmd+p`, then twice more after switching spellings; a second
model got it four times for `ctrl+f2`. The model's own account was that it must
be sending the wrong arguments, because the arguments were the only thing left it
could see to change — a false noop does not read as a bad verdict, it reads as a
bad request.

Whether those two keys landed is a separate question the executor never answered,
and one this section is deliberately not decided by. The verdict was not read off
the key's effect; it was read off a value the key was never going to touch, and
the same reading condemns `cmd+A` on a text view of an application that *is*
active, which does land and leaves that value exactly where it was. A verdict
that happens to correlate with the truth for a reason unrelated to the truth is
not evidence.

The honest answers cost the host nothing it had:

| both mean | `effect` | `verification.method` |
| --- | --- | --- |
| I looked at the subject of this action, and it did not move | `suspected_noop` | the method that looked |
| I looked at what I have, and it cannot tell me | `unverifiable` | the method that looked |
| I have no observation that bears on this | `unverifiable` | `none` |

Which method belongs to which action, in full:

| method | dispatch | action |
| --- | --- | --- |
| `value_readback` | `dispatch.element` | `set_value`, `move_window`, `resize_window`, `minimize_window` |
| | `dispatch.key` | `kind: "type"` |
| `selection_readback` | `dispatch.element` | `select_text` |
| `tree_delta` | `dispatch.element` | `click`, `scroll` — with `settle: "quiesce"` |
| | `dispatch.key` | `kind: "key"` — with `settle: "quiesce"` |
| `action_result` | `dispatch.element` | `secondary_action`, and `click`/`scroll` without a settle |
| `none` | `dispatch.key` | `kind: "key"` without a settle |
| | any | every refusal (§6.5), including every `dispatch.point`, and a readback with nothing on either side to read |

`none` is where a key without a settle lands rather than `action_result` because
there is no result to report: the events were written to the target pid and
`CGEvent` says nothing about what became of them. Naming a method there would
claim a check that was never made, which is the same overreach one row up.

Only `tree_delta` is available to a key, and it is a weak instrument by
construction: the digest is recomputed over the elements **the quoted snapshot
recorded**, so a key whose effect arrives as a new sheet, a new window, another
application or a file on disk leaves it byte-identical. That is exactly why it
may not refuse — and why a host that wants a key verified should send
`observeAfter.settle: "quiesce"`, which is the difference between
`unverifiable` / `tree_delta` and `unverifiable` / `none`.

`verified` is **not** a wire field. The host sets
`verified = (effect === "confirmed")` when building `CuDispatchOutcome`. Two
fields carrying one bit is how `verification()` in `cua-driver-result.ts:48-58`
ended up deriving each from the other with three fallbacks.

### 6.6 `screen.capture`

```json
{ "method": "screen.capture",
  "params": { "session": "s-01J…", "displayId": "69732928" } }
```

```json
{ "method": "screen.capture",
  "params": { "session": "s-01J…" } }
```

```json
{ "ok": true,
  "image": { "path": "…/cap_8812.png", "format": "png",
             "widthPx": 3024, "heightPx": 1964, "byteLength": 2_100_331,
             "sha256": "sha256:…", "scale": 2.0 },
  "displayId": "69732928",
  "capturedAt": 1753574400123 }
```

Whole-display capture, no snapshot, no binding, no state change. It exists
because `CuAction` has a `screenshot` member and the model may ask for one
without a target.

**`displayId` is optional, and absent means the main display.** It has to be
optional for the same reason the method exists: the request this method serves
is the one with no target, and a model that has observed nothing has not read
`displays[]` either. Requiring the field answered every untargeted screenshot
with `-32602`, so the one action the method was added for was the one action it
never performed. The result reports `displayId` whether or not the request
carried one, so a caller that declined to choose still knows exactly which
screen it is looking at.

Absent is not the same as wrong. A `displayId` that names no attached display is
`-32602` on the field, never a quiet fall back to the main one. Substituting a
display the caller did not ask for answers a question about display B with a
picture of display A, and the `displayId` in the result would agree with the
picture rather than with the request, so nothing downstream could tell. The
executor validates against the displays the window server reports, not against
`NSScreen` (§5.5).

The image is the display at the display's own pixel density, which is what the
example above shows: a Retina screen comes back at its full pixel count with
`scale: 2.0`, not at its point count with `scale: 1.0`. `SCDisplay`'s `width`
and `height` are points, and feeding them to a capture's pixel-sized output made
the compositor downscale to fit. Nothing about that frame is inconsistent — it
fills, and `1.0` describes it correctly — it is simply half the detail the
machine can give, for a method whose entire output is what the model can see.

### 6.7 Every image fills the size it declares

`image.widthPx` / `heightPx` describe the whole bitmap and every pixel of it is
content. An executor may not return a bitmap larger than the region it drew, and
`image.scale` must be the scaling the content actually has — not the scaling the
executor meant to apply, and not a display's `backingScaleFactor`.

This is a stated rule rather than an obvious consequence because the failure is
silent at every layer that could otherwise catch it. macOS takes the capture's
output size in pixels and the region it renders in points; hand it a buffer
larger than the content it is about to draw and it anchors that content at the
top-left and leaves the rest transparent instead of objecting. The PNG is
well-formed, its IHDR matches the declared `widthPx` / `heightPx`, and `sha256`
verifies. What reaches the model is a window shrunk into one corner of a mostly
empty image at half the resolution its `scale` claims, and a host that mirrors
the frame renders the empty part as a black margin — which is how this was
found, two layers away from the cause.

The executor therefore sizes the output buffer from the same source it renders
from, so the two cannot disagree, and measures `scale` from the bitmap it got
back (§5.3). Neither number is chosen twice.

---

## 7. Errors, mapping and bounds

### 7.1 Domain code → Maka error code

The host maps mechanically. No inference, no message matching.

| executor `code` | `ComputerUseErrorCode` |
| --- | --- |
| `snapshot_unknown`, `snapshot_expired`, `snapshot_evicted`, `element_unknown`, `element_digest_mismatch` | `stale_frame` |
| `snapshot_spent` | `duplicate_action` |
| `snapshot_superseded` | `stale_epoch` |
| `element_released`, `window_gone`, `process_replaced`, `app_not_found` | `target_missing` |
| `element_changed`, `window_changed`, `focus_changed` | `target_changed` |
| `window_occluded` | `target_occluded` |
| `element_not_actionable`, `element_disabled`, `unsupported_action`, `not_implemented` | `unsupported_action` |
| `permission_missing` | `permission_missing` |
| `screen_locked` | `screen_locked` |
| `physical_input_active` | `user_intervened` |
| `invalid_point` | `invalid_coordinate` |
| `capture_failed`, `response_too_large`, `image_write_failed` | `capture_failed` |
| `outcome_unknown` | `outcome_unknown` |
| `aborted` | `aborted` |
| `timeout` | `timeout` |
| `dispatch_refused` | `dispatch_refused` |

**`COMPUTER_USE_ERROR_CODES` gains `dispatch_refused`.** This was the open
question `maka.cu/1` flagged and left open; leaving it open is what produced two
wrong answers. The set had no member meaning *"the executor attempted the action,
the OS refused it, and nothing happened"*, so `normalizeCuaDriverOutcome`'s
default branch sent it to `capture_failed` — telling the model a screenshot
failed when a button refused a press — and the `maka.cu/1` host, reading the same
table, chose `unsupported_action` instead.

Neither is salvageable. `capture_failed` names the wrong subsystem.
`unsupported_action` is already what `element_not_actionable` and
`element_disabled` map to, and those are decided *before* anything is dispatched:
collapsing them destroys the difference between "the element does not offer this"
and "it offered it, we tried, the OS said no", which is the difference between
"try something else" and "try again". That is the same collapse as §6.2, and it
gets the same answer — a new member.

What the host does with it:

- Surfaces it to the model as an outcome, with the executor's `detail` (enums and
  numbers only, §1.2) as evidence.
- Does **not** re-observe automatically. A refused dispatch leaves the frame live
  (§4.1), so the model may retry against the same frame with different arguments.
- Does not treat it as a permission problem. `permission_missing` is a separate
  code precisely so that "TCC is revoked" and "this control said no" do not get
  the same recovery.

### 7.2 Cancellation

```json
{ "jsonrpc": "2.0", "method": "$/cancel", "params": { "id": 42 } }
```

A notification. The executor:

- answers request 42 with `aborted` if it has not yet dispatched;
- **ignores** the cancel if it has already dispatched, and answers with whatever
  actually happened.

An action already in flight cannot be un-fired, and reporting `aborted` for one
that landed is a lie the host would act on. The host already distinguishes these
by request stage (`cua-driver-service.ts:538-552`); this makes the executor
agree instead of the host inferring from where the kill landed.

`capture.next` long polls MUST be cancellable this way, or a poll outstanding at
session end pins the process.

### 7.3 Timeouts

The executor's own ceilings are `limits.settleCeilingMs` and
`limits.treeWalkCeilingMs`. The host owns request deadlines
(`DEFAULT_REQUEST_TIMEOUT_MS = 20_000`) and enforces them by `$/cancel`
followed, if the request had already been delivered, by teardown.

The executor's ceilings exist because of what that enforcement costs. A host
deadline is not a way to bound a slow operation, it is a way to give up on the
executor: the session, its snapshots and its images go with it. So every
executor-side operation whose duration is set by another process — settling on
an application's own repaint schedule, reading a tree hosted across XPC — carries
a ceiling under the host's, and reports on the wire that it hit it. Their sum has
to fit: an `observe` that captures an image (up to 5 s) and then walks a tree (up
to `treeWalkCeilingMs`) is 11 s of the host's 20, and a `dispatch` that settles
(2.5 s) before doing both is 13.5 s.

A ceiling only bounds what it is checked against. Settling's is checked before
each look rather than only between them, so its overrun is one look rather than
one look per round (§6.1); `waitedMs` reports the overrun rather than hiding it
under the ceiling.

### 7.4 Bounds

Everything bounded says so on the wire:

| bound | field that reports it |
| --- | --- |
| element count | `snapshot.truncated.elements` |
| tree depth | `snapshot.truncated.depth` |
| tree walk time | `snapshot.truncated.elements` (§5.2 — the field cannot say which bound fired) |
| element text | `element.truncated: ["value", …]` |
| selected text | `snapshot.selectedText.truncated` |
| settle time | `settle.reason: "ceiling"` / `"window_too_slow"`, with the real duration in `settle.waitedMs` |
| launch wait | `waited.reason: "timeout"` |
| capture stream frames | `capture.next` → `dropped: n` |

### 7.5 Response size

If a response would exceed `limits.maxResponseBytes`, the executor MUST reduce
`maxElements` by half and retry, up to three times, and report the reduction in
`truncated.elements`. If it still does not fit, it returns
`response_too_large` with `detail: { "bytes": n, "limit": m }`. It MUST NOT drop
fields to fit.

---

## 8. References, not payloads

**Every image is a file path. There is no size threshold and no inline branch.**

A threshold means two code paths, and the host would have to implement both
forever to handle the small case. Base64 on a line-delimited channel is a 4/3
blow-up that stalls every other pending response while one 8 MB line is written —
today the host raises `MAX_STDOUT_BUFFER` to 32 MiB to survive it
(`cua-driver-service.ts:23`). At the frame rates a live mirror needs, inlining is
not merely wasteful, it is impossible.

Everything else stays inline. The AX tree is bounded by `maxElements` and
`maxTextChars` and is declared-truncating, so it cannot surprise the channel.

**The line: images by reference, structured data inline, one message capped at
`limits.maxResponseBytes` (1 MiB).**

Image file contract:

- The executor writes into `imageDir` and nowhere else.
- Filenames are executor-chosen and opaque. The host addresses them only by the
  `path` it was given.
- `sha256` and `byteLength` are of the file's bytes as written, and `sha256` is
  written the one way §1.3 declares — `"sha256:"` then lowercase hex. The host
  MAY verify; a mismatch is a protocol violation, which is why the two sides
  cannot be allowed to disagree about the spelling. They did, and every
  screenshot mismatched.
- **Lifetime is the snapshot's lifetime.** The executor deletes an image when its
  snapshot leaves the live set — spent, superseded, expired or evicted. The host
  must copy or consume before then; `limits.snapshotTtlMs` is therefore also the
  file's guaranteed lifetime, and it is in the handshake so the host does not
  hardcode it.
- `screen.capture` images are not attached to a snapshot. They live for
  `limits.snapshotTtlMs` from `capturedAt` and are then deleted.
- If writing would push `imageDir` past `limits.imageDirBudgetBytes`, the
  executor evicts its oldest own files first; if it still does not fit it returns
  `image_write_failed`. It never silently returns a snapshot without the image
  the caller asked for.
- After an executor crash the files leak. The host owns `imageDir` and MUST purge
  it before every spawn.

---

## 9. Concurrency

The executor uses one reader and a set of serial lanes:

| lane | methods |
| --- | --- |
| `control` | `host.hello`, `session.*`, `permissions.check`, `apps.list`, `window.list` |
| `target:<pid>:<windowId>` | `observe`, `dispatch.*` for that target |
| `capture:<streamId>` | `capture.next` for that stream |
| `misc` | `apps.launch`, `screen.capture` |

Within a lane, strict FIFO. Across lanes, concurrent. Two consequences the host
depends on:

- All observes and dispatches against one window are ordered, so a dispatch can
  never overtake the observe that produced its snapshot.
- A `capture.next` long poll cannot block a dispatch. This is the framing
  property that has to exist **now** for the stream to land later without a
  protocol break.

The host serialises per session today (`withOperationQueue`); per-target is
finer and remains safe because the host's queue is still upstream of it.

---

## 10. Capture stream (reserved, not implemented in `maka.cu/2`)

Maka's picture-in-picture mirror repaints from the screenshot each action
returns. A live mirror needs a stream, and this channel is request/response —
so the stream is long-polling, the way Codex does it on its privileged channel
(`AppStartCapture` then repeated `AppNextCaptureUpdate`).

The method space is reserved now. In `maka.cu/2` all three return
`{ "ok": false, "error": { "code": "not_implemented" } }` — a **domain** result,
not `-32601`, so feature detection is a stable field read and the names can never
be taken by something else.

```json
{ "method": "capture.start",
  "params": { "session": "s-01J…",
              "target": { "kind": "window", "pid": 4711, "windowId": 90210 },
              "maxFps": 10, "format": "jpeg" } }
→ { "ok": true, "streamId": "st_…", "ringFrames": 30, "ttlMs": 30000 }

{ "method": "capture.next",
  "params": { "streamId": "st_…", "sinceSeq": 41, "timeoutMs": 5000 } }
→ { "ok": true, "seq": 44, "dropped": 2,
    "frames": [ { "seq": 43, "capturedAt": 1753574400500, "image": { "path": …, "sha256": … } },
                { "seq": 44, "capturedAt": 1753574400600, "image": { … } } ] }
→ { "ok": true, "seq": 41, "dropped": 0, "frames": [], "timedOut": true }

{ "method": "capture.stop", "params": { "streamId": "st_…" } }
→ { "ok": true, "released": { "frames": 30 } }
```

What `maka.cu/2` already provides so this needs no protocol change:

- **Images are already references.** A 10 fps stream is path churn, not stdout
  churn.
- **The `capture` lane already exists** (§9), so a 5 s poll does not block a
  dispatch.
- **`$/cancel` already applies** to a long poll (§7.2), so a session ending with
  a poll outstanding does not pin the process.
- **`dropped` is a declared field**, so a slow host loses frames visibly.
- **`ringFrames` and `ttlMs` come back from `capture.start`**, so the host never
  hardcodes the ring size.

What a future version must add and is deliberately absent now: nothing in the
framing, the handshake, or the error space. `capabilities.captureStream` flips to
`true` and the three methods start answering. That is the whole delta.

---

## 11. Process lifecycle

**Start.** The host spawns the executor as a **direct child**, as
`<executable> host` — the subcommand is not optional. macOS attributes TCC
grants through the responsibility chain, and a helper launched via
`open`/LaunchServices gets its own attribution and its own prompts. The host
purges `imageDir`, spawns, sends `host.hello`, and treats any failure before a
successful `session.begin` as a start failure.

The subcommand is spelled out here because leaving it unsaid cost a debugging
session: the same executable also serves `doctor`, `list-apps` and `snapshot`
for a human at a terminal, and a bare invocation prints help and exits. Each
side picked for itself, they disagreed, and the first live run reported an
exhausted restart budget rather than a wrong argv. A host that spawns bare
sees the child die before the handshake; that is a host bug, not a protocol
negotiation, and there is nothing on the wire to catch it.

**Death.** The host classifies in-flight requests by stage — already implemented
in `cua-driver-service.ts:423-468`:

| stage at death | host result |
| --- | --- |
| queued, never written to stdin | `service_unavailable` |
| written or delivered | `outcome_unknown` |

The executor's obligations that make this sound:

- exactly one response per request id;
- flush stdout before exiting on a handled signal;
- snapshot ids carry a per-process nonce, so nothing from a previous generation
  can be mistaken for live state (§4.1).

**SIGTERM.** Stop reading new requests; answer queued-but-unstarted with
`aborted`; let in-flight mutating dispatches finish within
`limits.shutdownGraceMs`; end every session (which removes cursors and deletes
images); exit 0. The host SIGKILLs after the grace period.

**Crash.** Images leak; the host purges `imageDir` at next start. Every snapshot
id from the dead generation fails `snapshot_unknown`, never silently resolves.

**Host death.** The `hostPid` poll (§2) exits the executor within 2 s. Without
it, an executor holding Accessibility outlives every host crash.

---

## 12. Conformance vectors

Each rule below needs a test that fails without it. Executor tests are Swift
(`OpenComputerUseKitTests`), host tests are the `@maka/computer-use` backend
suite; the fixture rows are shared JSON so both ends assert the same bytes.

Frame binding:

1. Dispatch quoting a spent snapshot → `snapshot_spent`, and the action is not
   performed.
2. Dispatch quoting a snapshot superseded by a later `observe` of the same window
   → `snapshot_superseded`; a snapshot of a *different* window stays live.
3. Dispatch after `limits.snapshotTtlMs` → `snapshot_expired`.
4. `snapshotsPerSession + 1` observes → the oldest yields `snapshot_evicted`, not
   `snapshot_unknown`.
5. Token whose element was destroyed → `element_released`; token whose element
   had its label changed → `element_changed` with `detail.changed: ["label"]`.
6. `expectElementDigest` from snapshot A used against a token from snapshot B →
   `element_unknown` (tokens are snapshot-scoped) — not a successful dispatch.
   The sibling case, a token that *is* in the quoted snapshot carrying a digest
   the snapshot did not record for it, is `element_digest_mismatch` — and the two
   vectors must produce different codes, because `maka.cu/1` produced one.
7. `strictness: "window"` refuses when an unrelated element in the window
   changed; `strictness: "element"` does not.
8. A refused dispatch leaves the snapshot `live`; an `outcome_unknown` spends it.
9. Snapshot ids from two executor generations never collide.

Observation revisions:

9a. The first observation assigns depth-first stable ids; a later observation
    with fresh tokens preserves ids for structurally matched nodes and gives new
    nodes ids above the previous maximum.
9b. A spent snapshot remains the next difference baseline, while expired and
    evicted snapshots do not.
9c. Empty effective change produces `presentation: "no-change"`; insert/update
    changes carry current tokens; removals carry no token and their stable ids
    are compressed into inclusive ranges.
9d. A difference whose rendered line count exceeds the full tree selects
    `presentation: "full"`.

Declared schema:

10. Every dispatch result carries all four of `outcome`, `tier`, `path`,
    `effect`; a response missing any is rejected by the host as a protocol
    violation.
11. `tier`/`path` pairs outside the §6.3 table are rejected, not coerced.
12. `set_value` whose readback equals the previous value reports
    `suspected_noop`, not `ok`.
13. `click` with `settle: "none"` never reports `effect: "confirmed"` via
    `tree_delta`.
14. `dispatch.point` returns `unsupported_action`, `path: "none"` and
    `verification.method: "none"` without resolving or consuming the snapshot,
    inspecting a window, or posting an event.

Versioning:

15. `host.hello` with an unknown protocol string → `-32000` with `supported`,
    exit 78, host does not retry.
16. Any method before `host.hello` → `-32001`.

Bounds and references:

17. A tree over `maxElements` sets `truncated.elements: true` and still returns
    usable tokens.
18. An element value over `maxTextChars` sets `element.truncated: ["value"]`, and
    its digest is over the untruncated string (edit past char 500 → digest
    changes → `element_changed`).
19. No response contains a base64 image.
20. An image file is deleted when its snapshot is superseded, and the host's read
    of a stale path fails rather than returning a previous frame's pixels.

Lifecycle:

21. `session.end` releases every snapshot and image and removes any cursor;
    `released` counts match.
22. `capture.start`/`next`/`stop` all return `not_implemented` as a domain result
    with `ok: false`, never `-32601`.
23. `$/cancel` before dispatch yields `aborted`; after dispatch it is ignored and
    the real outcome is reported.
24. Killing the executor mid-dispatch produces `outcome_unknown` on the host, and
    `service_unavailable` for requests never written.

Refusals carry the declared fields (§1.1, §6.5):

25. Every `ok: false` dispatch result carries `outcome`, `tier`, `path`, `effect`
    and `verification`; the executor emits them on the refusal path, and a
    refusal missing any of them is rejected by the host as a protocol violation.
    Asserted on a binding refusal (`element_changed`), a policy refusal
    (`window_occluded`) and an attempted-and-rejected one (`dispatch_refused`).
26. A pre-dispatch refusal reports `outcome: "refused"`, `path: "none"`,
    `effect: "unverifiable"`, `verification.method: "none"`, and
    `error.detail.snapshotSpent: 0`; an attempted refusal reports its concrete
    AX path and `snapshotSpent: 1`. The host accepts both, maps the error code,
    and does **not** tear the executor down. The `maka.cu/1` host SIGKILLed on
    any non-`ok` outcome, so this vector fails against it.
27. An attempted unknown element action reports `outcome: "unknown"`, its
    concrete `ax_action`/`ax_attribute` path, `effect: "unverifiable"`,
    `verification.observedChange: false`, and `error.detail.snapshotSpent: 1`;
    it is never rewritten as a refusal or as verified success.
28. `ok: true` with `outcome: "refused"`, and `ok: false` with `outcome: "ok"`,
    are both protocol violations.

Hashes (§1.3):

28. `element.digest`, `snapshot.windowDigest` and `image.sha256` all match
    `^sha256:[0-9a-f]{64}$` in the same response.
29. A host verifying an image prefixes its own digest before comparing, and a
    bare-hex `image.sha256` from the executor is a protocol violation rather than
    a mismatch. This is the vector that fails on `maka.cu/1`: bare hex on one
    side and prefixed on the other made every screenshot compare unequal, and the
    host's response to an unequal image is teardown.

Naming an app (§5.1):

30. `apps.list`, `window.list`, `snapshot.target` and the `apps.launch` result
    report the same `appId` for the same process.
31. `observe` with `{ "kind": "app", "app": "<appId of a bundled app>" }`
    resolves; the reviewer's reproduction — an `{app, windowId}` observation of a
    bundle-identified app — succeeds instead of being refused.
32. `observe` with an `app` that is a display name, not an `appId`, is
    `app_not_found`; the executor does not fall back to matching `appName` or
    `title`.
33. `apps.launch` by display name returns the resolved `appId`, and a subsequent
    `observe` with that `appId` resolves the launched window.

Keys (§6.4):

34. The host parses `"cmd+a"`, `"shift+Tab"`, `"Return"`, `"a"` and `"cmd++"`
    into `{ key, modifiers }` on the closed sets; the raw string never reaches
    the wire.
35. `"delete"`, `"del"`, `"cmd+"` (empty final segment that is not a trailing
    `"+"`), `"a+b"` and `"hyper+a"` fail the action with `unsupported_action`
    before any request is sent — no defaulted key press, no dropped modifier.
36. `dispatch.key` with `key: "cmd+a"` is `-32602` at the executor: the closed
    set is closed, and a host that sent it has a bug.

Coordinate space (§5.3):

37. For a window whose `bounds.origin` is not `(0, 0)`, the host's
    `CuObservedElement.frame` equals `element.frame + bounds.origin`. A snapshot
    passed through unconverted fails this by exactly the window origin, which is
    what the `maka.cu/1` host shipped.
38. The occlusion check and the agent cursor read the same converted rectangle,
    and an element at the far edge of a window at `x: 900` is not judged to be at
    `x: 0` on the desktop.

Refused, not unsupported (§7.1):

39. A `dispatch_refused` result reaches the model as `dispatch_refused`, not as
    `capture_failed` and not as `unsupported_action`, and the frame it quoted is
    still live afterwards.

Focus policy (§6.4):

40. `dispatch.key` with no `focusPolicy` behaves exactly as `require`: focus
    elsewhere is `focus_changed` with no key posted **and no `kAXFocused` write
    attempted**, and focus already on the named element posts the key, also
    without writing focus. With `focusPolicy: "acquire"` that same
    focus-elsewhere case writes focus onto the bound element and posts.
41. `acquire` against an element that does not end up focused — the write
    refused, and the write accepted while focus stays put — is `focus_changed`
    both times, with no key posted. The second half is the vector that fails
    against an executor which trusts the write instead of re-reading.
42. `focusPolicy` outside `require` / `acquire` is `-32602` naming the field,
    not a silent fallback to `require`.

Launching an app (§5.7):

43. `apps.launch` with `waitForWindowMs: 8000` resolves the application under a
    budget of 8000 ms, not under an executor-chosen one; a request that declares
    no budget still gets the executor's default. The vector that fails against an
    executor which waits its own five seconds for the process and then hands the
    caller's budget to the window wait — which is what refused a cold TextEdit at
    5571 ms.
44. An application that was started and had not registered within the budget is
    `timeout`; an application nothing on the machine answers to is
    `app_not_found`, and it is answered without spending the budget. The two
    codes must differ: one tells the model to wait, the other to try another
    name, and an executor that reports both as `app_not_found` sends the model
    hunting for an app it already launched.
45. An app on the executor's safety list is `unsupported_action`, and a launch
    the system refuses is `dispatch_refused`. Neither is `app_not_found`. This is
    the vector that fails against a handler which reaches the resolver through a
    `try?`, because that collapses every failure into the one code.
46. An application started after the executor appears in the next `apps.list`,
    and one that registers part-way through a launch budget resolves rather than
    timing out; `foregroundTaken` is the difference between a read before the
    launch and a read after it. The vector that fails against an executor reading
    `NSWorkspace.shared.runningApplications` or `frontmostApplication`, both of
    which are frozen at process start on any thread but the main one (§5.5) — and
    it only fails from a lane, so a check that runs on the main thread, or parks
    on anything that spins the main run loop, passes against the broken executor.

Capture geometry (§6.6, §6.7):

47. A window capture is drawn over the whole of the size it declares: the
    bounding box of the image's non-transparent pixels is the entire bitmap,
    under both capture scopes. The vector that fails against an executor which
    sizes the output buffer from `NSScreen.backingScaleFactor` instead of from
    the filter it renders through — a 674 × 408 pt window came back 1348 × 816
    px with the window in the top-left quarter, three quarters transparent, and
    `scale: 2.0` declared over content rendered at 1.0. It can only fail on a
    machine whose displays do not all share one backing scale, because where the
    guess happens to be right there is nothing to catch; that is why it is a
    live vector and why it sweeps every window on screen rather than one.
48. `screen.capture` with no `displayId` captures the main display and reports
    the id it used. The vector that fails against an executor which decodes the
    field as required: `CuAction.screenshot` is defined to arrive with no
    target, so a required `displayId` makes `-32602` the answer to every
    screenshot the model actually asks for.
49. `screen.capture` naming a display that is not attached is `-32602` on
    `displayId`, and no image is written. This vector and 48 have to be read as
    a pair — an executor that satisfies 48 by defaulting whenever the lookup
    fails passes 48 and fails 49, and it fails it by returning a picture of the
    main display under the display id the caller asked for.

Launching without taking the foreground (§5.7):

50. The configuration `apps.launch` opens an application with does not activate
    it, and does not record it in Recent Items. The vector that fails against an
    executor which builds an `NSWorkspace.OpenConfiguration` and passes it
    unmodified, because the default is `activates: true` — it never asked for a
    background launch, and a cold Preview took the user's foreground while
    `focusHeld` was being asserted false. Its live half starts an application
    that is not running and watches the front layer-0 window owner for the whole
    launch, because a request is only evidence of what was asked for. Its pair is
    the honesty half: an app whose pid holds the foreground after a launch that
    asked not to activate is still `foregroundTaken: true`, and an executor that
    answers from its own request rather than from the two reads fails it.

Observing a window that is expensive to read (§5.2):

51. A walk that reaches `limits.treeWalkCeilingMs` stops, returns the elements it
    already has with usable tokens, and reports `truncated.elements: true`. Two
    executors fail this and they fail it differently: one has no clock at all and
    returns a complete tree 35 s after a host that waits 20 s has already killed
    it, and one stops on time but reports
    `truncated: { "elements": false, "depth": false }`, which tells the host it
    saw the whole window. The unit half drives the walk through an injected
    clock, because the windows that are actually slow are open and save panels
    and a test cannot put one on the screen. The live half observes a real one
    and asserts the answer arrived inside the ceiling — an executor whose ceiling
    is per-attempt rather than per-observation passes the unit half and fails
    this one, because §7.5 walks the tree up to four times.

Refusing point mutation (§6.3):

52. Begin a valid session, install a live snapshot, then send `dispatch.point`
    with a deliberately wrong `expectWindowDigest`, an empty live window
    inventory, and an event sink configured to fail if called. The answer is the
    stable `unsupported_action` refusal, no event is posted, and the snapshot
    remains live. This proves the compatibility endpoint does not inspect or
    mutate the target before refusing.

Judging a key by something that bears on it (§6.5):

53. `dispatch.key` with `{ "kind": "key", … }`, posted at a focused element whose
    value the key does not touch, is never `suspected_noop`. With
    `settle: "quiesce"` it reports `tree_delta` — `confirmed` when the window
    moved, `unverifiable` when it did not — and with no settle it reports
    `unverifiable` / `none`. `kind: "type"` is unchanged: it is still judged by
    the focused element's value, under the same settle, on the same element, and
    it can still report a real `suspected_noop`.

    The vector that fails against an executor which reads that value back for
    every key it posts. Measured: a model asked to export a document found the
    menu bar unreachable, reached for `cmd+p`, was answered
    `ok … effect: suspected_noop` seven times, and sent it seven times — then
    reported that it must be getting the arguments wrong. A second model did the
    same with `ctrl+f2` four times.

    The vector is built on an application the live half **activates**, and the
    reason is the finding still open in §14: `cmd+A` is a main-menu key
    equivalent, `performKeyEquivalent:` is reached through `NSApp`'s key window,
    and a background application has none. Against a background window this
    vector's key goes nowhere, so it would measure delivery rather than the
    verdict and would pass for the wrong reason before the fix and after it
    alike. Activating removes the confound and is the field case exactly: `cmd+A`
    on the document the user is looking at. What the live half does not relax is
    the executor's invariant — the frontmost application is asserted unchanged
    across each dispatch, and the one that had it is put back.

    Both halves are needed and neither is redundant. The unit half drives a
    binding probe whose answer changes once a key has been posted, because a
    probe that answers from its own record can never produce a window delta and
    no test built on one can tell the two evidence sources apart. The live half
    exists because the unit half **cannot fail the way production failed**: a
    fake `AXUIElement` has no value, both sides of the readback come back `nil`,
    the executor takes its own "nothing to check" arm, and the answer is the
    `unverifiable` the fix produces. The defect is only visible against an
    element that really has a value, which means a real text view — the live half
    reads the selection out of the executor's own post-dispatch observation to
    establish that the key arrived before saying anything about the verdict.

Posting a key that the application can act on (§6.4):

54. Every member of the closed set resolves to an event that **carries
    characters**, and a key posted to a **background** application arrives.

    Its unit half enumerates the set rather than sampling it — 26 named keys and
    94 printable characters, 120 members — and asserts that the set the decoder
    accepts and the set the dispatcher can build are one set, with a character on
    every member. For 22 of the named keys it asserts *both* that the character
    is the one AppKit binds and that it is **not** the one the key code's own
    layout translation supplies: the right arrow translates to U+001D against
    AppKit's U+F703, `ForwardDelete` translates to the backspace key's U+007F,
    and all twelve function keys collapse onto one U+0010. That second half is
    what fails against the executor that shipped, which built the event and
    posted it unmodified.

    It also asserts the `command` exception, and asserts it as a property of the
    stroke rather than of the event, because the difference between a string set
    by the executor and one the system supplied is invisible from inside the
    posting process — which is exactly why the live halves exist.

    Its live half posts against a **background** TextEdit document and reads the
    application's own answer: the insertion point for the four arrows, and the
    document's value for `Tab`, `Return`, `Backspace`, `ForwardDelete` and a
    printable character with and without `shift`. It never activates the target,
    and the frontmost pid is asserted unchanged across every dispatch — which is
    what makes those effects evidence of background delivery rather than of a
    foreground the test quietly took.

    Vector 53 is the other half of the pair and neither is redundant: 53
    **activates** its target and sends `cmd+A`, so it is the vector that catches
    an executor which sets characters on a command stroke and silently deletes
    every menu shortcut that used to work. 54 never activates, because background
    delivery is the thing it measures. An executor cannot satisfy both by
    choosing one behaviour for all keys, which is the point.

Settling a window that is expensive to look at (§6.1):

55. `settle.waitedMs` is the time the settle spent, on every arm, and a window
    that cannot be looked at twice inside the budget is reported as
    `window_too_slow` rather than as a settle that ran the budget out.

    The vector that fails against the executor that shipped, and it fails it on
    the honesty field first. That loop answered its timeout arm with
    `limits.settleCeilingMs` — a constant — so a settle that really spent 4.3 s
    reported 2500, and `waitedMs` is the field the host traces to see overruns.
    Measured against the real loop: System Settings costs 2.2 s a look, which
    fits the budget, so a second look began at 2270 ms and the call returned at
    4310 ms reporting `2500`; a 1225-element Finder window costs 3.6 s a look, so
    the second look — the minimum quiescence can be proven in — never happened at
    all, and it too reported `ceiling` and `2500` for a 3674 ms call. `ceiling`
    was false on the second one in a second way: it says the window was compared
    and had moved, and nothing had been compared. The three defects are one
    finding, because the fabricated duration is what kept the other two off every
    instrument.

    Its unit half drives the loop through a hand-moved clock, which is the only
    way to land the boundary exactly: four looks of 500 ms end at 2150 ms, and an
    executor answering with the constant says 2500. It asserts the ordinary
    window too — 0.23 s per look still quiesces on the second, at 510 ms — because
    a fix that refuses to begin an unaffordable look must not refuse the
    affordable one.

    Its wire half drives a binding probe that costs 2.6 s of **real** time per
    look, because a fabricated `waitedMs` is invisible to any test with a fake
    clock in it: there, the constant and the clock agree by construction. It
    asserts `waitedMs` against the wall-clock time of the call itself.

    Its live half settles against every ordinary window on the screen, System
    Settings included, and asserts the same thing with nothing faked at all. It
    is a read — settling presses nothing — so it can be pointed at the user's own
    windows. It also asserts the shape of the answer against the count of looks
    that were actually paid for: `quiesced` and `ceiling` both claim a comparison
    was made and so require two, and `window_too_slow` claims none was affordable
    and so requires exactly one. An executor that renamed the timeout without
    changing when it stops passes the unit half and fails this one, and the old
    loop fails it three ways on two windows: `waitedMs 2500` against 4310 ms,
    `waitedMs 2500` against 3674 ms, and `ceiling` on a window it had looked at
    once.

Managing a window (§6.1):

56. The three window actions are addressable only as the snapshot root, refuse an
    attribute the application will not let anyone write, and reject a geometry
    that is not one. A non-root token is `element_not_actionable`;
    `resize_window` against **Calculator**, whose window advertises `AXSize` and
    refuses to have it written, is `element_not_actionable` and **not** an
    `ok: true` result — the executor asks `AXUIElementIsAttributeSettable` before
    it writes rather than reporting the write's own `kAXErrorFailure` as a fault;
    a non-finite `position`, or a negative extent in `size`, is `-32602` naming
    the field. Its live half is the census: seventeen applications, `AXPosition`
    settable on all seventeen, `AXSize` on fourteen, `AXMinimized` on fifteen,
    and `AXPosition`/`AXSize` settable on no ordinary control.

57. A window action is judged by the attribute it wrote, at whole logical points,
    and the three arms are told apart. A move to a free position reads back equal
    and is `confirmed` / `value_readback`; a move macOS clamps reads back as
    neither the request nor the previous value and is `unverifiable` /
    `value_readback`, never `confirmed` and never `suspected_noop`. The vector
    that fails against an executor which reports the write's `AXError` as the
    verdict: every one of the clamped cases returns `kAXErrorSuccess`. Its live
    half uses the two clamps this machine actually produces — `(99999, 300)` →
    `(1687, -52)`, and a 10 × 10 resize of TextEdit → 115 × 46 — and reads the
    landing point out of the executor's own post-observation, because that is
    where §6.1 says it is reported.

58. No window action takes the foreground, and none returns before the window
    server agrees with it. The live half asserts the frontmost pid unchanged
    across every single dispatch, on a target launched in the background and
    never activated, and it puts every window back where it found it. It then
    dispatches `observe` immediately after a move and asserts the answer is a
    snapshot whose `target.bounds` is the *new* origin — not `window_gone`.

    That second half is the one an executor fails by being fast. The application
    answers `AXPosition` in 3–16 ms and the window server catches up in
    26–172 ms, and `observe` resolves its target out of the window list and then
    matches the AX window against that frame to within a point. Returning on the
    application's acknowledgement therefore hands back a frame in which the
    executor's own `observeAfter` cannot find the window it just moved. It fails
    hardest on Chromium and Electron, which are the slowest to propagate and the
    windows a model is most likely to be asked to move.

    The minimise arm is the third thing only a live half can see: it asserts
    `effect: "confirmed"`, and the executor answered `suspected_noop` until the
    readback was moved to after the wait, because `AXMinimized` still reads
    `false` on the instant after a write that worked. No unit vector can produce
    that — a fake element has no attribute to read stale — and the model's answer
    to a `suspected_noop` is to send the request again.

    It also asserts that `unminimize` is measured rather than assumed: the
    restore the test has to perform anyway is done outside the protocol, and the
    frontmost pid is asserted to have become the target's. That is the §14
    finding, standing as a test rather than as a note.

    `secondary_action: "raise"` is asserted in the same test and for the same
    invariant: raising a background window moves it up the z-order — measured,
    Preview 22 → 24 and Stickies 20 → 24 — with the frontmost pid unchanged.
    Calculator is asserted separately because it advertises `AXRaise` and answers
    `kAXErrorAttributeUnsupported`, which must arrive as `outcome: "failed"` with
    `path: "ax_action"` rather than as an `ok` that did nothing.

59. `menu` is absent from a snapshot that did not ask for it and present when it
    did; an application with no menu bar answers with the key and an empty array,
    and an application with an empty menu bar answers with one root element and
    no children. The three are different facts and the wire distinguishes all
    three: a host that read an absent key as "no menus" could not tell it from
    "you never asked", and would stop looking for a command that is there.

60. Asking for the menu does not change `windowDigest` and does not change
    `elements`. This is what keeps the menu out of the settle loop: the digest is
    recomputed once per settle sample at one Accessibility round trip per
    recorded element, and a menu folded into `elements` would have charged every
    settle of every window for 141–393 elements that cannot move while the window
    does. It also keeps one window from digesting two ways depending on a flag in
    the request that observed it.

61. A menu is cut by its own bound and says so in its own field:
    `menu.truncated.elements` rises and `truncated.elements` does not. The bound
    asserted is the shipped `limits.maxMenuElements`, not one injected by the
    test — the number *is* the claim, since 500 has to clear the largest menu bar
    measured (VS Code, 393 with the Apple menu excluded) or the applications that
    need menus most are the ones that get cut.

62. **Live.** A background application's menu items are readable and pressable,
    and neither reading nor pressing takes the foreground. The live test observes
    a background Calculator with `menu: true` and asserts, with the frontmost pid
    checked across every call:

    - the menu came back at all, rooted at `AXMenuBar`, with items exposing
      `press` — the whole of what was missing before;
    - **no element under `menu` carries a `frame`**, which is the half no unit
      test can reach: the value being suppressed is the degenerate
      `(0, 982, 0, 0)` AppKit puts on a real unopened menu item, and no fake
      produces it;
    - nothing under `menu` is titled `"Apple"`, so the system menu — and
      `关机` with it — is out of scope rather than merely far down the list;
    - a `dispatch.element` against a menu token is **not** refused
      `element_changed`, which is the assertion that the frame suppression was
      applied at *both* ends of §4.3 rather than only at the walk. An executor
      that suppressed it only on the way out passes every unit vector above and
      fails this one on every menu item of every application;
    - pressing an *enabled* item lands: `显示 > 基础` / `显示 > 科学` on a
      background Calculator moves the window between 230×408 and 674×408, which
      is observable from outside the application and reversible from inside the
      test. The item is chosen for exactly that: a menu press with a side effect
      the test cannot undo is not a test, it is damage.

    The disabled half of the pair — that `AXPress` on an item the application
    reports disabled returns `kAXErrorSuccess` and does nothing — is asserted as
    a refusal in the unit vectors, because the executor must refuse before it
    reaches the API. What the live test would otherwise be asserting is
    AppKit's behaviour, and the measurement is recorded in §5.8 instead.

63. `title` and `label` arrive as separate fields and neither overwrites the
    other: a title-only element is named, a description-only element is named,
    and an element carrying both keeps both. A cut title raises `"title"` in
    `truncated`. The vector exists because the wire carried `label` alone while
    §4.3 digested `title` and §6.2 could report `changed: ["title"]` — and
    because which of the two an element uses is the application's choice, so an
    executor that reads one of them returns an anonymous tree for whichever half
    of macOS chose the other. Measured: 23 of 35 Calculator window elements carry
    `label`, 2 of its 126 menu elements do.

- **No tool schemas, no descriptions, no instructions.** `ToolDefinitions.swift`
  and `computerUseServerInstructions` do not survive. Maka's runtime owns every
  model-facing word, and a second copy in the executor is a second copy to drift.
- **No rendered text.** `AppSnapshot.renderedText`, the tab-indented tree, the
  `list_apps` catalogue: all of it is model-facing prose generated from data the
  host now receives as data.
- **No approval logic.** Approval classes are runtime policy
  (`COMPUTER_USE_APPROVAL_CLASSES`); the executor neither knows nor asks.
- **No redaction.** The executor does not put application content anywhere except
  the declared observation fields (§1.2), so there is nothing to redact.
- **No retries.** The executor performs an action once. Retry is a host decision
  because only the host knows whether the model has been told.
- **No `verified` field.** One bit, two producers, three fallbacks; see §6.5.
- **No env-var behaviour switches.** `maka-cu` currently reads
  `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` and
  `OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS` from the process environment. Every
  behavioural switch this protocol needs is a handshake parameter, so the wire
  says what the executor will do rather than the ambient environment.
- **No `bundleId` alongside `appId`.** One namespace, §5.1.

---

## 14. Open questions

`maka.cu/1` referred to this section from §4.4 and §7.1 and never contained it,
which is how its one flagged question stayed open long enough for two
implementations to answer it differently. What remains open is listed here and
nowhere else.

- **A main-menu key equivalent does not reach a background application.** §6.4
  posts key events to the target pid and forbids activating the application, and
  that is right. Measured against a TextEdit document window while another
  application was frontmost, one key press per row:

  ```
  type "typed"                            landed     value "ORIGINAL" → "typedORIGINAL"
  Right, virtual key only                 no effect  loc 0
  Right, + unicode U+F703                 landed     loc 0 → 1
  Right, + numeric-pad and fn flags       no effect  loc 1
  Right, + those flags + unicode U+F703   landed     loc 1 → 2
  a, virtual key only                     no effect  value unchanged
  a, + unicode U+0061                     landed     "OR" → "ORa"
  cmd+a, virtual key only                 no effect  selection loc 0 len 0
  cmd+a, + unicode U+0061                 no effect  selection loc 0 len 0
  ```

  Two separate faults, and the second one was only visible once the first was out
  of the way.

  **The first is closed.** An event posted straight to a pid carries only what
  the executor put on it, and the executor put no characters on it: a key code
  is half an event, and what an application acts on is the character. `typeText`
  worked because it set the unicode string; `pressKey` never did, so
  `dispatch.key` with `kind: "key"` delivered nothing at all. Nor was passing the
  layout's own translation along an option — measured afterwards, the key code
  alone translates to the wrong character for 22 of the 26 named keys: U+001D for
  the right arrow where AppKit binds U+F703, U+007F for `ForwardDelete` which is
  the *backspace* key's character, and one shared U+0010 for all twelve function
  keys. The executor now resolves the closed set through a table that carries the
  character for every one of its 120 members (§6.4), and the answer to *where the
  characters come from* is that table rather than `UCKeyTranslate`, for the
  reasons stated there.

  Measured against a background TextEdit document afterwards, through the full
  `dispatch.key` path, with the frontmost application asserted unchanged across
  every one:

  ```
  Right                                   landed     loc 0 → 1 → 2
  Left                                    landed     loc 2 → 1
  Down / Up                               landed     loc 1 → end of document → 1
  Tab                                     landed     tab inserted at the caret
  Return                                  landed     newline inserted
  Backspace                               landed     character before the caret deleted
  ForwardDelete                           landed     character after the caret deleted
  z                                       landed     "z" inserted
  shift+z                                 landed     "Z" inserted
  Home / End                              no caret   bound to scrolling on macOS, not to the caret
  Escape                                  no effect  visible; `cancelOperation:` orders in no panel for an inactive app
  ```

  `Escape` was measured separately against a background Calculator, where it
  cleared the entry two digit keys had just put in the display: it lands, and
  TextEdit is simply not an application that can show it. `Home` and `End` are
  `scrollToBeginningOfDocument:` and `scrollToEndOfDocument:` on macOS, so a
  document that fits its window has nothing to show for them either way.
  `HostKeyDeliveryLiveTests` is the standing form of this table (§12 vector 54).

  **The second is still open, and closing the first sharpened it.** A main-menu
  key equivalent needs a key window. `cmd+a` did not land even carrying its
  character, and landed immediately once the same application was activated:
  `performKeyEquivalent:` is reached through `NSApp`'s key window, and a
  background application has none. So `cmd+p`, `cmd+s`, `cmd+w` and `ctrl+f2` —
  the shortcuts a model reaches for precisely when the menu bar is not in the
  observation — cannot be delivered this way at all.

  What the fix added is the other half of it: an event carrying characters is
  taken as text and is never offered to `performKeyEquivalent:` at all, so
  setting them *removes* a shortcut that worked while the target happened to be
  frontmost. §6.4 therefore posts a `command` stroke without characters, which
  costs one thing worth naming — `cmd+←` and its siblings are caret motions
  rather than menu commands and would reach a background application if the
  characters were there (measured: `loc 0 → 33`). The executor has no way to tell
  a menu equivalent from a responder-chain binding: `cmd+↓` is caret motion in a
  text view and *Open* in the Finder, and the two need opposite events.

  The executor reports `outcome: ok` for all of them, because the events were
  written to the pid and nothing said no. §6.5's honesty rule keeps that out of
  `confirmed`, but the model is still told a request succeeded that could not
  have.

  Three ways out, none taken yet: refuse a key the target cannot act on (and the
  executor cannot know which those are), route menu commands through the menu's
  own AX actions instead of through the keyboard (a different method, not a
  different key), or state the limitation on the wire so the host can put it in
  front of the model. Whichever it is, it also has to answer the `command`
  question above — and it needs measuring on more than one application first.
  Both tables here are TextEdit on one machine, with one Calculator row beside
  them.

  **The second of the three is now taken, and it does not close this.** §5.8 puts
  the menu bar in the observation and lets `dispatch.element` press a menu item
  through `AXPress`, so `cmd+s`, `cmd+p` and `cmd+w` have a route that does not
  go through a key window: the model presses `文件 > 存储` rather than sending the
  shortcut. Measured, that route works on a background application — a
  depth-2 item pressed on a background Calculator moved its window 674×408 →
  230×408 with the frontmost pid unchanged.

  What it does not do is make `dispatch.key` honest. A `cmd+s` sent as a key is
  still written to the pid, still cannot reach `performKeyEquivalent:`, and is
  still reported `outcome: "ok"`. The menu route is an *alternative* the host can
  now choose, not a repair of the keyboard one, and the executor still has no way
  to tell a menu equivalent from a responder-chain binding at the point the key
  arrives. What has changed is that the host now has somewhere else to go.

  §5.8 also puts a number on the cost of the responder chain being empty, which
  this section only had one row for: of TextEdit's 293 menu items, **110 report
  `enabled: false` while the application is in the background and flip to `true`
  the moment it is activated** — `导出为PDF…`, `存储`, `撤销`, `粘贴`, `全选`
  among them. The menu route reaches those items and reports them honestly; it
  does not make a background application willing to run them.

- **A window cannot be restored from the Dock without activating its
  application.** §6.1 ships `minimize_window` and no inverse, and the reason is
  measured rather than assumed. Writing `AXMinimized = false` restores the
  window *and* brings its application to the front, with no `AXMain` write
  anywhere near it and against an application that was not frontmost to begin
  with:

  ```
  Calculator  pid 30706   front 774   → minimize      774
                                      → unminimize +0ms    774
                                                   +300ms  30706
                                                   +1500ms 30706
  TextEdit    pid 93825   front 30706 → minimize      30706
                                      → unminimize +0ms    30706
                                                   +300ms  93825
                                                   +1500ms 93825
  ```

  Minimising is the safe half and is measured so: the frontmost pid did not move
  across either write, and it cannot — a minimise can only take a window *away*
  from the front. What it does mean is that a model can put a window in the Dock
  and cannot take it out, which is a real cost and is why this is written down
  here rather than left as an omission.

  **A later measurement disagrees, and both are kept.** Writing `AXMinimized =
  false` directly, then sampling the frontmost pid at 100 Hz for three seconds,
  across Calculator, TextEdit and Preview: 900 samples, the foreground moved
  zero times. The difference between the two is not established — the table
  above was taken through the executor's whole dispatch path, including the
  `observeAfter` that follows every dispatch, and the later probe writes the one
  attribute and nothing else. Until that is resolved, the activation claim is
  evidence rather than fact, and this section no longer rests on it.

  **What the absence does rest on is that there is nothing left to address.** A
  minimized window is not in the window list: `CGWindowListCopyWindowInfo` is
  asked for `.optionOnScreenOnly` and a minimized window is not on screen.
  Measured end to end — the moment `minimize_window` succeeds, `list_apps` for
  that application reports `windowCount: 0` and `observe` answers
  `target_missing`. An `unminimize_window` would need a `windowId`, and the
  observation that would have carried one no longer exists.

  Closing it means carrying off-screen windows in the list, and the unfiltered
  `CGWindowListCopyWindowInfo` is not a drop-in: 213 layer-0 entries against 17
  on screen, and `kCGWindowIsOnscreen` is absent from its entries, so there is
  no field to tell the two apart. The alternative — enumerate `AXWindows` per
  pid and match each back to its `CGWindowID` — has no public API for that
  mapping. That mapping is the actual work, and it is the reason this is still
  open rather than a small omission.

  Until then `minimize_window` is a one-way door, and the tool description says
  so in as many words: a model that minimises a window should know, before it
  does, that only a person can bring it back.

  Three ways out, none taken. Advertise it and declare that it activates —
  rejected, because §5.7's own rule says a field that is a constant is not a
  field, and "always takes the foreground" is a constant. Restore the previous
  frontmost application afterwards — rejected, that is the executor taking the
  foreground twice to hide taking it once. Or find a path that deminiaturises
  without activating; `NSWindow.deminiaturize(_:)` is not one, and nothing else
  has been measured. Whichever it is, it is a product decision about Maka's
  invariant and not one the executor gets to make on its own.

  Two smaller facts fell out of the same measurements and are settled rather than
  open. `AXMain = true` does **not** take the foreground (measured on both
  applications, frontmost pid unchanged), so it is not the mechanism here. And a
  minimized window is still writable — `AXPosition` remained settable, the write
  returned `kAXErrorSuccess`, and the readback moved — which is why
  `minimize_window` does not have to be ordered against the geometry actions.

- **The Electron/Chromium `element_released` rate is unmeasured.** §4.4 item 2
  states that tree-rebuilding applications can fail E1 on a control that is
  visibly present, and that the correct host response is to re-observe. Nobody
  has measured how often that happens per action in a real Electron window. Until
  someone does, the host's retry budget for `element_released` is a guess, and
  the protocol says nothing about what that budget should be.

Closed since `maka.cu/1`: the `dispatch_refused` mapping, now §7.1.
