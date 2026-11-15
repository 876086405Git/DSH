//! ADD09 unread-control-channel regression fixtures. Only bounded Tokio memory
//! transports and virtual time; no socket, device, model, or user record.
//! This is a separate target: it does not run the older resource/deep fixtures.
use idevice::xpc::{Dictionary, RemoteXpcClient, XPCMessage, XPCObject};
use std::{future::Future, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::sync::oneshot;

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(1), future).await
        .expect("bounded synthetic operation must finish within virtual deadline")
}

async fn client() -> (RemoteXpcClient<DuplexStream>, DuplexStream) {
    let (io, mut peer) = tokio::io::duplex(32768);
    let client = within(RemoteXpcClient::new(io)).await.unwrap();
    let mut preface = [0u8; 24];
    within(peer.read_exact(&mut preface)).await.unwrap();
    assert_eq!(&preface, b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    (client, peer)
}

fn message(object: XPCObject) -> Vec<u8> {
    XPCMessage::new(None, Some(object), None).encode(1).unwrap()
}

fn wire(kind: u8, flags: u8, channel: u32, body: &[u8]) -> Vec<u8> {
    assert!(body.len() <= 16384);
    let mut bytes = (body.len() as u32).to_be_bytes()[1..].to_vec();
    bytes.extend_from_slice(&[kind, flags]);
    bytes.extend_from_slice(&channel.to_be_bytes());
    bytes.extend_from_slice(body);
    bytes
}

async fn frame(peer: &mut DuplexStream, channel: u32, body: &[u8]) {
    within(peer.write_all(&wire(0, 0, channel, body))).await.unwrap();
}

async fn update(peer: &mut DuplexStream) -> (u32, u32) {
    let mut bytes = [0u8; 13];
    within(peer.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes[..5], &[0, 0, 4, 8, 0]);
    (
        u32::from_be_bytes(bytes[5..9].try_into().unwrap()),
        u32::from_be_bytes(bytes[9..13].try_into().unwrap()),
    )
}

async fn receive(client: &mut RemoteXpcClient<DuplexStream>, channel: u32) -> plist::Value {
    if channel == 1 { within(client.recv_root()).await.unwrap() }
    else { assert_eq!(channel, 3); within(client.recv()).await.unwrap() }
}

#[tokio::test(start_paused = true)]
async fn unread_control_channel_returns_credit_across_windows_and_preserves_its_body() {
    for requested in [3, 1] {
        let other = if requested == 3 { 1 } else { 3 };
        let (mut client, mut peer) = client().await;
        let body = message(XPCObject::Data(vec![0x41; 128 * 1024]));
        assert!(body.len() > 2 * 65535 && body.len() < 132_000);
        let expected_credit = body.len() as u32;
        let answer = message(XPCObject::String("selected route".into()));
        let (done, finished) = oneshot::channel();
        let writer = tokio::spawn(async move {
            let mut credited = 0;
            for part in body.chunks(16384) {
                frame(&mut peer, other, part).await;
                // The peer waits for actual WINDOW_UPDATE before supplying its
                // next frame; it never sends beyond the initial receive window.
                assert_eq!(update(&mut peer).await, (0, part.len() as u32));
                assert_eq!(update(&mut peer).await, (other, part.len() as u32));
                credited += part.len() as u32;
            }
            frame(&mut peer, requested, &answer).await;
            within(finished).await.unwrap(); // Keep transport open through reads.
            credited
        });
        assert_eq!(receive(&mut client, requested).await.as_string(), Some("selected route"));
        let kept = receive(&mut client, other).await;
        let bytes = kept.as_data().unwrap();
        assert_eq!(bytes.len(), 128 * 1024);
        assert!(bytes.iter().all(|byte| *byte == 0x41));
        done.send(()).unwrap();
        assert_eq!(within(writer).await.unwrap(), expected_credit);
    }
}

#[tokio::test(start_paused = true)]
async fn cancelled_reply_wait_keeps_other_channel_partial_bytes_and_returns_credit_once() {
    let (mut client, mut peer) = client().await;
    let root = message(XPCObject::String("root survives cancellation".into()));
    frame(&mut peer, 1, &root[..15]).await;
    assert!(tokio::time::timeout(Duration::from_secs(1), client.recv()).await.is_err());
    assert_eq!(update(&mut peer).await, (0, 15));
    assert_eq!(update(&mut peer).await, (1, 15));
    frame(&mut peer, 1, &root[15..]).await;
    frame(&mut peer, 3, &message(XPCObject::String("reply".into()))).await;
    assert_eq!(within(client.recv()).await.unwrap().as_string(), Some("reply"));
    assert_eq!(within(client.recv_root()).await.unwrap().as_string(), Some("root survives cancellation"));
}

#[tokio::test(start_paused = true)]
async fn zero_byte_unread_data_frames_do_not_exhaust_the_http2_frame_queue() {
    let (mut client, mut peer) = client().await;
    let (done, finished) = oneshot::channel();
    let writer = tokio::spawn(async move {
        // 1,100 * 9 bytes on the wire, zero DATA credit and no large allocation.
        // The old single-route read retained 1,025 frames and hit its frame cap.
        for _ in 0..1100 { frame(&mut peer, 1, &[]).await; }
        frame(&mut peer, 3, &message(XPCObject::String("reply after empty DATA".into()))).await;
        within(finished).await.unwrap();
    });
    assert_eq!(within(client.recv()).await.unwrap().as_string(), Some("reply after empty DATA"));
    done.send(()).unwrap();
    within(writer).await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn unread_channel_still_rejects_an_oversize_length_at_sixteen_bytes_and_closes() {
    for requested in [3, 1] {
        let other = if requested == 3 { 1 } else { 3 };
        let (mut client, mut peer) = client().await;
        let mut header = [0u8; 16];
        header[..4].copy_from_slice(&0x29b00b92u32.to_le_bytes());
        header[8..16].copy_from_slice(&(16 * 1024 * 1024u64 + 1).to_le_bytes());
        frame(&mut peer, other, &header[..15]).await;
        frame(&mut peer, other, &header[15..]).await;
        let result = if requested == 3 { within(client.recv()).await }
            else { within(client.recv_root()).await };
        assert!(result.unwrap_err().to_string().contains("control message exceeds limit"));
        // The first 15 bytes may already have earned credit. Drain only a tiny
        // bounded output buffer, then require EOF; no extra input/body is sent.
        let mut output = [0u8; 64];
        let mut total = 0;
        loop {
            assert!(total < output.len());
            let count = within(peer.read(&mut output[total..])).await.unwrap();
            if count == 0 { break; }
            total += count;
        }
        assert!(total == 0 || total == 26);
        assert!(within(client.recv()).await.is_err());
    }
}

#[tokio::test(start_paused = true)]
async fn any_receive_drains_buffered_keepalives_before_returning_preserved_root_bodies() {
    let (mut client, mut peer) = client().await;
    let mut roots = XPCMessage::new(None, None, None).encode(1).unwrap();
    roots.extend(message(XPCObject::Dictionary(Dictionary::new())));
    roots.extend(message(XPCObject::String("root first".into())));
    roots.extend(message(XPCObject::String("root second".into())));
    frame(&mut peer, 1, &roots).await;
    frame(&mut peer, 3, &message(XPCObject::String("reply only".into()))).await;
    assert_eq!(within(client.recv()).await.unwrap().as_string(), Some("reply only"));
    // No more network input: empty/bodyless wrappers already buffered before a
    // body cannot make recv_any wait on HTTP/2 instead of consuming that body.
    assert_eq!(within(client.recv_any()).await.unwrap().as_string(), Some("root first"));
    assert_eq!(within(client.recv_any()).await.unwrap().as_string(), Some("root second"));
}

#[tokio::test(start_paused = true)]
async fn required_stream_eof_is_not_hidden_by_the_other_open_control_channel() {
    for requested in [1, 3] {
        for (kind, flags) in [(0, 1), (1, 5)] { // DATA END_STREAM; HEADERS END_STREAM|END_HEADERS.
            let (mut client, mut peer) = client().await;
            within(peer.write_all(&wire(kind, flags, requested, &[]))).await.unwrap();
            let result = if requested == 3 { within(client.recv()).await }
                else { within(client.recv_root()).await };
            assert!(result.unwrap_err().to_string().contains("requested streams have ended"));
            let mut byte = [0u8; 1];
            assert_eq!(within(peer.read(&mut byte)).await.unwrap(), 0);
        }
    }
}

#[tokio::test(start_paused = true)]
async fn required_stream_final_data_is_readable_before_its_eof() {
    for requested in [1, 3] {
        let (mut client, mut peer) = client().await;
        let final_body = message(XPCObject::String("final body".into()));
        within(peer.write_all(&wire(0, 1, requested, &final_body))).await.unwrap();
        assert_eq!(receive(&mut client, requested).await.as_string(), Some("final body"));
        let result = if requested == 3 { within(client.recv()).await }
            else { within(client.recv_root()).await };
        assert!(result.unwrap_err().to_string().contains("requested streams have ended"));
        // The final consumed bytes replenish the connection, never a closed
        // stream. This is the existing HTTP/2 accounting behavior, kept intact.
        assert_eq!(update(&mut peer).await, (0, final_body.len() as u32));
        let mut byte = [0u8; 1];
        assert_eq!(within(peer.read(&mut byte)).await.unwrap(), 0);
    }
}
