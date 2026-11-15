//! Owned display-service media, using the SAME RSD adapter as CoreDevice/HID.
//!
//! The pinned Apple DDI daemon's ARM64 data flow assigns
//! SessionWrapper.identifier = ConnectionInfo.streamConfig.RemoteSSRC and
//! matches StopRequest.identifiers against it. See README's evidence scope.
//! This is static protocol evidence, not a successful run on a device.
//! No global stopAll is sent. A preflight status check is not an atomic lock
//! against a different controller starting a concurrent media session.
use std::borrow::Cow;
use std::collections::{BTreeSet, VecDeque};
use std::net::IpAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use idevice::{IdeviceError, ReadWrite, RemoteXpcClient, RsdService};
use idevice::core_device::{CallInfoBlob, DisplayServiceClient,
    build_screen_audio_offer, build_screen_video_offer,
    build_start_audio_parameters, build_start_video_parameters};
use idevice::core_device::display_stream::{RtpPacket, SenderReport, ReportBlock,
    build_receiver_report, build_sdes, is_rtcp};
use idevice::tcp::handle::UdpSocketHandle;
use idevice::xpc::{Dictionary, XPCObject};
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::{Failure, Tunnel, STOP_UNCONFIRMED};

const DISPLAY: &str = "com.apple.coredevice.displayservice";
const PROTOCOL: Failure = Failure("ERR_PHONE_MEDIA_PROTOCOL");
const FOREIGN: Failure = Failure("ERR_PHONE_FOREIGN_MEDIA_SESSION");
const SERVICE: Failure = Failure("ERR_PHONE_CORE_SERVICE_UNAVAILABLE");
const STREAM_LOST: Failure = Failure("ERR_PHONE_MEDIA_STREAM_LOST");
const NOT_PREPARED: Failure = Failure("ERR_PHONE_INPUT_NOT_PREPARED");
const FEATURES: u64 = 140;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind { Audio, Video }
impl Kind {
    fn parse(value: &str) -> Option<Self> { match value { "audio" => Some(Self::Audio), "video" => Some(Self::Video), _ => None } }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Connection {
    kind: Kind,
    session: uuid::Uuid,
    receiver_ip: IpAddr,
    receiver_port: u16,
    sender_ip: IpAddr,
    sender_port: u16,
    identifier: u32,
    peer_ssrc: u32,
}
fn dict(value: &plist::Value) -> Result<&plist::Dictionary, Failure> { value.as_dictionary().ok_or(PROTOCOL) }
fn field<'a>(value: &'a plist::Dictionary, name: &str) -> Result<&'a plist::Value, Failure> { value.get(name).ok_or(PROTOCOL) }
fn string<'a>(value: &'a plist::Dictionary, name: &str) -> Result<&'a str, Failure> { field(value, name)?.as_string().ok_or(PROTOCOL) }
fn uint(value: &plist::Dictionary, name: &str) -> Result<u64, Failure> { field(value, name)?.as_unsigned_integer().ok_or(PROTOCOL) }
fn endpoint(value: &plist::Value) -> Result<(IpAddr, u16), Failure> {
    let value = dict(value)?;
    let text = string(value, "ipv6Address")?;
    if text.len() > 64 { return Err(PROTOCOL); }
    let ip = text.parse().map_err(|_| PROTOCOL)?;
    let port: u16 = uint(value, "port")?.try_into().map_err(|_| PROTOCOL)?;
    if port == 0 { return Err(PROTOCOL); }
    Ok((ip, port))
}
fn connection(value: &plist::Value) -> Result<Connection, Failure> {
    let value = dict(value)?;
    if string(value, "direction")? != "output" { return Err(PROTOCOL); }
    let kind = Kind::parse(string(value, "type")?).ok_or(PROTOCOL)?;
    let (receiver_ip, receiver_port) = endpoint(field(value, "receiver")?)?;
    let (sender_ip, sender_port) = endpoint(field(value, "sender")?)?;
    let options = dict(field(value, "options")?)?;
    let session_value = dict(field(options, "avcMediaStreamOptionClientSessionID")?)?;
    let session_text = string(session_value, "uuid")?;
    if session_text.len() > 36 { return Err(PROTOCOL); }
    let session = uuid::Uuid::parse_str(session_text).map_err(|_| PROTOCOL)?;
    let config = dict(field(value, "streamConfig")?)?;
    let identifier = uint(config, "RemoteSSRC")?.try_into().map_err(|_| PROTOCOL)?;
    let peer_ssrc = uint(config, "LocalSSRC")?.try_into().map_err(|_| PROTOCOL)?;
    // Keep both the negotiated connection and transport fields consistent. The
    // server can choose its source port; the host's bound receiver port is ours.
    if string(config, "SourceIP")?.parse::<IpAddr>().map_err(|_| PROTOCOL)? != sender_ip
        || string(config, "DestIp")?.parse::<IpAddr>().map_err(|_| PROTOCOL)? != receiver_ip
        || uint(config, "SourcePort")? != sender_port as u64
        || uint(config, "DestPort")? != receiver_port as u64 { return Err(PROTOCOL); }
    Ok(Connection { kind, session, receiver_ip, receiver_port, sender_ip, sender_port, identifier, peer_ssrc })
}
struct Server { running: bool, healthy: bool, connections: Vec<Connection> }
fn server(value: &plist::Value) -> Result<Server, Failure> {
    let value = dict(value)?;
    let running = field(value, "running")?.as_boolean().ok_or(PROTOCOL)?;
    // SessionInfo.connection is optional. A missing connection in an active
    // record is not evidence of an idle server or of ownership.
    let sessions = match value.get("sessions") {
        Some(plist::Value::Array(sessions)) => sessions.as_slice(),
        None if !running => &[],
        _ => return Err(PROTOCOL),
    };
    if sessions.len() > 16 { return Err(PROTOCOL); }
    if !running && !sessions.is_empty() { return Err(PROTOCOL); }
    let mut connections = Vec::with_capacity(sessions.len());
    let mut identifiers = BTreeSet::new();
    let mut healthy = true;
    for session in sessions {
        let session = dict(session)?;
        let status = dict(field(session, "status")?)?;
        healthy &= uint(status, "connectionErrors")? == 0;
        uint(status, "runDurationSeconds")?;
        let connection = connection(field(session, "connection")?)?;
        // A duplicated numeric identifier would make a selective stop ambiguous.
        if !identifiers.insert(connection.identifier) { return Err(PROTOCOL); }
        connections.push(connection);
    }
    Ok(Server { running, healthy, connections })
}
async fn status(tunnel: &mut Tunnel) -> Result<Server, Failure> {
    let mut client = DisplayServiceClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| SERVICE)?;
    server(&client.get_media_stream_server_status().await.map_err(|_| SERVICE)?)
}
pub(crate) async fn probe(tunnel: &mut Tunnel) -> Result<(), Failure> {
    let mut client = DisplayServiceClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| SERVICE)?;
    let support = client.get_media_support_info().await.map_err(|_| SERVICE)?;
    uint(dict(&support)?, "supportedFeatures")?;
    let server = server(&client.get_media_stream_server_status().await.map_err(|_| SERVICE)?)?;
    if !server.connections.is_empty() { return Err(FOREIGN); }
    Ok(())
}

// The pinned DisplayServiceClient exports only stopAll=true. This small typed
// extension keeps its exact CoreDevice v2 action envelope, but preserves UInt64
// XPC encoding for the UInt32 stop identifiers (plist conversion uses Int64).
struct SelectiveStop { inner: RemoteXpcClient<Box<dyn ReadWrite>> }
impl RsdService for SelectiveStop {
    fn rsd_service_name() -> Cow<'static, str> { DISPLAY.into() }
    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let mut inner = RemoteXpcClient::new(stream).await?;
        inner.do_handshake().await?;
        Ok(Self { inner })
    }
}
fn stop_envelope(identifiers: &[u32]) -> Result<Dictionary, Failure> {
    if identifiers.is_empty() || identifiers.len() > 2 || identifiers.iter().copied().collect::<BTreeSet<_>>().len() != identifiers.len() { return Err(PROTOCOL); }
    let mut input = Dictionary::new();
    input.insert("stopAll".into(), XPCObject::Bool(false));
    input.insert("identifiers".into(), XPCObject::Array(identifiers.iter().map(|id| XPCObject::UInt64(*id as u64)).collect()));
    let mut version = Dictionary::new();
    version.insert("originalComponentsCount".into(), XPCObject::Int64(2));
    version.insert("components".into(), XPCObject::Array(vec![XPCObject::UInt64(629), XPCObject::UInt64(3)]));
    version.insert("stringValue".into(), XPCObject::String("629.3".into()));
    let mut request = Dictionary::new();
    request.insert("CoreDevice.CoreDeviceDDIProtocolVersion".into(), XPCObject::Int64(2));
    request.insert("CoreDevice.action".into(), XPCObject::Dictionary(Dictionary::new()));
    request.insert("CoreDevice.coreDeviceVersion".into(), XPCObject::Dictionary(version));
    request.insert("CoreDevice.deviceIdentifier".into(), XPCObject::String(uuid::Uuid::new_v4().to_string()));
    request.insert("CoreDevice.invocationIdentifier".into(), XPCObject::String(uuid::Uuid::new_v4().to_string()));
    request.insert("CoreDevice.featureIdentifier".into(), XPCObject::String("com.apple.coredevice.feature.stopmediastream".into()));
    request.insert("CoreDevice.actionIdentifier".into(), XPCObject::String("com.apple.coredevice.action.mediastreamstop".into()));
    request.insert("CoreDevice.input".into(), XPCObject::Dictionary(input));
    Ok(request)
}
impl SelectiveStop {
    async fn stop(&mut self, identifiers: &[u32]) -> Result<Server, Failure> {
        self.inner.send_object(stop_envelope(identifiers)?, true).await.map_err(|_| SERVICE)?;
        let response = self.inner.recv().await.map_err(|_| SERVICE)?;
        let response = dict(field(dict(&response)?, "CoreDevice.output")?)?;
        let stopped = field(response, "stoppedStreams")?.as_array().ok_or(PROTOCOL)?;
        if stopped.len() != identifiers.len() { return Err(PROTOCOL); }
        let stopped: BTreeSet<u32> = stopped.iter().map(|value| {
            value.as_unsigned_integer().and_then(|value| value.try_into().ok()).ok_or(PROTOCOL)
        }).collect::<Result<_, _>>()?;
        if stopped != identifiers.iter().copied().collect() { return Err(PROTOCOL); }
        server(field(response, "serverInfo")?)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum State { Cold, Preparing, Ready, Done }
#[derive(Clone)]
struct Plan { kind: Kind, receiver_ip: IpAddr, receiver_port: u16, sender_ip: IpAddr }
impl Plan {
    fn matches(&self, connection: &Connection, session: uuid::Uuid) -> bool {
        connection.session == session && connection.kind == self.kind
            && connection.receiver_ip == self.receiver_ip && connection.receiver_port == self.receiver_port
            && connection.sender_ip == self.sender_ip
    }
}
struct Drain { task: JoinHandle<()>, alive: Arc<AtomicBool>, feedback: watch::Sender<Option<Connection>> }
struct Alive(Arc<AtomicBool>);
impl Drop for Alive { fn drop(&mut self) { self.0.store(false, Ordering::Release); } }
impl Drain {
    fn start(socket: UdpSocketHandle) -> Self {
        let alive = Arc::new(AtomicBool::new(true));
        let live = alive.clone();
        let (feedback, receiver) = watch::channel(None);
        let task = tokio::spawn(async move {
            let _alive = Alive(live);
            drain(socket, receiver).await;
        });
        Self { task, alive, feedback }
    }
}

pub(crate) struct OwnedMedia {
    state: State,
    session: uuid::Uuid,
    plans: Vec<Plan>,
    confirmed: Vec<Connection>,
    pending_start: bool,
    dirty: bool,
    client: Option<DisplayServiceClient<Box<dyn ReadWrite>>>,
    drains: Vec<Drain>,
}
impl OwnedMedia {
    pub(crate) fn new() -> Self {
        Self { state: State::Cold, session: uuid::Uuid::new_v4(), plans: Vec::new(), confirmed: Vec::new(),
            pending_start: false, dirty: false, client: None, drains: Vec::new() }
    }
    pub(crate) fn uncertain(&self) -> bool { self.state == State::Preparing || self.pending_start || self.dirty }
    fn owned(&self, server: &Server) -> Result<Vec<Connection>, Failure> {
        let mut owned = Vec::new();
        for connection in &server.connections {
            if connection.session == self.session {
                if !self.plans.iter().any(|plan| plan.matches(connection, self.session)) { return Err(PROTOCOL); }
                if let Some(known) = self.confirmed.iter().find(|known| known.kind == connection.kind) {
                    if known != connection { return Err(PROTOCOL); }
                }
                if owned.iter().any(|known: &Connection| known.kind == connection.kind) { return Err(PROTOCOL); }
                owned.push(connection.clone());
            } else if self.confirmed.iter().any(|known| known.identifier == connection.identifier) {
                return Err(FOREIGN);
            }
        }
        Ok(owned)
    }
    pub(crate) async fn check_active(&mut self, tunnel: &mut Tunnel) -> Result<(), Failure> {
        if self.state != State::Ready { return Err(NOT_PREPARED); }
        let current = status(tunnel).await?;
        let owned = self.owned(&current)?;
        if owned.len() != 2 || current.connections.len() != 2 || !current.running || !current.healthy
            || self.drains.iter().any(|drain| !drain.alive.load(Ordering::Acquire)) {
            self.dirty = true; return Err(STREAM_LOST);
        }
        Ok(())
    }
    pub(crate) async fn prepare(&mut self, tunnel: &mut Tunnel, may_have_acted: &AtomicBool) -> Result<(), Failure> {
        if self.state == State::Ready { return self.check_active(tunnel).await; }
        if self.state != State::Cold { self.dirty = true; return Err(STOP_UNCONFIRMED); }
        let current = status(tunnel).await?;
        if !current.connections.is_empty() { return Err(FOREIGN); }
        self.state = State::Preparing;
        self.client = Some(DisplayServiceClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| SERVICE)?);
        let audio = tunnel.adapter.bind_udp(0).await.map_err(|_| SERVICE)?;
        let audio_port = audio.local_port();
        self.drains.push(Drain::start(audio));
        let video = tunnel.adapter.bind_udp(0).await.map_err(|_| SERVICE)?;
        let video_port = video.local_port();
        self.drains.push(Drain::start(video));
        let receiver_ip = tunnel.adapter.host_ip();
        let sender_ip = tunnel.adapter.peer_ip();
        self.plans = vec![Plan { kind: Kind::Audio, receiver_ip, receiver_port: audio_port, sender_ip },
            Plan { kind: Kind::Video, receiver_ip, receiver_port: video_port, sender_ip }];
        // These are the pinned upstream's captured negotiation compatibility
        // constants, not claims about this host's actual Mac/OS identity.
        let call_info = CallInfoBlob { call_id: 0, client_version: 1, device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(), os_version: "25F71".into(), device_name: None, audio_device_uid: None };
        let offer = build_screen_audio_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &call_info).map_err(|_| PROTOCOL)?;
        let audio_params = build_start_audio_parameters(&receiver_ip.to_string(), audio_port, &sender_ip.to_string(),
            50000, offer, FEATURES, self.session);
        self.pending_start = true;
        // The daemon can replace a duplicate existing stream as part of start.
        // Therefore this flag precedes media start, not just the first HID send.
        may_have_acted.store(true, Ordering::Release);
        let answer = self.client.as_mut().ok_or(PROTOCOL)?.start_media_stream(audio_params).await.map_err(|_| SERVICE)?;
        let audio_connection = connection(field(dict(&answer)?, "connection")?)?;
        if !self.plans[0].matches(&audio_connection, self.session) { return Err(PROTOCOL); }
        self.confirmed.push(audio_connection.clone());
        self.pending_start = false;
        self.drains[0].feedback.send(Some(audio_connection)).map_err(|_| STREAM_LOST)?;
        // Recheck after audio, before video. This is still a best-effort guard,
        // not a cross-controller atomic acquisition primitive.
        let current = status(tunnel).await?;
        if current.connections.len() != 1 || self.owned(&current)?.len() != 1 || !current.healthy { return Err(FOREIGN); }
        let our_ssrc = uuid::Uuid::new_v4().as_u128() as u32;
        let offer = build_screen_video_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &call_info, our_ssrc).map_err(|_| PROTOCOL)?;
        let video_params = build_start_video_parameters(&receiver_ip.to_string(), video_port, &sender_ip.to_string(),
            50001, offer, FEATURES, 1, self.session);
        self.pending_start = true;
        let answer = self.client.as_mut().ok_or(PROTOCOL)?.start_media_stream(video_params).await.map_err(|_| SERVICE)?;
        let video_connection = connection(field(dict(&answer)?, "connection")?)?;
        if !self.plans[1].matches(&video_connection, self.session) || video_connection.identifier != our_ssrc
            || self.confirmed.iter().any(|known| known.identifier == video_connection.identifier) { return Err(PROTOCOL); }
        self.confirmed.push(video_connection.clone());
        self.pending_start = false;
        self.drains[1].feedback.send(Some(video_connection)).map_err(|_| STREAM_LOST)?;
        let current = status(tunnel).await?;
        if !current.running || !current.healthy || current.connections.len() != 2 || self.owned(&current)?.len() != 2 { return Err(PROTOCOL); }
        self.state = State::Ready;
        Ok(())
    }
    async fn cleanup_remote(&mut self, tunnel: &mut Tunnel) -> Result<(), Failure> {
        if self.confirmed.is_empty() && !self.pending_start { return Ok(()); }
        let current = status(tunnel).await?;
        let owned = self.owned(&current)?;
        if !owned.is_empty() {
            let identifiers: Vec<_> = owned.iter().map(|connection| connection.identifier).collect();
            let mut stop = SelectiveStop::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| SERVICE)?;
            let after = stop.stop(&identifiers).await?;
            if !self.owned(&after)?.is_empty() { return Err(STOP_UNCONFIRMED); }
            // A successful stop RPC alone is insufficient: independently query
            // the actual server and confirm our UUID/endpoints have gone.
            let after = status(tunnel).await?;
            if !self.owned(&after)?.is_empty() { return Err(STOP_UNCONFIRMED); }
        }
        if self.pending_start {
            // A dropped start future may still be committing on the device.
            // An empty status snapshot cannot prove that no late creation will
            // occur. Preserve the poison even after removing observed matches.
            return Err(STOP_UNCONFIRMED);
        }
        Ok(())
    }
    pub(crate) async fn cleanup(&mut self, tunnel: &mut Tunnel) -> Result<(), Failure> {
        if self.state == State::Cold { return Ok(()); }
        if self.state == State::Done { return if self.dirty || self.pending_start { Err(STOP_UNCONFIRMED) } else { Ok(()) }; }
        let result = self.cleanup_remote(tunnel).await;
        self.client = None;
        let drains = std::mem::take(&mut self.drains);
        for drain in &drains { drain.task.abort(); }
        for drain in drains { let _ = drain.task.await; }
        self.state = State::Done;
        self.dirty = result.is_err();
        result
    }
}
impl Drop for OwnedMedia {
    fn drop(&mut self) {
        // Runtime drop joins/cancels these local tasks. Remote cleanup is only
        // ever confirmed by cleanup(), never by dropping an async future.
        for drain in &self.drains { drain.task.abort(); }
    }
}

// RTP is discarded, never decoded, logged, stored, or sent to the model. Small
// RTCP receiver reports keep the negotiated media gate alive. Their packet
// counters use only observed headers and have a bounded duplicate window.
#[derive(Default)]
struct ReceiveStats {
    first: Option<u32>, highest: u32, received: u32,
    recent: BTreeSet<u32>, order: VecDeque<u32>,
    last_expected: u32, last_received: u32,
    sender_report: Option<(u32, Instant)>,
}
impl ReceiveStats {
    fn packet(&mut self, sequence: u16) {
        let extended = if self.first.is_none() { sequence as u32 } else {
            let forward = sequence.wrapping_sub(self.highest as u16);
            if forward < 0x8000 { self.highest.wrapping_add(forward as u32) }
            else { self.highest.saturating_sub((self.highest as u16).wrapping_sub(sequence) as u32) }
        };
        if self.first.is_none() { self.first = Some(extended); self.highest = extended; }
        if extended < self.first.unwrap() || self.highest.saturating_sub(extended) > 4096 || !self.recent.insert(extended) { return; }
        self.highest = self.highest.max(extended);
        self.received = self.received.saturating_add(1);
        self.order.push_back(extended);
        if self.order.len() > 4096 { self.recent.remove(&self.order.pop_front().unwrap()); }
    }
    fn report(&mut self, connection: &Connection) -> Vec<u8> {
        let mut blocks = Vec::new();
        if let Some(first) = self.first {
            let expected = self.highest.saturating_sub(first).saturating_add(1);
            let interval_expected = expected.saturating_sub(self.last_expected);
            let interval_received = self.received.saturating_sub(self.last_received);
            let interval_lost = interval_expected.saturating_sub(interval_received);
            let (lsr, dlsr) = self.sender_report.map(|(lsr, at)| (lsr,
                ((at.elapsed().as_secs_f64() * 65536.0).min(u32::MAX as f64)) as u32)).unwrap_or((0, 0));
            blocks.push(ReportBlock { source_ssrc: connection.peer_ssrc,
                fraction_lost: if interval_expected == 0 { 0 } else { (((interval_lost as u64) << 8) / interval_expected as u64).min(255) as u8 },
                cumulative_lost: expected.saturating_sub(self.received).min(0x7fffff), highest_seq: self.highest,
                jitter: 0, lsr, dlsr });
            self.last_expected = expected; self.last_received = self.received;
        }
        let mut report = build_receiver_report(connection.identifier, &blocks);
        report.extend(build_sdes(connection.identifier, "dsh-phone-core"));
        report
    }
}
async fn drain(socket: UdpSocketHandle, feedback: watch::Receiver<Option<Connection>>) {
    let mut timer = tokio::time::interval(Duration::from_millis(500));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut stats = ReceiveStats::default();
    loop {
        tokio::select! {
            packet = socket.recv() => {
                let Ok(packet) = packet else { return; };
                let connection = feedback.borrow().clone();
                if let Some(connection) = connection {
                    if packet.source_port != connection.sender_port { continue; }
                    if is_rtcp(&packet.data) {
                        if let Some(report) = SenderReport::parse_first(&packet.data) {
                            if report.ssrc == connection.peer_ssrc { stats.sender_report = Some((report.ntp_middle, Instant::now())); }
                        }
                    } else if let Some(rtp) = RtpPacket::parse(&packet.data) {
                        if rtp.ssrc == connection.peer_ssrc { stats.packet(rtp.sequence_number); }
                    }
                }
            }
            _ = timer.tick() => {
                let connection = feedback.borrow().clone();
                if let Some(connection) = connection {
                    if socket.send_to(connection.sender_port, stats.report(&connection)).await.is_err() { return; }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn connection_fixture(session: uuid::Uuid, kind: &str, port: u16, id: u32) -> plist::Value {
        // Constructed from the fixed Apple DDI reflection schema and pinned
        // protocol source. This fixture is NOT a captured device response.
        let json = serde_json::json!({"direction":"output","type":kind,
            "receiver":{"ipv6Address":"fd00::1","port":port},
            "sender":{"ipv6Address":"fd00::2","port":50000},
            "streamConfig":{"RemoteSSRC":id,"LocalSSRC":123,"SourceIP":"fd00::2","DestIp":"fd00::1","SourcePort":50000,"DestPort":port},
            "options":{"avcMediaStreamOptionClientSessionID":{"uuid":session.to_string()}}});
        plist::to_value(&json).unwrap()
    }
    fn server_fixture(connections: Vec<plist::Value>) -> plist::Value {
        let mut value = plist::Dictionary::new();
        value.insert("running".into(), (!connections.is_empty()).into());
        value.insert("sessions".into(), plist::Value::Array(connections.into_iter().map(|connection| {
            let mut entry = plist::Dictionary::new(); entry.insert("connection".into(), connection);
            let mut status = plist::Dictionary::new(); status.insert("connectionErrors".into(), 0u64.into()); status.insert("runDurationSeconds".into(), 1u64.into());
            entry.insert("status".into(), status.into()); entry.into()
        }).collect()));
        value.into()
    }
    fn owned_fixture() -> OwnedMedia {
        let mut owner = OwnedMedia::new();
        owner.plans = vec![Plan { kind: Kind::Audio, receiver_ip: "fd00::1".parse().unwrap(), receiver_port: 40000, sender_ip: "fd00::2".parse().unwrap() },
            Plan { kind: Kind::Video, receiver_ip: "fd00::1".parse().unwrap(), receiver_port: 40001, sender_ip: "fd00::2".parse().unwrap() }];
        owner.confirmed = vec![connection(&connection_fixture(owner.session, "audio", 40000, 7)).unwrap(),
            connection(&connection_fixture(owner.session, "video", 40001, 9)).unwrap()];
        owner
    }
    #[test]
    fn stop_wire_is_selective_and_unsigned_with_exact_action() {
        let envelope = stop_envelope(&[7, 9]).unwrap();
        assert_eq!(envelope.get("CoreDevice.CoreDeviceDDIProtocolVersion"), Some(&XPCObject::Int64(2)));
        assert_eq!(envelope.get("CoreDevice.actionIdentifier"), Some(&XPCObject::String("com.apple.coredevice.action.mediastreamstop".into())));
        let XPCObject::Dictionary(input) = envelope.get("CoreDevice.input").unwrap() else { panic!("input"); };
        assert_eq!(input.get("stopAll"), Some(&XPCObject::Bool(false)));
        assert_eq!(input.get("identifiers"), Some(&XPCObject::Array(vec![XPCObject::UInt64(7), XPCObject::UInt64(9)])));
        assert!(stop_envelope(&[]).is_err()); assert!(stop_envelope(&[7, 7]).is_err()); assert!(stop_envelope(&[1, 2, 3]).is_err());
        // This exercises the real upstream XPC serialization, not a JSON mock.
        let encoded = XPCObject::Dictionary(envelope.clone()).encode().unwrap();
        assert_eq!(XPCObject::decode(&encoded).unwrap(), XPCObject::Dictionary(envelope));
    }
    #[test]
    fn schema_rejects_unknown_idle_and_ambiguous_identifiers() {
        assert!(server(&plist::Dictionary::new().into()).is_err());
        assert!(server(&server_fixture(Vec::new())).unwrap().connections.is_empty());
        let owner = owned_fixture();
        let a = connection_fixture(owner.session, "audio", 40000, 7);
        let b = connection_fixture(owner.session, "video", 40001, 7);
        assert!(server(&server_fixture(vec![a, b])).is_err());
        let mut missing = server_fixture(vec![connection_fixture(owner.session, "audio", 40000, 7)]);
        missing.as_dictionary_mut().unwrap().get_mut("sessions").unwrap().as_array_mut().unwrap()[0].as_dictionary_mut().unwrap().remove("connection");
        assert!(server(&missing).is_err());
    }
    #[test]
    fn ownership_requires_uuid_identifier_kind_and_endpoint() {
        let owner = owned_fixture();
        let own = server(&server_fixture(vec![connection_fixture(owner.session, "audio", 40000, 7), connection_fixture(owner.session, "video", 40001, 9)])).unwrap();
        assert_eq!(owner.owned(&own).unwrap().len(), 2);
        let foreign = server(&server_fixture(vec![connection_fixture(uuid::Uuid::new_v4(), "video", 50001, 10)])).unwrap();
        assert!(owner.owned(&foreign).unwrap().is_empty());
        let collision = server(&server_fixture(vec![connection_fixture(uuid::Uuid::new_v4(), "video", 40001, 9)])).unwrap();
        assert!(owner.owned(&collision).is_err());
        let changed_port = server(&server_fixture(vec![connection_fixture(owner.session, "audio", 45000, 7)])).unwrap();
        assert!(owner.owned(&changed_port).is_err());
        let changed_id = server(&server_fixture(vec![connection_fixture(owner.session, "audio", 40000, 8)])).unwrap();
        assert!(owner.owned(&changed_id).is_err());
    }
    #[test]
    fn feedback_tracks_actual_sequence_wrap_and_does_not_count_duplicates() {
        let connection = owned_fixture().confirmed[0].clone();
        let mut stats = ReceiveStats::default();
        for sequence in [65534, 65535, 0, 0, 2, 1] { stats.packet(sequence); }
        assert_eq!(stats.highest, 65538); assert_eq!(stats.received, 5);
        let report = stats.report(&connection);
        assert_eq!(report[0], 0x81); assert_eq!(report[1], 201);
        assert_eq!(u32::from_be_bytes(report[4..8].try_into().unwrap()), 7);
        assert_eq!(u32::from_be_bytes(report[8..12].try_into().unwrap()), 123);
        assert_eq!(u32::from_be_bytes(report[16..20].try_into().unwrap()), 65538);
    }
}
