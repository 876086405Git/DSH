//! Private pairing input shared by CoreDevice and XCTest. Never formatted or
//! included in an ABI event. This module performs no pairing setup or repair.
use std::path::Path;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use idevice::remote_pairing::RpPairingFile;
use serde::Deserialize;
use tokio::io::AsyncReadExt;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::{Failure, PAIRING};

pub(crate) const MAX_PAIRING: usize = 64 * 1024;
pub(crate) const MAX_PAIRING_BASE64: usize = 4 * MAX_PAIRING.div_ceil(3);

/// Each owned field cleans itself even when deserialization fails before the
/// surrounding ConfigWire/PairingWire has been completely constructed.
pub(crate) struct SecretString(Zeroizing<String>);
impl From<String> for SecretString {
    fn from(value: String) -> Self { Self(Zeroizing::new(value)) }
}
impl<'de> Deserialize<'de> for SecretString {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer).map(Self::from)
    }
}
impl Drop for SecretString {
    fn drop(&mut self) {
        self.0.zeroize();
        #[cfg(test)] record_clear("string", self.0.is_empty());
    }
}

struct SecretData(Zeroizing<Vec<u8>>);
impl SecretData {
    fn new(value: Vec<u8>) -> Self { Self(Zeroizing::new(value)) }
}
impl<'de> Deserialize<'de> for SecretData {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        plist::Data::deserialize(deserializer).map(|value| Self::new(value.into()))
    }
}
impl Drop for SecretData {
    fn drop(&mut self) {
        self.0.zeroize();
        #[cfg(test)] record_clear("data", self.0.is_empty());
    }
}

/// The persistent signing key already implements ZeroizeOnDrop in the pinned
/// dependency. The constructor below enforces that feature at compile time.
pub(crate) struct PairingRecord(RpPairingFile);
impl std::ops::Deref for PairingRecord {
    type Target = RpPairingFile;
    fn deref(&self) -> &Self::Target { &self.0 }
}
impl std::ops::DerefMut for PairingRecord {
    fn deref_mut(&mut self) -> &mut Self::Target { &mut self.0 }
}
impl Drop for PairingRecord {
    fn drop(&mut self) {
        self.0.identifier.zeroize();
        if let Some(irk) = &mut self.0.alt_irk { irk.zeroize(); }
        // SigningKey's own ZeroizeOnDrop runs when the inner record is dropped.
        #[cfg(test)] record_clear("record", self.0.identifier.is_empty()
            && self.0.alt_irk.as_ref().is_none_or(|irk| irk.is_empty()));
    }
}

pub(crate) enum PairingInput {
    Memory(PairingRecord),
    // Compatibility for the old XCTest ABI only. New Swift callers use Memory.
    LegacyFile(String),
}

impl PairingInput {
    /// Borrow only for synchronous validation. The typed record owns the key
    /// fields; no raw plist, base64 or caller pointer is retained.
    pub(crate) fn from_bytes(bytes: &[u8]) -> Option<Self> {
        Some(Self::Memory(validate(bytes).ok()?))
    }

    pub(crate) fn parse(base64: Option<SecretString>, file: Option<String>) -> Option<Self> {
        match (base64, file) {
            (Some(encoded), None) => {
                if encoded.0.is_empty() || encoded.0.len() > MAX_PAIRING_BASE64 {
                    return None;
                }
                // Decode into our own guarded buffer so a partial decode error
                // also clears bytes already written by the base64 decoder.
                let mut bytes = SecretData::new(vec![0; base64::decoded_len_estimate(encoded.0.len())]);
                let used = STANDARD.decode_slice(encoded.0.as_bytes(), bytes.0.as_mut_slice()).ok()?;
                bytes.0.truncate(used);
                if bytes.0.len() > MAX_PAIRING
                    || Zeroizing::new(STANDARD.encode(bytes.0.as_slice())).as_str() != encoded.0.as_str()
                {
                    return None;
                }
                Some(Self::Memory(validate(&bytes.0).ok()?))
            }
            (None, Some(file))
                if Path::new(&file).is_absolute()
                    && file.len() <= 4096
                    && !file.contains('\0') =>
            {
                Some(Self::LegacyFile(file))
            }
            _ => None,
        }
    }

    pub(crate) async fn load(self) -> Result<PairingRecord, Failure> {
        match self {
            Self::Memory(record) => Ok(record),
            Self::LegacyFile(path) => {
                let file = tokio::fs::OpenOptions::new().read(true)
                    .custom_flags(libc::O_NONBLOCK).open(path).await.map_err(|_| PAIRING)?;
                let metadata = file.metadata().await.map_err(|_| PAIRING)?;
                if !metadata.is_file() || metadata.len() > MAX_PAIRING as u64 {
                    return Err(PAIRING);
                }
                // Reserve the complete bounded read, including its oversize
                // sentinel, before any pairing bytes enter this allocation.
                let mut bytes = SecretData::new(Vec::with_capacity(MAX_PAIRING + 1));
                #[cfg(test)]
                let allocation = (bytes.0.capacity(), bytes.0.as_ptr() as usize);
                file.take((MAX_PAIRING + 1) as u64)
                    .read_to_end(&mut bytes.0)
                    .await
                    .map_err(|_| PAIRING)?;
                #[cfg(test)]
                LEGACY_READS.with(|reads| reads.borrow_mut().push((allocation.0,
                    bytes.0.capacity(), allocation.1 == bytes.0.as_ptr() as usize, bytes.0.len())));
                validate(&bytes.0)
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PairingWire {
    public_key: SecretData,
    private_key: SecretData,
    identifier: SecretString,
    alt_irk: Option<SecretData>,
}
fn validate(bytes: &[u8]) -> Result<PairingRecord, Failure> {
    #[cfg(test)] VALIDATIONS.with(|count| count.set(count.get() + 1));
    if bytes.is_empty() || bytes.len() > MAX_PAIRING {
        return Err(PAIRING);
    }
    // A typed flat record rejects duplicate keys and nested arrays/dictionaries
    // before building a recursive generic Value. The upstream parser alone
    // accepts unbounded identifiers and arbitrary alt_irk lengths.
    let mut value: PairingWire = plist::from_bytes(bytes).map_err(|_| PAIRING)?;
    if value.private_key.0.len() != 32 || value.public_key.0.len() != 32
        || value.identifier.0.is_empty() || value.identifier.0.len() > 128 || value.identifier.0.contains('\0') {
        return Err(PAIRING);
    }
    if value.alt_irk.as_ref().is_some_and(|value| value.0.len() != 16) {
        return Err(PAIRING);
    }
    let private: &[u8; 32] = value.private_key.0.as_slice().try_into().map_err(|_| PAIRING)?;
    let record = PairingRecord(RpPairingFile {
        e_private_key: private.into(),
        e_public_key: value.public_key.0.as_slice().try_into().map_err(|_| PAIRING)?,
        identifier: std::mem::take(&mut *value.identifier.0),
        alt_irk: value.alt_irk.as_mut().map(|value| std::mem::take(&mut *value.0)),
    });
    fn requires_zeroize_on_drop<T: ZeroizeOnDrop>(_: &T) {}
    requires_zeroize_on_drop(&record.e_private_key);
    if record.e_private_key.verifying_key().to_bytes() != record.e_public_key.to_bytes() {
        return Err(PAIRING);
    }
    Ok(record)
}

#[cfg(test)]
thread_local! {
    static CLEARS: std::cell::RefCell<Vec<(&'static str, bool)>> = const { std::cell::RefCell::new(Vec::new()) };
    static VALIDATIONS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static LEGACY_READS: std::cell::RefCell<Vec<(usize, usize, bool, usize)>> = const { std::cell::RefCell::new(Vec::new()) };
}
#[cfg(test)]
fn record_clear(kind: &'static str, cleared: bool) { CLEARS.with(|events| events.borrow_mut().push((kind, cleared))); }
#[cfg(test)]
pub(crate) fn take_clear_events() -> Vec<(&'static str, bool)> {
    CLEARS.with(|events| std::mem::take(&mut *events.borrow_mut()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes() -> Vec<u8> {
        RpPairingFile::generate("dsh-portable-test.invalid").to_bytes()
    }

    struct LegacyFixture(std::path::PathBuf);
    impl LegacyFixture {
        fn new(bytes: &[u8]) -> Self {
            use std::io::Write;
            let path = std::env::temp_dir().join(format!("dsh-pairing-capacity-{}.plist", uuid::Uuid::new_v4()));
            let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&path).unwrap();
            let fixture = Self(path);
            file.write_all(bytes).unwrap();
            fixture
        }

        async fn load(&self) -> Result<PairingRecord, Failure> {
            let input = PairingInput::LegacyFile(self.0.to_str().unwrap().into());
            tokio::time::timeout(std::time::Duration::from_secs(2), input.load())
                .await.expect("bounded synthetic regular-file read")
        }
    }
    impl Drop for LegacyFixture {
        fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); }
    }

    fn check_legacy_allocation(length: usize) {
        let reads = LEGACY_READS.with(|reads| std::mem::take(&mut *reads.borrow_mut()));
        assert_eq!(reads.len(), 1);
        let (before, after, same_pointer, used) = reads[0];
        assert!(before >= MAX_PAIRING + 1);
        assert_eq!(before, after);
        assert!(same_pointer, "the guarded destination must not reallocate after receiving pairing bytes");
        assert_eq!(used, length);
    }

    #[tokio::test]
    async fn w31_pairing_legacy_capacity_reuses_one_buffer() {
        let short = bytes();
        let value: plist::Value = plist::from_bytes(&short).unwrap();
        let mut maximum = Vec::new();
        plist::to_writer_xml(&mut maximum, &value).unwrap();
        maximum.resize(MAX_PAIRING, b' ');
        for source in [short, maximum] {
            let fixture = LegacyFixture::new(&source);
            take_clear_events();
            LEGACY_READS.with(|reads| reads.borrow_mut().clear());
            let record = fixture.load().await.unwrap();
            check_legacy_allocation(source.len());
            let events = take_clear_events();
            assert!(events.contains(&("data", true)));
            assert!(events.iter().all(|(_, cleared)| *cleared));
            drop(record);
            assert_eq!(take_clear_events(), vec![("record", true)]);
        }
    }

    #[tokio::test]
    async fn w31_pairing_legacy_capacity_rejects_and_clears() {
        let partial = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>private_key</key><data>AQIDBA==</data><key>unknown</key><true/></dict></plist>";
        for source in [Vec::new(), partial.to_vec()] {
            let fixture = LegacyFixture::new(&source);
            take_clear_events();
            LEGACY_READS.with(|reads| reads.borrow_mut().clear());
            assert!(fixture.load().await.is_err());
            check_legacy_allocation(source.len());
            let events = take_clear_events();
            assert!(events.contains(&("data", true)));
            assert!(events.iter().all(|(_, cleared)| *cleared));
        }
        let oversized = LegacyFixture::new(&vec![0; MAX_PAIRING + 1]);
        take_clear_events();
        LEGACY_READS.with(|reads| reads.borrow_mut().clear());
        VALIDATIONS.with(|count| count.set(0));
        assert!(oversized.load().await.is_err());
        assert!(LEGACY_READS.with(|reads| reads.borrow().is_empty()));
        assert_eq!(VALIDATIONS.with(|count| count.get()), 0);
        assert!(take_clear_events().is_empty());
    }

    fn changed(field: &str, value: plist::Value) -> Vec<u8> {
        let mut dictionary: plist::Dictionary = plist::from_bytes(&bytes()).unwrap();
        dictionary.insert(field.into(), value);
        let mut result = Vec::new();
        plist::to_writer_binary(&mut result, &dictionary).unwrap();
        result
    }

    #[tokio::test]
    async fn w31_pairing_bytes_borrow_ends_after_one_validation() {
        let generated = RpPairingFile::generate("w31-byte-fixture.invalid");
        let expected_public = generated.e_public_key.to_bytes();
        let mut source = generated.to_bytes();
        VALIDATIONS.with(|count| count.set(0));
        let input = PairingInput::from_bytes(&source).unwrap();
        assert_eq!(VALIDATIONS.with(|count| count.get()), 1);
        source.zeroize();
        drop(source);
        let record = input.load().await.unwrap();
        assert_eq!(VALIDATIONS.with(|count| count.get()), 1);
        assert_eq!(record.e_public_key.to_bytes(), expected_public);
        assert_eq!(record.e_private_key.verifying_key(), record.e_public_key);
        take_clear_events();
        drop(record);
        assert_eq!(take_clear_events(), vec![("record", true)]);
    }

    #[test]
    fn w31_pairing_bytes_boundaries_and_partial_errors_release_owned_fields() {
        assert!(PairingInput::from_bytes(&[]).is_none());
        assert!(PairingInput::from_bytes(&vec![0; MAX_PAIRING + 1]).is_none());
        take_clear_events();
        let malformed = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>private_key</key><data>AQIDBA==</data><key>unknown</key><true/></dict></plist>";
        assert!(PairingInput::from_bytes(malformed).is_none());
        let events = take_clear_events();
        assert!(events.contains(&("data", true)));
        assert!(events.iter().all(|(_, cleared)| *cleared));

        let value: plist::Value = plist::from_bytes(&bytes()).unwrap();
        let mut maximum = Vec::new();
        plist::to_writer_xml(&mut maximum, &value).unwrap();
        maximum.resize(MAX_PAIRING, b' ');
        assert!(PairingInput::from_bytes(&maximum).is_some());
        maximum.push(b' ');
        assert!(PairingInput::from_bytes(&maximum).is_none());
    }

    #[tokio::test]
    async fn memory_record_roundtrips_without_a_file() {
        let bytes = bytes();
        let input = PairingInput::parse(Some(STANDARD.encode(&bytes).into()), None).unwrap();
        let record = input.load().await.unwrap();
        assert_eq!(record.e_private_key.verifying_key(), record.e_public_key);
        assert!(PairingInput::parse(Some(STANDARD.encode(&bytes).into()), Some("/tmp/unused".into())).is_none());
    }

    #[test]
    fn malformed_or_inconsistent_pairing_is_rejected() {
        for (field, value) in [
            ("identifier", "".into()),
            ("identifier", "x".repeat(129).into()),
            ("identifier", "nul\0suffix".into()),
            ("alt_irk", plist::Value::Data(vec![0; 15])),
            ("alt_irk", plist::Value::Data(vec![0; 17])),
            ("private_key", plist::Value::Data(vec![0; 31])),
            ("private_key", plist::Value::Data(vec![1; 32])),
            ("HostID", "not-a-remote-pairing-record".into()),
        ] {
            assert!(PairingInput::parse(Some(STANDARD.encode(changed(field, value)).into()), None).is_none(), "{field}");
        }
        assert!(validate(&vec![0; MAX_PAIRING + 1]).is_err());
        assert!(PairingInput::parse(Some("A".repeat(MAX_PAIRING_BASE64 + 1).into()), None).is_none());
        let encoded = STANDARD.encode(bytes());
        assert!(PairingInput::parse(Some((encoded + "\n").into()), None).is_none());
        assert!(PairingInput::parse(None, Some("relative.plist".into())).is_none());
        assert!(PairingInput::parse(None, None).is_none());
    }

    #[test]
    fn duplicate_and_deeply_nested_plist_fields_are_rejected_before_generic_parse() {
        let value: plist::Value = plist::from_bytes(&bytes()).unwrap();
        let mut xml = Vec::new(); plist::to_writer_xml(&mut xml, &value).unwrap();
        let xml = String::from_utf8(xml).unwrap();
        let duplicate = xml.replace("</dict>", "<key>identifier</key><string>duplicate</string></dict>");
        assert!(validate(duplicate.as_bytes()).is_err());
        let nested = format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>private_key</key>{}<data></data>{}</dict></plist>",
            "<array>".repeat(4000), "</array>".repeat(4000));
        assert!(nested.len() < MAX_PAIRING);
        assert!(validate(nested.as_bytes()).is_err());
    }

    #[tokio::test]
    async fn w31_pairing_record_is_validated_once_and_consumed() {
        VALIDATIONS.with(|count| count.set(0));
        let input = PairingInput::parse(Some(STANDARD.encode(bytes()).into()), None).unwrap();
        assert_eq!(VALIDATIONS.with(|count| count.get()), 1);
        let record = input.load().await.unwrap();
        assert_eq!(VALIDATIONS.with(|count| count.get()), 1);
        assert_eq!(record.e_private_key.verifying_key(), record.e_public_key);
        take_clear_events();
        drop(record);
        assert_eq!(take_clear_events(), vec![("record", true)]);
    }

    #[test]
    fn w31_pairing_partial_base64_error_clears_owned_buffers() {
        take_clear_events();
        let malformed = STANDARD.encode([0u8; 24]) + "!";
        assert!(PairingInput::parse(Some(malformed.into()), None).is_none());
        let events = take_clear_events();
        assert!(events.contains(&("string", true)));
        assert!(events.contains(&("data", true)));
        assert!(events.iter().all(|(_, cleared)| *cleared));
    }

    #[test]
    fn w31_pairing_partial_plist_error_clears_completed_secret_fields() {
        for suffix in [
            "<key>public_key</key><string>wrong-type</string>",
            "<key>private_key</key><data>AA==</data>",
            "<key>unknown</key><string>reject</string>",
        ] {
            take_clear_events();
            let xml = format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>private_key</key><data>AQIDBA==</data>{suffix}</dict></plist>");
            assert!(validate(xml.as_bytes()).is_err());
            let events = take_clear_events();
            assert!(events.contains(&("data", true)), "{suffix}");
            assert!(events.iter().all(|(_, cleared)| *cleared));
        }
    }

    #[test]
    fn w31_pairing_mismatch_and_conflicting_inputs_release_secrets() {
        take_clear_events();
        let malformed = changed("private_key", plist::Value::Data(vec![1; 32]));
        assert!(PairingInput::parse(Some(STANDARD.encode(malformed).into()), None).is_none());
        let events = take_clear_events();
        assert!(events.contains(&("record", true)));
        assert!(events.iter().all(|(_, cleared)| *cleared));
        assert!(PairingInput::parse(Some(STANDARD.encode(bytes()).into()), Some("/unused".into())).is_none());
        assert_eq!(take_clear_events(), vec![("string", true)]);
    }

    #[tokio::test(start_paused = true)]
    async fn w31_pairing_cancelled_future_releases_its_only_record() {
        let mut slot = Some(PairingInput::parse(Some(STANDARD.encode(bytes()).into()), None).unwrap());
        let input = slot.take().unwrap();
        assert!(slot.is_none());
        take_clear_events();
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), async move {
            let _record = input.load().await.unwrap();
            std::future::pending::<()>().await;
        }).await;
        assert!(result.is_err());
        assert_eq!(take_clear_events(), vec![("record", true)]);
    }

}
