//! Rust unwind containment for the synchronous admission paths.
//! This does not make invalid foreign pointers or unwinding callbacks safe.

#[cfg(not(panic = "unwind"))]
compile_error!("phone-self-runner requires panic=unwind for its C admission boundary");

pub(crate) fn catch<T>(body: impl FnOnce() -> T) -> Result<T, ()> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)) {
        Ok(value) => Ok(value),
        Err(payload) => {
            // A user-defined panic payload may itself panic when dropped. Drop
            // it under a second catch; do not unwind across C while discarding
            // that second payload. Ordinary request/config values still drop.
            if let Err(second) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(payload))) {
                std::mem::forget(second);
            }
            Err(())
        }
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use std::cell::RefCell;
    use std::sync::{Condvar, Mutex};
    use std::time::Duration;

    type Hook = Box<dyn FnMut(&'static str)>;
    thread_local! { static HOOK: RefCell<Option<Hook>> = const { RefCell::new(None) }; }
    static GATES: (Mutex<Vec<(u64, bool)>>, Condvar) = (Mutex::new(Vec::new()), Condvar::new());

    pub(crate) struct HookGuard;
    impl Drop for HookGuard {
        fn drop(&mut self) { HOOK.with(|slot| { slot.borrow_mut().take(); }); }
    }
    pub(crate) fn hook(body: impl FnMut(&'static str) + 'static) -> HookGuard {
        HOOK.with(|slot| {
            assert!(slot.borrow().is_none());
            *slot.borrow_mut() = Some(Box::new(body));
        });
        HookGuard
    }
    pub(crate) fn at(point: &'static str) {
        HOOK.with(|slot| {
            let body = slot.borrow_mut().take();
            if let Some(mut body) = body {
                body(point);
                *slot.borrow_mut() = Some(body);
            }
        });
    }
    pub(crate) fn gate(handle: u64, admitted: bool) {
        GATES.0.lock().unwrap().push((handle, admitted));
        GATES.1.notify_all();
    }
    pub(crate) fn clear_gates() { GATES.0.lock().unwrap().clear(); }
    pub(crate) fn wait_gate() -> (u64, bool) {
        let records = GATES.0.lock().unwrap();
        let (mut records, timeout) = GATES.1.wait_timeout_while(records, Duration::from_secs(5), |v| v.is_empty()).unwrap();
        assert!(!timeout.timed_out());
        records.remove(0)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn w31_ffi_unwind_and_panicking_payload_drop_are_contained() {
        assert!(cfg!(panic = "unwind"));
        struct PanickingDrop;
        impl Drop for PanickingDrop {
            fn drop(&mut self) { panic!("synthetic panic payload drop"); }
        }
        assert!(super::catch(|| std::panic::panic_any(PanickingDrop)).is_err());
        assert_eq!(super::catch(|| 17), Ok(17));
    }
}
