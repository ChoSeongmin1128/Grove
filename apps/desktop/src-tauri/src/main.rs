#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod processing;
use grove_core::{CoreHandle, Device, Meeting, Snapshot, Transcript, TranscriptVersion};
use processing::{Processing, Progress};
use serde::Serialize;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_dialog::DialogExt;

struct DesktopState {
    core: CoreHandle,
    quitting: Arc<AtomicBool>,
    polling: Arc<AtomicBool>,
    processing: Arc<Processing>,
}

fn require_main(window: &WebviewWindow) -> Result<(), String> {
    if window.label() == "main" {
        Ok(())
    } else {
        Err("본창에서 실행해 주세요.".into())
    }
}

fn require_local_window(window: &WebviewWindow) -> Result<(), String> {
    if matches!(window.label(), "main" | "recorder") {
        Ok(())
    } else {
        Err("허용되지 않은 창입니다.".into())
    }
}

async fn on_core<T: Send + 'static>(
    core: CoreHandle,
    action: impl FnOnce(CoreHandle) -> Result<T, grove_core::CoreError> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || action(core))
        .await
        .map_err(|_| "작업을 완료하지 못했습니다. 다시 시도해 주세요.".to_string())?
        .map_err(|error| error.to_string())
}

fn publish(app: &tauri::AppHandle, snapshot: &Snapshot) {
    let _ = app.emit("grove://snapshot", snapshot);
}

fn show_main(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn show_recorder_window(app: &tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("recorder") {
        return window
            .show()
            .map_err(|_| "녹음 제어창을 열지 못했습니다.".into());
    }
    WebviewWindowBuilder::new(app, "recorder", WebviewUrl::App("recorder.html".into()))
        .title("Grove")
        .inner_size(236.0, 44.0)
        .resizable(false)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .build()
        .map(|_| ())
        .map_err(|_| "녹음 제어창을 열지 못했습니다.".into())
}

fn active_session(snapshot: &Snapshot) -> Option<&str> {
    snapshot
        .session
        .as_ref()
        .filter(|session| {
            matches!(
                session.state,
                grove_core::SessionState::Recording | grove_core::SessionState::Paused
            )
        })
        .map(|session| session.id.as_str())
}

#[tauri::command]
async fn read_snapshot(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
) -> Result<Snapshot, String> {
    require_local_window(&window)?;
    on_core(state.core.clone(), |core| core.snapshot()).await
}

#[tauri::command]
async fn create_meeting(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    title: String,
    notes: String,
) -> Result<Meeting, String> {
    require_main(&window)?;
    on_core(state.core.clone(), move |core| {
        core.create_meeting(&title, &notes)
    })
    .await
}

#[tauri::command]
async fn update_meeting(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    id: String,
    title: String,
    notes: String,
) -> Result<Meeting, String> {
    require_main(&window)?;
    on_core(state.core.clone(), move |core| {
        core.update_meeting(&id, &title, &notes)
    })
    .await
}

#[tauri::command]
async fn list_devices(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
) -> Result<Vec<Device>, String> {
    require_main(&window)?;
    on_core(state.core.clone(), |core| core.devices()).await
}

#[tauri::command]
async fn start_recording(
    app: tauri::AppHandle,
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    meeting_id: String,
    device_id: Option<String>,
) -> Result<Snapshot, String> {
    require_main(&window)?;
    let processing = state.processing.snapshot();
    if processing.status == "running" && processing.kind == "import" {
        return Err("음성 가져오기가 끝난 뒤 녹음을 시작해 주세요.".into());
    }
    let snapshot = on_core(state.core.clone(), move |core| {
        let selected = match device_id {
            Some(id) => id,
            None => core
                .devices()?
                .into_iter()
                .find(|device| device.is_default)
                .map(|device| device.id)
                .unwrap_or_default(),
        };
        core.start(&meeting_id, &selected)
    })
    .await?;
    publish(&app, &snapshot);
    Ok(snapshot)
}

#[tauri::command]
async fn pause_recording(
    app: tauri::AppHandle,
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    session_id: String,
) -> Result<Snapshot, String> {
    require_local_window(&window)?;
    let snapshot = on_core(state.core.clone(), move |core| core.pause(&session_id)).await?;
    publish(&app, &snapshot);
    Ok(snapshot)
}

#[tauri::command]
async fn resume_recording(
    app: tauri::AppHandle,
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    session_id: String,
) -> Result<Snapshot, String> {
    require_local_window(&window)?;
    let snapshot = on_core(state.core.clone(), move |core| core.resume(&session_id)).await?;
    publish(&app, &snapshot);
    Ok(snapshot)
}

#[tauri::command]
async fn stop_recording(
    app: tauri::AppHandle,
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    session_id: String,
) -> Result<Snapshot, String> {
    require_local_window(&window)?;
    let snapshot = on_core(state.core.clone(), move |core| core.stop(&session_id)).await?;
    publish(&app, &snapshot);
    Ok(snapshot)
}

#[tauri::command]
async fn audio_file(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    meeting_id: String,
) -> Result<String, String> {
    require_main(&window)?;
    on_core(state.core.clone(), move |core| core.audio_path(&meeting_id))
        .await?
        .into_os_string()
        .into_string()
        .map_err(|_| "음성 경로를 열지 못했습니다.".into())
}

#[tauri::command]
fn show_recorder(app: tauri::AppHandle, window: WebviewWindow) -> Result<(), String> {
    require_main(&window)?;
    show_recorder_window(&app)
}

#[tauri::command]
fn hide_recorder(window: WebviewWindow, app: tauri::AppHandle) -> Result<(), String> {
    require_local_window(&window)?;
    if let Some(recorder) = app.get_webview_window("recorder") {
        recorder
            .hide()
            .map_err(|_| "제어창을 숨기지 못했습니다.".to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn hide_main(
    window: WebviewWindow,
    app: tauri::AppHandle,
    state: tauri::State<'_, DesktopState>,
) -> Result<(), String> {
    require_main(&window)?;
    let snapshot = on_core(state.core.clone(), |core| core.snapshot()).await?;
    if active_session(&snapshot).is_some() {
        show_recorder_window(&app)?;
    }
    window.hide().map_err(|_| "창을 숨기지 못했습니다.".into())
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenMeeting {
    meeting_id: String,
    error: Option<String>,
}

#[tauri::command]
async fn open_meeting(
    window: WebviewWindow,
    app: tauri::AppHandle,
    state: tauri::State<'_, DesktopState>,
    meeting_id: String,
    error: Option<String>,
) -> Result<(), String> {
    require_local_window(&window)?;
    let id = meeting_id.clone();
    let exists = on_core(state.core.clone(), move |core| {
        core.list_meetings()
            .map(|meetings| meetings.iter().any(|meeting| meeting.id == id))
    })
    .await?;
    if !exists {
        return Err("회의를 찾지 못했습니다.".into());
    }
    show_main(&app);
    app.emit_to(
        "main",
        "grove://open-meeting",
        OpenMeeting {
            meeting_id,
            error: error.map(|text| text.chars().take(2048).collect()),
        },
    )
    .map_err(|_| "회의를 열지 못했습니다.".into())
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct QuitRequest {
    session_id: Option<String>,
}

fn ask_quit(app: &tauri::AppHandle) {
    show_main(app);
    let app = app.clone();
    let core = app.state::<DesktopState>().core.clone();
    tauri::async_runtime::spawn(async move {
        if let Ok(snapshot) = on_core(core, |core| core.snapshot()).await {
            let session_id = active_session(&snapshot).map(str::to_string);
            let _ = app.emit_to("main", "grove://quit-requested", QuitRequest { session_id });
        }
    });
}

#[tauri::command]
async fn request_quit(
    window: WebviewWindow,
    app: tauri::AppHandle,
    state: tauri::State<'_, DesktopState>,
    session_id: Option<String>,
) -> Result<(), String> {
    require_main(&window)?;
    let processing = state.processing.clone();
    tauri::async_runtime::spawn_blocking(move || processing.shutdown())
        .await
        .map_err(|_| "음성 처리를 종료하지 못했습니다.".to_string())?;
    let result = on_core(state.core.clone(), move |core| {
        core.prepare_shutdown(session_id.as_deref())
    })
    .await;
    let snapshot = match result {
        Ok(snapshot) => snapshot,
        Err(error) => {
            state.processing.resume();
            return Err(error);
        }
    };
    publish(&app, &snapshot);
    state.quitting.store(true, Ordering::Release);
    state.polling.store(false, Ordering::Release);
    app.exit(0);
    Ok(())
}

#[tauri::command]
fn processing_status(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
) -> Result<Progress, String> {
    require_main(&window)?;
    Ok(state.processing.snapshot())
}
#[tauri::command]
fn prepare_model(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
) -> Result<Progress, String> {
    require_main(&window)?;
    state.processing.prepare_model()
}
#[tauri::command]
async fn import_audio(
    window: WebviewWindow,
    app: tauri::AppHandle,
    state: tauri::State<'_, DesktopState>,
) -> Result<Option<Progress>, String> {
    require_main(&window)?;
    if !state.processing.snapshot().supported {
        return Err("이 기기의 음성 가져오기가 아직 준비되지 않았습니다.".into());
    }
    let snapshot = on_core(state.core.clone(), |core| core.snapshot()).await?;
    if active_session(&snapshot).is_some() {
        return Err("녹음을 마친 뒤 음성을 가져와 주세요.".into());
    }
    let source = tauri::async_runtime::spawn_blocking(move || {
        app.dialog()
            .file()
            .add_filter("음성", &["wav", "m4a", "mp3", "aac", "aiff", "aif", "caf"])
            .blocking_pick_file()
    })
    .await
    .map_err(|_| "파일 선택 창을 열지 못했습니다.")?;
    let Some(source) = source else {
        return Ok(None);
    };
    let source = source
        .into_path()
        .map_err(|_| "로컬 음성 파일을 선택해 주세요.")?;
    state
        .processing
        .import(state.core.clone(), source)
        .map(Some)
}
#[tauri::command]
async fn transcribe_audio(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    meeting_id: String,
) -> Result<Progress, String> {
    require_main(&window)?;
    let processing = state.processing.clone();
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || processing.transcribe(core, meeting_id))
        .await
        .map_err(|_| "전사를 시작하지 못했습니다.".to_string())?
}
#[tauri::command]
fn cancel_processing(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    job_id: String,
) -> Result<(), String> {
    require_main(&window)?;
    state.processing.cancel(&job_id)
}
#[tauri::command]
async fn read_transcript(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    meeting_id: String,
) -> Result<Option<Transcript>, String> {
    require_main(&window)?;
    on_core(state.core.clone(), move |core| core.transcript(&meeting_id)).await
}
#[tauri::command]
async fn save_transcript(
    window: WebviewWindow,
    state: tauri::State<'_, DesktopState>,
    meeting_id: String,
    expected: TranscriptVersion,
    texts: Vec<String>,
) -> Result<Transcript, String> {
    require_main(&window)?;
    on_core(state.core.clone(), move |core| {
        core.edit_transcript(&meeting_id, expected, texts)
    })
    .await
}

fn tray_icon() -> tauri::image::Image<'static> {
    let mut pixels = vec![0u8; 20 * 20 * 4];
    for y in 3..17 {
        for x in 3..17 {
            if (x - 10_i32).pow(2) + (y - 10_i32).pow(2) <= 44 {
                let offset = (y as usize * 20 + x as usize) * 4;
                pixels[offset..offset + 4].copy_from_slice(&[58, 113, 79, 255]);
            }
        }
    }
    tauri::image::Image::new_owned(pixels, 20, 20)
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            show_main(app)
        }))
        .invoke_handler(tauri::generate_handler![
            read_snapshot,
            create_meeting,
            update_meeting,
            list_devices,
            start_recording,
            pause_recording,
            resume_recording,
            stop_recording,
            audio_file,
            show_recorder,
            hide_recorder,
            hide_main,
            open_meeting,
            request_quit,
            processing_status,
            prepare_model,
            import_audio,
            transcribe_audio,
            cancel_processing,
            read_transcript,
            save_transcript
        ])
        .setup(|app| {
            let root = app.path().app_data_dir()?;
            let core = CoreHandle::open(&root)?;
            let processing = Processing::new(root, app.path().resource_dir()?);
            let polling = Arc::new(AtomicBool::new(true));
            app.manage(DesktopState {
                core: core.clone(),
                quitting: Arc::new(AtomicBool::new(false)),
                polling: polling.clone(),
                processing: processing.clone(),
            });
            let menu = tauri::menu::Menu::with_items(
                app,
                &[
                    &tauri::menu::MenuItem::with_id(app, "open", "Grove 열기", true, None::<&str>)?,
                    &tauri::menu::MenuItem::with_id(
                        app,
                        "recorder",
                        "녹음 제어",
                        true,
                        None::<&str>,
                    )?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::MenuItem::with_id(app, "quit", "종료", true, None::<&str>)?,
                ],
            )?;
            tauri::tray::TrayIconBuilder::with_id("grove")
                .icon(tray_icon())
                .tooltip("Grove")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show_main(app),
                    "recorder" => {
                        let _ = show_recorder_window(app);
                    }
                    "quit" => ask_quit(app),
                    _ => (),
                })
                .build(app)?;
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                while polling.load(Ordering::Acquire) {
                    if let Ok(snapshot) = core.snapshot() {
                        publish(&handle, &snapshot);
                        let _ = handle.emit_to("main", "grove://processing", processing.snapshot());
                    }
                    std::thread::sleep(Duration::from_millis(750));
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                if window.label() == "main" {
                    let _ = window.emit("grove://close-requested", ());
                } else {
                    let _ = window.hide();
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("Grove를 시작하지 못했습니다.");
    app.run(|app, event| {
        if let tauri::RunEvent::ExitRequested { ref api, .. } = event {
            if !app.state::<DesktopState>().quitting.load(Ordering::Acquire) {
                api.prevent_exit();
                ask_quit(app);
            }
        }
        if let tauri::RunEvent::Exit = event {
            app.state::<DesktopState>()
                .polling
                .store(false, Ordering::Release);
        }
    });
}
