use tauri::menu::{Menu, MenuItemKind};
use tauri::{AppHandle, Runtime};

fn korean_label(text: &str) -> Option<String> {
    let plain = text.replace('&', "");
    let (label, mnemonic) = match plain.as_str() {
        "File" => ("파일", "F"),
        "Edit" => ("편집", "E"),
        "View" => ("보기", "V"),
        "Window" => ("창", "W"),
        "Help" => ("도움말", "H"),
        "Undo" => ("실행 취소", "U"),
        "Redo" => ("다시 실행", "R"),
        "Cut" => (
            if cfg!(target_os = "windows") {
                "잘라내기"
            } else {
                "오려두기"
            },
            "T",
        ),
        "Copy" => ("복사", "C"),
        "Paste" => ("붙여넣기", "P"),
        "Select All" => ("모두 선택", "A"),
        "Minimize" => ("최소화", "M"),
        "Maximize" => ("최대화", "X"),
        "Zoom" => ("확대/축소", "X"),
        "Close" | "Close Window" => ("창 닫기", "C"),
        "Toggle Full Screen" => ("전체 화면", "F"),
        "Services" => ("서비스", "S"),
        "Hide" => ("가리기", "H"),
        "Hide Others" => ("기타 가리기", "O"),
        "Show All" => ("모두 보기", "A"),
        "Quit" | "Exit" => ("종료", "X"),
        "About" => ("Nero 정보", "A"),
        _ => {
            if let Some(name) = plain.strip_prefix("About ") {
                return Some(format!("{name} 정보"));
            }
            if let Some(name) = plain.strip_prefix("Hide ") {
                return Some(format!("{name} 가리기"));
            }
            if let Some(name) = plain.strip_prefix("Quit ") {
                return Some(format!("{name} 종료"));
            }
            return None;
        }
    };
    #[cfg(target_os = "windows")]
    return Some(format!("{label}(&{mnemonic})"));
    #[cfg(not(target_os = "windows"))]
    {
        let _ = mnemonic;
        Some(label.into())
    }
}

fn localize<R: Runtime>(items: Vec<MenuItemKind<R>>) -> tauri::Result<()> {
    for item in items {
        let text = match &item {
            MenuItemKind::MenuItem(item) => item.text()?,
            MenuItemKind::Submenu(item) => item.text()?,
            MenuItemKind::Predefined(item) => item.text()?,
            MenuItemKind::Check(item) => item.text()?,
            MenuItemKind::Icon(item) => item.text()?,
        };
        if let Some(text) = korean_label(&text) {
            match &item {
                MenuItemKind::MenuItem(item) => item.set_text(&text)?,
                MenuItemKind::Submenu(item) => item.set_text(&text)?,
                MenuItemKind::Predefined(item) => item.set_text(&text)?,
                MenuItemKind::Check(item) => item.set_text(&text)?,
                MenuItemKind::Icon(item) => item.set_text(&text)?,
            }
        }
        if let MenuItemKind::Submenu(item) = item {
            localize(item.items()?)?;
        }
    }
    Ok(())
}

pub fn default<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Menu<R>> {
    let menu = Menu::default(app)?;
    localize(menu.items()?)?;
    Ok(menu)
}
