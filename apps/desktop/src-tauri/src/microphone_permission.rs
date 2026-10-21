#[cfg(any(target_os = "macos", test))]
use std::sync::mpsc;

#[cfg(any(target_os = "macos", test))]
fn resolve_permission(
    status: isize,
    reply: mpsc::SyncSender<Result<(), String>>,
    request: impl FnOnce(mpsc::SyncSender<Result<(), String>>),
) {
    let result = match status {
        0 => return request(reply),
        1 => Err("이 Mac에서 마이크 사용이 제한되어 있습니다.".into()),
        2 => Err("시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Nero를 허용해 주세요.".into()),
        3 => Ok(()),
        _ => Err("마이크 권한을 확인하지 못했습니다. 앱을 다시 실행해 주세요.".into()),
    };
    let _ = reply.send(result);
}

#[cfg(target_os = "macos")]
pub async fn ensure_authorized(app: &tauri::AppHandle) -> Result<(), String> {
    let (reply, response) = mpsc::sync_channel(1);
    app.run_on_main_thread(move || native::authorize(reply))
        .map_err(|_| "마이크 권한을 요청하지 못했습니다.".to_string())?;
    tauri::async_runtime::spawn_blocking(move || response.recv())
        .await
        .map_err(|_| "마이크 권한 확인이 중단되었습니다.".to_string())?
        .map_err(|_| "마이크 권한 확인이 중단되었습니다.".to_string())?
}

#[cfg(not(target_os = "macos"))]
pub async fn ensure_authorized(_app: &tauri::AppHandle) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use block2::RcBlock;
    use objc2::runtime::Bool;
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {
        static AVMediaTypeAudio: &'static NSString;
    }

    pub fn authorize(reply: mpsc::SyncSender<Result<(), String>>) {
        // Permission must settle before CPAL creates its AudioUnit and device listeners.
        let status: isize = unsafe {
            msg_send![class!(AVCaptureDevice), authorizationStatusForMediaType: AVMediaTypeAudio]
        };
        resolve_permission(status, reply, |reply| {
            let completion = RcBlock::new(move |granted: Bool| {
                let result = if granted.as_bool() {
                    Ok(())
                } else {
                    Err("마이크 사용이 허용되지 않아 녹음을 시작하지 않았습니다.".into())
                };
                let _ = reply.send(result);
            });
            unsafe {
                let _: () = msg_send![class!(AVCaptureDevice),
                    requestAccessForMediaType: AVMediaTypeAudio,
                    completionHandler: &*completion
                ];
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::TryRecvError;

    #[test]
    fn pending_first_use_does_not_complete_before_user_answers() {
        let (reply, response) = mpsc::sync_channel(1);
        let mut completion = None;
        resolve_permission(0, reply, |reply| completion = Some(reply));
        assert_eq!(response.try_recv(), Err(TryRecvError::Empty));
        let completion = completion.unwrap();
        std::thread::spawn(move || completion.send(Ok(())).unwrap())
            .join()
            .unwrap();
        assert_eq!(response.recv().unwrap(), Ok(()));
    }

    #[test]
    fn denied_pending_reply_cannot_start_capture() {
        let (reply, response) = mpsc::sync_channel(1);
        resolve_permission(0, reply, |reply| {
            std::thread::spawn(move || reply.send(Err("denied".into())).unwrap());
        });
        assert_eq!(response.recv().unwrap(), Err("denied".into()));
    }

    #[test]
    fn known_decisions_never_request_permission_again() {
        for (status, allowed) in [(1, false), (2, false), (3, true), (99, false)] {
            let (reply, response) = mpsc::sync_channel(1);
            resolve_permission(status, reply, |_| panic!("must not request again"));
            assert_eq!(response.recv().unwrap().is_ok(), allowed);
        }
    }
}
