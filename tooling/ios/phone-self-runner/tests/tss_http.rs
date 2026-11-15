//! Compile and exercise the actual pinned, patched HTTP implementation.
//! All tests use byte slices, in-memory streams or virtual time; no network.
//! The production idevice dependency separately compiles with its ring TLS feature.
#![allow(dead_code, unexpected_cfgs)]

pub use idevice::{IdeviceError, ReadWrite};

#[path = "../.upstream/idevice/src/http.rs"]
mod http;
