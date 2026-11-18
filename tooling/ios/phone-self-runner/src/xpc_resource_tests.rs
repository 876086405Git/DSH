//! ADD08 fixtures: bounded object trees and in-memory HTTP/2 transports only.
//! Include the prepared files so private HTTP/2 accounting tests exercise the
//! same source that is compiled into the pinned idevice dependency.
#[path = "../.upstream/idevice/src/xpc/http2/mod.rs"]
mod http2;
#[path = "../.upstream/idevice/src/xpc/object_limits.rs"]
mod object_limits;

use idevice::xpc::{Dictionary, RemoteXpcClient, XPCMessage, XPCObject};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn nested(depth: usize) -> XPCObject {
    let mut object = XPCObject::Null;
    for _ in 1..depth { object = XPCObject::Array(vec![object]); }
    object
}
fn expect_limit<T: std::fmt::Debug>(result: Result<T, idevice::IdeviceError>, kind: &str) {
    let reason = result.unwrap_err().to_string();
    assert!(reason.contains(&format!("object {kind} exceeds limit")), "{reason}");
}
fn data_frame(stream: u32, body: &[u8]) -> Vec<u8> {
    let mut bytes = (body.len() as u32).to_be_bytes()[1..].to_vec();
    bytes.extend_from_slice(&[0, 0]);
    bytes.extend_from_slice(&stream.to_be_bytes());
    bytes.extend_from_slice(body);
    bytes
}

#[test]
fn public_decode_and_plist_conversion_accept_depth_64_reject_65() {
    let allowed = nested(64);
    let wire = allowed.encode().unwrap();
    assert!(wire.len() < 800); // Deliberately small, never an old deep-stack probe.
    XPCObject::decode(&wire).unwrap().to_plist().unwrap();
    allowed.to_plist().unwrap();
    let denied = nested(65);
    expect_limit(XPCObject::decode(&denied.encode().unwrap()), "depth");
    expect_limit(denied.to_plist(), "depth");
}

#[test]
fn cumulative_object_budget_includes_nulls_and_sibling_containers() {
    let allowed = XPCObject::Array(vec![XPCObject::Null; object_limits::MAX_OBJECTS - 1]);
    let decoded = XPCObject::decode(&allowed.encode().unwrap()).unwrap();
    assert_eq!(decoded.as_array().unwrap().len(), object_limits::MAX_OBJECTS - 1);
    assert_eq!(decoded.to_plist().unwrap().as_array().unwrap().len(), object_limits::MAX_OBJECTS - 1);

    let denied = XPCObject::Array(vec![
        XPCObject::Array(vec![XPCObject::Null; 32_767]),
        XPCObject::Array(vec![XPCObject::Null; 32_767]),
    ]); // Each width is allowed; the shared count is 65,537 including containers.
    expect_limit(XPCObject::decode(&denied.encode().unwrap()), "count");
    expect_limit(denied.to_plist(), "count");

    // An impossible declared count is rejected with no child bytes present.
    let mut wire = XPCObject::Array(Vec::new()).encode().unwrap();
    wire[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
    expect_limit(XPCObject::decode(&wire), "count");
}

#[test]
fn program_constructed_payload_and_dictionary_keys_share_the_byte_budget() {
    let denied = XPCObject::Array(vec![
        XPCObject::Data(vec![0; object_limits::MAX_DYNAMIC_BYTES - 3]),
        XPCObject::String("four".into()),
    ]);
    expect_limit(denied.to_plist(), "payload bytes");
    drop(denied);
    let mut dictionary = Dictionary::new();
    dictionary.insert("k".repeat(object_limits::MAX_DYNAMIC_BYTES + 1), XPCObject::Null);
    expect_limit(XPCObject::Dictionary(dictionary).to_plist(), "payload bytes");
}

#[test]
fn file_transfer_conversion_counts_its_generated_scalar_and_keys() {
    let transfer = XPCObject::FileTransfer {
        msg_id: 7,
        data: Box::new(XPCObject::Array(vec![XPCObject::Null; object_limits::MAX_OBJECTS - 2])),
    };
    // Decoded source fits exactly, but the generated msg_id scalar adds a node.
    let decoded = XPCObject::decode(&transfer.encode().unwrap()).unwrap();
    expect_limit(decoded.to_plist(), "count");
    let transfer = XPCObject::FileTransfer {
        msg_id: 8,
        data: Box::new(XPCObject::Data(vec![0; object_limits::MAX_DYNAMIC_BYTES - 9])),
    }; // "msg_id" and "data" add 10 bytes to the converted representation.
    expect_limit(transfer.to_plist(), "payload bytes");
}

#[test]
fn normal_strings_data_and_dictionary_keys_round_trip_with_remaining_length_checks() {
    let mut dict = Dictionary::new();
    dict.insert("键".into(), XPCObject::String("正文".into()));
    dict.insert("data".into(), XPCObject::Data(vec![1, 2, 3]));
    let source = XPCObject::Dictionary(dict);
    let decoded = XPCObject::decode(&source.encode().unwrap()).unwrap();
    assert_eq!(decoded, source);
    assert_eq!(decoded.to_plist().unwrap().as_dictionary().unwrap()["键"].as_string(), Some("正文"));
    for kind in [0x9000u32, 0x8000] {
        let mut wire = 0x42133742u32.to_le_bytes().to_vec();
        wire.extend_from_slice(&5u32.to_le_bytes());
        wire.extend_from_slice(&kind.to_le_bytes());
        wire.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(matches!(XPCObject::decode(&wire), Err(idevice::IdeviceError::NotEnoughBytes(..))));
    }
    let mut bad_string = XPCObject::String("x".into()).encode().unwrap();
    bad_string[16] = 0; // Embedded NUL before the declared terminator.
    assert!(XPCObject::decode(&bad_string).is_err());
}

#[tokio::test(start_paused = true)]
async fn all_public_receive_routes_drop_owned_transport_after_a_bounded_depth_error() {
    for route in 0..3 {
        let (io, mut peer) = tokio::io::duplex(4096);
        let mut client = RemoteXpcClient::new(io).await.unwrap();
        let mut preface = [0u8; 24];
        peer.read_exact(&mut preface).await.unwrap();
        assert_eq!(&preface, b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
        let channel = if route == 0 { 1 } else { 3 };
        let bytes = XPCMessage::new(None, Some(nested(65)), None).encode(1).unwrap();
        assert!(bytes.len() < 850);
        peer.write_all(&data_frame(channel, &bytes)).await.unwrap();
        let result = tokio::time::timeout(Duration::from_secs(1), async {
            match route {
                0 => client.recv_root().await,
                1 => client.recv().await,
                _ => client.recv_any().await,
            }
        }).await.expect("complete rejected input must not wait for more bytes");
        expect_limit(result, "depth");
        let mut byte = [0u8; 1];
        assert_eq!(peer.read(&mut byte).await.unwrap(), 0);
        assert!(client.recv().await.is_err()); // Sticky closed transport.
    }
}

#[tokio::test(start_paused = true)]
async fn multi_frame_message_returns_consumed_credit_then_closes_on_conversion_budget() {
    let object = XPCObject::FileTransfer {
        msg_id: 9,
        data: Box::new(XPCObject::Array(vec![XPCObject::Null; object_limits::MAX_OBJECTS - 2])),
    };
    let body = XPCMessage::new(None, Some(object), None).encode(1).unwrap();
    assert!(body.len() > 65535 && body.len() < 300_000);
    XPCMessage::decode(&body).unwrap(); // Source object fits; plist adds msg_id.
    let expected_credit = ((body.len() - 1) / 16384 * 16384) as u32;
    let (io, mut peer) = tokio::io::duplex(32768);
    let mut client = RemoteXpcClient::new(io).await.unwrap();
    let writer = tokio::spawn(async move {
        let mut preface = [0u8; 24];
        peer.read_exact(&mut preface).await.unwrap();
        for part in body.chunks(16384) {
            peer.write_all(&data_frame(3, part)).await.unwrap();
        }
        let mut updates = Vec::new();
        peer.read_to_end(&mut updates).await.unwrap();
        assert_eq!(updates.len() % 13, 0);
        let mut totals = [0u32; 2];
        for update in updates.chunks_exact(13) {
            assert_eq!(&update[..5], &[0, 0, 4, 8, 0]);
            let stream = u32::from_be_bytes(update[5..9].try_into().unwrap());
            assert!(stream == 0 || stream == 3);
            let increment = u32::from_be_bytes(update[9..13].try_into().unwrap());
            totals[usize::from(stream == 3)] += increment;
        }
        assert_eq!(totals, [expected_credit, expected_credit]);
    });
    let result = tokio::time::timeout(Duration::from_secs(1), client.recv()).await
        .expect("bounded in-memory multi-frame input must make progress");
    expect_limit(result, "count");
    tokio::time::timeout(Duration::from_secs(1), writer).await.unwrap().unwrap();
}
