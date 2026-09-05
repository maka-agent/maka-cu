/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

//! Minimal, deliberately bounded Windows executor for the #4318 language
//! comparison.  The transport is line-delimited JSON-RPC 2.0 and implements
//! the shared `maka.cu/2` host protocol.  On Windows the UIA calls are made through the
//! IUIAutomation COM interfaces (there is no managed/UIA wrapper).
//!
//! Security properties shared with the C# spike:
//! * only an explicitly supplied HWND is observed or captured;
//! * every observation mints opaque, one-use element tokens;
//! * mutation spends the token before dispatch and revalidates HWND/PID and
//!   the element identity; and
//! * the production capability surface is semantic-only: there is no
//!   foreground activation, global keyboard, pointer, clipboard, coordinate,
//!   PostMessage, process-launch, or screen-rectangle fallback.

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{create_dir_all, write};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::Arc;
#[cfg(windows)]
use std::sync::Once;
use std::thread;
use std::time::{Duration, Instant};
#[cfg(any(windows, test))]
#[cfg_attr(not(windows), allow(dead_code))]
mod readback;
const PROTOCOL: &str = "maka.cu/2";
const MAX_ELEMENTS: usize = 512;
const MAX_SNAPSHOTS_PER_SESSION: usize = 8;
const MAX_SNAPSHOT_TOMBSTONES_PER_SESSION: usize = 64;
const SNAPSHOT_TTL: Duration = Duration::from_secs(120);
const MAX_TEXT: usize = 1024;
const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
const MAX_IMAGE_DIR_BYTES: usize = 256 * 1024 * 1024;
#[cfg(windows)]
const MAX_CAPTURE_PIXELS: i64 = 16_000_000;
#[cfg(windows)]
const MAX_CAPTURE_PNG_BYTES: usize = 4 * 1024 * 1024;
const SHUTDOWN_GRACE_MS: u64 = 1_000;
static HOST_PID: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RpcRequest {
    jsonrpc: Option<String>,
    id: Option<Value>,
    method: Option<String>,
    #[serde(default)]
    params: Value,
}

#[derive(Debug)]
struct Registry {
    // Monotonic ids are used only for snapshot bookkeeping. The protocol
    // handshake and session set are owned by the same worker registry so a
    // request cannot bypass the shared lifecycle state.
    next: AtomicU64,
    nonce: u128,
    snapshots: HashMap<String, Snapshot>,
    sessions: HashSet<String>,
    image_dir: Option<PathBuf>,
    image_sizes: HashMap<PathBuf, usize>,
    image_created_at: HashMap<PathBuf, Instant>,
    image_bytes: usize,
    unattached_images: HashMap<PathBuf, UnattachedImage>,
    host_pid: Option<u32>,
    // Presentation identity is scoped to one target process/window. RuntimeId
    // is used only as the matching key; dispatch still quotes the opaque
    // snapshot token and digest.
    stable_ids: HashMap<(u32, isize), HashMap<Vec<i32>, u64>>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SnapshotState {
    Live,
    Spent,
    Superseded,
    Expired,
    Evicted,
}

impl SnapshotState {
    fn error_code(self) -> &'static str {
        match self {
            Self::Live => "snapshot_live",
            Self::Spent => "snapshot_spent",
            Self::Superseded => "snapshot_superseded",
            Self::Expired => "snapshot_expired",
            Self::Evicted => "snapshot_evicted",
        }
    }
}

#[derive(Debug, Clone)]
struct Snapshot {
    session: String,
    hwnd: isize,
    pid: u32,
    start_time: u64,
    generation: String,
    // Live snapshots retain their dispatch references. Terminal snapshots
    // retain only bounded tombstone metadata, never the potentially large
    // element map.
    elements: Option<HashMap<String, ElementRef>>,
    captured_at: Instant,
    state: SnapshotState,
    image_path: Option<PathBuf>,
}

#[derive(Debug, Clone)]
#[cfg_attr(not(windows), allow(dead_code))]
struct ElementRef {
    automation_id: String,
    name: String,
    control_type: i32,
    runtime_id: Vec<i32>,
    digest: String,
}

#[derive(Debug, Clone)]
struct UnattachedImage {
    session: String,
    captured_at: Instant,
}

#[derive(Debug)]
struct StoredImage {
    path: PathBuf,
    value: Value,
}

impl Registry {
    fn new() -> Self {
        let mut bytes = [0_u8; 16];
        getrandom::fill(&mut bytes).expect("OS randomness is required for snapshot isolation");
        Self {
            next: AtomicU64::new(0),
            nonce: u128::from_le_bytes(bytes),
            snapshots: HashMap::new(),
            sessions: HashSet::new(),
            image_dir: None,
            image_sizes: HashMap::new(),
            image_created_at: HashMap::new(),
            image_bytes: 0,
            unattached_images: HashMap::new(),
            host_pid: None,
            stable_ids: HashMap::new(),
        }
    }

    fn prune_tombstones(&mut self, session: &str) {
        let mut terminal = self
            .snapshots
            .iter()
            .filter(|(_, snapshot)| {
                snapshot.session == session && snapshot.state != SnapshotState::Live
            })
            .map(|(id, snapshot)| (id.clone(), snapshot.captured_at))
            .collect::<Vec<_>>();
        terminal.sort_by_key(|(_, captured_at)| *captured_at);
        let excess = terminal
            .len()
            .saturating_sub(MAX_SNAPSHOT_TOMBSTONES_PER_SESSION);
        for (id, _) in terminal.into_iter().take(excess) {
            self.snapshots.remove(&id);
        }
    }

    fn delete_image(&mut self, path: &Path) -> bool {
        let size = self.image_sizes.remove(path);
        self.image_created_at.remove(path);
        if let Some(size) = size {
            self.image_bytes = self.image_bytes.saturating_sub(size);
        }
        let _ = std::fs::remove_file(path);
        size.is_some()
    }

    fn track_image(&mut self, path: PathBuf, size: usize) {
        if let Some(previous) = self.image_sizes.insert(path.clone(), size) {
            self.image_bytes = self.image_bytes.saturating_sub(previous);
        }
        self.image_created_at.insert(path, Instant::now());
        self.image_bytes = self.image_bytes.saturating_add(size);
    }

    fn make_room_for_image(&mut self, required: usize) -> bool {
        while self.image_bytes.saturating_add(required) > MAX_IMAGE_DIR_BYTES {
            let Some(oldest_path) = self
                .image_created_at
                .iter()
                .min_by_key(|(_, created_at)| *created_at)
                .map(|(path, _)| path.clone())
            else {
                return false;
            };

            for snapshot in self.snapshots.values_mut() {
                if snapshot.image_path.as_ref() == Some(&oldest_path) {
                    snapshot.state = SnapshotState::Evicted;
                    snapshot.elements = None;
                    snapshot.image_path = None;
                    break;
                }
            }
            self.unattached_images.remove(&oldest_path);
            self.delete_image(&oldest_path);
        }
        true
    }

    fn attach_snapshot_image(&mut self, snapshot_id: &str, path: PathBuf) -> bool {
        if let Some(snapshot) = self.snapshots.get_mut(snapshot_id) {
            snapshot.image_path = Some(path);
            true
        } else {
            self.delete_image(&path);
            false
        }
    }

    fn register_unattached_image(&mut self, session: String, path: PathBuf) {
        if self.sessions.contains(&session) {
            self.unattached_images.insert(
                path,
                UnattachedImage {
                    session,
                    captured_at: Instant::now(),
                },
            );
        } else {
            self.delete_image(&path);
        }
    }

    fn reap_expired(&mut self, now: Instant) {
        let mut retired_images = Vec::new();
        for snapshot in self.snapshots.values_mut() {
            if snapshot.state == SnapshotState::Live
                && now >= snapshot.captured_at
                && now.duration_since(snapshot.captured_at) >= SNAPSHOT_TTL
            {
                snapshot.state = SnapshotState::Expired;
                snapshot.elements = None;
                if let Some(path) = snapshot.image_path.take() {
                    retired_images.push(path);
                }
            }
        }

        let expired_unattached = self
            .unattached_images
            .iter()
            .filter(|(_, image)| {
                now >= image.captured_at && now.duration_since(image.captured_at) >= SNAPSHOT_TTL
            })
            .map(|(path, _)| path.clone())
            .collect::<Vec<_>>();
        for path in expired_unattached {
            self.unattached_images.remove(&path);
            retired_images.push(path);
        }

        for path in retired_images {
            self.delete_image(&path);
        }
        let sessions = self
            .snapshots
            .values()
            .filter(|snapshot| snapshot.state != SnapshotState::Live)
            .map(|snapshot| snapshot.session.clone())
            .collect::<HashSet<_>>();
        for session in sessions {
            self.prune_tombstones(&session);
        }
    }

    fn register_snapshot(&mut self, id: String, snapshot: Snapshot) {
        self.reap_expired(Instant::now());
        let mut retired_images = Vec::new();

        for existing in self.snapshots.values_mut() {
            if existing.state == SnapshotState::Live
                && existing.session == snapshot.session
                && existing.pid == snapshot.pid
                && existing.hwnd == snapshot.hwnd
            {
                existing.state = SnapshotState::Superseded;
                existing.elements = None;
                if let Some(path) = existing.image_path.take() {
                    retired_images.push(path);
                }
            }
        }

        let mut live = self
            .snapshots
            .iter()
            .filter(|(_, existing)| {
                existing.state == SnapshotState::Live && existing.session == snapshot.session
            })
            .map(|(id, existing)| (id.clone(), existing.captured_at))
            .collect::<Vec<_>>();
        live.sort_by_key(|(_, captured_at)| *captured_at);
        while live.len() >= MAX_SNAPSHOTS_PER_SESSION {
            let (id, _) = live.remove(0);
            if let Some(existing) = self.snapshots.get_mut(&id) {
                existing.state = SnapshotState::Evicted;
                existing.elements = None;
                if let Some(path) = existing.image_path.take() {
                    retired_images.push(path);
                }
            }
        }

        let session = snapshot.session.clone();
        self.snapshots.insert(id, snapshot);
        for path in retired_images {
            self.delete_image(&path);
        }
        self.prune_tombstones(&session);
    }

    fn resolve_snapshot(
        &mut self,
        session: &str,
        id: &str,
    ) -> Result<Snapshot, (i32, &'static str)> {
        self.reap_expired(Instant::now());
        let snapshot = self.snapshots.get(id).ok_or((-32001, "snapshot_unknown"))?;
        if snapshot.session != session {
            return Err((-32001, "snapshot_unknown"));
        }
        if snapshot.state != SnapshotState::Live {
            return Err((-32001, snapshot.state.error_code()));
        }
        Ok(snapshot.clone())
    }

    fn spend_snapshot(&mut self, id: &str) -> Result<Snapshot, (i32, &'static str)> {
        self.reap_expired(Instant::now());
        let (snapshot, image_path) = {
            let snapshot = self
                .snapshots
                .get_mut(id)
                .ok_or((-32001, "snapshot_unknown"))?;
            if snapshot.state != SnapshotState::Live {
                return Err((-32001, snapshot.state.error_code()));
            }
            snapshot.state = SnapshotState::Spent;
            let image_path = snapshot.image_path.take();
            let quoted = snapshot.clone();
            snapshot.elements = None;
            (quoted, image_path)
        };
        if let Some(path) = image_path {
            self.delete_image(&path);
        }
        self.prune_tombstones(&snapshot.session);
        Ok(snapshot)
    }

    fn end_session(&mut self, session: &str) -> (usize, usize) {
        self.sessions.remove(session);
        self.reap_expired(Instant::now());
        let snapshot_ids = self
            .snapshots
            .iter()
            .filter(|(_, snapshot)| snapshot.session == session)
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        let mut released_snapshots = 0;
        let mut released_images = 0;
        for id in snapshot_ids {
            if let Some(snapshot) = self.snapshots.remove(&id) {
                if snapshot.state == SnapshotState::Live {
                    released_snapshots += 1;
                }
                if let Some(path) = snapshot.image_path {
                    released_images += usize::from(self.delete_image(&path));
                }
            }
        }

        let image_paths = self
            .unattached_images
            .iter()
            .filter(|(_, image)| image.session == session)
            .map(|(path, _)| path.clone())
            .collect::<Vec<_>>();
        for path in image_paths {
            self.unattached_images.remove(&path);
            released_images += usize::from(self.delete_image(&path));
        }
        (released_snapshots, released_images)
    }
}

#[derive(Debug)]
struct Work {
    key: String,
    id: Option<Value>,
    method: String,
    params: Value,
    cancelled: Arc<AtomicBool>,
    dispatch_started: Arc<AtomicBool>,
}

#[derive(Debug)]
struct WorkerResult {
    key: String,
    id: Option<Value>,
    result: Result<Value, (i32, &'static str)>,
}

#[derive(Debug)]
struct Pending {
    id: Option<Value>,
    cancelled: Arc<AtomicBool>,
    dispatch_started: Arc<AtomicBool>,
}

fn main() {
    platform::initialize_process();
    // stdin is read independently so the control plane can still settle a
    // cancel/shutdown while a UIA provider is blocked in the worker.
    let (input_tx, input_rx) = mpsc::channel::<Option<String>>();
    thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            if input_tx.send(line.ok()).is_err() {
                return;
            }
        }
        let _ = input_tx.send(None);
    });

    let (work_tx, work_rx) = mpsc::sync_channel::<Work>(32);
    let (result_tx, result_rx) = mpsc::channel::<WorkerResult>();
    thread::spawn(move || worker_loop(work_rx, result_tx));

    let mut out = RpcOutput::new();
    let mut pending = HashMap::<String, Pending>::new();
    let mut next_key = 0u64;
    let mut input_closed = false;
    let mut eof_deadline = None;
    let mut next_parent_check = Instant::now() + Duration::from_secs(2);

    while !input_closed || !pending.is_empty() {
        while let Ok(result) = result_rx.try_recv() {
            pending.remove(&result.key);
            match result.result {
                Ok(value) => write_rpc(&mut out, result.id, Some(value), None),
                Err((code, message)) => write_rpc(&mut out, result.id, None, Some((code, message))),
            }
        }

        // The stdio pipe is not a sufficient parent-death signal on Windows:
        // a host can crash while another inherited handle keeps the pipe open.
        // Poll the PID declared in host.hello and terminate the native child
        // without leaving UIA/WGC state behind.
        if Instant::now() >= next_parent_check {
            next_parent_check = Instant::now() + Duration::from_secs(2);
            let host_pid = HOST_PID.load(Ordering::Acquire);
            if host_pid != 0 && !platform::process_alive(host_pid as u32) {
                break;
            }
        }

        match input_rx.recv_timeout(Duration::from_millis(10)) {
            Ok(Some(line)) => {
                if line.trim().is_empty() {
                    continue;
                }
                let raw = match serde_json::from_str::<Value>(&line) {
                    Ok(raw) => raw,
                    Err(_) => {
                        write_rpc(&mut out, None, None, Some((-32700, "parse_error")));
                        continue;
                    }
                };
                let request = match serde_json::from_value::<RpcRequest>(raw.clone()) {
                    Ok(request) => request,
                    Err(_) => {
                        write_rpc(
                            &mut out,
                            raw.get("id").cloned(),
                            None,
                            Some((-32600, "invalid_request")),
                        );
                        continue;
                    }
                };
                if request.jsonrpc.as_deref() != Some("2.0") || request.method.is_none() {
                    write_rpc(
                        &mut out,
                        request.id,
                        None,
                        Some((-32600, "invalid_request")),
                    );
                    continue;
                }
                let method = request.method.clone().unwrap_or_default();
                if method == "$/cancel" {
                    handle_cancel(request.id, request.params, &mut pending, &mut out);
                    continue;
                }
                if method == "shutdown" {
                    write_rpc(
                        &mut out,
                        request.id,
                        Some(
                            json!({"ok": true, "graceMs": SHUTDOWN_GRACE_MS, "worker": "detached_after_grace"}),
                        ),
                        None,
                    );
                    let _ = out.flush();
                    break;
                }

                next_key = next_key.wrapping_add(1);
                let key = format!("r{next_key}");
                let cancelled = Arc::new(AtomicBool::new(false));
                let dispatch_started = Arc::new(AtomicBool::new(false));
                pending.insert(
                    key.clone(),
                    Pending {
                        id: request.id.clone(),
                        cancelled: cancelled.clone(),
                        dispatch_started: dispatch_started.clone(),
                    },
                );
                let work = Work {
                    key: key.clone(),
                    id: request.id,
                    method,
                    params: request.params,
                    cancelled,
                    dispatch_started,
                };
                match work_tx.try_send(work) {
                    Ok(()) => {}
                    Err(TrySendError::Full(_)) => {
                        pending.remove(&key);
                        write_rpc(&mut out, None, None, Some((-32003, "worker_queue_full")));
                    }
                    Err(TrySendError::Disconnected(_)) => {
                        pending.remove(&key);
                        write_rpc(&mut out, None, None, Some((-32004, "worker_unavailable")));
                    }
                }
            }
            Ok(None) => {
                input_closed = true;
                eof_deadline = Some(Instant::now() + Duration::from_millis(2_000));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                input_closed = true;
                eof_deadline.get_or_insert_with(|| Instant::now() + Duration::from_millis(2_000));
            }
        }
        if input_closed && eof_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            break;
        }
    }
}

/// Keep stdout off the control thread. A full bounded queue is a typed
/// backpressure failure (exit 2), rather than an unbounded/orphaning write
/// block when the supervising host stops reading.
struct RpcOutput {
    sender: SyncSender<Vec<u8>>,
}

impl RpcOutput {
    fn new() -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Vec<u8>>(64);
        thread::spawn(move || {
            let stdout = io::stdout();
            let mut out = io::BufWriter::new(stdout.lock());
            for chunk in receiver {
                if out.write_all(&chunk).is_err() || out.flush().is_err() {
                    std::process::exit(2);
                }
            }
        });
        Self { sender }
    }
}

impl Write for RpcOutput {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.sender
            .try_send(buf.to_vec())
            .map_err(|error| io::Error::new(io::ErrorKind::BrokenPipe, error.to_string()))?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn handle_cancel(
    response_id: Option<Value>,
    params: Value,
    pending: &mut HashMap<String, Pending>,
    out: &mut impl Write,
) {
    let Some(parameters) = params.as_object() else {
        if let Some(id) = response_id {
            write_rpc(
                out,
                Some(id),
                Some(
                    json!({"cancelled":false,"reason":"invalid_cancel_params","settlement":"original_request_must_settle","graceMs":2000}),
                ),
                None,
            );
        }
        return;
    };
    let requested_id = parameters.get("id");
    let target = pending
        .iter()
        .find(|(_, item)| requested_id.is_none() || item.id.as_ref() == requested_id)
        .map(|(key, _)| key.clone());
    let Some(key) = target else {
        if let Some(id) = response_id {
            write_rpc(
                out,
                Some(id),
                Some(json!({"cancelled":false,"settlement":"no_pending_request","graceMs":2000})),
                None,
            );
        }
        return;
    };
    let item = pending.get(&key).expect("pending key selected");
    item.cancelled.store(true, Ordering::Release);
    let started = item.dispatch_started.load(Ordering::Acquire);
    if let Some(id) = response_id {
        write_rpc(
            out,
            Some(id),
            Some(json!({
                "cancelled": true,
                "pendingRequestId": item.id,
                "dispatchStarted": started,
                "settlement": "original_request_must_settle",
                "graceMs": 2000
            })),
            None,
        );
    }
}

fn worker_loop(work_rx: Receiver<Work>, result_tx: mpsc::Sender<WorkerResult>) {
    #[cfg(windows)]
    platform::initialize_worker();
    let mut registry = Registry::default();
    for work in work_rx {
        let result = if work.cancelled.load(Ordering::Acquire) {
            if work.method == "act" {
                cancel_queued_action(work.params, &mut registry)
            } else {
                Err((-32001, "cancelled"))
            }
        } else {
            work.dispatch_started.store(true, Ordering::Release);
            dispatch(&work.method, work.params, &mut registry, &work.cancelled)
        };
        let _ = result_tx.send(WorkerResult {
            key: work.key,
            id: work.id,
            result,
        });
    }
}

fn cancel_queued_action(
    params: Value,
    registry: &mut Registry,
) -> Result<Value, (i32, &'static str)> {
    let snapshot_id = params
        .get("snapshotId")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_snapshot"))?;
    let _ = registry.spend_snapshot(snapshot_id)?;
    Ok(
        json!({"outcome":{"tier":"cancelled-before-dispatch","path":"none","status":"refused","reason":"cancelled_before_dispatch","effect":"none","snapshotSpent":true,"verification":"no_mutation"}}),
    )
}

fn write_rpc(
    out: &mut impl Write,
    id: Option<Value>,
    result: Option<Value>,
    error: Option<(i32, &str)>,
) {
    let mut response = if let Some((code, message)) = error {
        json!({"jsonrpc":"2.0", "id":id, "error":{"code":code,"message":message}})
    } else {
        json!({"jsonrpc":"2.0", "id":id, "result":result.unwrap_or_else(|| json!({}))})
    };
    let mut line = serde_json::to_vec(&response).unwrap_or_else(|_| b"{}".to_vec());
    if line.len() > MAX_RESPONSE_BYTES && error.is_none() {
        let bytes = line.len();
        response = json!({
            "jsonrpc":"2.0",
            "id":id,
            "error":{
                "code":-32002,
                "message":"response_too_large",
                "data":{"bytes":bytes,"limit":MAX_RESPONSE_BYTES}
            }
        });
        line = serde_json::to_vec(&response).unwrap();
    } else if line.len() > MAX_RESPONSE_BYTES {
        line = serde_json::to_vec(&json!({
            "jsonrpc":"2.0",
            "id":id,
            "error":{
                "code":-32002,
                "message":"response_too_large",
                "data":{"bytes":line.len(),"limit":MAX_RESPONSE_BYTES}
            }
        }))
        .unwrap();
    }
    if out.write_all(&line).is_err() || out.write_all(b"\n").is_err() {
        std::process::exit(2);
    }
    let _ = out.flush();
}

fn response_is_oversized(response: &Value) -> bool {
    serde_json::to_vec(response)
        .map(|line| line.len() > MAX_RESPONSE_BYTES)
        .unwrap_or(true)
}

fn dispatch(
    method: &str,
    params: Value,
    registry: &mut Registry,
    cancelled: &AtomicBool,
) -> Result<Value, (i32, &'static str)> {
    if method == "host.hello" {
        return host_hello(params, registry);
    }
    if registry.image_dir.is_none() {
        return Err((-32001, "handshake_required"));
    }
    registry.reap_expired(Instant::now());
    match method {
        "session.begin" => session_begin(params, registry),
        "session.end" => session_end(params, registry),
        "window.list" => generic_window_list(),
        "apps.list" => generic_apps_list(),
        "observe" => generic_observe(params, registry),
        "dispatch.element" => generic_dispatch_element(params, registry, cancelled),
        "dispatch.key" => generic_dispatch_key(params, registry),
        // The protocol keeps this endpoint for old callers, but coordinate
        // mutation is never a capability and must not resolve or spend a
        // snapshot before refusing.
        "dispatch.point" => Ok(generic_point_refusal(&params)),
        "screen.capture" => generic_screen_capture(params, registry),
        "permissions.check" => Ok(json!({
            "ok": true,
            "accessibility": cfg!(windows),
            "screenRecording": cfg!(windows),
            "prompted": false
        })),
        "apps.launch" => generic_launch(),
        // Transport regression seam; never used by the model-facing runtime.
        "debug_sleep" => {
            let millis = params
                .get("ms")
                .and_then(Value::as_u64)
                .unwrap_or(100)
                .min(5_000);
            std::thread::sleep(Duration::from_millis(millis));
            Ok(json!({"ok":true,"sleptMs":millis}))
        }
        _ => Err((-32601, "method_not_found")),
    }
}

fn host_hello(params: Value, registry: &mut Registry) -> Result<Value, (i32, &'static str)> {
    if registry.image_dir.is_some() {
        return Err((-32602, "host_hello_must_be_first"));
    }
    let protocol = params
        .get("protocol")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_protocol"))?;
    if protocol != PROTOCOL {
        return Err((-32000, "protocol_version_mismatch"));
    }
    if params.get("allowGlobalPointer").and_then(Value::as_bool) != Some(false) {
        return Err((-32602, "global_pointer_must_be_false"));
    }
    let host_pid = params
        .get("hostPid")
        .and_then(Value::as_u64)
        .filter(|pid| *pid > 0 && *pid <= u32::MAX as u64)
        .ok_or((-32602, "invalid_host_pid"))? as u32;
    let image_dir = params
        .get("imageDir")
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .ok_or((-32602, "invalid_image_dir"))?;
    if !image_dir.is_absolute() {
        return Err((-32602, "image_dir_must_be_absolute"));
    }
    create_dir_all(&image_dir).map_err(|_| (-32603, "image_dir_unavailable"))?;
    let probe = image_dir.join(".maka-cu-write-probe");
    write(&probe, b"maka.cu/2").map_err(|_| (-32603, "image_dir_unwritable"))?;
    let _ = std::fs::remove_file(probe);
    registry.image_dir = Some(image_dir);
    registry.host_pid = Some(host_pid);
    HOST_PID.store(host_pid as u64, Ordering::Release);
    Ok(json!({
        "ok": true,
        "protocol": PROTOCOL,
        "executor": {
            "name": "maka-cu-windows-rust",
            "version": env!("CARGO_PKG_VERSION"),
            "commit": "local"
        },
        "pid": std::process::id(),
        "capabilities": {
            "captureStream": false,
            "elementActions": ["click", "set_value"],
            "pointActions": [],
            "keyActions": [],
            "imageFormats": ["png"]
        },
        "limits": {
            "snapshotsPerSession": MAX_SNAPSHOTS_PER_SESSION,
            "snapshotTtlMs": SNAPSHOT_TTL.as_millis(),
            "maxElements": MAX_ELEMENTS,
            "maxDepth": 64,
            "maxTextChars": 500,
            "maxResponseBytes": MAX_RESPONSE_BYTES,
            "settleCeilingMs": 2500,
            "treeWalkCeilingMs": 6000,
            "shutdownGraceMs": SHUTDOWN_GRACE_MS,
            "imageDirBudgetBytes": MAX_IMAGE_DIR_BYTES
        }
    }))
}

fn session_id(params: &Value) -> Result<String, (i32, &'static str)> {
    params
        .get("session")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(ToOwned::to_owned)
        .ok_or((-32602, "missing_session"))
}

fn require_session(params: &Value, registry: &Registry) -> Result<String, (i32, &'static str)> {
    let session = session_id(params)?;
    if !registry.sessions.contains(&session) {
        return Err((-32002, "session_unknown"));
    }
    Ok(session)
}

fn session_begin(params: Value, registry: &mut Registry) -> Result<Value, (i32, &'static str)> {
    let session = session_id(&params)?;
    if !registry.sessions.insert(session.clone()) {
        return Err((-32602, "session_already_started"));
    }
    Ok(json!({"ok":true,"session":session,"captureScope":"window"}))
}

fn session_end(params: Value, registry: &mut Registry) -> Result<Value, (i32, &'static str)> {
    let session = session_id(&params)?;
    if !registry.sessions.contains(&session) {
        return Ok(json!({
            "ok":true,
            "session":session,
            "released":{"snapshots":0,"images":0,"streams":0}
        }));
    }
    let (released_snapshots, released_images) = registry.end_session(&session);
    Ok(
        json!({"ok":true,"session":session,"released":{"snapshots":released_snapshots,"images":released_images,"streams":0}}),
    )
}

fn generic_domain_error(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message,"detail":{}}})
}

fn generic_dispatch_refusal(params: &Value, code: &str, message: &str, tier: &str) -> Value {
    json!({
        "ok": false,
        "toolCallId": params.get("toolCallId").cloned().unwrap_or(Value::Null),
        "outcome":"refused",
        "tier":tier,
        "path":"none",
        "effect":"unverifiable",
        "verification":{"method":"none","observedChange":false},
        "error":{"code":code,"message":message,"detail":{}}
    })
}

fn generic_dispatch_element_failure(
    params: &Value,
    outcome: &str,
    path: &str,
    effect: &str,
    verification_method: &str,
    code: &str,
    message: &str,
    reason: Option<&str>,
    snapshot_spent: bool,
) -> Value {
    let mut detail = serde_json::Map::new();
    detail.insert(
        "snapshotSpent".to_owned(),
        json!(if snapshot_spent { 1 } else { 0 }),
    );
    if let Some(reason) = reason {
        detail.insert("reason".to_owned(), json!(reason));
    }
    json!({
        "ok": false,
        "toolCallId": params.get("toolCallId").cloned().unwrap_or(Value::Null),
        "outcome": outcome,
        "tier": "ax",
        "path": path,
        "effect": effect,
        "verification": {"method": verification_method, "observedChange": false},
        "error": {"code": code, "message": message, "detail": detail}
    })
}

fn generic_dispatch_element_refusal(params: &Value, code: &str, message: &str) -> Value {
    generic_dispatch_element_failure(
        params,
        "refused",
        "none",
        "unverifiable",
        "none",
        code,
        message,
        None,
        false,
    )
}

fn snapshot_refusal(params: &Value, code: &'static str, tier: &str) -> Value {
    let message = match code {
        "snapshot_spent" => "The snapshot has already been spent.",
        "snapshot_superseded" => "A newer snapshot superseded this snapshot.",
        "snapshot_expired" => "The snapshot has expired.",
        "snapshot_evicted" => {
            "The snapshot was evicted because the session exceeded its frame budget."
        }
        _ => "The snapshot is no longer available.",
    };
    generic_dispatch_refusal(params, code, message, tier)
}

fn generic_point_refusal(params: &Value) -> Value {
    generic_dispatch_refusal(
        params,
        "unsupported_action",
        "The requested point action is not supported by this executor.",
        "coordinate-background",
    )
}

fn digest_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("sha256:{:x}", hasher.finalize())
}

fn digest_value(value: &Value) -> String {
    digest_bytes(&serde_json::to_vec(value).unwrap_or_default())
}

fn normalized_action_names(raw: &[&'static str]) -> Vec<String> {
    let mut names = raw
        .iter()
        .filter_map(|action| match *action {
            "click_element" => Some("press"),
            "select" => Some("pick"),
            "toggle" => Some("confirm"),
            "scroll" => Some("scroll_down"),
            _ => None,
        })
        .map(str::to_owned)
        .collect::<Vec<_>>();
    names.sort();
    names.dedup();
    names
}

fn semantic_role(control_type: &str) -> &'static str {
    match control_type.strip_prefix("UIA.ControlType.") {
        Some("50000") => "button",
        Some("50001") => "calendar",
        Some("50002") => "checkbox",
        Some("50003") => "combobox",
        Some("50004") => "edit",
        Some("50005") => "link",
        Some("50006") => "image",
        Some("50007") => "listitem",
        Some("50008") => "list",
        Some("50009") => "menu",
        Some("50010") => "menubar",
        Some("50011") => "menuitem",
        Some("50012") => "progressbar",
        Some("50013") => "radiobutton",
        Some("50014") => "scrollbar",
        Some("50015") => "slider",
        Some("50016") => "spinner",
        Some("50017") => "statusbar",
        Some("50018") => "tab",
        Some("50019") => "tabitem",
        Some("50020") => "text",
        Some("50021") => "toolbar",
        Some("50022") => "tooltip",
        Some("50023") => "tree",
        Some("50024") => "treeitem",
        Some("50025") => "custom",
        Some("50026") => "group",
        Some("50027") => "thumb",
        Some("50028") => "datagrid",
        Some("50029") => "dataitem",
        Some("50030") => "document",
        Some("50031") => "splitbutton",
        Some("50032") => "window",
        Some("50033") => "pane",
        Some("50034") => "header",
        Some("50035") => "headeritem",
        Some("50036") => "table",
        Some("50037") => "titlebar",
        Some("50038") => "separator",
        Some("50039") => "semanticzoom",
        Some("50040") => "appbar",
        _ => "unknown",
    }
}

fn element_digest_for_observed(element: &ObservedElement, window_bounds: [i32; 4]) -> String {
    let [x, y, width, height] = element.bounds;
    let frame = json!([x - window_bounds[0], y - window_bounds[1], width, height]);
    let value_digest = element
        .value
        .as_deref()
        .map(|value| digest_bytes(value.as_bytes()));
    // This is the single canonical input assembly used by both observe and
    // dispatch revalidation. Ancestors and sibling position come from the
    // same UIA TreeWalker path in both observations; they are not inferred
    // from the flat FindAll index.
    digest_value(&json!([
        format!("UIA.ControlType.{}", element.control_type),
        Value::Null,
        if element.automation_id.is_empty() {
            Value::Null
        } else {
            json!(element.automation_id)
        },
        if element.name.is_empty() {
            Value::Null
        } else {
            json!(element.name)
        },
        Value::Null,
        value_digest,
        frame,
        normalized_action_names(&element.actions),
        &element.ancestor_roles,
        element.sibling_index,
    ]))
}

fn window_digest(elements: &[Value], bounds: &Value, title: &Value) -> String {
    let mut digests = elements
        .iter()
        .filter_map(|element| element.get("digest").and_then(Value::as_str))
        .map(str::to_owned)
        .collect::<Vec<_>>();
    digests.sort();
    digest_value(&json!([digests, bounds, title]))
}

fn rect_value(value: Option<&Value>, fallback: Value) -> Value {
    let Some(array) = value.and_then(Value::as_array) else {
        return fallback;
    };
    if array.len() < 4 {
        return fallback;
    }
    json!({
        "x": array[0].as_f64().unwrap_or(0.0),
        "y": array[1].as_f64().unwrap_or(0.0),
        "width": array[2].as_f64().unwrap_or(0.0),
        "height": array[3].as_f64().unwrap_or(0.0)
    })
}

fn generic_windows() -> Result<Vec<Value>, (i32, &'static str)> {
    let raw = platform::list_windows()?;
    let Some(windows) = raw.get("windows").and_then(Value::as_array) else {
        return Err((-32603, "window_inventory_invalid"));
    };
    let display_id = platform::displays()
        .ok()
        .and_then(|values| {
            values
                .first()
                .and_then(|value| value.get("displayId"))
                .cloned()
        })
        .unwrap_or_else(|| json!("windows-primary"));
    Ok(windows
        .iter()
        .enumerate()
        .filter_map(|(index, window)| {
            let hwnd = window.get("hwnd").and_then(Value::as_i64)?;
            let pid = window.get("pid").and_then(Value::as_u64)?;
            if hwnd <= 0 || pid == 0 || pid > u32::MAX as u64 {
                return None;
            }
            let title = window.get("title").cloned().unwrap_or(Value::Null);
            let bounds = rect_value(
                window.get("bounds"),
                json!({"x":0.0,"y":0.0,"width":1.0,"height":1.0}),
            );
            let app_id = window
                .get("appId")
                .cloned()
                .unwrap_or_else(|| json!(format!("pid:{pid}")));
            Some(json!({
                "pid":pid,
                "windowId":hwnd,
                "appId":app_id,
                "appName":title,
                "title":title,
                "bounds":bounds,
                "layer":0,
                "zIndex":(windows.len() - index) as i64,
                "onScreen":window.get("isOffscreen").and_then(Value::as_bool) != Some(true),
                "displayId":display_id
            }))
        })
        .collect())
}

fn generic_window_list() -> Result<Value, (i32, &'static str)> {
    Ok(json!({"ok":true,"windows":generic_windows()?}))
}

fn generic_launch() -> Result<Value, (i32, &'static str)> {
    Ok(generic_domain_error(
        "unsupported_action",
        "Launching applications is disabled by the background-only Windows executor.",
    ))
}

fn generic_apps_list() -> Result<Value, (i32, &'static str)> {
    let mut apps = HashMap::<String, (u32, String, usize)>::new();
    for window in generic_windows()? {
        let Some(pid) = window.get("pid").and_then(Value::as_u64) else {
            continue;
        };
        let title = window
            .get("appName")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let app_id = window
            .get("appId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let entry = apps.entry(app_id).or_insert((pid as u32, title, 0));
        entry.2 += 1;
    }
    let values = apps
        .into_iter()
        .map(|(app_id, (pid, name, count))| {
            json!({"appId":app_id,"pid":pid,"name":name,"windowCount":count})
        })
        .collect::<Vec<_>>();
    Ok(json!({"ok":true,"apps":values}))
}

fn target_window(params: &Value) -> Result<(isize, u32), (i32, &'static str)> {
    let target = params
        .get("target")
        .and_then(Value::as_object)
        .ok_or((-32602, "missing_target"))?;
    match target.get("kind").and_then(Value::as_str) {
        Some("window") => {
            let pid = target
                .get("pid")
                .and_then(Value::as_u64)
                .filter(|pid| *pid > 0 && *pid <= u32::MAX as u64)
                .ok_or((-32602, "invalid_target_pid"))? as u32;
            let hwnd = target
                .get("windowId")
                .and_then(Value::as_i64)
                .filter(|hwnd| *hwnd > 0)
                .ok_or((-32602, "invalid_target_window"))?;
            Ok((hwnd as isize, pid))
        }
        Some("app") => {
            let app = target
                .get("app")
                .and_then(Value::as_str)
                .ok_or((-32602, "invalid_target_app"))?;
            let windows = generic_windows()?;
            let window = windows
                .iter()
                .filter(|window| window.get("appId").and_then(Value::as_str) == Some(app))
                .find(|window| window.get("onScreen").and_then(Value::as_bool) != Some(false))
                .or_else(|| {
                    windows
                        .iter()
                        .find(|window| window.get("appId").and_then(Value::as_str) == Some(app))
                });
            let window = window.ok_or((-32001, "app_not_found"))?;
            let pid = window
                .get("pid")
                .and_then(Value::as_u64)
                .filter(|pid| *pid > 0 && *pid <= u32::MAX as u64)
                .ok_or((-32001, "app_not_found"))? as u32;
            let hwnd = window
                .get("windowId")
                .and_then(Value::as_i64)
                .ok_or((-32001, "app_not_found"))?;
            Ok((hwnd as isize, pid))
        }
        _ => Err((-32602, "invalid_target_kind")),
    }
}

fn store_capture(
    registry: &mut Registry,
    image_id: &str,
    raw: Value,
) -> Result<StoredImage, (i32, &'static str)> {
    let frame = raw
        .get("frame")
        .and_then(Value::as_object)
        .ok_or((-32001, "capture_failed"))?;
    let encoded = frame
        .get("base64")
        .and_then(Value::as_str)
        .ok_or((-32001, "capture_failed"))?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| (-32001, "capture_failed"))?;
    let width = frame.get("width").and_then(Value::as_i64).unwrap_or(0);
    let height = frame.get("height").and_then(Value::as_i64).unwrap_or(0);
    let scale = frame
        .get("scaleFactor")
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite() && *value > 0.0)
        .unwrap_or(1.0);
    if width <= 0 || height <= 0 {
        return Err((-32001, "capture_failed"));
    }
    if !registry.make_room_for_image(bytes.len()) {
        return Err((-32001, "image_write_failed"));
    }
    let directory = registry
        .image_dir
        .as_ref()
        .ok_or((-32001, "handshake_required"))?;
    let safe_id = image_id
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
        .collect::<String>();
    let path = directory.join(format!("{safe_id}.png"));
    write(&path, &bytes).map_err(|_| (-32001, "image_write_failed"))?;
    registry.track_image(path.clone(), bytes.len());
    Ok(StoredImage {
        path: path.clone(),
        value: json!({
            "path":path,
            "format":"png",
            "widthPx":width,
            "heightPx":height,
            "byteLength":bytes.len(),
            "sha256":digest_bytes(&bytes),
            "scale":scale
        }),
    })
}

fn generic_image_for_window(
    registry: &mut Registry,
    hwnd: isize,
    generation: &str,
    image_id: &str,
    snapshot_id: &str,
) -> Result<Option<Value>, (i32, &'static str)> {
    let raw = platform::capture(json!({
        "hwnd":hwnd,
        "windowGeneration":generation
    }))?;
    if raw.get("status").and_then(Value::as_str) != Some("available") {
        return Ok(None);
    }
    let stored = store_capture(registry, image_id, raw)?;
    if !registry.attach_snapshot_image(snapshot_id, stored.path) {
        return Err((-32001, "snapshot_unknown"));
    }
    Ok(Some(stored.value))
}

fn generic_observe(params: Value, registry: &mut Registry) -> Result<Value, (i32, &'static str)> {
    let requested = params
        .get("maxElements")
        .and_then(Value::as_u64)
        .unwrap_or(MAX_ELEMENTS as u64)
        .clamp(1, MAX_ELEMENTS as u64) as usize;
    let mut max_elements = requested;
    let mut response_truncated = false;
    for attempt in 0..4 {
        let result =
            generic_observe_once(params.clone(), registry, max_elements, response_truncated)?;
        let envelope = json!({"jsonrpc":"2.0","id":Value::Null,"result":result});
        if !response_is_oversized(&envelope) {
            return Ok(envelope["result"].clone());
        }
        if attempt == 3 || max_elements == 1 {
            // Keep the complete, protocol-shaped result intact. write_rpc
            // will turn it into response_too_large with byte/limit details.
            return Ok(envelope["result"].clone());
        }
        max_elements = max_elements.div_ceil(2);
        response_truncated = true;
    }
    unreachable!("the observation budget loop always returns")
}

fn generic_observe_once(
    params: Value,
    registry: &mut Registry,
    max_elements: usize,
    response_truncated: bool,
) -> Result<Value, (i32, &'static str)> {
    let session = require_session(&params, registry)?;
    let (hwnd, requested_pid) = target_window(&params)?;
    let Some(meta) = generic_windows()?.into_iter().find(|window| {
        window.get("windowId").and_then(Value::as_i64) == Some(hwnd as i64)
            && window.get("pid").and_then(Value::as_u64) == Some(requested_pid as u64)
    }) else {
        return Ok(generic_domain_error(
            "window_gone",
            "The requested window is no longer available.",
        ));
    };
    let raw = observe(
        &session,
        json!({"hwnd":hwnd,"maxElements":max_elements}),
        registry,
    );
    let raw = match raw {
        Ok(raw) => raw,
        Err((-32001, "stale_target_revalidate_failed")) => {
            return Ok(generic_domain_error(
                "process_replaced",
                "The requested window identity changed.",
            ));
        }
        Err((-32001, "target_window_gone")) => {
            return Ok(generic_domain_error(
                "window_gone",
                "The requested window is no longer available.",
            ));
        }
        Err(_) => {
            return Ok(generic_domain_error(
                "capture_failed",
                "The window could not be observed.",
            ))
        }
    };
    let snapshot_id = raw
        .get("snapshotId")
        .and_then(Value::as_str)
        .ok_or((-32603, "snapshot_invalid"))?;
    let generation = raw
        .get("windowGeneration")
        .and_then(Value::as_str)
        .ok_or((-32603, "snapshot_generation_missing"))?;
    let nodes = raw
        .get("tree")
        .and_then(|tree| tree.get("nodes"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let stable_ids = {
        let key = (requested_pid, hwnd);
        let mut assigned = Vec::with_capacity(nodes.len());
        for node in &nodes {
            let runtime = node
                .get("runtimeId")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_i64)
                        .map(|value| value as i32)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            if runtime.is_empty() {
                assigned.push(None);
                continue;
            }
            let existing = registry
                .stable_ids
                .get(&key)
                .and_then(|values| values.get(&runtime).copied());
            let stable = existing.unwrap_or_else(|| {
                let value = registry.next.fetch_add(1, Ordering::Relaxed);
                registry
                    .stable_ids
                    .entry(key)
                    .or_default()
                    .insert(runtime, value);
                value
            });
            assigned.push(Some(stable));
        }
        assigned
    };
    let bounds = meta
        .get("bounds")
        .cloned()
        .unwrap_or_else(|| json!({"x":0.0,"y":0.0,"width":1.0,"height":1.0}));
    let origin_x = bounds.get("x").and_then(Value::as_f64).unwrap_or(0.0);
    let origin_y = bounds.get("y").and_then(Value::as_f64).unwrap_or(0.0);
    let elements = nodes
        .iter()
        .enumerate()
        .filter_map(|(index, node)| {
            let token = node.get("token")?.as_str()?;
            let title = node.get("name").cloned().unwrap_or(Value::Null);
            let role = node
                .get("controlType")
                .and_then(Value::as_str)
                .map(semantic_role)
                .unwrap_or("unknown");
            let mut actions = Vec::<Value>::new();
            if node
                .get("actions")
                .and_then(Value::as_array)
                .is_some_and(|values| {
                    values.iter().any(|value| {
                        matches!(
                            value.as_str(),
                            Some("click_element" | "select" | "toggle")
                        )
                    })
                })
            {
                actions.push(json!("press"));
            }
            let frame = node
                .get("bounds")
                .and_then(Value::as_array)
                .and_then(|values| {
                    (values.len() >= 4).then(|| {
                        json!({
                            "x":values[0].as_f64().unwrap_or(0.0) - origin_x,
                            "y":values[1].as_f64().unwrap_or(0.0) - origin_y,
                            "width":values[2].as_f64().unwrap_or(0.0),
                            "height":values[3].as_f64().unwrap_or(0.0)
                        })
                    })
                });
            let parent_token = node
                .get("parentRuntimeId")
                .and_then(Value::as_array)
                .and_then(|parent| {
                    nodes.iter().find(|candidate| {
                        candidate
                            .get("runtimeId")
                            .and_then(Value::as_array)
                            == Some(parent)
                    })
                })
                .and_then(|candidate| candidate.get("token"))
                .cloned()
                .unwrap_or(Value::Null);
            Some(json!({
                "token":token,
                "stableId":stable_ids.get(index).and_then(|value| *value).unwrap_or(index as u64),
                "parentToken":parent_token,
                "depth":node.get("depth").and_then(Value::as_u64).unwrap_or(if index == 0 { 0 } else { 1 }),
                "role":role,
                "title":title,
                "axIdentifier":if node.get("automationId").and_then(Value::as_str).is_some_and(|value| !value.is_empty()) { node.get("automationId").cloned().unwrap_or(Value::Null) } else { Value::Null },
                "label":null,
                "value":node.get("value").cloned().unwrap_or(Value::Null),
                "placeholder":null,
                "enabled":node.get("isEnabled").and_then(Value::as_bool).unwrap_or(false),
                "focused":node.get("focused").and_then(Value::as_bool).unwrap_or(false),
                "selected":null,
                "frame":frame,
                "actions":actions,
                "digest":node.get("digest").cloned().unwrap_or(Value::Null),
                "truncated":[]
            }))
        })
        .collect::<Vec<_>>();
    let focused_element_token = nodes.iter().find_map(|node| {
        (node.get("focused").and_then(Value::as_bool) == Some(true))
            .then(|| node.get("token").and_then(Value::as_str))
            .flatten()
    });
    let window_digest = window_digest(
        &elements,
        &bounds,
        &meta.get("title").cloned().unwrap_or(Value::Null),
    );
    let include_image = params
        .get("includeImage")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let image = if include_image {
        generic_image_for_window(registry, hwnd, generation, snapshot_id, snapshot_id)?
    } else {
        None
    };
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    let mut target = meta.clone();
    if let Some(target) = target.as_object_mut() {
        let process_start_time = raw
            .get("target")
            .and_then(|value| value.get("processStartTimeUtc"))
            .cloned()
            .unwrap_or(Value::Null);
        target.insert("processStartTimeUtc".to_owned(), process_start_time);
        target.insert("windowGeneration".to_owned(), json!(generation));
    }
    let snapshot = json!({
        "snapshotId":snapshot_id,
        "capturedAt":timestamp,
        "target":target,
        "windowDigest":window_digest,
        "focusedElementToken":focused_element_token,
        "selectedText":null,
        "image":image,
        "displays":platform::displays().unwrap_or_default(),
        "obscuringRects":[],
        "elements":elements,
        "truncated":{"elements":response_truncated || raw.get("tree").and_then(|tree| tree.get("truncated")).and_then(Value::as_bool).unwrap_or(false),"depth":false}
    });
    if let Some(stored) = registry.snapshots.get_mut(snapshot_id) {
        stored.session = session;
    }
    Ok(json!({"ok":true,"snapshot":snapshot}))
}

fn generic_dispatch_element(
    params: Value,
    registry: &mut Registry,
    cancelled: &AtomicBool,
) -> Result<Value, (i32, &'static str)> {
    let session = require_session(&params, registry)?;
    let snapshot_id = params
        .get("snapshotId")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_snapshot_id"))?;
    let token = params
        .get("elementToken")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_element_token"))?;
    let expected = params
        .get("expectElementDigest")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_element_digest"))?;
    let quoted = match registry.resolve_snapshot(&session, snapshot_id) {
        Ok(snapshot) => snapshot,
        Err((-32001, code)) => return Ok(snapshot_refusal(&params, code, "ax")),
        Err(error) => return Err(error),
    };
    let Some(element) = quoted
        .elements
        .as_ref()
        .and_then(|elements| elements.get(token))
    else {
        return Ok(generic_dispatch_element_refusal(
            &params,
            "element_unknown",
            "The element is not in the snapshot.",
        ));
    };
    if expected != element.digest {
        return Ok(generic_dispatch_element_refusal(
            &params,
            "element_digest_mismatch",
            "The element digest does not match the quoted snapshot.",
        ));
    }
    let action = params
        .get("action")
        .and_then(Value::as_object)
        .ok_or((-32602, "missing_action"))?;
    let kind = action
        .get("kind")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_action_kind"))?;
    if !matches!(kind, "click" | "set_value") {
        return Ok(generic_dispatch_element_refusal(
            &params,
            "unsupported_action",
            "The background-only Windows executor supports only semantic click and set_value.",
        ));
    }
    if kind == "click"
        && (action
            .get("button")
            .and_then(Value::as_str)
            .unwrap_or("left")
            != "left"
            || action.get("count").and_then(Value::as_u64).unwrap_or(1) != 1)
    {
        return Ok(generic_dispatch_element_refusal(
            &params,
            "unsupported_action",
            "This executor supports only one semantic left click.",
        ));
    }
    let (legacy_action, value) = match kind {
        "click" => ("click_element", String::new()),
        "set_value" => (
            "set_value",
            action
                .get("value")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        ),
        _ => {
            return Ok(generic_dispatch_element_refusal(
                &params,
                "unsupported_action",
                "The requested semantic action is not supported by this executor.",
            ));
        }
    };
    let path = if legacy_action == "set_value" {
        "ax_attribute"
    } else {
        "ax_action"
    };
    let raw = act(
        json!({"snapshotId":snapshot_id,"elementToken":token,"action":legacy_action,"value":value}),
        registry,
        cancelled,
    );
    let old = match raw {
        Ok(value) => value,
        Err((-32001, code)) if code.starts_with("snapshot_") => {
            return Ok(snapshot_refusal(&params, code, "ax"));
        }
        Err((-32001, "element_token_unknown_in_snapshot")) => {
            return Ok(generic_dispatch_element_failure(
                &params,
                "refused",
                "none",
                "unverifiable",
                "none",
                "element_unknown",
                "The element is not in the snapshot.",
                Some("element_token_unknown_in_snapshot"),
                true,
            ));
        }
        Err((-32001, "stale_target_revalidate_failed")) => {
            return Ok(generic_dispatch_element_failure(
                &params,
                "refused",
                "none",
                "unverifiable",
                "none",
                "process_replaced",
                "The target process or window changed.",
                Some("stale_target_revalidate_failed"),
                true,
            ));
        }
        Err((-32602, "unsupported_action")) => {
            return Ok(generic_dispatch_element_failure(
                &params,
                "refused",
                "none",
                "unverifiable",
                "none",
                "element_not_actionable",
                "The element does not expose this action.",
                Some("unsupported_action"),
                true,
            ));
        }
        Err((
            -32001,
            reason @ ("element_not_actionable"
            | "element_disabled"
            | "password_field_refused"
            | "value_pattern_readonly"),
        )) => {
            return Ok(generic_dispatch_element_failure(
                &params,
                "refused",
                "none",
                "unverifiable",
                "none",
                "element_not_actionable",
                "The element cannot safely perform this action.",
                Some(reason),
                true,
            ));
        }
        Err((-32001, "invoke_failed")) => {
            return Ok(generic_dispatch_element_failure(
                &params,
                "unknown",
                path,
                "unverifiable",
                "action_result",
                "outcome_unknown",
                "The action outcome is unknown.",
                Some("invoke_failed"),
                true,
            ));
        }
        Err((_, reason)) => {
            return Ok(generic_dispatch_element_failure(
                &params,
                "refused",
                "none",
                "unverifiable",
                "none",
                "dispatch_refused",
                "The target refused the action.",
                Some(reason),
                true,
            ));
        }
    };
    let outcome = old
        .get("outcome")
        .and_then(Value::as_object)
        .ok_or((-32603, "dispatch_result_invalid"))?;
    let status = outcome
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let method = match outcome.get("verification").and_then(Value::as_str) {
        Some("value_readback") => "value_readback",
        _ => "action_result",
    };
    if status == "verified" {
        let post = generic_observe(
            json!({
                "session":session,
                "target":{"kind":"window","pid":quoted.pid,"windowId":quoted.hwnd},
                "includeImage":false
            }),
            registry,
        )
        .ok()
        .and_then(|value| value.get("snapshot").cloned());
        return Ok(json!({
            "ok":true,
            "toolCallId":params.get("toolCallId").cloned().unwrap_or(Value::Null),
            "outcome":"ok","tier":"ax","path":path,"effect":"confirmed",
            "verification":{"method":method,"observedChange":true},
            "settle":{"waitedMs":0,"quiesced":true,"reason":"quiesced"},
            "snapshot":post
        }));
    }
    let reason = outcome
        .get("verification")
        .and_then(Value::as_str)
        .unwrap_or(if status == "unknown" {
            "outcome_unknown"
        } else {
            "dispatch_refused"
        });
    if status == "unknown" {
        return Ok(generic_dispatch_element_failure(
            &params,
            "unknown",
            path,
            "unverifiable",
            method,
            "outcome_unknown",
            "The action outcome is unknown.",
            Some(reason),
            true,
        ));
    }
    Ok(generic_dispatch_element_failure(
        &params,
        "refused",
        path,
        "unverifiable",
        "none",
        "dispatch_refused",
        "The target refused the action.",
        Some(reason),
        true,
    ))
}

fn generic_dispatch_key(
    params: Value,
    registry: &mut Registry,
) -> Result<Value, (i32, &'static str)> {
    let _ = require_session(&params, registry)?;
    Ok(generic_dispatch_refusal(
        &params,
        "unsupported_action",
        "Keyboard input is disabled by the background-only Windows executor.",
        "coordinate-background",
    ))
}

fn generic_screen_capture(
    params: Value,
    registry: &mut Registry,
) -> Result<Value, (i32, &'static str)> {
    let session = require_session(&params, registry)?;
    let requested_display = params.get("displayId").and_then(Value::as_str);
    let raw = platform::capture_display(requested_display)?;
    if raw.get("status").and_then(Value::as_str) != Some("available") {
        return Ok(generic_domain_error(
            "capture_failed",
            "The screen could not be captured.",
        ));
    }
    let display_id = raw
        .get("displayId")
        .and_then(Value::as_str)
        .unwrap_or("windows-primary")
        .to_owned();
    let stored = store_capture(
        registry,
        &format!(
            "screen-{}-{}",
            display_id,
            registry.next.fetch_add(1, Ordering::Relaxed)
        ),
        raw,
    )?;
    registry.register_unattached_image(session, stored.path);
    Ok(json!({
        "ok":true,
        "image":stored.value,
        "displayId":display_id,
        "capturedAt":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default()
    }))
}

fn observe(
    session: &str,
    params: Value,
    registry: &mut Registry,
) -> Result<Value, (i32, &'static str)> {
    let hwnd = params
        .get("hwnd")
        .and_then(Value::as_i64)
        .ok_or((-32602, "missing_hwnd"))? as isize;
    if hwnd <= 0 {
        return Err((-32602, "invalid_hwnd"));
    }
    let observed = platform::observe(hwnd)?;
    let generation = observed.generation.clone();
    let max_elements = params
        .get("maxElements")
        .and_then(Value::as_u64)
        .unwrap_or(MAX_ELEMENTS as u64)
        .clamp(1, MAX_ELEMENTS as u64) as usize;
    // Reserve a disjoint token range per snapshot. Without this stride,
    // e(N+1) from a later observation could alias e(N) from the prior one.
    let token_seed = registry
        .next
        .fetch_add((MAX_ELEMENTS as u64) + 1, Ordering::Relaxed)
        .wrapping_add(1);
    let snapshot_id = format!("s{:032x}{:016x}", registry.nonce, token_seed);
    let mut elements = HashMap::new();
    let mut rendered = Vec::with_capacity(observed.elements.len());
    let window_bounds = observed.window_bounds;
    for (index, element) in observed.elements.into_iter().enumerate().take(max_elements) {
        let token = format!(
            "e{:032x}{:016x}",
            registry.nonce,
            token_seed.wrapping_add(index as u64 + 1)
        );
        let digest = element_digest_for_observed(&element, window_bounds);
        elements.insert(
            token.clone(),
            ElementRef {
                automation_id: element.automation_id.clone(),
                name: element.name.clone(),
                control_type: element.control_type,
                runtime_id: element.runtime_id.clone(),
                digest: digest.clone(),
            },
        );
        rendered.push(json!({"token":token,"name":element.name,"automationId":element.automation_id,"controlType":element.control_type,"runtimeId":element.runtime_id,"patterns":element.patterns,"actions":element.actions,"isEnabled":element.is_enabled,"focused":element.focused,"value":element.value,"bounds":element.bounds,"parentRuntimeId":element.parent_runtime_id,"depth":element.depth,"ancestorRoles":element.ancestor_roles,"siblingIndex":element.sibling_index,"digest":digest}));
    }
    let element_count = rendered.len();
    registry.register_snapshot(
        snapshot_id.clone(),
        Snapshot {
            session: session.to_owned(),
            hwnd,
            pid: observed.pid,
            start_time: observed.start_time,
            generation: generation.clone(),
            elements: Some(elements),
            captured_at: Instant::now(),
            state: SnapshotState::Live,
            image_path: None,
        },
    );
    let nodes = rendered
        .iter()
        .map(|item| {
            let mut node = item.clone();
            if let Some(object) = node.as_object_mut() {
                // Keep actual provider patterns. ScrollItem is not Scroll,
                // and SelectionItem/Toggle fallback is not Invoke support.
                let control_type = object
                    .get("controlType")
                    .and_then(Value::as_i64)
                    .unwrap_or_default();
                object.insert(
                    "controlType".to_owned(),
                    json!(format!("UIA.ControlType.{control_type}")),
                );
            }
            node
        })
        .collect::<Vec<_>>();
    Ok(
        json!({"snapshotId":snapshot_id,"protocol":PROTOCOL,"hwnd":hwnd,"pid":observed.pid,"windowGeneration":generation,"target":{"hwnd":hwnd,"pid":observed.pid,"processStartTimeUtc":format!("filetime:{}", observed.start_time),"windowGeneration":generation},"elements":rendered,"tree":{"rootToken":null,"nodeCount":element_count,"truncated":observed.truncated,"rawDescendantCount":observed.raw_descendant_count,"elapsedMs":observed.elapsed_ms,"nodes":nodes},"capture":{"path":"capture_rpc","status":"separate"}}),
    )
}

fn act(
    params: Value,
    registry: &mut Registry,
    cancelled: &AtomicBool,
) -> Result<Value, (i32, &'static str)> {
    let snapshot_id = params
        .get("snapshotId")
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_snapshot"))?;
    let token = params
        .get("elementToken")
        .or_else(|| params.get("token"))
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_element_token"))?;
    let action = params
        .get("action")
        .or_else(|| params.get("op"))
        .or_else(|| params.get("name"))
        .and_then(Value::as_str)
        .ok_or((-32602, "missing_action"))?;
    // Spend before touching COM. A duplicate action is therefore always refused.
    let snapshot = registry.spend_snapshot(snapshot_id)?;
    let element = snapshot
        .elements
        .as_ref()
        .and_then(|elements| elements.get(token))
        .ok_or((-32001, "element_token_unknown_in_snapshot"))?
        .clone();
    if !matches!(action, "set_value" | "click_element") {
        return Err((-32602, "unsupported_action"));
    }
    let current = match platform::identity(snapshot.hwnd) {
        Ok(identity) => identity,
        Err((-32001, "target_window_gone")) => {
            return Err((-32001, "stale_target_revalidate_failed"));
        }
        Err(error) => return Err(error),
    };
    if current.pid != snapshot.pid
        || current.start_time != snapshot.start_time
        || current.generation != snapshot.generation
    {
        return Err((-32001, "stale_target_revalidate_failed"));
    }
    let value = params
        .get("value")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if action == "set_value" && value.chars().count() > MAX_TEXT {
        return Err((-32602, "value_too_long"));
    }
    let desktop_before = platform::desktop_state();
    let sentinel = DesktopSentinel::start(desktop_before);
    let mut readback = None;
    let dispatch = platform::act(
        snapshot.hwnd,
        element,
        action,
        value,
        VerificationContext {
            snapshot: &snapshot,
            cancelled,
            report: &mut readback,
        },
    );
    let transient_interference = sentinel.finish();
    let (mut status, mut verification) = dispatch?;
    let desktop_after = platform::desktop_state();
    if status != "refused" {
        if let Some(reason) = transient_interference
            .or_else(|| background_interference(desktop_before, desktop_after))
        {
            status = "unknown";
            verification = reason;
        }
    }
    let post_dispatch_delay = params
        .get("debugPostDispatchDelayMs")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    if post_dispatch_delay > 3_000 {
        return Err((-32602, "invalid_debugPostDispatchDelayMs"));
    }
    if post_dispatch_delay > 0 && status != "refused" {
        std::thread::sleep(Duration::from_millis(post_dispatch_delay));
    }
    if status != "refused" {
        let post_valid = platform::identity(snapshot.hwnd)
            .map(|after| {
                after.pid == snapshot.pid
                    && after.start_time == snapshot.start_time
                    && after.generation == snapshot.generation
            })
            .unwrap_or(false);
        if !post_valid {
            status = "unknown";
            verification = "post_revalidation_failed";
        }
    }
    let effect = if status == "verified" {
        if action == "set_value" {
            "value_set"
        } else {
            "invoked"
        }
    } else if status == "unknown" {
        "possibly_dispatched"
    } else {
        "none"
    };
    Ok(
        json!({"outcome":{"tier":"uia-pattern","path":match action { "set_value" => "value_pattern", "click_element" => "invoke_toggle_selection", _ => "none" },"status":status,"effect":effect,"snapshotSpent":true,"verification":verification,"readback":readback}}),
    )
}

#[cfg_attr(not(windows), allow(dead_code))]
struct VerificationContext<'a> {
    snapshot: &'a Snapshot,
    cancelled: &'a AtomicBool,
    report: &'a mut Option<Value>,
}

#[derive(Debug)]
struct ObservedElement {
    automation_id: String,
    name: String,
    control_type: i32,
    runtime_id: Vec<i32>,
    actions: Vec<&'static str>,
    patterns: Vec<&'static str>,
    is_enabled: bool,
    value: Option<String>,
    // Absolute screen-pixel bounds from UIA. The protocol façade converts
    // these to window-local logical points exactly once.
    bounds: [i32; 4],
    focused: bool,
    parent_runtime_id: Vec<i32>,
    depth: usize,
    ancestor_roles: Vec<String>,
    sibling_index: usize,
}
#[derive(Debug)]
struct Observed {
    pid: u32,
    start_time: u64,
    generation: String,
    window_bounds: [i32; 4],
    elements: Vec<ObservedElement>,
    raw_descendant_count: i32,
    truncated: bool,
    elapsed_ms: u64,
}
#[derive(Debug)]
struct Identity {
    pid: u32,
    start_time: u64,
    generation: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DesktopState {
    foreground_hwnd: Option<isize>,
    foreground_pid: Option<u32>,
    pointer: Option<(i32, i32)>,
    clipboard_sequence: u32,
}

fn background_interference(before: DesktopState, after: DesktopState) -> Option<&'static str> {
    if before.foreground_hwnd != after.foreground_hwnd
        || before.foreground_pid != after.foreground_pid
    {
        return Some("foreground_changed_during_dispatch");
    }
    if before.pointer != after.pointer {
        return Some("pointer_changed_during_dispatch");
    }
    if before.clipboard_sequence != after.clipboard_sequence {
        return Some("clipboard_changed_during_dispatch");
    }
    None
}

struct DesktopSentinel {
    stop: Arc<AtomicBool>,
    handle: thread::JoinHandle<Option<&'static str>>,
}

impl DesktopSentinel {
    fn start(baseline: DesktopState) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let monitor_stop = stop.clone();
        let (ready_tx, ready_rx) = mpsc::sync_channel(0);
        let handle = thread::spawn(move || {
            let _ = ready_tx.send(());
            while !monitor_stop.load(Ordering::Acquire) {
                if let Some(reason) = background_interference(baseline, platform::desktop_state()) {
                    return Some(reason);
                }
                thread::sleep(Duration::from_millis(2));
            }
            None
        });
        let _ = ready_rx.recv();
        Self { stop, handle }
    }

    fn finish(self) -> Option<&'static str> {
        self.stop.store(true, Ordering::Release);
        self.handle
            .join()
            .unwrap_or(Some("desktop_sentinel_failed"))
    }
}

#[cfg(not(windows))]
mod platform {
    use super::*;
    pub fn initialize_process() {}
    pub fn desktop_state() -> DesktopState {
        DesktopState {
            foreground_hwnd: None,
            foreground_pid: None,
            pointer: None,
            clipboard_sequence: 0,
        }
    }
    pub fn process_alive(pid: u32) -> bool {
        pid == std::process::id()
    }
    pub fn displays() -> Result<Vec<Value>, (i32, &'static str)> {
        Ok(Vec::new())
    }
    pub fn list_windows() -> Result<Value, (i32, &'static str)> {
        Ok(json!({"windows":[],"platform":"non_windows"}))
    }
    pub fn observe(_: isize) -> Result<Observed, (i32, &'static str)> {
        Err((-32001, "windows_only"))
    }
    pub fn identity(_: isize) -> Result<Identity, (i32, &'static str)> {
        Err((-32001, "windows_only"))
    }
    pub fn act(
        _: isize,
        _: ElementRef,
        _: &str,
        _: &str,
        _: VerificationContext<'_>,
    ) -> Result<(&'static str, &'static str), (i32, &'static str)> {
        Err((-32001, "windows_only"))
    }
    pub fn capture(_: Value) -> Result<Value, (i32, &'static str)> {
        Ok(json!({"status":"unavailable","path":"none","reason":"windows_only"}))
    }
    pub fn capture_display(_: Option<&str>) -> Result<Value, (i32, &'static str)> {
        Ok(json!({"status":"unavailable","path":"none","reason":"windows_only"}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_profile_advertises_semantic_actions_only() {
        let mut registry = Registry::default();
        let image_dir = std::env::temp_dir().join(format!(
            "maka-cu-hello-{}-{:032x}",
            std::process::id(),
            registry.nonce
        ));
        let response = host_hello(
            json!({
                "protocol": PROTOCOL,
                "allowGlobalPointer": false,
                "hostPid": std::process::id(),
                "imageDir": image_dir
            }),
            &mut registry,
        )
        .expect("background-only handshake should succeed");

        assert_eq!(
            response["capabilities"]["elementActions"],
            json!(["click", "set_value"])
        );
        assert_eq!(response["capabilities"]["pointActions"], json!([]));
        assert_eq!(response["capabilities"]["keyActions"], json!([]));

        if let Some(directory) = registry.image_dir.take() {
            let _ = std::fs::remove_dir_all(directory);
        }
    }

    #[test]
    fn background_profile_refuses_launch_and_keyboard_without_spending_snapshot() {
        let launch = generic_launch().expect("launch refusal is a domain result");
        assert_eq!(launch["ok"], json!(false));
        assert_eq!(launch["error"]["code"], json!("unsupported_action"));

        let mut registry = Registry::default();
        registry.sessions.insert("s".to_owned());
        registry.snapshots.insert(
            "s1".to_owned(),
            snapshot_for_test("s", 1, Instant::now(), None),
        );
        let key = generic_dispatch_key(
            json!({"session":"s","snapshotId":"s1","toolCallId":"key-1"}),
            &mut registry,
        )
        .expect("keyboard refusal is a domain result");
        assert_eq!(key["outcome"], json!("refused"));
        assert_eq!(key["error"]["code"], json!("unsupported_action"));
        assert_eq!(registry.snapshots["s1"].state, SnapshotState::Live);
    }

    #[test]
    fn background_guard_allows_unchanged_target_foreground_and_detects_changes() {
        let baseline = DesktopState {
            foreground_hwnd: Some(10),
            foreground_pid: Some(20),
            pointer: Some((30, 40)),
            clipboard_sequence: 50,
        };
        assert_eq!(background_interference(baseline, baseline), None);
        assert_eq!(
            background_interference(
                baseline,
                DesktopState {
                    foreground_hwnd: Some(11),
                    ..baseline
                }
            ),
            Some("foreground_changed_during_dispatch")
        );
        assert_eq!(
            background_interference(
                baseline,
                DesktopState {
                    pointer: Some((31, 40)),
                    ..baseline
                }
            ),
            Some("pointer_changed_during_dispatch")
        );
        assert_eq!(
            background_interference(
                baseline,
                DesktopState {
                    clipboard_sequence: 51,
                    ..baseline
                }
            ),
            Some("clipboard_changed_during_dispatch")
        );
    }

    #[test]
    fn element_unknown_keeps_ax_path_and_marks_spent_snapshot() {
        let response = generic_dispatch_element_failure(
            &json!({"toolCallId":"call-unknown"}),
            "unknown",
            "ax_action",
            "unverifiable",
            "action_result",
            "outcome_unknown",
            "The action outcome is unknown.",
            Some("invoke_has_no_effect_readback"),
            true,
        );

        assert_eq!(response["ok"], json!(false));
        assert_eq!(response["outcome"], json!("unknown"));
        assert_eq!(response["path"], json!("ax_action"));
        assert_eq!(response["effect"], json!("unverifiable"));
        assert_eq!(response["verification"]["method"], json!("action_result"));
        assert_eq!(response["error"]["detail"]["snapshotSpent"], json!(1));
        assert_eq!(
            response["error"]["detail"]["reason"],
            json!("invoke_has_no_effect_readback")
        );
    }

    #[test]
    fn refused_act_keeps_reason_and_marks_spent_snapshot() {
        let response = generic_dispatch_element_failure(
            &json!({"toolCallId":"call-refused"}),
            "refused",
            "ax_attribute",
            "unverifiable",
            "none",
            "dispatch_refused",
            "The target refused the action.",
            Some("value_pattern_readonly"),
            true,
        );

        assert_eq!(response["outcome"], json!("refused"));
        assert_eq!(response["path"], json!("ax_attribute"));
        assert_eq!(response["verification"]["method"], json!("none"));
        assert_eq!(response["error"]["detail"]["snapshotSpent"], json!(1));
        assert_eq!(
            response["error"]["detail"]["reason"],
            json!("value_pattern_readonly")
        );
    }

    #[test]
    fn pre_dispatch_element_refusal_marks_snapshot_unspent() {
        let response = generic_dispatch_element_refusal(
            &json!({"toolCallId":"call-preflight"}),
            "element_digest_mismatch",
            "The element digest does not match the quoted snapshot.",
        );

        assert_eq!(response["outcome"], json!("refused"));
        assert_eq!(response["path"], json!("none"));
        assert_eq!(response["error"]["detail"]["snapshotSpent"], json!(0));
    }

    #[test]
    fn snapshot_is_spent_before_platform_dispatch() {
        let mut registry = Registry::default();
        registry.snapshots.insert(
            "s1".to_owned(),
            Snapshot {
                session: String::new(),
                hwnd: 1,
                pid: 1,
                start_time: 1,
                generation: "g".to_owned(),
                elements: Some(HashMap::from([(
                    "e1".to_owned(),
                    ElementRef {
                        automation_id: "a".to_owned(),
                        name: "n".to_owned(),
                        control_type: 50000,
                        runtime_id: vec![1],
                        digest: String::new(),
                    },
                )])),
                captured_at: Instant::now(),
                state: SnapshotState::Live,
                image_path: None,
            },
        );
        let params = json!({"snapshotId":"s1","elementToken":"e1","op":"click_element"});
        let _ = act(params.clone(), &mut registry, &AtomicBool::new(false));
        assert_eq!(registry.snapshots["s1"].state, SnapshotState::Spent);
        let second = act(params, &mut registry, &AtomicBool::new(false)).unwrap_err();
        assert_eq!(second.1, "snapshot_spent");
    }

    #[test]
    fn cancellation_before_dispatch_spends_action_snapshot() {
        let mut registry = Registry::default();
        registry.snapshots.insert(
            "s-cancel".to_owned(),
            Snapshot {
                session: String::new(),
                hwnd: 1,
                pid: 1,
                start_time: 1,
                generation: "g".to_owned(),
                elements: Some(HashMap::new()),
                captured_at: Instant::now(),
                state: SnapshotState::Live,
                image_path: None,
            },
        );
        let result = cancel_queued_action(json!({"snapshotId":"s-cancel"}), &mut registry)
            .expect("queued cancellation should settle");
        assert_eq!(result["outcome"]["status"], json!("refused"));
        assert_eq!(registry.snapshots["s-cancel"].state, SnapshotState::Spent);
    }

    fn snapshot_for_test(
        session: &str,
        hwnd: isize,
        captured_at: Instant,
        image_path: Option<PathBuf>,
    ) -> Snapshot {
        Snapshot {
            session: session.to_owned(),
            hwnd,
            pid: 1,
            start_time: 1,
            generation: "g".to_owned(),
            elements: Some(HashMap::new()),
            captured_at,
            state: SnapshotState::Live,
            image_path,
        }
    }

    fn temporary_image_path(registry: &Registry, suffix: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "maka-cu-{}-{}-{suffix}.png",
            std::process::id(),
            registry.next.load(Ordering::Relaxed)
        ))
    }

    #[test]
    fn snapshot_registry_supersedes_per_window_and_evicts_per_session() {
        let mut registry = Registry::default();
        registry.sessions.insert("s".to_owned());
        let now = Instant::now();
        for index in 0..MAX_SNAPSHOTS_PER_SESSION {
            registry.register_snapshot(
                format!("s{index}"),
                snapshot_for_test(
                    "s",
                    100 + index as isize,
                    now - Duration::from_millis((MAX_SNAPSHOTS_PER_SESSION - index) as u64),
                    None,
                ),
            );
        }
        registry.register_snapshot("s8".to_owned(), snapshot_for_test("s", 108, now, None));

        assert_eq!(registry.snapshots["s0"].state, SnapshotState::Evicted);
        assert_eq!(registry.snapshots["s8"].state, SnapshotState::Live);
        assert_eq!(
            registry.resolve_snapshot("s", "s0").unwrap_err().1,
            "snapshot_evicted"
        );
        assert_eq!(
            registry
                .snapshots
                .values()
                .filter(|snapshot| snapshot.state == SnapshotState::Live)
                .count(),
            MAX_SNAPSHOTS_PER_SESSION
        );

        registry.register_snapshot(
            "same-window-new".to_owned(),
            snapshot_for_test("s", 102, now, None),
        );
        assert_eq!(registry.snapshots["s2"].state, SnapshotState::Superseded);
    }

    #[test]
    fn terminal_snapshot_states_delete_owned_images() {
        let mut registry = Registry::default();
        registry.sessions.insert("s".to_owned());
        let path = temporary_image_path(&registry, "terminal");
        write(&path, b"image").unwrap();
        registry.track_image(path.clone(), 5);
        let now = Instant::now();
        registry.register_snapshot(
            "old".to_owned(),
            snapshot_for_test("s", 1, now, Some(path.clone())),
        );
        registry.register_snapshot("new".to_owned(), snapshot_for_test("s", 1, now, None));
        assert_eq!(registry.snapshots["old"].state, SnapshotState::Superseded);
        assert_eq!(
            registry.resolve_snapshot("s", "old").unwrap_err().1,
            "snapshot_superseded"
        );
        assert_eq!(registry.image_bytes, 0);
        assert!(!path.exists());

        let expired_path = temporary_image_path(&registry, "expired");
        write(&expired_path, b"image").unwrap();
        registry.track_image(expired_path.clone(), 5);
        registry.register_snapshot(
            "expired".to_owned(),
            snapshot_for_test(
                "s",
                2,
                Instant::now() - SNAPSHOT_TTL - Duration::from_secs(1),
                Some(expired_path.clone()),
            ),
        );
        assert_eq!(
            registry.resolve_snapshot("s", "expired").unwrap_err().1,
            "snapshot_expired"
        );
        assert!(!expired_path.exists());
        assert_eq!(registry.image_bytes, 0);
    }

    #[test]
    fn session_end_releases_snapshot_and_unattached_images() {
        let mut registry = Registry::default();
        registry.sessions.insert("s".to_owned());
        let snapshot_path = temporary_image_path(&registry, "session-snapshot");
        let capture_path = temporary_image_path(&registry, "session-capture");
        write(&snapshot_path, b"image").unwrap();
        write(&capture_path, b"capture").unwrap();
        registry.track_image(snapshot_path.clone(), 5);
        registry.track_image(capture_path.clone(), 7);
        registry.register_snapshot(
            "session-snapshot".to_owned(),
            snapshot_for_test("s", 1, Instant::now(), Some(snapshot_path.clone())),
        );
        registry.unattached_images.insert(
            capture_path.clone(),
            UnattachedImage {
                session: "s".to_owned(),
                captured_at: Instant::now(),
            },
        );
        let released = registry.end_session("s");
        assert_eq!(released, (1, 2));
        assert!(!snapshot_path.exists());
        assert!(!capture_path.exists());
        assert_eq!(registry.image_bytes, 0);
    }

    #[test]
    fn expired_unattached_images_are_removed_on_the_snapshot_clock() {
        let mut registry = Registry::default();
        registry.sessions.insert("s".to_owned());
        let path = temporary_image_path(&registry, "expired-capture");
        write(&path, b"capture").unwrap();
        registry.track_image(path.clone(), 7);
        registry.unattached_images.insert(
            path.clone(),
            UnattachedImage {
                session: "s".to_owned(),
                captured_at: Instant::now() - SNAPSHOT_TTL - Duration::from_secs(1),
            },
        );
        registry.reap_expired(Instant::now());
        assert!(!path.exists());
        assert_eq!(registry.image_bytes, 0);
        assert!(registry.unattached_images.is_empty());
    }

    #[test]
    fn image_budget_rejects_a_single_image_larger_than_available_space() {
        let mut registry = Registry {
            image_bytes: MAX_IMAGE_DIR_BYTES,
            ..Registry::default()
        };
        assert!(!registry.make_room_for_image(1));
    }

    #[test]
    fn snapshot_ids_are_isolated_between_worker_generations() {
        let first = Registry::default();
        let second = Registry::default();
        assert_ne!(first.nonce, second.nonce);
    }

    #[test]
    fn terminal_snapshots_drop_elements_and_keep_bounded_tombstones() {
        let mut registry = Registry::default();
        registry.sessions.insert("s".to_owned());
        for index in 0..(MAX_SNAPSHOT_TOMBSTONES_PER_SESSION + 8) {
            registry.register_snapshot(
                format!("snapshot-{index}"),
                snapshot_for_test("s", index as isize + 1, Instant::now(), None),
            );
        }
        assert!(
            registry
                .snapshots
                .values()
                .filter(|snapshot| snapshot.state != SnapshotState::Live)
                .count()
                <= MAX_SNAPSHOT_TOMBSTONES_PER_SESSION
        );
        assert!(registry.snapshots.values().all(|snapshot| {
            snapshot.state == SnapshotState::Live || snapshot.elements.is_none()
        }));
    }

    #[test]
    fn oversized_observation_returns_protocol_error_without_mutating_payload() {
        let many_elements = (0..10_000)
            .map(|_| json!({"title":"x".repeat(256)}))
            .collect::<Vec<_>>();
        let many_nodes = (0..10_000)
            .map(|_| json!({"name":"x".repeat(256)}))
            .collect::<Vec<_>>();
        let mut out = Vec::new();
        write_rpc(
            &mut out,
            Some(json!(1)),
            Some(json!({
                "snapshot": {
                    "snapshotId": "s1",
                    "target": {"title": "target"},
                    "elements": many_elements,
                    "tree": {"nodes": many_nodes}
                }
            })),
            None,
        );
        let line = out.strip_suffix(b"\n").unwrap_or(&out);
        assert!(line.len() <= MAX_RESPONSE_BYTES);
        let response: Value = serde_json::from_slice(line).unwrap();
        assert_eq!(response["error"]["code"], json!(-32002));
        assert_eq!(response["error"]["message"], json!("response_too_large"));
        assert_eq!(
            response["error"]["data"]["limit"],
            json!(MAX_RESPONSE_BYTES)
        );
        assert!(response["error"]["data"]["bytes"].as_u64().unwrap() > MAX_RESPONSE_BYTES as u64);
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use base64::Engine;
    use flate2::{write::ZlibEncoder, Compression};
    use std::io::Write;
    use std::time::{Duration, Instant};
    use windows::core::{IUnknown, Interface, GUID, HSTRING, PWSTR};
    use windows::core::{BOOL, BSTR};
    use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem};
    use windows::Graphics::DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat};
    use windows::Graphics::SizeInt32;
    use windows::Win32::Foundation::{CloseHandle, FILETIME, HWND, LPARAM, POINT, RECT};
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
        D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE,
        D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
    use windows::Win32::Graphics::Dxgi::IDXGIDevice;
    use windows::Win32::Graphics::Gdi::{
        EnumDisplayMonitors, GetMonitorInfoW, HMONITOR, MONITORINFO,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
    };
    use windows::Win32::System::DataExchange::GetClipboardSequenceNumber;
    use windows::Win32::System::Ole::{
        SafeArrayDestroy, SafeArrayGetElement, SafeArrayGetLBound, SafeArrayGetUBound,
    };
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, GetProcessTimes, OpenProcess, QueryFullProcessImageNameW,
        PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::System::WinRT::Direct3D11::CreateDirect3D11DeviceFromDXGIDevice;
    use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
    use windows::Win32::System::WinRT::{
        RoGetActivationFactory, RoInitialize, RO_INIT_MULTITHREADED,
    };
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationInvokePattern,
        IUIAutomationSelectionItemPattern, IUIAutomationTogglePattern, IUIAutomationTreeWalker,
        IUIAutomationValuePattern, TreeScope_Descendants, UIA_InvokePatternId,
        UIA_SelectionItemPatternId, UIA_TogglePatternId, UIA_ValuePatternId,
    };
    use windows::Win32::UI::HiDpi::{
        GetDpiForMonitor, GetDpiForWindow, SetProcessDpiAwarenessContext,
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetCursorPos, GetForegroundWindow, GetWindowRect, GetWindowTextW,
        GetWindowThreadProcessId, IsWindow, IsWindowVisible,
    };
    static COM_INIT: Once = Once::new();
    const IID_IDIRECT3D_DXGI_INTERFACE_ACCESS: GUID =
        GUID::from_u128(0xa9b3d012_3df2_4ee3_b8d1_8695f457d3c1);

    pub fn initialize_process() {
        // This must run before any worker thread touches UIA, WGC, or HWND
        // geometry. A manifest may have established the same context already;
        // in that case Windows refuses the duplicate call and no fallback to a
        // DPI-unaware mode is attempted.
        let _ =
            unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    }

    pub fn desktop_state() -> DesktopState {
        let foreground = unsafe { GetForegroundWindow() };
        let foreground_hwnd = (!foreground.0.is_null()).then_some(foreground.0 as isize);
        let mut pid = 0u32;
        if foreground_hwnd.is_some() {
            unsafe {
                GetWindowThreadProcessId(foreground, Some(&mut pid));
            }
        }
        let mut point = POINT::default();
        let pointer = unsafe { GetCursorPos(&mut point) }
            .is_ok()
            .then_some((point.x, point.y));
        DesktopState {
            foreground_hwnd,
            foreground_pid: (pid > 0).then_some(pid),
            pointer,
            clipboard_sequence: unsafe { GetClipboardSequenceNumber() },
        }
    }

    /// The worker owns the COM apartment.  Keeping initialization here makes
    /// the stdio thread a pure control plane and avoids UIA calls crossing
    /// apartments when a request is cancelled.
    pub fn initialize_worker() {
        COM_INIT.call_once(|| unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        });
    }

    #[repr(C)]
    struct DxgiInterfaceAccessVtbl {
        query: usize,
        add_ref: usize,
        release: usize,
        get_interface: unsafe extern "system" fn(
            *mut core::ffi::c_void,
            *const GUID,
            *mut *mut core::ffi::c_void,
        ) -> windows::core::HRESULT,
    }

    pub fn list_windows() -> Result<Value, (i32, &'static str)> {
        let mut windows: Vec<Value> = Vec::new();
        unsafe {
            let _ = EnumWindows(Some(enum_window), LPARAM(&mut windows as *mut _ as isize));
        }
        Ok(json!({"windows":windows,"platform":"windows"}))
    }

    pub fn displays() -> Result<Vec<Value>, (i32, &'static str)> {
        let mut values = Vec::new();
        unsafe {
            let _ = EnumDisplayMonitors(
                None,
                None,
                Some(enum_monitor),
                LPARAM(&mut values as *mut _ as isize),
            );
        }
        if values.is_empty() {
            return Err((-32001, "display_inventory_unavailable"));
        }
        Ok(values)
    }

    unsafe extern "system" fn enum_monitor(
        monitor: HMONITOR,
        _: windows::Win32::Graphics::Gdi::HDC,
        _: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if !GetMonitorInfoW(monitor, &mut info).as_bool() {
            return BOOL(1);
        }
        let rect = info.rcMonitor;
        if rect.right <= rect.left || rect.bottom <= rect.top {
            return BOOL(1);
        }
        let values = &mut *(data.0 as *mut Vec<Value>);
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        let id = format!("monitor:{:x}", monitor.0 as usize);
        let mut dpi_x = 96u32;
        let mut dpi_y = 96u32;
        let _ = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y);
        values.push(json!({
            "displayId": id,
            "logicalBounds":{"x":rect.left,"y":rect.top,"width":width,"height":height},
            "sourceBoundsPx":{"x":rect.left,"y":rect.top,"width":width,"height":height},
            "scaleFactor":dpi_x as f64 / 96.0
        }));
        BOOL(1)
    }

    pub fn process_alive(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        let Ok(handle) = (unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) })
        else {
            return false;
        };
        let mut exit_code = 0u32;
        let alive =
            unsafe { GetExitCodeProcess(handle, &mut exit_code).is_ok() } && exit_code == 259; // STILL_ACTIVE
        unsafe {
            let _ = CloseHandle(handle);
        }
        alive
    }

    fn process_app_id(pid: u32) -> Option<String> {
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()? };
        let mut buffer = vec![0u16; 32_768];
        let mut length = buffer.len() as u32;
        let ok = unsafe {
            QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_WIN32,
                PWSTR(buffer.as_mut_ptr()),
                &mut length,
            )
            .is_ok()
        };
        unsafe {
            let _ = CloseHandle(handle);
        }
        if !ok || length == 0 {
            return None;
        }
        let path = String::from_utf16(&buffer[..length as usize]).ok()?;
        Some(format!("win32:{}", path.to_ascii_lowercase()))
    }

    unsafe extern "system" fn enum_window(hwnd: HWND, data: LPARAM) -> BOOL {
        if !IsWindowVisible(hwnd).as_bool() {
            return BOOL(1);
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return BOOL(1);
        }
        let mut title = [0u16; 512];
        let len = GetWindowTextW(hwnd, &mut title) as usize;
        let title = String::from_utf16_lossy(&title[..len]);
        let windows = &mut *(data.0 as *mut Vec<Value>);
        if windows.len() < 128 {
            let mut rect = RECT::default();
            let bounds = if GetWindowRect(hwnd, &mut rect).is_ok() {
                json!([
                    rect.left,
                    rect.top,
                    rect.right - rect.left,
                    rect.bottom - rect.top
                ])
            } else {
                json!([0, 0, 1, 1])
            };
            windows.push(json!({
                "hwnd":hwnd.0 as isize,
                "pid":pid,
                "appId":process_app_id(pid).unwrap_or_else(|| format!("pid:{pid}")),
                "title":title,
                "bounds":bounds,
                "isOffscreen":false
            }));
        }
        BOOL(1)
    }

    fn automation() -> Result<IUIAutomation, (i32, &'static str)> {
        COM_INIT.call_once(|| unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        });
        unsafe {
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                .map_err(|_| (-32001, "uia_unavailable"))
        }
    }
    fn text(b: BSTR) -> String {
        String::try_from(b).unwrap_or_default()
    }
    fn process_start_time(pid: u32) -> Option<u64> {
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()? };
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        let ok = unsafe {
            GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user).is_ok()
        };
        unsafe {
            let _ = CloseHandle(handle);
        }
        ok.then_some(((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64)
    }
    fn generation(hwnd: HWND, pid: u32, root: &IUIAutomationElement) -> String {
        let name = unsafe { root.CurrentName().map(text).unwrap_or_default() };
        let class = unsafe { root.CurrentClassName().map(text).unwrap_or_default() };
        let runtime = runtime_id(root)
            .into_iter()
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join(",");
        let mut fingerprint =
            format!("{}|{}|{}|{}|{}", hwnd.0 as isize, class, name, pid, runtime).into_bytes();
        // Keep the same 16-hex-character wire shape as the C# driver. This is
        // a small deterministic hash, not a security primitive; PID/start
        // time and exact RuntimeId are separately revalidated before actions.
        let mut hash = 0xcbf29ce484222325u64;
        for byte in fingerprint.drain(..) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("{hash:016x}")
    }
    fn runtime_id(element: &IUIAutomationElement) -> Vec<i32> {
        let Ok(array) = (unsafe { element.GetRuntimeId() }) else {
            return Vec::new();
        };
        if array.is_null() {
            return Vec::new();
        }
        let (Ok(lower), Ok(upper)) = (unsafe { SafeArrayGetLBound(array, 1) }, unsafe {
            SafeArrayGetUBound(array, 1)
        }) else {
            unsafe {
                let _ = SafeArrayDestroy(array);
            }
            return Vec::new();
        };
        let mut ids = Vec::new();
        for index in lower..=upper {
            let mut value = 0i32;
            if unsafe { SafeArrayGetElement(array, &index, &mut value as *mut _ as *mut _) }.is_ok()
            {
                ids.push(value);
            }
        }
        unsafe {
            let _ = SafeArrayDestroy(array);
        }
        ids
    }

    fn tree_walker(uia: &IUIAutomation) -> Result<IUIAutomationTreeWalker, (i32, &'static str)> {
        unsafe { uia.ControlViewWalker() }
            .or_else(|_| unsafe { uia.RawViewWalker() })
            .map_err(|_| (-32001, "uia_tree_walker_unavailable"))
    }

    fn hierarchy_metadata(
        uia: &IUIAutomation,
        root: &IUIAutomationElement,
        element: &IUIAutomationElement,
    ) -> (Vec<i32>, usize, Vec<String>, usize) {
        let Ok(walker) = tree_walker(uia) else {
            return (Vec::new(), 1, Vec::new(), 0);
        };
        let root_id = runtime_id(root);
        let element_id = runtime_id(element);
        let mut parent_runtime_id = Vec::new();
        let mut ancestor_roles = Vec::new();
        let mut sibling_index = 0usize;
        let mut depth = 0usize;
        let mut current = element.clone();
        for _ in 0..64 {
            let Ok(parent) = (unsafe { walker.GetParentElement(&current) }) else {
                break;
            };
            let parent_id = runtime_id(&parent);
            if depth == 0 {
                parent_runtime_id = parent_id.clone();
                let mut sibling = unsafe { walker.GetFirstChildElement(&parent).ok() };
                while let Some(candidate) = sibling {
                    if runtime_id(&candidate) == element_id {
                        break;
                    }
                    sibling_index += 1;
                    sibling = unsafe { walker.GetNextSiblingElement(&candidate).ok() };
                }
            }
            depth += 1;
            let role = unsafe { parent.CurrentControlType().map(|value| value.0).ok() }
                .map(|value| format!("UIA.ControlType.{value}"));
            if let Some(role) = role {
                if ancestor_roles.len() < 8 {
                    ancestor_roles.push(role);
                }
            }
            if parent_id == root_id {
                break;
            }
            if parent_id.is_empty() || parent_id == runtime_id(&current) {
                break;
            }
            current = parent;
        }
        (parent_runtime_id, depth, ancestor_roles, sibling_index)
    }

    pub fn identity(hwnd: isize) -> Result<Identity, (i32, &'static str)> {
        let hwnd = HWND(hwnd as *mut _);
        if unsafe { !IsWindow(Some(hwnd)).as_bool() } {
            return Err((-32001, "target_window_gone"));
        }
        let mut pid = 0u32;
        unsafe {
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
        }
        let uia = automation()?;
        let start_time =
            process_start_time(pid).ok_or((-32001, "target_process_start_time_unavailable"))?;
        let root = unsafe {
            uia.ElementFromHandle(hwnd)
                .map_err(|_| (-32001, "uia_element_unavailable"))?
        };
        Ok(Identity {
            pid,
            start_time,
            generation: generation(hwnd, pid, &root),
        })
    }
    pub fn observe(hwnd: isize) -> Result<Observed, (i32, &'static str)> {
        let started = Instant::now();
        let hwnd = HWND(hwnd as *mut _);
        let ident = identity(hwnd.0 as isize)?;
        let mut window_rect = RECT::default();
        let window_bounds = if unsafe { GetWindowRect(hwnd, &mut window_rect).is_ok() } {
            [
                window_rect.left,
                window_rect.top,
                window_rect.right - window_rect.left,
                window_rect.bottom - window_rect.top,
            ]
        } else {
            [0, 0, 0, 0]
        };
        let uia = automation()?;
        let root = unsafe {
            uia.ElementFromHandle(hwnd)
                .map_err(|_| (-32001, "uia_element_unavailable"))?
        };
        let condition = unsafe {
            uia.CreateTrueCondition()
                .map_err(|_| (-32001, "uia_condition_failed"))?
        };
        let all = unsafe {
            root.FindAll(TreeScope_Descendants, &condition)
                .map_err(|_| (-32001, "uia_observe_failed"))?
        };
        let raw_count = unsafe { all.Length().unwrap_or(0) };
        let truncated = raw_count > MAX_ELEMENTS as i32;
        let count = raw_count.min(MAX_ELEMENTS as i32);
        let mut elements = Vec::with_capacity(count as usize);
        for i in 0..count {
            let Ok(el) = (unsafe { all.GetElement(i) }) else {
                continue;
            };
            let name = unsafe { el.CurrentName().map(text).unwrap_or_default() };
            let automation_id = unsafe { el.CurrentAutomationId().map(text).unwrap_or_default() };
            let control_type = unsafe { el.CurrentControlType().map(|x| x.0).unwrap_or_default() };
            let runtime_id = runtime_id(&el);
            let is_enabled = unsafe { el.CurrentIsEnabled().map(|x| x.as_bool()).unwrap_or(false) };
            let focused = unsafe {
                el.CurrentHasKeyboardFocus()
                    .map(|x| x.as_bool())
                    .unwrap_or(false)
            };
            let bounds = unsafe { el.CurrentBoundingRectangle() }
                .map(|rect| {
                    [
                        rect.left,
                        rect.top,
                        rect.right - rect.left,
                        rect.bottom - rect.top,
                    ]
                })
                .unwrap_or([0, 0, 0, 0]);
            let value = unsafe {
                el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    .ok()
                    .and_then(|pattern| pattern.CurrentValue().ok().map(text))
            };
            let mut actions = Vec::new();
            let mut patterns = Vec::new();
            if unsafe {
                el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    .is_ok()
            } {
                actions.push("set_value");
                patterns.push("Value");
            }
            if unsafe {
                el.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                    .is_ok()
            } {
                actions.push("click_element");
                patterns.push("Invoke");
            }
            let has_selection = unsafe {
                el.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(
                    UIA_SelectionItemPatternId,
                )
                .is_ok()
            };
            if has_selection {
                actions.push("select");
                patterns.push("SelectionItem");
            }
            let has_toggle = unsafe {
                el.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId)
                    .is_ok()
            };
            if has_toggle {
                actions.push("toggle");
                patterns.push("Toggle");
            }
            if (has_selection || has_toggle) && !actions.contains(&"click_element") {
                actions.push("click_element");
            }
            if !actions.is_empty() || !name.is_empty() {
                let (parent_runtime_id, depth, ancestor_roles, sibling_index) =
                    hierarchy_metadata(&uia, &root, &el);
                elements.push(ObservedElement {
                    automation_id,
                    name,
                    control_type,
                    runtime_id,
                    actions,
                    patterns,
                    is_enabled,
                    value,
                    bounds,
                    focused,
                    parent_runtime_id,
                    depth,
                    ancestor_roles,
                    sibling_index,
                });
            }
        }
        Ok(Observed {
            pid: ident.pid,
            start_time: ident.start_time,
            generation: ident.generation,
            window_bounds,
            elements,
            raw_descendant_count: raw_count,
            truncated,
            elapsed_ms: started.elapsed().as_millis() as u64,
        })
    }

    pub fn act(
        hwnd: isize,
        element: ElementRef,
        action: &str,
        value: &str,
        verification: VerificationContext<'_>,
    ) -> Result<(&'static str, &'static str), (i32, &'static str)> {
        let hwnd = HWND(hwnd as *mut _);
        // Rebuild the §4.3 binding from a fresh UIA observation before
        // acquiring or invoking any pattern. This catches value, frame,
        // action-set, and provider-tree changes in addition to RuntimeId.
        let current = observe(hwnd.0 as isize)?;
        let current_digest = current
            .elements
            .iter()
            .enumerate()
            .find(|(_, candidate)| candidate.runtime_id == element.runtime_id)
            .map(|(_index, candidate)| {
                element_digest_for_observed(candidate, current.window_bounds)
            });
        if current_digest.as_deref() != Some(element.digest.as_str()) {
            return Err((-32001, "element_changed"));
        }
        let uia = automation()?;
        let root = unsafe {
            uia.ElementFromHandle(hwnd)
                .map_err(|_| (-32001, "uia_element_unavailable"))?
        };
        let condition = unsafe {
            uia.CreateTrueCondition()
                .map_err(|_| (-32001, "uia_condition_failed"))?
        };
        let all = unsafe {
            root.FindAll(TreeScope_Descendants, &condition)
                .map_err(|_| (-32001, "uia_observe_failed"))?
        };
        let count = unsafe { all.Length().unwrap_or(0).min(MAX_ELEMENTS as i32) };
        for i in 0..count {
            let Ok(el) = (unsafe { all.GetElement(i) }) else {
                continue;
            };
            let aid = unsafe { el.CurrentAutomationId().map(text).unwrap_or_default() };
            let name = unsafe { el.CurrentName().map(text).unwrap_or_default() };
            let ct = unsafe { el.CurrentControlType().map(|x| x.0).unwrap_or_default() };
            let rid = runtime_id(&el);
            // RuntimeId is the provider's identity for an element instance.
            // Never rematch a replacement by name, index, or automation id.
            if element.runtime_id.is_empty() || rid.is_empty() || rid != element.runtime_id {
                continue;
            }
            if aid != element.automation_id || name != element.name || ct != element.control_type {
                continue;
            }
            if unsafe { !el.CurrentIsEnabled().map(|x| x.as_bool()).unwrap_or(false) } {
                return Err((-32001, "element_disabled"));
            }
            if action == "set_value" {
                if unsafe { el.CurrentIsPassword().map(|x| x.as_bool()).unwrap_or(true) } {
                    return Err((-32001, "password_field_refused"));
                }
                let pattern = unsafe {
                    el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                        .map_err(|_| (-32001, "element_not_actionable"))?
                };
                if unsafe {
                    pattern
                        .CurrentIsReadOnly()
                        .map(|x| x.as_bool())
                        .unwrap_or(true)
                } {
                    return Err((-32001, "value_pattern_readonly"));
                }
                let same_identity = || {
                    let snapshot = verification.snapshot;
                    identity(snapshot.hwnd)
                        .map(|current| {
                            current.pid == snapshot.pid
                                && current.start_time == snapshot.start_time
                                && current.generation == snapshot.generation
                        })
                        .unwrap_or(false)
                        && runtime_id(&el) == element.runtime_id
                };
                if !same_identity() {
                    return Err((-32001, "stale_target_revalidate_failed"));
                }
                if verification.cancelled.load(Ordering::Acquire) {
                    return Ok(("refused", "cancelled_before_dispatch"));
                }
                let input: BSTR = value.into();
                if unsafe { pattern.SetValue(&input) }.is_err() {
                    // The provider might have mutated before returning an error.
                    return Ok(("unknown", "set_value_failed_after_dispatch"));
                }
                let report = readback::run(
                    || {
                        if !same_identity() {
                            return Err("readback_identity_changed");
                        }
                        let password = unsafe { el.CurrentIsPassword() }
                            .map_err(|_| "readback_unavailable")?;
                        if password.as_bool() {
                            return Err("readback_password_field_refused");
                        }
                        let fresh = unsafe {
                            el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                        }
                        .map_err(|_| "readback_unavailable")?;
                        let actual =
                            unsafe { fresh.CurrentValue() }.map_err(|_| "readback_unavailable")?;
                        let actual =
                            String::try_from(actual).map_err(|_| "readback_unavailable")?;
                        if actual.chars().count() > MAX_TEXT {
                            return Err("readback_value_too_long");
                        }
                        if !same_identity() {
                            return Err("readback_identity_changed");
                        }
                        if unsafe { el.CurrentIsPassword() }
                            .map_err(|_| "readback_unavailable")?
                            .as_bool()
                        {
                            return Err("readback_password_field_refused");
                        }
                        Ok(actual == value)
                    },
                    || verification.cancelled.load(Ordering::Acquire),
                );
                let outcome = (report.status, report.verification);
                *verification.report = Some(json!(report));
                return Ok(outcome);
            }
            if let Ok(pattern) = unsafe {
                el.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(
                    UIA_SelectionItemPatternId,
                )
            } {
                unsafe {
                    pattern.Select().map_err(|_| (-32001, "select_failed"))?;
                }
                let selected = unsafe {
                    pattern
                        .CurrentIsSelected()
                        .map(|state| state.as_bool())
                        .unwrap_or(false)
                };
                return if selected {
                    Ok(("verified", "selection_readback_selected"))
                } else {
                    Ok(("unknown", "selection_readback_mismatch"))
                };
            }
            if let Ok(pattern) =
                unsafe { el.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId) }
            {
                let before = unsafe {
                    pattern
                        .CurrentToggleState()
                        .map_err(|_| (-32001, "toggle_state_unavailable"))?
                };
                unsafe {
                    pattern.Toggle().map_err(|_| (-32001, "toggle_failed"))?;
                }
                let after = unsafe {
                    pattern
                        .CurrentToggleState()
                        .map_err(|_| (-32001, "toggle_readback_unavailable"))?
                };
                return if after != before {
                    Ok(("verified", "toggle_state_readback_changed"))
                } else {
                    Ok(("unknown", "toggle_state_unchanged_after_action"))
                };
            }
            let pattern = unsafe {
                el.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                    .map_err(|_| (-32001, "element_not_actionable"))?
            };
            unsafe {
                pattern.Invoke().map_err(|_| (-32001, "invoke_failed"))?;
            }
            return Ok(("unknown", "invoke_has_no_effect_readback"));
        }
        Err((-32001, "element_changed"))
    }

    pub fn capture(params: Value) -> Result<Value, (i32, &'static str)> {
        let hwnd = params
            .get("hwnd")
            .and_then(Value::as_i64)
            .ok_or((-32602, "missing_hwnd"))?;
        let hwnd = HWND(hwnd as *mut _);
        if unsafe { !IsWindow(Some(hwnd)).as_bool() } {
            return Ok(json!({"status":"unavailable","path":"none","reason":"target_window_gone"}));
        }
        let expected = params
            .get("windowGeneration")
            .and_then(Value::as_str)
            .ok_or((-32602, "missing_window_generation"))?;
        let actual = identity(hwnd.0 as isize)?;
        if actual.generation != expected {
            return Ok(
                json!({"status":"unavailable","path":"none","reason":"stale_target_window_generation"}),
            );
        }
        let started = Instant::now();
        let scale_factor = unsafe { GetDpiForWindow(hwnd) } as f64 / 96.0;
        match capture_wgc(hwnd) {
            Ok((width, height, png)) => Ok(
                json!({"status":"available","path":"wgc_createforwindow","frame":{"width":width,"height":height,"scaleFactor":if scale_factor > 0.0 { scale_factor } else { 1.0 },"bytes":png.len(),"format":"png","base64":base64::engine::general_purpose::STANDARD.encode(png),"elapsedMs":started.elapsed().as_millis()}}),
            ),
            Err(reason) => Ok(
                json!({"status":"unavailable","path":"none","reason":format!("capture_unavailable:{reason}")}),
            ),
        }
    }

    pub fn capture_display(display_id: Option<&str>) -> Result<Value, (i32, &'static str)> {
        let displays = displays()?;
        let selected = match display_id {
            Some(requested) => displays
                .iter()
                .find(|display| display.get("displayId").and_then(Value::as_str) == Some(requested))
                .ok_or((-32602, "display_not_found"))?,
            None => displays
                .first()
                .ok_or((-32001, "display_inventory_unavailable"))?,
        };
        let id = selected
            .get("displayId")
            .and_then(Value::as_str)
            .ok_or((-32001, "display_inventory_unavailable"))?;
        let monitor = id
            .strip_prefix("monitor:")
            .and_then(|value| usize::from_str_radix(value, 16).ok())
            .ok_or((-32001, "display_inventory_unavailable"))?;
        let started = Instant::now();
        let scale_factor = selected
            .get("scaleFactor")
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite() && *value > 0.0)
            .unwrap_or(1.0);
        match capture_wgc_monitor(HMONITOR(monitor as *mut _)) {
            Ok((width, height, png)) => Ok(json!({
                "status":"available",
                "path":"wgc_createmonitor",
                "displayId":id,
                "frame":{"width":width,"height":height,"scaleFactor":scale_factor,"bytes":png.len(),"format":"png","base64":base64::engine::general_purpose::STANDARD.encode(png),"elapsedMs":started.elapsed().as_millis()}
            })),
            Err(reason) => Ok(json!({
                "status":"unavailable",
                "path":"none",
                "displayId":id,
                "reason":format!("capture_unavailable:{reason}")
            })),
        }
    }

    fn capture_wgc_monitor(monitor: HMONITOR) -> Result<(i32, i32, Vec<u8>), &'static str> {
        unsafe {
            let _ = RoInitialize(RO_INIT_MULTITHREADED);
        }
        let class = HSTRING::from("Windows.Graphics.Capture.GraphicsCaptureItem");
        let interop: IGraphicsCaptureItemInterop =
            unsafe { RoGetActivationFactory(&class).map_err(|_| "activation_factory")? };
        let item: GraphicsCaptureItem = unsafe {
            interop
                .CreateForMonitor(monitor)
                .map_err(|_| "create_for_monitor")?
        };
        capture_wgc_item(item)
    }

    fn capture_wgc(hwnd: HWND) -> Result<(i32, i32, Vec<u8>), &'static str> {
        unsafe {
            let _ = RoInitialize(RO_INIT_MULTITHREADED);
        }
        let class = HSTRING::from("Windows.Graphics.Capture.GraphicsCaptureItem");
        let interop: IGraphicsCaptureItemInterop =
            unsafe { RoGetActivationFactory(&class).map_err(|_| "activation_factory")? };
        let item: GraphicsCaptureItem = unsafe {
            interop
                .CreateForWindow(hwnd)
                .map_err(|_| "create_for_window")?
        };
        capture_wgc_item(item)
    }

    fn capture_wgc_item(item: GraphicsCaptureItem) -> Result<(i32, i32, Vec<u8>), &'static str> {
        let size = item.Size().map_err(|_| "capture_size")?;
        if size.Width <= 0
            || size.Height <= 0
            || (size.Width as i64 * size.Height as i64) > MAX_CAPTURE_PIXELS
        {
            return Err("capture_dimensions");
        }
        let mut device: Option<ID3D11Device> = None;
        let mut context: Option<ID3D11DeviceContext> = None;
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                Default::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .map_err(|_| "d3d11_device")?;
        }
        let device = device.ok_or("d3d11_device_null")?;
        let context = context.ok_or("d3d11_context_null")?;
        let dxgi: IDXGIDevice = device.cast().map_err(|_| "dxgi_device")?;
        let inspectable =
            unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi).map_err(|_| "winrt_device")? };
        let d3d_device: IDirect3DDevice = inspectable.cast().map_err(|_| "direct3d_device")?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            &d3d_device,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            SizeInt32 {
                Width: size.Width,
                Height: size.Height,
            },
        )
        .map_err(|_| "frame_pool")?;
        let session = pool
            .CreateCaptureSession(&item)
            .map_err(|_| "capture_session")?;
        session.StartCapture().map_err(|_| "start_capture")?;
        let deadline = Instant::now() + Duration::from_millis(3_000);
        let frame = loop {
            if let Ok(frame) = pool.TryGetNextFrame() {
                break frame;
            }
            if Instant::now() >= deadline {
                return Err("frame_timeout");
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let surface = frame.Surface().map_err(|_| "frame_surface")?;
        let unknown: IUnknown = surface.cast().map_err(|_| "surface_unknown")?;
        let mut access_ptr = core::ptr::null_mut();
        unsafe {
            unknown
                .query(&IID_IDIRECT3D_DXGI_INTERFACE_ACCESS, &mut access_ptr)
                .ok()
                .map_err(|_| "surface_access")?;
        }
        let access_vtbl = unsafe { *(access_ptr as *mut *mut DxgiInterfaceAccessVtbl) };
        let mut source_ptr = core::ptr::null_mut();
        unsafe {
            ((*access_vtbl).get_interface)(access_ptr, &ID3D11Texture2D::IID, &mut source_ptr)
                .ok()
                .map_err(|_| "surface_texture")?;
        }
        let source: ID3D11Texture2D = unsafe { ID3D11Texture2D::from_raw(source_ptr) };
        let desc = D3D11_TEXTURE2D_DESC {
            Width: size.Width as u32,
            Height: size.Height as u32,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };
        let mut staging: Option<ID3D11Texture2D> = None;
        unsafe {
            device
                .CreateTexture2D(&desc, None, Some(&mut staging))
                .map_err(|_| "staging_texture")?;
        }
        let staging = staging.ok_or("staging_texture_null")?;
        unsafe {
            context.CopyResource(&staging, &source);
        }
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe {
            context
                .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                .map_err(|_| "map_texture")?;
        }
        let row_bytes = (size.Width as usize)
            .checked_mul(4)
            .ok_or("capture_overflow")?;
        let total = row_bytes
            .checked_mul(size.Height as usize)
            .ok_or("capture_overflow")?;
        let mut bgra = vec![0u8; total];
        for y in 0..size.Height as usize {
            unsafe {
                core::ptr::copy_nonoverlapping(
                    mapped.pData.add(y * mapped.RowPitch as usize),
                    bgra.as_mut_ptr().add(y * row_bytes) as *mut _,
                    row_bytes,
                );
            }
        }
        unsafe {
            context.Unmap(&staging, 0);
        }
        let png = encode_png_bgra(&bgra, size.Width as usize, size.Height as usize);
        if png.len() > MAX_CAPTURE_PNG_BYTES {
            return Err("png_too_large");
        }
        Ok((size.Width, size.Height, png))
    }

    fn encode_png_bgra(bgra: &[u8], width: usize, height: usize) -> Vec<u8> {
        let mut raw = Vec::with_capacity((width * 4 + 1) * height);
        for y in 0..height {
            raw.push(0);
            for x in 0..width {
                let i = (y * width + x) * 4;
                raw.extend_from_slice(&[bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]]);
            }
        }
        let mut compressed = ZlibEncoder::new(Vec::new(), Compression::fast());
        compressed.write_all(&raw).expect("memory write");
        let compressed = compressed.finish().expect("memory finish");
        let mut png = vec![137, 80, 78, 71, 13, 10, 26, 10];
        png_chunk(
            &mut png,
            b"IHDR",
            &[
                ((width >> 24) & 255) as u8,
                (width >> 16) as u8,
                (width >> 8) as u8,
                width as u8,
                ((height >> 24) & 255) as u8,
                (height >> 16) as u8,
                (height >> 8) as u8,
                height as u8,
                8,
                6,
                0,
                0,
                0,
            ],
        );
        png_chunk(&mut png, b"IDAT", &compressed);
        png_chunk(&mut png, b"IEND", &[]);
        png
    }
    fn png_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(data);
        let mut crc = 0xffff_ffffu32;
        for b in kind.iter().chain(data) {
            crc ^= *b as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xedb88320
                } else {
                    crc >> 1
                };
            }
        }
        out.extend_from_slice(&(!crc).to_be_bytes());
    }
}
