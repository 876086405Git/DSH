//! Explicitly authorized DDI preparation over the existing RSD tunnel.
//! Portable validation is tested; mounting and Apple TSS are NOT device-verified.
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use idevice::RsdService;
use idevice::cryptexd::{Cryptex1Assets, CryptexInstallRequest, CryptexdClient};
use idevice::lockdown::LockdownClient;
use idevice::mobile_image_mounter::ImageMounter;
use idevice::ReadWrite;
use serde::Deserialize;
use sha2::{Digest, Sha256, Sha384};

use crate::{DDI, Failure, Tunnel};

pub(crate) const CATALOG_ID: &str = "ddi-e2aaeac89ca8fa56c2fa1f144d182994e07a525b-v1";
const INTEGRITY: Failure = Failure("ERR_PHONE_DDI_INTEGRITY");
const UNSUPPORTED: Failure = Failure("ERR_PHONE_DDI_UNSUPPORTED_DEVICE");
const PERSONALIZATION: Failure = Failure("ERR_PHONE_DDI_PERSONALIZATION");
const MOUNT: Failure = Failure("ERR_PHONE_DDI_MOUNT");
const ALREADY_PRESENT: Failure = Failure("ERR_PHONE_DDI_ALREADY_PRESENT");
const SERVICES: Failure = Failure("ERR_PHONE_CORE_SERVICE_UNAVAILABLE");
const CRYPTEX_SERVICE: &str = "com.apple.security.cryptexd.remote";

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DdiCache {
    pub(crate) catalog_id: String,
    pub(crate) directory: String,
    pub(crate) personalized: Option<PersonalizedHashes>,
    pub(crate) cryptex: Option<CryptexHashes>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PersonalizedHashes {
    manifest: String,
    image: String,
    trust_cache: String,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CryptexHashes {
    manifest: String,
    image: String,
    trust_cache: String,
    info: String,
    root_hash: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Variant { Personalized, Cryptex }
impl Variant {
    pub(crate) fn name(self) -> &'static str {
        match self { Self::Personalized => "personalized", Self::Cryptex => "cryptex" }
    }
    fn missing(self) -> Failure {
        match self {
            Self::Personalized => Failure("ERR_PHONE_DDI_CACHE_REQUIRED:personalized"),
            Self::Cryptex => Failure("ERR_PHONE_DDI_CACHE_REQUIRED:cryptex"),
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Progress {
    pub(crate) stage: &'static str,
    pub(crate) variant: Option<Variant>,
    pub(crate) completed: Option<usize>,
    pub(crate) total: Option<usize>,
}
impl Progress {
    fn stage(stage: &'static str, variant: Variant) -> Self { Self { stage, variant: Some(variant), completed: None, total: None } }
}

impl DdiCache {
    pub(crate) fn valid(&self) -> bool {
        self.catalog_id == CATALOG_ID && Path::new(&self.directory).is_absolute()
            && self.directory.len() <= 4096 && !self.directory.contains('\0')
            && self.personalized.as_ref().is_none_or(|pins| {
                pins.manifest == expected(Variant::Personalized, "BuildManifest.plist")
                    && pins.image == expected(Variant::Personalized, "Image.dmg")
                    && pins.trust_cache == expected(Variant::Personalized, "Image.dmg.trustcache")
            })
            && self.cryptex.as_ref().is_none_or(|pins| {
                pins.manifest == expected(Variant::Cryptex, "BuildManifest.plist")
                    && pins.image == expected(Variant::Cryptex, "Image.dmg")
                    && pins.trust_cache == expected(Variant::Cryptex, "Image.dmg.trustcache")
                    && pins.info == expected(Variant::Cryptex, "Image.dmg.cryptex_info")
                    && pins.root_hash == expected(Variant::Cryptex, "Image.dmg.root_hash")
            })
    }
}

// These are byte hashes independently verified against the pinned mirror's Git
// blobs. The mirror redistributes Apple's DDI; it is not an Apple download host.
fn expected(variant: Variant, name: &str) -> &'static str {
    match (variant, name) {
        (Variant::Personalized, "BuildManifest.plist") => "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54",
        (Variant::Personalized, "Image.dmg") => "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca",
        (Variant::Personalized, "Image.dmg.trustcache") => "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c",
        (Variant::Cryptex, "BuildManifest.plist") => "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012",
        (Variant::Cryptex, "Image.dmg") => "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176",
        (Variant::Cryptex, "Image.dmg.trustcache") => "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0",
        (Variant::Cryptex, "Image.dmg.cryptex_info") => "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c",
        (Variant::Cryptex, "Image.dmg.root_hash") => "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302",
        _ => "",
    }
}

// The immutable catalog fixes lengths as well as hashes. Reject an unexpected
// length before allocating or reading; a broad format maximum is not needed.
fn expected_bytes(variant: Variant, name: &str) -> usize {
    match (variant, name) {
        (Variant::Personalized, "BuildManifest.plist") => 801_505,
        (Variant::Personalized, "Image.dmg") => 15_733_248,
        (Variant::Personalized, "Image.dmg.trustcache") => 1895,
        (Variant::Cryptex, "BuildManifest.plist") => 804_946,
        (Variant::Cryptex, "Image.dmg") => 15_895_040,
        (Variant::Cryptex, "Image.dmg.trustcache") => 1895,
        (Variant::Cryptex, "Image.dmg.cryptex_info") => 430,
        (Variant::Cryptex, "Image.dmg.root_hash") => 229,
        _ => 0,
    }
}

fn open_at(directory: &File, name: &str, is_directory: bool) -> Result<File, Failure> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') { return Err(INTEGRITY); }
    let name = CString::new(name).map_err(|_| INTEGRITY)?;
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK
        | if is_directory { libc::O_DIRECTORY } else { 0 };
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 { return Err(INTEGRITY); }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn read_checked(directory: &File, name: &str, expected_len: usize, hash: &str) -> Result<Vec<u8>, Failure> {
    if hash.len() != 64 || expected_len == 0 { return Err(INTEGRITY); }
    let file = open_at(directory, name, false)?;
    let metadata = file.metadata().map_err(|_| INTEGRITY)?;
    if !metadata.is_file() || metadata.len() != expected_len as u64 {
        return Err(INTEGRITY);
    }
    let mut bytes = Vec::new();
    file.take((expected_len + 1) as u64).read_to_end(&mut bytes).map_err(|_| INTEGRITY)?;
    if bytes.len() != expected_len || format!("{:x}", Sha256::digest(&bytes)) != hash {
        return Err(INTEGRITY);
    }
    Ok(bytes)
}

struct Assets {
    manifest: plist::Dictionary,
    image: Vec<u8>,
    trust_cache: Vec<u8>,
    info: Vec<u8>,
    root_hash: Vec<u8>,
}
fn load(cache: Option<&DdiCache>, variant: Variant) -> Result<Assets, Failure> {
    let cache = cache.ok_or_else(|| variant.missing())?;
    if !cache.valid() { return Err(INTEGRITY); }
    match variant {
        Variant::Personalized if cache.personalized.is_none() => return Err(variant.missing()),
        Variant::Cryptex if cache.cryptex.is_none() => return Err(variant.missing()),
        _ => {}
    }
    let root = OpenOptions::new().read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&cache.directory).map_err(|_| variant.missing())?;
    let directory = open_at(&root, variant.name(), true)?;
    let read = |name: &str| read_checked(&directory, name, expected_bytes(variant, name), expected(variant, name));
    let manifest = read("BuildManifest.plist")?;
    let manifest = plist::from_bytes(&manifest).map_err(|_| INTEGRITY)?;
    let image = read("Image.dmg")?;
    let trust_cache = read("Image.dmg.trustcache")?;
    let (info, root_hash) = if variant == Variant::Cryptex {
        (read("Image.dmg.cryptex_info")?, read("Image.dmg.root_hash")?)
    } else { (Vec::new(), Vec::new()) };
    Ok(Assets { manifest, image, trust_cache, info, root_hash })
}

fn major_version(value: &str) -> Option<u32> {
    let parts: Vec<_> = value.split('.').collect();
    if parts.is_empty() || parts.len() > 3 || parts.iter().any(|s| s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit())) {
        return None;
    }
    parts[0].parse().ok().filter(|major| *major >= 17 && *major < 100)
}
fn choose(major: u32, features: Option<&[String]>) -> Variant {
    // pymobiledevice3 776d601's conservative auto policy is 27.0, not the
    // separate 26.4 minimum discussed in its documentation. Capability alone
    // does not establish that an older daemon can mount the imported cryptex.
    if major >= 27 && features.is_some_and(|list| list.iter().any(|s| s == "CryptexInstall")) {
        Variant::Cryptex
    } else {
        Variant::Personalized
    }
}

async fn device_info(tunnel: &mut Tunnel) -> Result<(u32, u64), Failure> {
    let mut client = LockdownClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| MOUNT)?;
    let version = client.get_value(Some("ProductVersion"), None).await.map_err(|_| MOUNT)?;
    let major = version.as_string().and_then(major_version).ok_or(UNSUPPORTED)?;
    let identifier = client.get_value(Some("UniqueChipID"), None).await.map_err(|_| MOUNT)?;
    let identifier = identifier.as_unsigned_integer().ok_or(UNSUPPORTED)?;
    Ok((major, identifier))
}
async fn mounter(tunnel: &mut Tunnel) -> Result<(ImageMounter, u32, u64), Failure> {
    let client = ImageMounter::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| MOUNT)?;
    // The pinned ImageMounter documents a required lockdown query AFTER opening
    // each mounter connection, including its query-manifest reconnection path.
    let (major, ecid) = device_info(tunnel).await?;
    Ok((client, major, ecid))
}
async fn cryptex_client(tunnel: &mut Tunnel) -> Result<CryptexdClient<Box<dyn ReadWrite>>, Failure> {
    CryptexdClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| MOUNT)
}

pub(crate) async fn ensure(
    tunnel: &mut Tunnel, cache: Option<&DdiCache>, allow_mount: bool,
    required: &[&str], progress: impl Fn(Progress) + Copy,
    submitted: &AtomicBool,
) -> Result<bool, Failure> {
    if required.iter().all(|name| tunnel.handshake.services.contains_key(*name)) { return Ok(false); }
    // A status/check call never acquires mounting authority merely because the
    // bytes happen to exist. Only the foreground setup action sets this flag.
    if !allow_mount { return Err(DDI); }
    let has_mounter = tunnel.handshake.services.contains_key(ImageMounter::rsd_service_name().as_ref());
    let mut existing_mounter = None;
    let (major, ecid) = if has_mounter {
        let (mut client, major, ecid) = mounter(tunnel).await?;
        if !client.copy_devices().await.map_err(|_| MOUNT)?.is_empty() {
            return Err(ALREADY_PRESENT);
        }
        existing_mounter = Some(client);
        (major, ecid)
    } else { device_info(tunnel).await? };
    let variant = choose(major, tunnel.handshake.services.get(CRYPTEX_SERVICE).and_then(|s| s.features.as_deref()));
    if variant == Variant::Cryptex {
        if idevice::cryptexd::installed_ddi(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| MOUNT)?.is_some() {
            return Err(ALREADY_PRESENT);
        }
    } else if !has_mounter { return Err(UNSUPPORTED); }
    progress(Progress::stage("verifyingAssets", variant));
    let assets = load(cache, variant)?;
    progress(Progress::stage("personalizing", variant));
    match variant {
        Variant::Personalized => {
            let mut client = existing_mounter.ok_or(MOUNT)?;
            if !client.query_developer_mode_status().await.map_err(|_| MOUNT)? { return Err(DDI); }
            let identifiers = client.query_personalization_identifiers(None).await.map_err(|_| PERSONALIZATION)?;
            let board = identifiers.get("BoardId").and_then(plist::Value::as_unsigned_integer).ok_or(UNSUPPORTED)?;
            let chip = identifiers.get("ChipID").and_then(plist::Value::as_unsigned_integer).ok_or(UNSUPPORTED)?;
            idevice::tss::select_build_identity(&assets.manifest, board, chip, None).map_err(|_| UNSUPPORTED)?;
            let signature = match client.query_personalization_manifest("DeveloperDiskImage", Sha384::digest(&assets.image).to_vec()).await {
                Ok(signature) => signature,
                Err(_) => {
                    // This request closes its service on a miss. Reconnect over
                    // the SAME tunnel and do the documented lockdown query.
                    client = mounter(tunnel).await?.0;
                    client.get_manifest_from_tss(&assets.manifest, ecid).await.map_err(|_| PERSONALIZATION)?
                }
            };
            progress(Progress::stage("uploading", variant));
            submitted.store(true, Ordering::Release);
            client.upload_image_with_progress("Personalized", &assets.image, signature.clone(),
                |((completed, total), ())| { progress(Progress { stage: "uploading", variant: Some(variant), completed: Some(completed), total: Some(total) }); std::future::ready(()) }, ()
            ).await.map_err(|_| MOUNT)?;
            progress(Progress::stage("mounting", variant));
            client.mount_image("Personalized", signature, Some(assets.trust_cache), None).await.map_err(|_| MOUNT)?;
        }
        Variant::Cryptex => {
            let identity = idevice::tss::select_cryptex_build_identity(&assets.manifest).map_err(|_| UNSUPPORTED)?.clone();
            let assets = Cryptex1Assets::from_parts(assets.image, assets.trust_cache, assets.info, assets.root_hash, identity);
            let chip = cryptex_client(tunnel).await?.read_personalization_identifiers().await.map_err(|_| PERSONALIZATION)?;
            let nonce = cryptex_client(tunnel).await?.cryptex_nonce(assets.nonce_domain().map_err(|_| INTEGRITY)?).await.map_err(|_| PERSONALIZATION)?;
            let mut request = idevice::tss::TSSRequest::new();
            request.add_cryptex1_tags(&assets.build_identity, &chip, &nonce).map_err(|_| PERSONALIZATION)?;
            let response = request.send().await.map_err(|_| PERSONALIZATION)?.into_dictionary().ok_or(PERSONALIZATION)?;
            let ticket = response.get("Cryptex1,Ticket").or_else(|| response.get("ApImg4Ticket")).and_then(plist::Value::as_data).ok_or(PERSONALIZATION)?.to_vec();
            let properties = assets.cryptex1_properties().map_err(|_| INTEGRITY)?;
            progress(Progress::stage("mounting", variant));
            let client = cryptex_client(tunnel).await?;
            submitted.store(true, Ordering::Release);
            // This upstream routine has no byte-progress callback. Report the
            // real indeterminate stage, not an invented percentage.
            client.install(CryptexInstallRequest::new(assets.image, assets.trustcache, ticket, assets.info, assets.volumehash, properties)).await.map_err(|_| MOUNT)?;
            if idevice::cryptexd::installed_ddi(&mut tunnel.adapter, &mut tunnel.handshake).await.map_err(|_| MOUNT)?.is_none() { return Err(MOUNT); }
        }
    }
    progress(Progress::stage("refreshingServices", variant));
    tunnel.refresh_services().await?;
    if !required.iter().all(|name| tunnel.handshake.services.contains_key(*name)) { return Err(SERVICES); }
    submitted.store(false, Ordering::Release);
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn selection_needs_version_and_capability() {
        let features = vec!["CryptexInstall".into()];
        assert_eq!(choose(17, Some(&features)), Variant::Personalized);
        assert_eq!(choose(26, Some(&features)), Variant::Personalized);
        assert_eq!(choose(27, Some(&features)), Variant::Cryptex);
        assert_eq!(choose(27, None), Variant::Personalized);
        assert_eq!(choose(27, Some(&[])), Variant::Personalized);
        for value in ["", "16.9", "27.beta", "27.0.", "27.0.0.1", "100.0"] { assert!(major_version(value).is_none()); }
        assert_eq!(major_version("26.4"), Some(26));
    }

    #[test]
    fn directory_capability_rejects_links_and_changed_bytes() {
        let base = std::env::temp_dir().join(format!("dsh-ddi-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&base).unwrap();
        std::fs::write(base.join("payload"), b"verified bytes").unwrap();
        symlink("payload", base.join("alias")).unwrap();
        let pipe = CString::new(base.join("pipe").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(pipe.as_ptr(), 0o600) }, 0);
        let directory = File::open(&base).unwrap();
        let expected = format!("{:x}", Sha256::digest(b"verified bytes"));
        assert_eq!(read_checked(&directory, "payload", 14, &expected).unwrap(), b"verified bytes");
        assert!(read_checked(&directory, "alias", 14, &expected).is_err());
        assert!(read_checked(&directory, "pipe", 14, &expected).is_err());
        assert!(read_checked(&directory, "payload", 64, &expected).is_err());
        assert!(read_checked(&directory, "payload", 4, &expected).is_err());
        assert!(read_checked(&directory, ".", 14, &expected).is_err());
        std::fs::write(base.join("payload"), b"modified bytes").unwrap();
        assert!(read_checked(&directory, "payload", 14, &expected).is_err());
        // An invalid cache with an otherwise acceptable format-scale size is
        // rejected at metadata, before allocating a payload-sized buffer.
        File::create(base.join("payload")).unwrap().set_len(256 * 1024 * 1024).unwrap();
        assert!(read_checked(&directory, "payload", 14, &expected).is_err());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn only_the_fixed_catalog_is_accepted() {
        let mut value = serde_json::json!({"catalogId":CATALOG_ID,"directory":"/private/cache","personalized":{
            "manifest":expected(Variant::Personalized,"BuildManifest.plist"),
            "image":expected(Variant::Personalized,"Image.dmg"),
            "trustCache":expected(Variant::Personalized,"Image.dmg.trustcache")}});
        assert!(serde_json::from_value::<DdiCache>(value.clone()).unwrap().valid());
        value["personalized"]["image"] = "0".repeat(64).into();
        assert!(!serde_json::from_value::<DdiCache>(value.clone()).unwrap().valid());
        value["url"] = "https://untrusted.invalid/payload".into();
        assert!(serde_json::from_value::<DdiCache>(value).is_err());
    }

    #[test]
    #[ignore = "requires the exact verified catalog fixture, never mounts or contacts a device"]
    fn real_pinned_catalog_files_pass_independent_native_validation() {
        let directory = std::env::var("DSH_TEST_DDI_CACHE").expect("set DSH_TEST_DDI_CACHE to the fixed-layout fixture");
        let cache = DdiCache { catalog_id: CATALOG_ID.into(), directory,
            personalized: Some(PersonalizedHashes {
                manifest: expected(Variant::Personalized,"BuildManifest.plist").into(),
                image: expected(Variant::Personalized,"Image.dmg").into(),
                trust_cache: expected(Variant::Personalized,"Image.dmg.trustcache").into() }),
            cryptex: Some(CryptexHashes {
                manifest: expected(Variant::Cryptex,"BuildManifest.plist").into(),
                image: expected(Variant::Cryptex,"Image.dmg").into(),
                trust_cache: expected(Variant::Cryptex,"Image.dmg.trustcache").into(),
                info: expected(Variant::Cryptex,"Image.dmg.cryptex_info").into(),
                root_hash: expected(Variant::Cryptex,"Image.dmg.root_hash").into() }) };
        let personalized = load(Some(&cache), Variant::Personalized).unwrap();
        assert_eq!(personalized.image.len(), 15_733_248);
        assert_eq!(personalized.trust_cache.len(), 1895);
        assert!(personalized.manifest.get("BuildIdentities").and_then(plist::Value::as_array).is_some_and(|a| !a.is_empty()));
        let cryptex = load(Some(&cache), Variant::Cryptex).unwrap();
        assert_eq!(cryptex.image.len(), 15_895_040);
        assert_eq!(cryptex.trust_cache.len(), 1895);
        assert_eq!(cryptex.info.len(), 430); assert_eq!(cryptex.root_hash.len(), 229);
        assert!(idevice::tss::select_cryptex_build_identity(&cryptex.manifest).is_ok());
    }
}
