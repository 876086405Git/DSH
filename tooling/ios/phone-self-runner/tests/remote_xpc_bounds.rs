//! Only in-memory transport, literal bytes and virtual time. No RSD/device/server.
pub use idevice::IdeviceError;
use idevice::xpc::{RemoteXpcClient, XPCMessage, XPCObject};
use tokio::io::{AsyncWriteExt, DuplexStream};
use std::time::Duration;

// Exercise the exact helper source prepared by the product's pinned patch.
#[path = "../.upstream/idevice/src/xpc/bounds.rs"]
mod bounds;

fn header(body: u64) -> Vec<u8> {
    let mut data = vec![0; 24];
    data[..4].copy_from_slice(&0x29b00b92u32.to_le_bytes());
    data[8..16].copy_from_slice(&body.to_le_bytes());
    data
}
fn message(text: &str) -> Vec<u8> {
    XPCMessage::new(None, Some(XPCObject::String(text.into())), None).encode(1).unwrap()
}
async fn frame(peer: &mut DuplexStream, channel: u32, payload: &[u8]) {
    let mut wire = (payload.len() as u32).to_be_bytes()[1..].to_vec();
    wire.extend_from_slice(&[0, 0]); // DATA, no flags
    wire.extend_from_slice(&channel.to_be_bytes());
    wire.extend_from_slice(payload);
    peer.write_all(&wire).await.unwrap();
}
async fn client() -> (RemoteXpcClient<DuplexStream>, DuplexStream) {
    let (io, peer) = tokio::io::duplex(4096);
    (RemoteXpcClient::new(io).await.unwrap(), peer)
}

#[test]
fn public_decoder_rejects_large_u64_before_arithmetic_or_body_decode() {
    for body in [16 * 1024 * 1024 + 1, u64::MAX] {
        let error = XPCMessage::decode(&header(body)).unwrap_err();
        assert!(error.to_string().contains("control message exceeds limit"));
    }
    assert!(matches!(XPCMessage::decode(&header(16 * 1024 * 1024)),
        Err(IdeviceError::CdTunnel(idevice::CdTunnelError::SizeMismatch))));
}

#[tokio::test(start_paused = true)]
async fn every_receive_route_rejects_a_split_oversize_header_without_more_data() {
    for route in 0..3 {
        let (mut client, mut peer) = client().await;
        let channel = if route == 0 { 1 } else { 3 };
        let bytes = header(u64::MAX);
        frame(&mut peer, channel, &bytes[..15]).await;
        frame(&mut peer, channel, &bytes[15..16]).await;
        // The rest of the wrapper/body never arrives; no EOF is supplied.
        let result = tokio::time::timeout(Duration::from_secs(1), async {
            match route {
                0 => client.recv_root().await,
                1 => client.recv().await,
                _ => client.recv_any().await,
            }
        }).await.expect("must reject at length prefix, not wait for more bytes");
        assert!(result.unwrap_err().to_string().contains("control message exceeds limit"));
    }
}

#[tokio::test]
async fn coalesced_messages_are_consumed_one_at_a_time() {
    let (mut client, mut peer) = client().await;
    let mut bytes = message("first");
    bytes.extend(message("second"));
    frame(&mut peer, 3, &bytes).await;
    assert_eq!(client.recv().await.unwrap().as_string(), Some("first"));
    assert_eq!(client.recv().await.unwrap().as_string(), Some("second"));
}

#[tokio::test(start_paused = true)]
async fn cancelled_partial_receive_can_resume_with_bounded_buffer() {
    let (mut client, mut peer) = client().await;
    let bytes = message("resumed");
    frame(&mut peer, 3, &bytes[..15]).await;
    assert!(tokio::time::timeout(Duration::from_secs(1), client.recv()).await.is_err());
    frame(&mut peer, 3, &bytes[15..]).await;
    assert_eq!(client.recv().await.unwrap().as_string(), Some("resumed"));
}

#[tokio::test(start_paused = true)]
async fn complete_body_with_impossible_string_or_data_length_is_fatal() {
    for kind in [0x00009000u32, 0x00008000] {
        let mut body = 0x42133742u32.to_le_bytes().to_vec();
        body.extend_from_slice(&5u32.to_le_bytes());
        body.extend_from_slice(&kind.to_le_bytes());
        body.extend_from_slice(&u32::MAX.to_le_bytes());
        let mut bytes = header(body.len() as u64);
        bytes.extend(body);
        assert!(matches!(XPCMessage::decode(&bytes), Err(IdeviceError::NotEnoughBytes(..))));
        let (mut client, mut peer) = client().await;
        frame(&mut peer, 3, &bytes).await;
        let result = tokio::time::timeout(Duration::from_secs(1), client.recv()).await
            .expect("a complete malformed body must not accumulate further frames");
        assert!(matches!(result, Err(IdeviceError::NotEnoughBytes(..))));
    }
}
