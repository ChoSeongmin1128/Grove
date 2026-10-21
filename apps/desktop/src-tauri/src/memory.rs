use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MemoryState {
    Normal,
    Warning,
    Critical,
    Unknown,
}

pub struct MemoryMonitor {
    #[cfg(windows)]
    handle: isize,
}

impl MemoryMonitor {
    pub fn new() -> Self {
        Self {
            #[cfg(windows)]
            handle: unsafe { windows::CreateMemoryResourceNotification(0) } as isize,
        }
    }

    pub fn sample(&self) -> MemoryState {
        #[cfg(target_os = "macos")]
        {
            use std::ffi::{c_char, c_int, c_void};
            extern "C" {
                fn sysctlbyname(
                    name: *const c_char,
                    old: *mut c_void,
                    old_len: *mut usize,
                    new: *mut c_void,
                    new_len: usize,
                ) -> c_int;
            }
            let mut level: c_int = 0;
            let mut size = std::mem::size_of::<c_int>();
            let status = unsafe {
                sysctlbyname(
                    b"kern.memorystatus_vm_pressure_level\0".as_ptr().cast(),
                    (&mut level as *mut c_int).cast(),
                    &mut size,
                    std::ptr::null_mut(),
                    0,
                )
            };
            // This macOS observation is best-effort and never gates a task.
            macos_state((status == 0).then_some(level), size)
        }
        #[cfg(windows)]
        {
            if self.handle == 0 {
                return MemoryState::Unknown;
            }
            let mut low = 0;
            let result = unsafe {
                windows::QueryMemoryResourceNotification(
                    self.handle as *mut std::ffi::c_void,
                    &mut low,
                )
            };
            windows_state((result != 0).then_some(low != 0))
        }
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            MemoryState::Unknown
        }
    }
}

#[cfg(windows)]
impl Drop for MemoryMonitor {
    fn drop(&mut self) {
        if self.handle != 0 {
            unsafe { windows::CloseHandle(self.handle as *mut std::ffi::c_void) };
        }
    }
}

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    extern "system" {
        pub fn CreateMemoryResourceNotification(kind: i32) -> *mut c_void;
        pub fn QueryMemoryResourceNotification(handle: *mut c_void, low: *mut i32) -> i32;
        pub fn CloseHandle(handle: *mut c_void) -> i32;
    }
}

#[cfg(any(target_os = "macos", test))]
fn macos_state(level: Option<i32>, bytes: usize) -> MemoryState {
    if bytes != std::mem::size_of::<i32>() {
        return MemoryState::Unknown;
    }
    match level {
        Some(1) => MemoryState::Normal,
        Some(2) => MemoryState::Warning,
        Some(4) => MemoryState::Critical,
        _ => MemoryState::Unknown,
    }
}

#[cfg(any(windows, test))]
fn windows_state(low: Option<bool>) -> MemoryState {
    match low {
        Some(true) => MemoryState::Warning,
        Some(false) => MemoryState::Normal,
        None => MemoryState::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_observations_distinguish_pressure_levels_from_unknown_results() {
        let bytes = std::mem::size_of::<i32>();
        assert_eq!(macos_state(Some(1), bytes), MemoryState::Normal);
        assert_eq!(macos_state(Some(2), bytes), MemoryState::Warning);
        assert_eq!(macos_state(Some(4), bytes), MemoryState::Critical);
        for level in [None, Some(0), Some(3), Some(5), Some(-1)] {
            assert_eq!(macos_state(level, bytes), MemoryState::Unknown);
        }
        assert_eq!(macos_state(Some(1), bytes - 1), MemoryState::Unknown);
        assert_eq!(macos_state(Some(2), bytes + 1), MemoryState::Unknown);
    }

    #[test]
    fn windows_notification_failure_is_not_a_low_memory_signal() {
        assert_eq!(windows_state(Some(false)), MemoryState::Normal);
        assert_eq!(windows_state(Some(true)), MemoryState::Warning);
        assert_eq!(windows_state(None), MemoryState::Unknown);
    }

    #[test]
    fn memory_states_use_stable_camel_case_wire_values() {
        for (state, expected) in [
            (MemoryState::Normal, "\"normal\""),
            (MemoryState::Warning, "\"warning\""),
            (MemoryState::Critical, "\"critical\""),
            (MemoryState::Unknown, "\"unknown\""),
        ] {
            assert_eq!(serde_json::to_string(&state).unwrap(), expected);
        }
    }
}
