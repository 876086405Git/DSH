//! Bounded CoreDevice ABI. A successful HID result means transport dispatch,
//! never proof that the foreground application has processed an input.
use std::ffi::{CString, c_char};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use idevice::{ReadWrite, RsdService};
use idevice::core_device::{AppServiceClient, ScreenCaptureServiceClient, ImageFormat,
    UniversalHidServiceClient, IndigoHidClient, MainKeyboardService, KeyboardUsage,
    ButtonState, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE};
use idevice::springboardservices::SpringBoardServicesClient;
use idevice::dvt::{remote_server::RemoteServerClient, screenshot::ScreenshotClient};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch};
use zeroize::Zeroize;

use crate::{Failure, Owner, Tunnel, cancelled, connect_tunnel_reporting, ddi, media, next_handle,
    owner, pairing, ffi, worker_admitted, MAX_CONFIG, STOP_UNCONFIRMED};

const MAX_REQUEST: usize = 16 * 1024;
const MAX_JSON: usize = 8192;
const MAX_PNG: usize = 16 * 1024 * 1024;
const MAX_APPS: usize = 1024 * 1024;
const MAX_ASCII: usize = 1024;
const FRAME_LIFETIME_NS: u64 = 30_000_000_000;
const SCREEN: &str = "com.apple.coredevice.screencaptureservice";
const APPS: &str = "com.apple.coredevice.appservice";
const ORIENTATION: &str = "com.apple.springboardservices.shim.remote";
const HID: &str = "com.apple.coredevice.hid.universalhidservice";
const INDIGO: &str = "com.apple.coredevice.hid.indigo";
const DISPLAY: &str = "com.apple.coredevice.displayservice";
const DVT: &str = "com.apple.instruments.dtservicehub";
// These establish the developer image's base services. Screenshot/input
// support is probed separately: older images expose DVT rather than SCREEN.
const CORE_REQUIRED: &[&str] = &[APPS, ORIENTATION];

const STARTING: u8 = 0;
const READY: u8 = 1;
const STOPPING: u8 = 2;
const FAULTED: u8 = 3;
const DONE: u8 = 4;

const INVALID: i32 = 1;
const BUSY: i32 = 2;
const STALE: i32 = 3;
const NOT_READY: i32 = 4;
const IS_STOPPING: i32 = 5;
const IS_FAULTED: i32 = 6;
const TOO_LARGE: i32 = 7;
const INTERNAL: i32 = 8;

const SERVICE: Failure = Failure("ERR_PHONE_CORE_SERVICE_UNAVAILABLE");
const PROTOCOL: Failure = Failure("ERR_PHONE_CORE_PROTOCOL");
const FRAME: Failure = Failure("ERR_PHONE_STALE_FRAME");
const ORIENTATION_CHANGED: Failure = Failure("ERR_PHONE_ORIENTATION_CHANGED");
const TOUCH_ORIENTATION: Failure = Failure("ERR_PHONE_TOUCH_ORIENTATION_UNVERIFIED");
const LIMIT: Failure = Failure("ERR_PHONE_SIZE_LIMIT");
const CANCELLED: Failure = Failure("ERR_PHONE_CANCELLED");
const DEADLINE: Failure = Failure("ERR_PHONE_REQUEST_TIMEOUT");
const INTERNAL_FAILURE: Failure = Failure("ERR_PHONE_INTERNAL");

type EventCallback = extern "C" fn(u64, *const c_char, i32, *const c_char);
type ResultCallback = extern "C" fn(u64, u64, i32, *const c_char, *const u8, usize);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfigWire {
    run_id: String,
    pairing_base64: Option<pairing::SecretString>,
    pairing_file: Option<String>,
    host: String,
    port: u16,
    ddi_cache: Option<ddi::DdiCache>,
    #[serde(rename = "allowDDIMount", default)]
    allow_ddi_mount: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ByteConfigWire {
    run_id: String,
    host: String,
    port: u16,
    ddi_cache: Option<ddi::DdiCache>,
    #[serde(rename = "allowDDIMount", default)]
    allow_ddi_mount: bool,
}
impl From<ByteConfigWire> for ConfigWire {
    fn from(value: ByteConfigWire) -> Self {
        Self { run_id: value.run_id, pairing_base64: None, pairing_file: None,
            host: value.host, port: value.port, ddi_cache: value.ddi_cache,
            allow_ddi_mount: value.allow_ddi_mount }
    }
}
struct Config {
    run_id: String,
    pairing: Option<pairing::PairingInput>,
    host: String,
    port: u16,
    ddi_cache: Option<ddi::DdiCache>,
    allow_ddi_mount: bool,
}
impl Config {
    fn parse(bytes: &[u8]) -> Option<Self> {
        if bytes.is_empty() || bytes.len() > MAX_CONFIG { return None; }
        let wire: ConfigWire = serde_json::from_slice(bytes).ok()?;
        Self::from_wire(wire, None)
    }
    fn parse_bytes(bytes: &[u8], pairing: &[u8]) -> Option<Self> {
        if bytes.is_empty() || bytes.len() > MAX_CONFIG
            || pairing.is_empty() || pairing.len() > pairing::MAX_PAIRING { return None; }
        let wire: ByteConfigWire = serde_json::from_slice(bytes).ok()?;
        Self::from_wire(wire.into(), Some(pairing))
    }
    fn from_wire(wire: ConfigWire, pairing_bytes: Option<&[u8]>) -> Option<Self> {
        let host: std::net::IpAddr = wire.host.parse().ok()?;
        if uuid::Uuid::parse_str(&wire.run_id).is_err() || wire.run_id.contains('\0')
            || !(host.is_loopback() || wire.host == "10.7.0.1") || wire.port == 0
            || wire.ddi_cache.as_ref().is_some_and(|cache| !cache.valid()) {
            return None;
        }
        Some(Self { run_id: wire.run_id,
            pairing: Some(match pairing_bytes {
                Some(bytes) => pairing::PairingInput::from_bytes(bytes)?,
                None => pairing::PairingInput::parse(wire.pairing_base64, wire.pairing_file)?,
            }),
            host: wire.host, port: wire.port, ddi_cache: wire.ddi_cache,
            allow_ddi_mount: wire.allow_ddi_mount })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum NamedKey { Home, Enter, Backspace, Tab, Escape, ArrowUp, ArrowDown, ArrowLeft, ArrowRight }
fn tap_duration() -> u64 { 50 }
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase", deny_unknown_fields)]
enum Input {
    PrepareInput,
    Screenshot,
    Apps,
    Launch { bundle_id: String },
    Tap { x: f64, y: f64, #[serde(default = "tap_duration")] duration_ms: u64, native_frame_id: String },
    Swipe { from_x: f64, from_y: f64, to_x: f64, to_y: f64, duration_ms: u64, native_frame_id: String },
    Key { key: NamedKey, native_frame_id: String },
    Ascii { text: String, #[serde(default)] replace: bool, native_frame_id: String },
    Paste { #[serde(default)] replace: bool, native_frame_id: String },
}
impl Drop for Input {
    fn drop(&mut self) {
        if let Self::Ascii { text, .. } = self { text.zeroize(); }
    }
}
fn bundle_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 255 && value.contains('.')
        && value.split('.').all(|part| !part.is_empty())
        && value.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-')
}
fn application_catalog(apps: impl IntoIterator<Item = (String, String)>) -> Result<Vec<u8>, Failure> {
    let mut output = Vec::new();
    for (index, (name, id)) in apps.into_iter().enumerate() {
        if index >= 4096 { return Err(LIMIT); }
        // Device inventories can contain non-launchable entries. One invalid
        // identifier must not hide every valid app, and must not be offered as
        // a launch target. Retain Swift's independent per-entry validation.
        if !bundle_id(&id) || name.is_empty() || name.len() > 512 || name.chars().any(char::is_control) { continue; }
        output.push(json!({"name": name, "id": id}));
    }
    let bytes = serde_json::to_vec(&json!({"apps": output})).map_err(|_| INTERNAL_FAILURE)?;
    if bytes.len() > MAX_APPS { return Err(LIMIT); }
    Ok(bytes)
}
fn coordinate(value: f64) -> bool { value.is_finite() && (0.0..=1.0).contains(&value) }
impl Input {
    fn parse(bytes: &[u8]) -> Option<Self> {
        if bytes.is_empty() || bytes.len() > MAX_REQUEST { return None; }
        let input: Self = serde_json::from_slice(bytes).ok()?;
        let valid_frame = |id: &str| uuid::Uuid::parse_str(id).is_ok();
        let valid = match &input {
            Self::PrepareInput | Self::Screenshot | Self::Apps => true,
            Self::Launch { bundle_id: id } => bundle_id(id),
            Self::Tap { x, y, duration_ms, native_frame_id: id } => coordinate(*x) && coordinate(*y) && (50..=1500).contains(duration_ms) && valid_frame(id),
            Self::Swipe { from_x, from_y, to_x, to_y, duration_ms, native_frame_id: id } =>
                [from_x, from_y, to_x, to_y].into_iter().all(|v| coordinate(*v))
                    && (50..=2000).contains(duration_ms) && valid_frame(id),
            Self::Key { native_frame_id: id, .. } | Self::Paste { native_frame_id: id, .. } => valid_frame(id),
            Self::Ascii { text, native_frame_id: id, .. } => valid_frame(id) && !text.is_empty()
                && text.len() <= MAX_ASCII && text.bytes().all(|c| ascii_key(c).is_some()),
        };
        valid.then_some(input)
    }
    fn frame_id(&self) -> Option<&str> {
        match self {
            Self::Tap { native_frame_id, .. } | Self::Swipe { native_frame_id, .. }
            | Self::Key { native_frame_id, .. } | Self::Ascii { native_frame_id, .. }
            | Self::Paste { native_frame_id, .. } => Some(native_frame_id),
            _ => None,
        }
    }
    fn timeout(&self) -> Duration {
        // Explicit prepareInput negotiates the owned audio/video gate. ASCII
        // also has a longer, still bounded deadline for its validated sequence.
        Duration::from_secs(if matches!(self, Self::PrepareInput) || self.frame_id().is_some() { 90 } else { 30 })
    }
}

pub(crate) struct Control {
    phase: AtomicU8,
    active: AtomicU64,
    last: AtomicU64,
    cancel: watch::Sender<u64>,
    requests: mpsc::Sender<PendingRequest>,
}
impl Control {
    pub(crate) fn stop_accepting(&self) {
        // The caller holds OWNER, so this transition is atomic with acceptance.
        if self.phase.load(Ordering::Acquire) < STOPPING {
            self.phase.store(STOPPING, Ordering::Release);
        }
    }
}

struct Responder {
    handle: u64,
    id: u64,
    callback: ResultCallback,
    control: Arc<Control>,
    may_have_acted: Arc<AtomicBool>,
    armed: bool,
}
impl Responder {
    fn complete(&mut self, status: i32, metadata: Value, bytes: &[u8]) {
        if !self.armed { return; }
        self.armed = false;
        self.control.active.compare_exchange(self.id, 0, Ordering::AcqRel, Ordering::Acquire).ok();
        emit_result(self.callback, self.handle, self.id, status, metadata, bytes);
    }
    fn failure(&mut self, error: Failure, cancelled: bool, cleanup: bool) {
        let acted = self.may_have_acted.load(Ordering::Acquire);
        self.complete(if acted { 3 } else if cancelled { 2 } else { 1 },
            failure_metadata(error, acted, cleanup), &[]);
    }
}
impl Drop for Responder {
    fn drop(&mut self) {
        // Also covers a panic while a request future or the receiver is dropped.
        // Unknown teardown is never reported as a safe completion.
        if self.armed {
            stop_accepting(self.handle, &self.control);
            self.failure(INTERNAL_FAILURE, false, false);
        }
    }
}
struct Request { input: Input, response: Responder }

enum RequestState { Pending, Ready(Request), Rejected, Closed }
struct RequestGate { state: Mutex<RequestState>, changed: Condvar }
struct PendingRequest { gate: Arc<RequestGate> }
impl PendingRequest {
    fn take(self) -> Option<Request> {
        let mut state = self.gate.state.lock().unwrap_or_else(|error| error.into_inner());
        while matches!(*state, RequestState::Pending) {
            state = self.gate.changed.wait(state).unwrap_or_else(|error| error.into_inner());
        }
        let request = match std::mem::replace(&mut *state, RequestState::Closed) {
            RequestState::Ready(request) => Some(request), _ => None,
        };
        drop(state);
        request
    }
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        let previous = {
            let mut state = self.gate.state.lock().unwrap_or_else(|error| error.into_inner());
            std::mem::replace(&mut *state, RequestState::Closed)
        };
        self.gate.changed.notify_all();
        // Before admission this contains no Responder, including when try_send
        // drops its argument on the calling thread. After admission only the
        // receiver owns this placeholder; its worker drops the unique responder
        // outside both locks, before it can emit the owner terminal event.
        drop(previous);
    }
}

fn stable_code(error: Failure) -> &'static str { error.0.split(':').next().unwrap_or("ERR_PHONE_INTERNAL") }
fn variant(error: Failure) -> Option<&'static str> {
    match error.0.split_once(':').map(|(_, value)| value) {
        Some("personalized") => Some("personalized"), Some("cryptex") => Some("cryptex"), _ => None,
    }
}
fn failure_metadata(error: Failure, acted: bool, cleanup: bool) -> Value {
    json!({"outcome":if acted { "uncertain" } else { "notSent" },
        "code":stable_code(error),"mayHaveActed":acted,"cleanupConfirmed":cleanup})
}
fn emit_event(callback: EventCallback, handle: u64, run_id: &str, kind: i32, metadata: Value) {
    let payload = metadata.to_string();
    if payload.len() > MAX_JSON { return; } // Every event field is bounded/static.
    if let (Ok(run), Ok(payload)) = (CString::new(run_id), CString::new(payload)) {
        callback(handle, run.as_ptr(), kind, payload.as_ptr());
    }
}
fn emit_result(callback: ResultCallback, handle: u64, id: u64, status: i32, metadata: Value, bytes: &[u8]) {
    let payload = metadata.to_string();
    let (status, payload, bytes) = if payload.len() > MAX_JSON || bytes.len() > MAX_PNG {
        let acted = metadata.get("mayHaveActed").and_then(Value::as_bool).unwrap_or(true);
        (if acted { 3 } else { 1 }, failure_metadata(LIMIT, acted, false).to_string(), &[][..])
    } else { (status, payload, bytes) };
    // JSON escapes control characters and therefore contains no interior NUL.
    if let Ok(payload) = CString::new(payload) {
        callback(handle, id, status, payload.as_ptr(),
            if bytes.is_empty() { std::ptr::null() } else { bytes.as_ptr() }, bytes.len());
    }
}

/// New length-delimited ABI. Pointers must describe readable/writable memory for
/// their supplied lengths; this cannot be verified by a C ABI implementation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsh_phone_core_start(
    config_json: *const u8, config_len: usize, callback: Option<EventCallback>, handle_out: *mut u64,
) -> i32 {
    let mut admitted = false;
    let result = ffi::catch(|| {
        if handle_out.is_null() { return INVALID; }
        unsafe { *handle_out = 0; }
        if config_json.is_null() || config_len == 0 || callback.is_none() { return INVALID; }
        if config_len > MAX_CONFIG { return TOO_LARGE; }
        #[cfg(test)] ffi::testing::at("core_parse");
        let Some(config) = Config::parse(unsafe { std::slice::from_raw_parts(config_json, config_len) }) else { return INVALID; };
        unsafe { start_core(config, callback.unwrap(), handle_out, &mut admitted) }
    });
    if admitted { 0 } else { result.unwrap_or(INTERNAL) }
}

/// Config contains no pairing fields. Both caller buffers expire at return;
/// only the validated typed pairing record reaches the unchanged worker path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsh_phone_core_start_bytes(
    config_json: *const u8, config_len: usize, pairing_plist: *const u8, pairing_len: usize,
    callback: Option<EventCallback>, handle_out: *mut u64,
) -> i32 {
    let mut admitted = false;
    let result = ffi::catch(|| {
        if handle_out.is_null() { return INVALID; }
        unsafe { *handle_out = 0; }
        if config_json.is_null() || config_len == 0 || pairing_plist.is_null()
            || pairing_len == 0 || callback.is_none() { return INVALID; }
        if config_len > MAX_CONFIG || pairing_len > pairing::MAX_PAIRING { return TOO_LARGE; }
        #[cfg(test)] ffi::testing::at("core_parse");
        let Some(config) = Config::parse_bytes(
            unsafe { std::slice::from_raw_parts(config_json, config_len) },
            unsafe { std::slice::from_raw_parts(pairing_plist, pairing_len) },
        ) else { return INVALID; };
        unsafe { start_core(config, callback.unwrap(), handle_out, &mut admitted) }
    });
    if admitted { 0 } else { result.unwrap_or(INTERNAL) }
}

unsafe fn start_core(config: Config, callback: EventCallback, handle_out: *mut u64, admitted: &mut bool) -> i32 {
    let Ok(mut slot) = owner().lock() else { return INTERNAL; };
    if slot.is_some() { return BUSY; }
    // This guard outlives the critical catch, including panic-payload disposal.
    // The spawned worker waits for its matching published owner before any I/O.
    let result = ffi::catch(|| {
        let Some(handle) = next_handle() else { return INTERNAL; };
        let (stop, stopped) = watch::channel(false);
        let (cancel, cancelled_request) = watch::channel(0);
        let (requests, receiver) = mpsc::channel(1);
        let control = Arc::new(Control { phase: AtomicU8::new(STARTING), active: AtomicU64::new(0),
            last: AtomicU64::new(0), cancel, requests });
        let entry = Owner { handle, stop, cancelled: Arc::new(AtomicBool::new(false)), core: Some(control.clone()) };
        let run_id = config.run_id.clone();
        let spawned = std::thread::Builder::new().name("dsh-phone-core".into()).spawn(move || {
            if !worker_admitted(handle) { return; }
            let mut outcome = ffi::catch(|| {
                emit_event(callback, handle, &run_id, 0, json!({"stage":"tunnel"}));
                let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(runtime) => runtime,
                    Err(_) => return Completion::failed(INTERNAL_FAILURE, true),
                };
                // All local transport tasks drop before the terminal event.
                runtime.block_on(run(config, callback, handle, control.clone(), stopped, cancelled_request, receiver))
            }).unwrap_or_else(|_| Completion::failed(STOP_UNCONFIRMED, false));
            if outcome.run_id.is_empty() { outcome.run_id = run_id; }
            finish(handle, callback, &control, outcome);
        });
        if spawned.is_err() { return INTERNAL; }
        #[cfg(test)] ffi::testing::at("core_spawned");
        *slot = Some(entry);
        unsafe { *handle_out = handle; }
        *admitted = true;
        #[cfg(test)] ffi::testing::at("core_committed");
        0
    });
    if *admitted { 0 } else { result.unwrap_or(INTERNAL) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsh_phone_core_request(
    handle: u64, request_id: u64, request_json: *const u8, request_len: usize, callback: Option<ResultCallback>,
) -> i32 {
    let mut admitted = false;
    let result = ffi::catch(|| {
        if request_id == 0 || request_json.is_null() || request_len == 0 || callback.is_none() { return INVALID; }
        if request_len > MAX_REQUEST { return TOO_LARGE; }
        #[cfg(test)] ffi::testing::at("request_parse");
        let Some(input) = Input::parse(unsafe { std::slice::from_raw_parts(request_json, request_len) }) else { return INVALID; };
        admit_request(handle, request_id, input, callback.unwrap(), &mut admitted)
    });
    if admitted { 0 } else { result.unwrap_or(INTERNAL) }
}

fn admit_request(handle: u64, request_id: u64, input: Input, callback: ResultCallback, admitted: &mut bool) -> i32 {
    let gate = Arc::new(RequestGate { state: Mutex::new(RequestState::Pending), changed: Condvar::new() });
    let may_have_acted = Arc::new(AtomicBool::new(false));
    let Ok(slot) = owner().lock() else { return INTERNAL; };
    let Some(entry) = slot.as_ref().filter(|entry| entry.handle == handle) else { return STALE; };
    let Some(control) = &entry.core else { return STALE; };
    match control.phase.load(Ordering::Acquire) {
        STARTING => return NOT_READY, STOPPING => return IS_STOPPING,
        FAULTED => return IS_FAULTED, DONE => return STALE, READY => {}, _ => return INTERNAL,
    }
    if request_id <= control.last.load(Ordering::Acquire) { return STALE; }
    if control.active.load(Ordering::Acquire) != 0 { return BUSY; }
    let request = Request { input, response: Responder { handle, id: request_id,
        callback, control: control.clone(), may_have_acted, armed: false } };
    let sent = ffi::catch(|| {
        #[cfg(test)] ffi::testing::at("request_pre_enqueue");
        if control.requests.try_send(PendingRequest { gate: gate.clone() }).is_err() { return false; }
        #[cfg(test)] ffi::testing::at("request_enqueued");
        true
    });
    commit_request(&gate, control, request, matches!(sent, Ok(true)), admitted);
    drop(slot);
    gate.changed.notify_all();
    if *admitted { 0 } else { INTERNAL }
}

fn commit_request(gate: &RequestGate, control: &Control, mut request: Request, queued: bool, admitted: &mut bool) {
    // OWNER is held by the caller, and this gate guard stays outside the
    // critical catch. The receiver cannot act before publication is resolved.
    let mut state = gate.state.lock().unwrap_or_else(|error| error.into_inner());
    // A Tokio sender can acquire its permit before receiver close/drain, then
    // push after that drain. A Pending placeholder alone does not prove that
    // a receiver can still own it. Do not publish an armed Request into such
    // an orphaned channel: it would also retain Request -> Control -> Sender.
    // If close instead races after this check, our already-enqueued placeholder
    // is owned by the receiver/drain, which waits on this gate before dropping
    // the unique responder. That accepted completion stays on the worker.
    if queued && matches!(*state, RequestState::Pending) && !control.requests.is_closed() {
        let _ = ffi::catch(|| {
            #[cfg(test)] ffi::testing::at("request_pre_commit");
            // Only infallible scalar stores and moves in this commit group.
            let request_id = request.response.id;
            request.response.armed = true;
            control.last.store(request_id, Ordering::Release);
            control.active.store(request_id, Ordering::Release);
            *state = RequestState::Ready(request);
            *admitted = true;
            #[cfg(test)] ffi::testing::at("request_committed");
        });
    }
    if !*admitted && matches!(*state, RequestState::Pending) {
        *state = RequestState::Rejected;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dsh_phone_core_cancel(handle: u64, request_id: u64) {
    if request_id == 0 { return; }
    if let Ok(slot) = owner().lock() {
        if let Some(control) = slot.as_ref().filter(|entry| entry.handle == handle).and_then(|entry| entry.core.as_ref()) {
            if control.active.load(Ordering::Acquire) == request_id { let _ = control.cancel.send(request_id); }
        }
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn dsh_phone_core_stop(handle: u64) {
    if let Ok(slot) = owner().lock() {
        if let Some(entry) = slot.as_ref().filter(|entry| entry.handle == handle && entry.core.is_some()) {
            entry.core.as_ref().unwrap().stop_accepting();
            entry.cancelled.store(true, Ordering::Release);
            let _ = entry.stop.send(true);
        }
    }
}

struct Completion { run_id: String, error: Option<Failure>, stopped: bool, cleanup: bool }
impl Completion {
    fn failed(error: Failure, cleanup: bool) -> Self { Self { run_id: String::new(), error: Some(error), stopped: false, cleanup } }
}
fn finish(handle: u64, callback: EventCallback, control: &Control, mut outcome: Completion) {
    if outcome.cleanup {
        match owner().lock() {
            Ok(mut slot) if slot.as_ref().is_some_and(|entry| entry.handle == handle) => { *slot = None; },
            _ => { outcome.cleanup = false; outcome.error = Some(STOP_UNCONFIRMED); },
        }
    }
    control.phase.store(if outcome.cleanup { DONE } else { FAULTED }, Ordering::Release);
    let error = outcome.error.unwrap_or(STOP_UNCONFIRMED);
    let mut event = json!({"cleanupConfirmed":outcome.cleanup});
    if !outcome.stopped || !outcome.cleanup { event["code"] = stable_code(error).into(); }
    if let Some(variant) = variant(error) { event["variant"] = variant.into(); }
    emit_event(callback, handle, &outcome.run_id, if !outcome.cleanup { 4 } else if outcome.stopped { 2 } else { 3 }, event);
}
async fn request_cancelled(receiver: &mut watch::Receiver<u64>, id: u64) {
    loop {
        if *receiver.borrow_and_update() == id { return; }
        if receiver.changed().await.is_err() { return; }
    }
}
fn stop_accepting(handle: u64, control: &Control) {
    if let Ok(slot) = owner().lock() {
        if slot.as_ref().is_some_and(|entry| entry.handle == handle) { control.stop_accepting(); }
    }
}
fn drain_cancelled(receiver: &mut mpsc::Receiver<PendingRequest>, cleanup: bool) {
    while let Ok(pending) = receiver.try_recv() {
        if let Some(mut request) = pending.take() { request.response.failure(CANCELLED, true, cleanup); }
    }
}

async fn run(mut config: Config, callback: EventCallback, handle: u64, control: Arc<Control>,
    mut stopped: watch::Receiver<bool>, mut cancel: watch::Receiver<u64>, mut requests: mpsc::Receiver<PendingRequest>,
) -> Completion {
    let mut completion = Completion { run_id: config.run_id.clone(), error: None, stopped: false, cleanup: true };
    let Some(pairing) = config.pairing.take() else { completion.error = Some(crate::PAIRING); return completion; };
    let connected = tokio::select! {
        biased;
        _ = cancelled(&mut stopped) => { completion.stopped = true; return completion; },
        result = tokio::time::timeout(Duration::from_secs(90), connect_tunnel_reporting(pairing, &config.host, config.port,
            |field| { let mut event = json!({"stage":"tunnel"}); event[field] = true.into(); emit_event(callback, handle, &config.run_id, 0, event); }
        )) => result.unwrap_or(Err(crate::TUNNEL)),
    };
    let mut tunnel = match connected { Ok(tunnel) => tunnel, Err(error) => { completion.error = Some(error); return completion; } };
    let lockdown = async {
        let mut client = idevice::lockdown::LockdownClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| SERVICE)?;
        let version = client.get_value(Some("ProductVersion"), None).await.map_err(|_| SERVICE)?;
        if version.as_string().is_none() { return Err(PROTOCOL); }
        Ok::<_, Failure>(())
    };
    let checked = tokio::select! { biased;
        _ = cancelled(&mut stopped) => { completion.stopped = true; Err(CANCELLED) },
        result = tokio::time::timeout(Duration::from_secs(20), lockdown) => result.unwrap_or(Err(SERVICE)),
    };
    if let Err(error) = checked { completion.error = Some(error); return completion; }
    emit_event(callback, handle, &config.run_id, 0, json!({"stage":"lockdown","lockdownReady":true}));
    emit_event(callback, handle, &config.run_id, 0, json!({"stage":"services"}));
    let submitted = AtomicBool::new(false);
    let prepare = ddi::ensure(&mut tunnel, config.ddi_cache.as_ref(), config.allow_ddi_mount,
        CORE_REQUIRED, |progress| {
            let mut event = json!({"stage":progress.stage});
            if let Some(variant) = progress.variant { event["variant"] = variant.name().into(); }
            if let (Some(done), Some(total)) = (progress.completed, progress.total) {
                event["completedBytes"] = done.into(); event["totalBytes"] = total.into();
            }
            emit_event(callback, handle, &config.run_id, 5, event);
        }, &submitted);
    let prepared = tokio::select! {
        biased;
        _ = cancelled(&mut stopped) => { completion.stopped = true; Err(CANCELLED) },
        result = tokio::time::timeout(Duration::from_secs(300), prepare) => result.unwrap_or(Err(crate::DDI)),
    };
    if let Err(error) = prepared {
        completion.cleanup = !submitted.load(Ordering::Acquire);
        completion.error = Some(if completion.cleanup { error } else { STOP_UNCONFIRMED });
        return completion;
    }
    if matches!(prepared, Ok(true)) {
        emit_event(callback, handle, &config.run_id, 5, json!({"stage":"refreshingServices","ddiMounted":true}));
    }
    let mut session = Session::new(tunnel);
    let probe = tokio::select! {
        biased;
        _ = cancelled(&mut stopped) => { completion.stopped = true; Err(CANCELLED) },
        result = tokio::time::timeout(Duration::from_secs(30), session.probe()) => result.unwrap_or(Err(SERVICE)),
    };
    let capabilities = match probe { Ok(capabilities) => capabilities,
        Err(error) => { completion.error = Some(error); return completion; } };
    let ready = if let Ok(slot) = owner().lock() {
        if slot.as_ref().is_some_and(|entry| entry.handle == handle) && control.phase.load(Ordering::Acquire) == STARTING {
            control.phase.store(READY, Ordering::Release); true
        } else { false }
    } else { false };
    if ready {
        emit_event(callback, handle, &config.run_id, 1, json!({"capabilities":capabilities}));
    } else { completion.stopped = true; }
    while ready && !completion.stopped && completion.error.is_none() {
        let request = tokio::select! { biased;
            _ = cancelled(&mut stopped) => { completion.stopped = true; None },
            request = requests.recv() => request,
        };
        let Some(pending) = request else { break; };
        let Some(mut request) = pending.take() else { continue; };
        let mut cancelled_now = false;
        let operation = session.execute(&request.input, &request.response.may_have_acted);
        let result = tokio::select! { biased;
            _ = cancelled(&mut stopped) => { completion.stopped = true; cancelled_now = true; Err(CANCELLED) },
            _ = request_cancelled(&mut cancel, request.response.id) => { cancelled_now = true; Err(CANCELLED) },
            result = tokio::time::timeout(request.input.timeout(), operation) => result.unwrap_or(Err(DEADLINE)),
        };
        if cancelled_now { session.frame = None; }
        match result {
            Ok(payload) => request.response.complete(0, payload.metadata, &payload.bytes),
            Err(error) => {
                let acted = request.response.may_have_acted.load(Ordering::Acquire);
                let retire = completion.stopped || acted || session.has_unconfirmed_resources();
                if retire {
                    stop_accepting(handle, &control);
                    completion.cleanup = session.cleanup().await;
                    request.response.failure(error, cancelled_now, completion.cleanup);
                    if !completion.stopped { completion.error = Some(error); }
                    if !completion.cleanup { completion.error = Some(STOP_UNCONFIRMED); }
                    drain_cancelled(&mut requests, completion.cleanup);
                    return completion;
                }
                request.response.failure(error, cancelled_now, true);
            }
        }
    }
    stop_accepting(handle, &control);
    completion.cleanup = session.cleanup().await;
    drain_cancelled(&mut requests, completion.cleanup);
    if !completion.cleanup { completion.error = Some(STOP_UNCONFIRMED); }
    completion
}

struct Payload { metadata: Value, bytes: Vec<u8> }
impl Payload {
    fn read(kind: &str, content_type: &str, bytes: Vec<u8>) -> Self {
        Self { metadata: json!({"outcome":"read","mayHaveActed":false,"cleanupConfirmed":true,
            "kind":kind,"contentType":content_type}), bytes }
    }
    fn dispatched() -> Self {
        Self { metadata: json!({"outcome":"dispatched","mayHaveActed":true,"cleanupConfirmed":true}), bytes: Vec::new() }
    }
}
// Rust 1.99.1's Apple Instant uses CLOCK_UPTIME_RAW, which excludes system
// sleep. Approval age instead uses an explicitly sleep-inclusive clock. These
// functions do not change Tokio/Instant scheduling or request timeout behavior.
#[cfg(any(target_vendor = "apple", test))]
fn mach_ticks_to_ns(ticks: u64, numer: u32, denom: u32) -> Option<u64> {
    if numer == 0 || denom == 0 { return None; }
    let value = (ticks as u128).checked_mul(numer as u128)? / denom as u128;
    u64::try_from(value).ok()
}

#[cfg(any(target_os = "linux", test))]
fn timespec_to_ns(seconds: i64, nanoseconds: i64) -> Option<u64> {
    if seconds < 0 || !(0..1_000_000_000).contains(&nanoseconds) { return None; }
    (seconds as u64).checked_mul(1_000_000_000)?.checked_add(nanoseconds as u64)
}

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    // <mach/mach_time.h>: uint64_t, available since iOS 10.0/macOS 10.12.
    // Pinned libc declares timebase_info but not mach_continuous_time.
    fn mach_continuous_time() -> u64;
}

#[cfg(target_vendor = "apple")]
#[allow(deprecated)] // Existing pinned libc's Mach timebase ABI; no new crate.
fn continuous_now_ns() -> Option<u64> {
    let mut info = libc::mach_timebase_info { numer: 0, denom: 0 };
    if unsafe { libc::mach_timebase_info(&mut info) } != 0 { return None; }
    mach_ticks_to_ns(unsafe { mach_continuous_time() }, info.numer, info.denom)
}

#[cfg(target_os = "linux")]
fn continuous_now_ns() -> Option<u64> {
    let mut value = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut value) } != 0 { return None; }
    timespec_to_ns(value.tv_sec as i64, value.tv_nsec as i64)
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
fn continuous_now_ns() -> Option<u64> { None }

struct Frame { id: uuid::Uuid, at_ns: u64, orientation: u8 }
impl Frame {
    fn matches(&self, id: &str, now_ns: Option<u64>) -> bool {
        uuid::Uuid::parse_str(id).ok() == Some(self.id)
            && now_ns.and_then(|now| now.checked_sub(self.at_ns))
                .is_some_and(|elapsed| elapsed <= FRAME_LIFETIME_NS)
    }
}
struct KeyboardLease { client: UniversalHidServiceClient<Box<dyn ReadWrite>>, service: MainKeyboardService }
struct TouchLease { client: UniversalHidServiceClient<Box<dyn ReadWrite>>, x: u16, y: u16 }
struct Session {
    tunnel: Tunnel,
    frame: Option<Frame>,
    media: media::OwnedMedia,
    keyboard: Option<KeyboardLease>,
    keyboard_unknown: bool,
    touch: Option<TouchLease>,
    home: Option<IndigoHidClient<Box<dyn ReadWrite>>>,
}
impl Session {
    fn new(tunnel: Tunnel) -> Self {
        Self { tunnel, frame: None, media: media::OwnedMedia::new(), keyboard: None,
            keyboard_unknown: false, touch: None, home: None }
    }
    async fn orientation(&mut self) -> Result<u8, Failure> {
        let mut client = SpringBoardServicesClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
        let orientation = client.get_interface_orientation().await.map_err(|_| SERVICE)? as u8;
        if !(1..=4).contains(&orientation) { return Err(PROTOCOL); }
        Ok(orientation)
    }
    async fn confirm_frame(&mut self, frame: &Frame, id: &str) -> Result<(), Failure> {
        if !frame.matches(id, continuous_now_ns()) { return Err(FRAME); }
        let orientation = self.orientation().await?;
        // A slow read-only RPC must not extend the approval's lifetime.
        if !frame.matches(id, continuous_now_ns()) { return Err(FRAME); }
        if orientation != frame.orientation { return Err(ORIENTATION_CHANGED); }
        Ok(())
    }
    async fn probe(&mut self) -> Result<Value, Failure> {
        self.orientation().await?;
        if self.tunnel.handshake.services.contains_key(SCREEN) {
            ScreenCaptureServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
        } else if self.tunnel.handshake.services.contains_key(DVT) {
            let mut client = self.dvt().await?;
            ScreenshotClient::new(&mut client).await.map_err(|_| SERVICE)?;
        } else { return Err(SERVICE); }
        AppServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
        let input = if self.tunnel.handshake.services.contains_key(HID) && self.tunnel.handshake.services.contains_key(DISPLAY) {
            let probe = async {
                let mut hid = UniversalHidServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
                hid.list_connected_services().await.map_err(|_| PROTOCOL)?;
                media::probe(&mut self.tunnel).await
            };
            probe.await.is_ok()
        } else { false };
        let home = if input && self.tunnel.handshake.services.contains_key(INDIGO) {
            IndigoHidClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.is_ok()
        } else { false };
        Ok(json!({"servicesReady":true,"screenshot":true,"apps":true,"launch":true,"touch":input,
            "touchPortraitOnly":true,"keys":input,"ascii":input,"paste":input,"home":home}))
    }
    fn has_unconfirmed_resources(&self) -> bool {
        self.keyboard_unknown || self.keyboard.is_some() || self.touch.is_some() || self.home.is_some() || self.media.uncertain()
    }
    async fn execute(&mut self, input: &Input, acted: &AtomicBool) -> Result<Payload, Failure> {
        match input {
            Input::PrepareInput => {
                // Swift invokes this only after a real native confirmation of
                // screen/control sharing. It is never an MCP/raw HID tool and
                // never part of a settings check or a DDI mount probe.
                self.frame = None;
                self.media.prepare(&mut self.tunnel, acted).await?;
                let changed = acted.load(Ordering::Acquire);
                return Ok(Payload { metadata: json!({"kind":"prepareInput",
                    "outcome":if changed { "dispatched" } else { "read" },
                    "mayHaveActed":changed,"cleanupConfirmed":true}), bytes: Vec::new() });
            }
            Input::Screenshot => return self.screenshot().await,
            Input::Apps => return self.apps().await,
            Input::Launch { bundle_id } => {
                self.frame = None;
                let mut client = AppServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
                acted.store(true, Ordering::Release);
                let result = client.launch_application(bundle_id.as_str(), &[], false, false, None, None, None).await.map_err(|_| SERVICE)?;
                if result.pid == 0 { return Err(PROTOCOL); }
                let mut payload = Payload::dispatched();
                payload.metadata["pid"] = result.pid.into();
                payload.metadata["foregroundVerified"] = false.into();
                return Ok(payload);
            }
            _ => {}
        }
        // Consume a frame before any input preparation. Even a rejected/expired
        // action requires a new screenshot and a fresh approval upstairs.
        let frame = self.frame.take().ok_or(FRAME)?;
        self.confirm_frame(&frame, input.frame_id().ok_or(FRAME)?).await?;
        require_touch_orientation(input, frame.orientation)?;
        // Input never starts media implicitly. Its approved screenshot must
        // have been captured after the explicit preparation operation.
        self.media.check_active(&mut self.tunnel).await?;
        // Read-only checks cannot extend a frame's lifetime; check again
        // immediately before creating any input resource or sending a report.
        self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
        match input {
            Input::Tap { x, y, duration_ms, .. } => {
                let client = UniversalHidServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
                self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
                self.touch = Some(TouchLease { client,
                    x: normalized(*x), y: normalized(*y) });
                let touch = self.touch.as_mut().unwrap();
                acted.store(true, Ordering::Release);
                touch.client.send_touchscreen(TOUCHSCREEN_STATE_CONTACT, touch.x, touch.y, None).await.map_err(|_| SERVICE)?;
                tokio::time::sleep(Duration::from_millis(*duration_ms)).await;
                self.release_touch().await?;
            }
            Input::Swipe { from_x, from_y, to_x, to_y, duration_ms, .. } => {
                let client = UniversalHidServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
                self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
                self.touch = Some(TouchLease { client,
                    x: normalized(*from_x), y: normalized(*from_y) });
                let steps = ((*duration_ms / 16).max(2)).min(125);
                let delay = Duration::from_millis(*duration_ms / steps);
                let touch = self.touch.as_mut().unwrap();
                acted.store(true, Ordering::Release);
                touch.client.send_touchscreen(TOUCHSCREEN_STATE_CONTACT, touch.x, touch.y, None).await.map_err(|_| SERVICE)?;
                for step in 1..=steps {
                    tokio::time::sleep(delay).await;
                    let t = step as f64 / steps as f64;
                    touch.x = normalized(*from_x + (*to_x - *from_x) * t);
                    touch.y = normalized(*from_y + (*to_y - *from_y) * t);
                    touch.client.send_touchscreen(TOUCHSCREEN_STATE_CONTACT, touch.x, touch.y, None).await.map_err(|_| SERVICE)?;
                }
                self.release_touch().await?;
            }
            Input::Key { key: NamedKey::Home, .. } => {
                let client = IndigoHidClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
                self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
                self.home = Some(client);
                acted.store(true, Ordering::Release);
                self.home.as_mut().unwrap().send_button(0x0c, 0x40, ButtonState::Down).await.map_err(|_| SERVICE)?;
                tokio::time::sleep(Duration::from_millis(80)).await;
                self.release_home().await?;
            }
            Input::Key { key, .. } => {
                self.create_keyboard(acted, &frame, input.frame_id().unwrap()).await?;
                self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
                self.keystroke(named_key(key).ok_or(PROTOCOL)?, false, false, acted).await?;
                self.remove_keyboard().await?;
            }
            Input::Ascii { text, replace, .. } => {
                // parse() validated the complete string before this first send.
                self.create_keyboard(acted, &frame, input.frame_id().unwrap()).await?;
                self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
                if *replace { self.keystroke(0x04, false, true, acted).await?; }
                for byte in text.bytes() {
                    let (usage, shift) = ascii_key(byte).ok_or(PROTOCOL)?;
                    self.keystroke(usage, shift, false, acted).await?;
                }
                self.remove_keyboard().await?;
            }
            Input::Paste { replace, .. } => {
                self.create_keyboard(acted, &frame, input.frame_id().unwrap()).await?;
                self.confirm_frame(&frame, input.frame_id().unwrap()).await?;
                if *replace { self.keystroke(0x04, false, true, acted).await?; }
                self.keystroke(0x19, false, true, acted).await?;
                self.remove_keyboard().await?;
            }
            _ => return Err(PROTOCOL),
        }
        Ok(Payload::dispatched())
    }
    async fn screenshot(&mut self) -> Result<Payload, Failure> {
        self.frame = None;
        let before = self.orientation().await?;
        let bytes = if self.tunnel.handshake.services.contains_key(SCREEN) {
            let mut client = ScreenCaptureServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
            client.take_screenshot(None, ImageFormat::Png).await.map_err(|_| SERVICE)?
        } else if self.tunnel.handshake.services.contains_key(DVT) {
            let mut client = self.dvt().await?;
            ScreenshotClient::new(&mut client).await.map_err(|_| SERVICE)?.take_screenshot().await.map_err(|_| SERVICE)?
        } else { return Err(SERVICE); };
        let (width, height) = png_dimensions(&bytes)?;
        let after = self.orientation().await?;
        if before != after { return Err(ORIENTATION_CHANGED); }
        let id = uuid::Uuid::new_v4();
        let mut payload = Payload::read("screenshot", "image/png", bytes);
        payload.metadata["width"] = width.into(); payload.metadata["height"] = height.into();
        payload.metadata["interfaceOrientation"] = (after as u32).into();
        payload.metadata["nativeFrameId"] = id.to_string().into();
        payload.metadata["foregroundVerified"] = false.into();
        self.frame = Some(Frame { id, at_ns: continuous_now_ns().ok_or(FRAME)?, orientation: after });
        Ok(payload)
    }
    async fn dvt(&mut self) -> Result<RemoteServerClient<Box<dyn ReadWrite>>, Failure> {
        let mut client = RemoteServerClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
        client.read_message(0).await.map_err(|_| SERVICE)?;
        Ok(client)
    }
    async fn apps(&mut self) -> Result<Payload, Failure> {
        let mut client = AppServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
        let apps = client.list_apps(false, true, false, false, true).await.map_err(|_| SERVICE)?;
        let bytes = application_catalog(apps.into_iter().map(|app| (app.name, app.bundle_identifier)))?;
        Ok(Payload::read("apps", "application/json", bytes))
    }
    async fn create_keyboard(&mut self, acted: &AtomicBool, frame: &Frame, id: &str) -> Result<(), Failure> {
        let mut client = UniversalHidServiceClient::connect_rsd(&mut self.tunnel.adapter, &mut self.tunnel.handshake).await.map_err(|_| SERVICE)?;
        self.confirm_frame(frame, id).await?;
        // If cancellation loses the allocated identity, never guess which
        // keyboard to remove. Poison the owner rather than remove another one.
        self.keyboard_unknown = true;
        // Registering a virtual keyboard is itself a device-side mutation.
        acted.store(true, Ordering::Release);
        let service = client.create_main_keyboard().await.map_err(|_| SERVICE)?;
        self.keyboard = Some(KeyboardLease { client, service });
        self.keyboard_unknown = false;
        Ok(())
    }
    async fn keystroke(&mut self, usage: u16, shift: bool, command: bool, acted: &AtomicBool) -> Result<(), Failure> {
        let keyboard = self.keyboard.as_mut().ok_or(PROTOCOL)?;
        let mut pressed = vec![KeyboardUsage::new(usage).map_err(|_| PROTOCOL)?];
        if shift { pressed.push(KeyboardUsage::new(0xe1).map_err(|_| PROTOCOL)?); }
        if command { pressed.push(KeyboardUsage::new(0xe3).map_err(|_| PROTOCOL)?); }
        acted.store(true, Ordering::Release);
        keyboard.client.set_main_keyboard_usages(&mut keyboard.service, pressed).await.map_err(|_| SERVICE)?;
        tokio::time::sleep(Duration::from_millis(12)).await;
        keyboard.client.set_main_keyboard_usages(&mut keyboard.service, []).await.map_err(|_| SERVICE)?;
        tokio::time::sleep(Duration::from_millis(12)).await;
        Ok(())
    }
    async fn remove_keyboard(&mut self) -> Result<(), Failure> {
        if let Some(keyboard) = &mut self.keyboard {
            keyboard.client.remove_main_keyboard(&mut keyboard.service).await.map_err(|_| SERVICE)?;
            self.keyboard = None;
        }
        Ok(())
    }
    async fn release_touch(&mut self) -> Result<(), Failure> {
        if let Some(touch) = &mut self.touch {
            touch.client.send_touchscreen(TOUCHSCREEN_STATE_RELEASE, touch.x, touch.y, None).await.map_err(|_| SERVICE)?;
            self.touch = None;
        }
        Ok(())
    }
    async fn release_home(&mut self) -> Result<(), Failure> {
        if let Some(client) = &mut self.home {
            client.send_button(0x0c, 0x40, ButtonState::Up).await.map_err(|_| SERVICE)?;
            self.home = None;
        }
        Ok(())
    }
    async fn cleanup(&mut self) -> bool {
        self.frame = None;
        // Each owned resource gets a bounded cleanup attempt, even if a previous
        // one failed. A lost create response has no safe guessed identifier.
        let touch = tokio::time::timeout(Duration::from_secs(5), self.release_touch()).await.is_ok_and(|r| r.is_ok());
        let home = tokio::time::timeout(Duration::from_secs(5), self.release_home()).await.is_ok_and(|r| r.is_ok());
        let keyboard = tokio::time::timeout(Duration::from_secs(5), self.remove_keyboard()).await.is_ok_and(|r| r.is_ok());
        let media = tokio::time::timeout(Duration::from_secs(15), self.media.cleanup(&mut self.tunnel)).await.is_ok_and(|r| r.is_ok());
        touch && home && keyboard && media && !self.keyboard_unknown
    }
}
fn require_touch_orientation(input: &Input, orientation: u8) -> Result<(), Failure> {
    // The fixed source establishes the report range, not a proven PNG-to-HID
    // rotation mapping. Do not invent a transform for other orientations.
    if matches!(input, Input::Tap { .. } | Input::Swipe { .. }) && orientation != 1 {
        Err(TOUCH_ORIENTATION)
    } else { Ok(()) }
}
fn normalized(value: f64) -> u16 { (value * 65535.0).round() as u16 }
fn named_key(key: &NamedKey) -> Option<u16> {
    Some(match key { NamedKey::Home => return None, NamedKey::Enter => 0x28,
        NamedKey::Escape => 0x29, NamedKey::Backspace => 0x2a, NamedKey::Tab => 0x2b,
        NamedKey::ArrowRight => 0x4f, NamedKey::ArrowLeft => 0x50,
        NamedKey::ArrowDown => 0x51, NamedKey::ArrowUp => 0x52 })
}
fn ascii_key(byte: u8) -> Option<(u16, bool)> {
    Some(match byte {
        b'a'..=b'z' => (0x04 + (byte - b'a') as u16, false),
        b'A'..=b'Z' => (0x04 + (byte - b'A') as u16, true),
        b'1'..=b'9' => (0x1e + (byte - b'1') as u16, false),
        b'0' => (0x27, false), b' ' => (0x2c, false),
        b'!' => (0x1e, true), b'@' => (0x1f, true), b'#' => (0x20, true), b'$' => (0x21, true),
        b'%' => (0x22, true), b'^' => (0x23, true), b'&' => (0x24, true), b'*' => (0x25, true),
        b'(' => (0x26, true), b')' => (0x27, true), b'-' => (0x2d, false), b'_' => (0x2d, true),
        b'=' => (0x2e, false), b'+' => (0x2e, true), b'[' => (0x2f, false), b'{' => (0x2f, true),
        b']' => (0x30, false), b'}' => (0x30, true), b'\\' => (0x31, false), b'|' => (0x31, true),
        b';' => (0x33, false), b':' => (0x33, true), b'\'' => (0x34, false), b'"' => (0x34, true),
        b'`' => (0x35, false), b'~' => (0x35, true), b',' => (0x36, false), b'<' => (0x36, true),
        b'.' => (0x37, false), b'>' => (0x37, true), b'/' => (0x38, false), b'?' => (0x38, true),
        _ => return None,
    })
}
fn png_dimensions(bytes: &[u8]) -> Result<(u32, u32), Failure> {
    if bytes.len() > MAX_PNG { return Err(LIMIT); }
    if bytes.len() < 33 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" || &bytes[8..16] != b"\0\0\0\rIHDR" { return Err(PROTOCOL); }
    if png_crc32(&bytes[12..29]) != u32::from_be_bytes(bytes[29..33].try_into().map_err(|_| PROTOCOL)?) { return Err(PROTOCOL); }
    let width = u32::from_be_bytes(bytes[16..20].try_into().map_err(|_| PROTOCOL)?);
    let height = u32::from_be_bytes(bytes[20..24].try_into().map_err(|_| PROTOCOL)?);
    if width == 0 || height == 0 || width > 8192 || height > 8192 || (width as u64 * height as u64) > 33_554_432 { return Err(LIMIT); }
    // Native exposes the PNG's actual IHDR dimensions; Swift independently
    // decodes the complete PNG and compares those dimensions before displaying.
    Ok((width, height))
}
fn png_crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= *byte as u32;
        for _ in 0..8 { crc = (crc >> 1) ^ (0xedb88320 & (0u32.wrapping_sub(crc & 1))); }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn app_catalog_keeps_valid_entries_when_inventory_contains_non_targets() {
        let bytes = application_catalog(vec![
            ("Settings".into(), "com.apple.Preferences".into()),
            ("non-target".into(), "invalid_identifier".into()),
            ("".into(), "com.example.hidden".into()),
            ("control\nname".into(), "com.example.control".into()),
            ("Shopping".into(), "com.example.shop".into()),
        ]).unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["apps"], json!([
            {"name":"Settings","id":"com.apple.Preferences"},
            {"name":"Shopping","id":"com.example.shop"},
        ]));
        for invalid in [".com.example", "com..example", "com.example."] { assert!(!bundle_id(invalid)); }
    }
    #[test]
    fn app_catalog_does_not_truncate_count_or_output_limits() {
        assert!(application_catalog((0..4097).map(|_| ("ignored".into(), "invalid_id".into()))).is_err());
        assert!(application_catalog((0..4096).map(|_| ("N".repeat(512), format!("{}.app", "a".repeat(240))))).is_err());
    }
    use std::ffi::CStr;
    use std::sync::{Condvar, Mutex};
    use crate::TEST_LOCK;

    const RUN_ID: &str = "12345678-1234-4234-8234-123456789abc";
    const FRAME_ID: &str = "87654321-4321-4321-8321-cba987654321";
    type RecordedEvent = (u64, String, i32, Value);
    type RecordedResult = (u64, u64, i32, Value, usize);
    static EVENTS: (Mutex<Vec<RecordedEvent>>, Condvar) = (Mutex::new(Vec::new()), Condvar::new());
    static RESULTS: Mutex<Vec<RecordedResult>> = Mutex::new(Vec::new());
    extern "C" fn event(handle: u64, run: *const c_char, kind: i32, json: *const c_char) {
        let (run, json) = unsafe { (CStr::from_ptr(run).to_str().unwrap().to_owned(),
            serde_json::from_slice(CStr::from_ptr(json).to_bytes()).unwrap()) };
        EVENTS.0.lock().unwrap().push((handle, run, kind, json)); EVENTS.1.notify_all();
    }
    extern "C" fn result(handle: u64, id: u64, status: i32, json: *const c_char, bytes: *const u8, len: usize) {
        assert_eq!(bytes.is_null(), len == 0);
        let json = unsafe { serde_json::from_slice(CStr::from_ptr(json).to_bytes()).unwrap() };
        RESULTS.lock().unwrap().push((handle, id, status, json, len));
    }
    extern "C" fn reentrant_stop_result(handle: u64, id: u64, status: i32, json: *const c_char, bytes: *const u8, len: usize) {
        dsh_phone_core_stop(handle);
        result(handle, id, status, json, bytes, len);
    }
    fn config() -> Vec<u8> {
        serde_json::to_vec(&json!({"runId":RUN_ID,"host":"10.7.0.1","port":49152,
            "pairingFile":"/nonexistent/dsh-native-core-pairing.plist"})).unwrap()
    }
    fn byte_config() -> Vec<u8> {
        serde_json::to_vec(&json!({"runId":RUN_ID,"host":"10.7.0.1","port":49152})).unwrap()
    }
    extern "C" fn stop_byte_start(handle: u64, run_id: *const c_char, kind: i32, json: *const c_char) {
        if kind == 0 { dsh_phone_core_stop(handle); }
        event(handle, run_id, kind, json);
    }
    #[test]
    fn w31_ffi_core_both_starts_resolve_publication_before_worker_entry() {
        use base64::Engine as _;
        let _guard = TEST_LOCK.lock().unwrap();
        let bytes = byte_config();
        let pairing = idevice::remote_pairing::RpPairingFile::generate("w31-unwind.invalid").to_bytes();
        let mut legacy: Value = serde_json::from_slice(&bytes).unwrap();
        legacy["pairingBase64"] = base64::engine::general_purpose::STANDARD.encode(&pairing).into();
        let legacy = legacy.to_string();
        for byte_abi in [false, true] {
            for point in ["core_parse", "core_spawned", "core_committed"] {
                assert!(owner().lock().unwrap().is_none());
                EVENTS.0.lock().unwrap().clear();
                ffi::testing::clear_gates();
                let injected = Arc::new(AtomicBool::new(false));
                let observed = injected.clone();
                let _hook = ffi::testing::hook(move |actual| {
                    if actual == point { observed.store(true, Ordering::Release); panic!("synthetic Core admission panic"); }
                });
                let mut handle = 999;
                let status = if byte_abi {
                    unsafe { dsh_phone_core_start_bytes(bytes.as_ptr(), bytes.len(), pairing.as_ptr(), pairing.len(), Some(stop_byte_start), &mut handle) }
                } else { unsafe { dsh_phone_core_start(legacy.as_ptr(), legacy.len(), Some(stop_byte_start), &mut handle) } };
                assert!(injected.load(Ordering::Acquire));
                if point == "core_committed" {
                    assert_eq!(status, 0); assert_ne!(handle, 0);
                    assert_eq!(ffi::testing::wait_gate(), (handle, true));
                    let events = EVENTS.0.lock().unwrap();
                    let (events, timeout) = EVENTS.1.wait_timeout_while(events, Duration::from_secs(5), |events| !events.iter().any(|e| e.2 >= 2)).unwrap();
                    assert!(!timeout.timed_out());
                    assert_eq!(events.iter().map(|e| e.2).collect::<Vec<_>>(), vec![0, 2]);
                } else {
                    assert_eq!(status, INTERNAL); assert_eq!(handle, 0);
                    if point == "core_spawned" { assert!(!ffi::testing::wait_gate().1); }
                    assert!(EVENTS.0.lock().unwrap().is_empty());
                }
                assert!(!owner().is_poisoned());
                assert!(owner().lock().unwrap().is_none());
            }
        }
    }
    #[test]
    fn w31_pairing_bytes_core_strict_json_and_legacy_compatibility() {
        use base64::Engine as _;
        let pairing = idevice::remote_pairing::RpPairingFile::generate("w31-byte-fixture.invalid").to_bytes();
        let bytes = byte_config();
        assert!(Config::parse_bytes(&bytes, &pairing).is_some());
        assert!(Config::parse(&bytes).is_none());
        for field in ["pairingBase64", "pairingFile", "private_key", "unknown"] {
            for value in [Value::Null, json!("synthetic-inline-value")] {
                let mut metadata: Value = serde_json::from_slice(&bytes).unwrap();
                metadata[field] = value;
                pairing::take_clear_events();
                assert!(Config::parse_bytes(&serde_json::to_vec(&metadata).unwrap(), &pairing).is_none());
                assert!(pairing::take_clear_events().is_empty());
            }
        }
        let duplicate = format!("{{\"runId\":\"{RUN_ID}\",{}", std::str::from_utf8(&bytes[1..]).unwrap());
        assert!(Config::parse_bytes(duplicate.as_bytes(), &pairing).is_none());
        assert!(Config::parse_bytes(&bytes[..bytes.len() - 1], &pairing).is_none());
        let mut legacy: Value = serde_json::from_slice(&bytes).unwrap();
        legacy["pairingBase64"] = base64::engine::general_purpose::STANDARD.encode(&pairing).into();
        assert!(Config::parse(&serde_json::to_vec(&legacy).unwrap()).is_some());
        assert!(Config::parse(&config()).is_some());
    }
    #[test]
    fn w31_pairing_bytes_core_rejections_are_unaccepted_and_callback_free() {
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        assert!(owner().lock().unwrap().is_none());
        let bytes = byte_config();
        let pairing = idevice::remote_pairing::RpPairingFile::generate("w31-byte-fixture.invalid").to_bytes();
        let large_config = vec![0; MAX_CONFIG + 1];
        let large_pairing = vec![0; pairing::MAX_PAIRING + 1];
        for (config, config_len, plist, plist_len, callback, expected) in [
            (std::ptr::null(), 1, pairing.as_ptr(), pairing.len(), Some(stop_byte_start as EventCallback), INVALID),
            (bytes.as_ptr(), 0, pairing.as_ptr(), pairing.len(), Some(stop_byte_start as EventCallback), INVALID),
            (large_config.as_ptr(), large_config.len(), pairing.as_ptr(), pairing.len(), Some(stop_byte_start as EventCallback), TOO_LARGE),
            (bytes.as_ptr(), bytes.len(), std::ptr::null(), 1, Some(stop_byte_start as EventCallback), INVALID),
            (bytes.as_ptr(), bytes.len(), pairing.as_ptr(), 0, Some(stop_byte_start as EventCallback), INVALID),
            (bytes.as_ptr(), bytes.len(), large_pairing.as_ptr(), large_pairing.len(), Some(stop_byte_start as EventCallback), TOO_LARGE),
            (bytes.as_ptr(), bytes.len(), b"invalid".as_ptr(), 7, Some(stop_byte_start as EventCallback), INVALID),
            (bytes.as_ptr(), bytes.len(), pairing.as_ptr(), pairing.len(), None, INVALID),
        ] {
            let mut handle = 999;
            assert_eq!(unsafe { dsh_phone_core_start_bytes(config, config_len, plist, plist_len, callback, &mut handle) }, expected);
            assert_eq!(handle, 0);
        }
        let mut bad_json = vec![b"{}".to_vec(), vec![0xff], bytes[..bytes.len() - 1].to_vec()];
        for field in ["pairingBase64", "pairingFile", "unknown"] {
            let mut value: Value = serde_json::from_slice(&bytes).unwrap();
            value[field] = Value::Null;
            bad_json.push(serde_json::to_vec(&value).unwrap());
        }
        for metadata in bad_json {
            let mut handle = 999;
            assert_eq!(unsafe { dsh_phone_core_start_bytes(metadata.as_ptr(), metadata.len(), pairing.as_ptr(), pairing.len(), Some(stop_byte_start), &mut handle) }, INVALID);
            assert_eq!(handle, 0);
        }
        assert_eq!(unsafe { dsh_phone_core_start_bytes(bytes.as_ptr(), bytes.len(), pairing.as_ptr(), pairing.len(), Some(stop_byte_start), std::ptr::null_mut()) }, INVALID);
        let (_control, _received, _stopped, _cancelled) = fixture_owner(613);
        let mut handle = 999;
        pairing::take_clear_events();
        assert_eq!(unsafe { dsh_phone_core_start_bytes(bytes.as_ptr(), bytes.len(), pairing.as_ptr(), pairing.len(), Some(stop_byte_start), &mut handle) }, BUSY);
        assert_eq!(handle, 0);
        assert!(pairing::take_clear_events().contains(&("record", true)));
        assert_eq!(owner().lock().unwrap().as_ref().unwrap().handle, 613);
        *owner().lock().unwrap() = None;
        assert!(EVENTS.0.lock().unwrap().is_empty());
    }
    #[test]
    fn w31_pairing_bytes_core_start_preserves_preconnection_cancel() {
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        let bytes = byte_config();
        let mut pairing = idevice::remote_pairing::RpPairingFile::generate("w31-byte-fixture.invalid").to_bytes();
        let mut handle = 0;
        assert_eq!(unsafe { dsh_phone_core_start_bytes(bytes.as_ptr(), bytes.len(), pairing.as_ptr(), pairing.len(), Some(stop_byte_start), &mut handle) }, 0);
        assert_ne!(handle, 0);
        pairing.zeroize();
        drop(pairing);
        let events = EVENTS.0.lock().unwrap();
        let (events, timeout) = EVENTS.1.wait_timeout_while(events, Duration::from_secs(5), |events| !events.iter().any(|event| event.2 >= 2)).unwrap();
        assert!(!timeout.timed_out());
        assert_eq!(events.iter().map(|event| event.2).collect::<Vec<_>>(), vec![0, 2]);
        assert_eq!(events[1].0, handle);
        assert_eq!(events[1].3["cleanupConfirmed"], true);
        assert!(owner().lock().unwrap().is_none());
    }
    #[test]
    fn w31_pairing_core_failed_json_clears_parsed_secret() {
        for bytes in [
            br#"{"pairingBase64":"synthetic","unknown":true}"#.as_slice(),
            br#"{"pairingBase64":"synthetic","pairingBase64":"duplicate"}"#.as_slice(),
            br#"{"pairingBase64":"synthetic","#.as_slice(),
            br#"{"pairingBase64":"synthetic","runId":"12345678-1234-4234-8234-123456789abc","host":"invalid-address","port":1}"#.as_slice(),
        ] {
            pairing::take_clear_events();
            assert!(Config::parse(bytes).is_none());
            let events = pairing::take_clear_events();
            assert!(events.contains(&("string", true)));
            assert!(events.iter().all(|(_, cleared)| *cleared));
        }
    }
    #[tokio::test]
    async fn w31_pairing_core_pre_cancel_drops_unpolled_connection_record() {
        use base64::Engine as _;
        let mut value: Value = serde_json::from_slice(&config()).unwrap();
        value.as_object_mut().unwrap().remove("pairingFile");
        value["pairingBase64"] = base64::engine::general_purpose::STANDARD.encode(
            idevice::remote_pairing::RpPairingFile::generate("w31-synthetic.invalid").to_bytes()).into();
        let config = Config::parse(&serde_json::to_vec(&value).unwrap()).unwrap();
        let (_stop, stopped) = watch::channel(true);
        let (cancel, cancelled_request) = watch::channel(0);
        let (requests, receiver) = mpsc::channel(1);
        let control = Arc::new(Control { phase: AtomicU8::new(STARTING), active: AtomicU64::new(0),
            last: AtomicU64::new(0), cancel, requests });
        pairing::take_clear_events();
        let result = run(config, event, 1, control, stopped, cancelled_request, receiver).await;
        assert!(result.stopped && result.cleanup && result.error.is_none());
        assert_eq!(pairing::take_clear_events(), vec![("record", true)]);
    }
    fn request(handle: u64, id: u64, input: Value, callback: ResultCallback) -> i32 {
        let bytes = input.to_string();
        unsafe { dsh_phone_core_request(handle, id, bytes.as_ptr(), bytes.len(), Some(callback)) }
    }
    fn fixture_owner(handle: u64) -> (Arc<Control>, mpsc::Receiver<PendingRequest>, watch::Receiver<bool>, watch::Receiver<u64>) {
        let (stop, stopped) = watch::channel(false);
        let (cancel, cancelled) = watch::channel(0);
        let (requests, received) = mpsc::channel(1);
        let control = Arc::new(Control { phase: AtomicU8::new(READY), active: AtomicU64::new(0),
            last: AtomicU64::new(0), cancel, requests });
        *owner().lock().unwrap() = Some(Owner { handle, stop, cancelled: Arc::new(AtomicBool::new(false)), core: Some(control.clone()) });
        (control, received, stopped, cancelled)
    }

    static FFI_CALLBACKS: Mutex<Vec<(&'static str, std::thread::ThreadId)>> = Mutex::new(Vec::new());
    extern "C" fn ffi_result(handle: u64, id: u64, status: i32, json: *const c_char, bytes: *const u8, len: usize) {
        reentrant_stop_result(handle, id, status, json, bytes, len);
        FFI_CALLBACKS.lock().unwrap().push(("result", std::thread::current().id()));
    }
    extern "C" fn ffi_terminal(handle: u64, run: *const c_char, kind: i32, json: *const c_char) {
        event(handle, run, kind, json);
        FFI_CALLBACKS.lock().unwrap().push(("terminal", std::thread::current().id()));
    }
    fn reset_ffi_records() {
        RESULTS.lock().unwrap().clear();
        EVENTS.0.lock().unwrap().clear();
        FFI_CALLBACKS.lock().unwrap().clear();
    }
    fn finish_fixture(handle: u64, control: &Control) {
        // Synthetic owner only: there has never been a Session or transport.
        finish(handle, ffi_terminal, control, Completion {
            run_id: RUN_ID.into(), error: None, stopped: true, cleanup: true,
        });
    }
    fn assert_worker_result_then_terminal(caller: std::thread::ThreadId) {
        let callbacks = FFI_CALLBACKS.lock().unwrap().clone();
        assert_eq!(callbacks.iter().map(|entry| entry.0).collect::<Vec<_>>(), vec!["result", "terminal"]);
        assert!(callbacks.iter().all(|entry| entry.1 != caller));
        assert_eq!(RESULTS.lock().unwrap().len(), 1);
        assert!(!owner().is_poisoned());
        assert!(owner().lock().unwrap().is_none());
    }

    #[test]
    fn w31_ffi_request_precommit_panics_are_callback_free() {
        let _guard = TEST_LOCK.lock().unwrap();
        for point in ["request_parse", "request_pre_enqueue", "request_enqueued", "request_pre_commit"] {
            reset_ffi_records();
            let (control, mut received, _, _) = fixture_owner(700);
            let injected = Arc::new(AtomicBool::new(false));
            let observed = injected.clone();
            let _hook = ffi::testing::hook(move |actual| {
                if actual == point { observed.store(true, Ordering::Release); panic!("synthetic request precommit panic"); }
            });
            assert_eq!(request(700, 1, json!({"op":"screenshot"}), result), INTERNAL);
            assert!(injected.load(Ordering::Acquire));
            if let Ok(pending) = received.try_recv() { assert!(pending.take().is_none()); }
            assert_eq!(control.last.load(Ordering::Acquire), 0);
            assert_eq!(control.active.load(Ordering::Acquire), 0);
            assert_eq!(control.phase.load(Ordering::Acquire), READY);
            assert!(RESULTS.lock().unwrap().is_empty());
            assert!(!owner().is_poisoned());
            *owner().lock().unwrap() = None;
        }
    }

    #[test]
    fn w31_ffi_waiting_receiver_observes_rejected_request() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_ffi_records();
        let (control, mut received, _, _) = fixture_owner(701);
        let (taken, seen) = std::sync::mpsc::channel();
        let (finished, done) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let pending = received.blocking_recv().unwrap();
            taken.send(()).unwrap();
            let request = pending.take();
            let rejected = request.is_none();
            drop(request);
            finished.send(rejected).unwrap();
        });
        let _hook = ffi::testing::hook(move |point| {
            if point == "request_enqueued" {
                seen.recv_timeout(Duration::from_secs(5)).unwrap();
                panic!("synthetic panic with waiting receiver");
            }
        });
        assert_eq!(request(701, 1, json!({"op":"apps"}), result), INTERNAL);
        assert!(done.recv_timeout(Duration::from_secs(5)).unwrap());
        worker.join().unwrap();
        assert_eq!(control.last.load(Ordering::Acquire), 0);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert!(RESULTS.lock().unwrap().is_empty());
        assert!(!owner().is_poisoned());
        *owner().lock().unwrap() = None;
    }

    #[test]
    fn w31_ffi_request_postcommit_panic_keeps_one_worker_result() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_ffi_records();
        let caller = std::thread::current().id();
        let (control, mut received, _, _) = fixture_owner(702);
        let worker_control = control.clone();
        let (taken, seen) = std::sync::mpsc::channel();
        let (finished, done) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let pending = received.blocking_recv().unwrap();
            taken.send(()).unwrap();
            let mut request = pending.take().unwrap();
            request.response.failure(CANCELLED, true, true);
            drop(request);
            finish_fixture(702, &worker_control);
            finished.send(()).unwrap();
        });
        struct PanickingDrop;
        impl Drop for PanickingDrop {
            fn drop(&mut self) { panic!("synthetic request payload destructor"); }
        }
        let _hook = ffi::testing::hook(move |point| {
            if point == "request_enqueued" { seen.recv_timeout(Duration::from_secs(5)).unwrap(); }
            if point == "request_committed" { std::panic::panic_any(PanickingDrop); }
        });
        assert_eq!(request(702, 1, json!({"op":"apps"}), ffi_result), 0);
        done.recv_timeout(Duration::from_secs(5)).unwrap();
        worker.join().unwrap();
        assert_eq!(control.last.load(Ordering::Acquire), 1);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert_worker_result_then_terminal(caller);
    }

    #[test]
    fn w31_ffi_receiver_drop_before_commit_rejects_without_result() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_ffi_records();
        let (control, received, _, _) = fixture_owner(703);
        let (drop_now, command) = std::sync::mpsc::channel();
        let (dropped, done) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            command.recv_timeout(Duration::from_secs(5)).unwrap();
            drop(received);
            dropped.send(()).unwrap();
        });
        let _hook = ffi::testing::hook(move |point| {
            if point == "request_enqueued" {
                drop_now.send(()).unwrap();
                done.recv_timeout(Duration::from_secs(5)).unwrap();
            }
        });
        assert_eq!(request(703, 1, json!({"op":"apps"}), result), INTERNAL);
        worker.join().unwrap();
        assert_eq!(control.last.load(Ordering::Acquire), 0);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert!(RESULTS.lock().unwrap().is_empty());
        assert!(!owner().is_poisoned());
        *owner().lock().unwrap() = None;
    }

    #[test]
    fn w31_ffi_receiver_drop_during_committed_unwind_finishes_on_worker() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_ffi_records();
        let caller = std::thread::current().id();
        let (control, received, _, _) = fixture_owner(704);
        let worker_control = control.clone();
        let (drop_now, command) = std::sync::mpsc::channel();
        let (dropping, started) = std::sync::mpsc::channel();
        let (finished, done) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            command.recv_timeout(Duration::from_secs(5)).unwrap();
            dropping.send(()).unwrap();
            drop(received);
            finish_fixture(704, &worker_control);
            finished.send(()).unwrap();
        });
        let _hook = ffi::testing::hook(move |point| {
            if point == "request_committed" {
                drop_now.send(()).unwrap();
                started.recv_timeout(Duration::from_secs(5)).unwrap();
                panic!("synthetic committed panic racing receiver drop");
            }
        });
        assert_eq!(request(704, 1, json!({"op":"apps"}), ffi_result), 0);
        done.recv_timeout(Duration::from_secs(5)).unwrap();
        worker.join().unwrap();
        assert_eq!(control.last.load(Ordering::Acquire), 1);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert_worker_result_then_terminal(caller);
    }

    #[test]
    fn w31_ffi_full_or_closed_queue_is_unaccepted_without_callback() {
        let _guard = TEST_LOCK.lock().unwrap();
        for closed in [false, true] {
            reset_ffi_records();
            let (control, received, _, _) = fixture_owner(705);
            let received = if closed { drop(received); None } else {
                assert!(control.requests.try_send(PendingRequest { gate: Arc::new(RequestGate {
                    state: Mutex::new(RequestState::Pending), changed: Condvar::new(),
                }) }).is_ok());
                Some(received)
            };
            assert_eq!(request(705, 1, json!({"op":"apps"}), result), INTERNAL);
            assert_eq!(control.last.load(Ordering::Acquire), 0);
            assert_eq!(control.active.load(Ordering::Acquire), 0);
            drop(received);
            assert!(RESULTS.lock().unwrap().is_empty());
            assert!(!owner().is_poisoned());
            *owner().lock().unwrap() = None;
        }
    }

    #[test]
    fn w31_ffi_reserved_permit_after_receiver_drop_rejects_without_a_control_cycle() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_ffi_records();
        let (control, received, _, _) = fixture_owner(706);
        let weak_control = Arc::downgrade(&control);
        let gate = Arc::new(RequestGate {
            state: Mutex::new(RequestState::Pending), changed: Condvar::new(),
        });
        let weak_gate = Arc::downgrade(&gate);
        let slot = owner().lock().unwrap();
        // Use the locked Tokio API's real legal order. try_send uses the same
        // acquire-then-push operations, but cannot be paused between them from
        // a public caller. This is not a fabricated "send failed" return.
        let permit = control.requests.try_reserve().unwrap();
        drop(received); // Close and drain before the acquired permit publishes.
        assert!(control.requests.is_closed());
        permit.send(PendingRequest { gate: gate.clone() });
        assert!(matches!(*gate.state.lock().unwrap(), RequestState::Pending));
        let request = Request { input: Input::Apps, response: Responder {
            handle: 706, id: 1, callback: result, control: control.clone(),
            may_have_acted: Arc::new(AtomicBool::new(false)), armed: false,
        } };
        let mut admitted = false;
        commit_request(&gate, &control, request, true, &mut admitted);
        assert!(!admitted);
        assert!(matches!(*gate.state.lock().unwrap(), RequestState::Rejected));
        assert_eq!(control.last.load(Ordering::Acquire), 0);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert!(RESULTS.lock().unwrap().is_empty());
        drop(slot);
        gate.changed.notify_all();
        *owner().lock().unwrap() = None;
        drop(control);
        drop(gate);
        assert!(weak_control.upgrade().is_none());
        assert!(weak_gate.upgrade().is_none());
        assert!(RESULTS.lock().unwrap().is_empty());
        assert!(!owner().is_poisoned());
    }

    #[test]
    fn w31_ffi_receiver_close_after_commit_check_keeps_one_worker_completion() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_ffi_records();
        let caller = std::thread::current().id();
        let (control, mut received, _, _) = fixture_owner(707);
        let worker_control = control.clone();
        let (close_now, command) = std::sync::mpsc::channel();
        let (closed, observed) = std::sync::mpsc::channel();
        let (finished, done) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            command.recv_timeout(Duration::from_secs(5)).unwrap();
            received.close();
            closed.send(()).unwrap();
            // The already-pushed placeholder is owned by this drain. Its Drop
            // waits for the caller's outer gate guard instead of losing Ready.
            drop(received);
            finish_fixture(707, &worker_control);
            finished.send(()).unwrap();
        });
        let _hook = ffi::testing::hook(move |point| {
            if point == "request_pre_commit" {
                close_now.send(()).unwrap();
                observed.recv_timeout(Duration::from_secs(5)).unwrap();
            }
        });
        assert_eq!(request(707, 1, json!({"op":"apps"}), ffi_result), 0);
        done.recv_timeout(Duration::from_secs(5)).unwrap();
        worker.join().unwrap();
        assert_eq!(control.last.load(Ordering::Acquire), 1);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert_worker_result_then_terminal(caller);
    }

    #[test]
    fn full_input_validation_precedes_any_acceptance() {
        for value in [
            json!({"op":"prepareInput"}), json!({"op":"screenshot"}), json!({"op":"apps"}),
            json!({"op":"launch","bundleId":"com.example.app"}),
            json!({"op":"tap","x":0.0,"y":1.0,"nativeFrameId":FRAME_ID}),
            json!({"op":"tap","x":0.0,"y":1.0,"durationMs":1500,"nativeFrameId":FRAME_ID}),
            json!({"op":"swipe","fromX":0.1,"fromY":0.8,"toX":0.1,"toY":0.2,"durationMs":300,"nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"Hello !~","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"Replace","replace":true,"nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"a".repeat(1024),"nativeFrameId":FRAME_ID}),
            json!({"op":"key","key":"arrowLeft","nativeFrameId":FRAME_ID}),
            json!({"op":"key","key":"enter","nativeFrameId":FRAME_ID}),
            json!({"op":"key","key":"tab","nativeFrameId":FRAME_ID}),
            json!({"op":"paste","nativeFrameId":FRAME_ID}),
            json!({"op":"paste","replace":true,"nativeFrameId":FRAME_ID}),
        ] { assert!(Input::parse(value.to_string().as_bytes()).is_some(), "{value}"); }
        for value in [
            json!({"op":"tap","x":0.2,"y":0.3}),
            json!({"op":"tap","x":-0.1,"y":0.3,"nativeFrameId":FRAME_ID}),
            json!({"op":"tap","x":0.1,"y":1.01,"nativeFrameId":FRAME_ID}),
            json!({"op":"tap","x":0.1,"y":0.3,"durationMs":49,"nativeFrameId":FRAME_ID}),
            json!({"op":"tap","x":0.1,"y":0.3,"durationMs":1501,"nativeFrameId":FRAME_ID}),
            json!({"op":"tap","x":0.1,"y":0.3,"durationMs":50.5,"nativeFrameId":FRAME_ID}),
            json!({"op":"swipe","fromX":0.0,"fromY":0.0,"toX":1.0,"toY":1.0,"durationMs":2001,"nativeFrameId":FRAME_ID}),
            json!({"op":"launch","bundleId":"com.example.app","env":{"A":"B"}}),
            json!({"op":"key","key":"0xe3","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"ok中","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"a".repeat(1025),"nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"ok\r","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"\n","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"\t","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"first\nsecond","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"first\tsecond","replace":true,"nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"","nativeFrameId":FRAME_ID}),
            json!({"op":"ascii","text":"valid","replace":"yes","nativeFrameId":FRAME_ID}),
            json!({"op":"paste","replace":1,"nativeFrameId":FRAME_ID}),
            json!({"op":"paste","nativeFrameId":"stale"}),
        ] { assert!(Input::parse(value.to_string().as_bytes()).is_none(), "{value}"); }
        for byte in 0..=255 {
            assert_eq!(ascii_key(byte).is_some(), (32..=126).contains(&byte));
        }
        assert_eq!(named_key(&NamedKey::Enter), Some(0x28));
        assert_eq!(named_key(&NamedKey::Tab), Some(0x2b));
        assert!(matches!(Input::parse(json!({"op":"tap","x":0.0,"y":1.0,"nativeFrameId":FRAME_ID}).to_string().as_bytes()), Some(Input::Tap { duration_ms: 50, .. })));
        assert!(matches!(Input::parse(json!({"op":"ascii","text":"a","nativeFrameId":FRAME_ID}).to_string().as_bytes()), Some(Input::Ascii { replace: false, .. })));
        assert!(matches!(Input::parse(json!({"op":"paste","nativeFrameId":FRAME_ID}).to_string().as_bytes()), Some(Input::Paste { replace: false, .. })));
    }

    #[test]
    fn latest_native_frame_has_real_expiry_and_identity() {
        let now = 100_000_000_000;
        let frame = Frame { id: uuid::Uuid::parse_str(FRAME_ID).unwrap(), at_ns: now, orientation: 1 };
        assert!(frame.matches(FRAME_ID, Some(now)));
        assert!(frame.matches(FRAME_ID, Some(now + FRAME_LIFETIME_NS)));
        assert!(!frame.matches(FRAME_ID, Some(now + FRAME_LIFETIME_NS + 1)));
        assert!(!frame.matches(RUN_ID, Some(now)));
        assert!(!frame.matches(FRAME_ID, Some(now - 1)));
        assert!(!frame.matches(FRAME_ID, None));
        // Inject a continuous timeline with two awake seconds and sixty asleep
        // seconds. This tests elapsed-time logic, not a real device suspension.
        assert!(!frame.matches(FRAME_ID, Some(now + 2_000_000_000 + 60_000_000_000)));
        assert_eq!(normalized(0.0), 0); assert_eq!(normalized(1.0), 65535); assert_eq!(normalized(0.5), 32768);
        let tap = Input::parse(json!({"op":"tap","x":0.5,"y":0.5,"nativeFrameId":FRAME_ID}).to_string().as_bytes()).unwrap();
        let swipe = Input::parse(json!({"op":"swipe","fromX":0.0,"fromY":0.0,"toX":1.0,"toY":1.0,"durationMs":300,"nativeFrameId":FRAME_ID}).to_string().as_bytes()).unwrap();
        let key = Input::parse(json!({"op":"key","key":"enter","nativeFrameId":FRAME_ID}).to_string().as_bytes()).unwrap();
        for orientation in 0..=u8::MAX {
            assert_eq!(require_touch_orientation(&tap, orientation).is_ok(), orientation == 1);
            assert_eq!(require_touch_orientation(&swipe, orientation).is_ok(), orientation == 1);
            assert!(require_touch_orientation(&key, orientation).is_ok());
            if orientation != 1 { assert_eq!(require_touch_orientation(&tap, orientation).unwrap_err().0, TOUCH_ORIENTATION.0); }
        }
    }

    #[test]
    fn continuous_clock_conversion_is_bounded_and_rejects_invalid_samples() {
        assert_eq!(mach_ticks_to_ns(24, 125, 3), Some(1000));
        assert_eq!(mach_ticks_to_ns(u64::MAX, 1, 1), Some(u64::MAX));
        assert_eq!(mach_ticks_to_ns(u64::MAX, 2, 1), None);
        assert_eq!(mach_ticks_to_ns(1, 0, 1), None);
        assert_eq!(mach_ticks_to_ns(1, 1, 0), None);
        assert_eq!(timespec_to_ns(2, 3), Some(2_000_000_003));
        assert_eq!(timespec_to_ns(0, 999_999_999), Some(999_999_999));
        assert_eq!(timespec_to_ns(-1, 0), None);
        assert_eq!(timespec_to_ns(0, -1), None);
        assert_eq!(timespec_to_ns(0, 1_000_000_000), None);
        assert_eq!(timespec_to_ns(i64::MAX, 0), None);
    }

    #[test]
    #[cfg(any(target_vendor = "apple", target_os = "linux"))]
    fn host_continuous_clock_is_available_and_nondecreasing() {
        let before = continuous_now_ns().expect("supported host continuous clock");
        let after = continuous_now_ns().expect("supported host continuous clock");
        assert!(after >= before);
    }

    #[test]
    fn png_metadata_uses_bounded_actual_ihdr_with_crc() {
        let mut header = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        header.extend_from_slice(&1170u32.to_be_bytes()); header.extend_from_slice(&2532u32.to_be_bytes());
        header.extend_from_slice(&[8, 6, 0, 0, 0]);
        header.extend_from_slice(&png_crc32(&header[12..29]).to_be_bytes());
        assert_eq!(png_dimensions(&header).unwrap(), (1170, 2532));
        header[19] ^= 1;
        assert!(png_dimensions(&header).is_err());
        for len in 0..33 { assert!(png_dimensions(&header[..len]).is_err()); }
        assert!(png_dimensions(&vec![0; MAX_PNG + 1]).is_err());
    }

    #[test]
    fn length_delimited_ffi_rejects_null_oversize_and_unknown_config() {
        let mut handle = 99;
        assert_eq!(unsafe { dsh_phone_core_start(std::ptr::null(), 1, Some(event), &mut handle) }, INVALID);
        assert_eq!(handle, 0);
        let bytes = config();
        assert_eq!(unsafe { dsh_phone_core_start(bytes.as_ptr(), bytes.len(), Some(event), std::ptr::null_mut()) }, INVALID);
        assert_eq!(unsafe { dsh_phone_core_start(bytes.as_ptr(), MAX_CONFIG + 1, Some(event), &mut handle) }, TOO_LARGE);
        let mut value: Value = serde_json::from_slice(&bytes).unwrap();
        value["allowDDIMount"] = true.into();
        assert!(Config::parse(value.to_string().as_bytes()).unwrap().allow_ddi_mount);
        value["arbitraryURL"] = "https://invalid.example".into();
        assert!(Config::parse(value.to_string().as_bytes()).is_none());
        assert_eq!(unsafe { dsh_phone_core_request(1, 1, bytes.as_ptr(), MAX_REQUEST + 1, Some(result)) }, TOO_LARGE);
    }

    #[test]
    fn request_owner_serialization_stale_cancel_and_reentrant_stop() {
        let _guard = TEST_LOCK.lock().unwrap();
        RESULTS.lock().unwrap().clear();
        let (control, mut received, stopped, cancelled) = fixture_owner(500);
        assert_eq!(request(499, 1, json!({"op":"screenshot"}), result), STALE);
        assert_eq!(request(500, 1, json!({"op":"ascii","text":"ok中","nativeFrameId":FRAME_ID}), result), INVALID);
        assert_eq!(control.active.load(Ordering::Acquire), 0);
        assert_eq!(request(500, 1, json!({"op":"screenshot"}), reentrant_stop_result), 0);
        assert_eq!(request(500, 2, json!({"op":"apps"}), result), BUSY);
        dsh_phone_core_cancel(499, 1); dsh_phone_core_cancel(500, 2); dsh_phone_core_stop(499);
        assert_eq!(*cancelled.borrow(), 0); assert!(!*stopped.borrow());
        dsh_phone_core_cancel(500, 1); assert_eq!(*cancelled.borrow(), 1);
        let mut accepted = received.try_recv().unwrap().take().unwrap();
        accepted.response.failure(CANCELLED, true, true);
        assert!(*stopped.borrow()); assert_eq!(control.phase.load(Ordering::Acquire), STOPPING);
        assert_eq!(request(500, 3, json!({"op":"screenshot"}), result), IS_STOPPING);
        assert_eq!(RESULTS.lock().unwrap().len(), 1);
        assert_eq!(RESULTS.lock().unwrap()[0].2, 2);
        *owner().lock().unwrap() = None;
    }

    #[test]
    fn accepted_request_drop_is_once_uncertain_and_blocks_new_requests() {
        let _guard = TEST_LOCK.lock().unwrap();
        RESULTS.lock().unwrap().clear();
        let (control, mut received, _, _) = fixture_owner(501);
        assert_eq!(request(501, 9, json!({"op":"screenshot"}), result), 0);
        let accepted = received.try_recv().unwrap().take().unwrap();
        accepted.response.may_have_acted.store(true, Ordering::Release);
        drop(accepted);
        let records = RESULTS.lock().unwrap();
        assert_eq!(records.len(), 1); assert_eq!(records[0].2, 3);
        assert_eq!(records[0].3["cleanupConfirmed"], false);
        assert_eq!(control.phase.load(Ordering::Acquire), STOPPING);
        drop(records);
        assert_eq!(request(501, 10, json!({"op":"apps"}), result), IS_STOPPING);
        *owner().lock().unwrap() = None;
    }

    #[test]
    fn actual_worker_preconnection_failure_releases_owner_and_preserves_run_id() {
        let _guard = TEST_LOCK.lock().unwrap();
        EVENTS.0.lock().unwrap().clear();
        let bytes = config(); let mut handle = 0;
        assert_eq!(unsafe { dsh_phone_core_start(bytes.as_ptr(), bytes.len(), Some(event), &mut handle) }, 0);
        assert_ne!(handle, 0);
        let events = EVENTS.0.lock().unwrap();
        let (events, timeout) = EVENTS.1.wait_timeout_while(events, Duration::from_secs(5), |events| !events.iter().any(|event| event.2 >= 2 && event.2 <= 4)).unwrap();
        assert!(!timeout.timed_out());
        let terminal = events.iter().find(|event| event.2 == 3).unwrap();
        assert_eq!(terminal.0, handle); assert_eq!(terminal.1, RUN_ID);
        assert_eq!(terminal.3["code"], "ERR_PHONE_PAIRING_REQUIRED");
        assert_eq!(terminal.3["cleanupConfirmed"], true);
        drop(events);
        assert!(owner().lock().unwrap().is_none());
        assert_eq!(request(handle, 1, json!({"op":"apps"}), result), STALE);
    }
}
