use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionInfo {
    available: bool,
    executable_path: Option<String>,
    data_dir: String,
    config: Value,
    cli_example: String,
}

fn executable_name() -> &'static str {
    if cfg!(windows) {
        "nero.exe"
    } else {
        "nero"
    }
}

pub fn connection_info(resources: &Path, root: &Path) -> ConnectionInfo {
    let executable = resource_agent_path(resources);
    let available = executable.is_file();
    let path = executable.to_string_lossy().into_owned();
    let data_dir = root.to_string_lossy().into_owned();
    let config = if available {
        json!({"mcpServers": {"nero": {
            "command": path,
            "args": ["--data-dir", data_dir, "mcp"]
        }}})
    } else {
        Value::Null
    };
    let cli_example = if available {
        format!(
            "{}{} --data-dir {} meetings list --json",
            if cfg!(windows) { "& " } else { "" },
            quote(&executable, cfg!(windows)),
            quote(root, cfg!(windows))
        )
    } else {
        String::new()
    };
    ConnectionInfo {
        available,
        executable_path: available.then_some(path),
        data_dir,
        config,
        cli_example,
    }
}

fn quote(path: &Path, powershell: bool) -> String {
    let path = path.to_string_lossy();
    format!(
        "'{}'",
        path.replace('\'', if powershell { "''" } else { "'\\''" })
    )
}

pub fn resource_agent_path(resources: &Path) -> PathBuf {
    resources.join("agent").join(executable_name())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_binary_does_not_offer_a_working_config_or_create_it() {
        let temporary = tempfile::tempdir().unwrap();
        let resources = temporary.path().join("missing resources");
        let info = connection_info(&resources, &temporary.path().join("missing data"));
        assert!(!info.available);
        assert!(info.config.is_null());
        assert!(info.cli_example.is_empty());
        assert!(!resources.exists());
    }

    #[test]
    fn config_preserves_exact_paths_and_uses_no_shell() {
        let temporary = tempfile::tempdir().unwrap();
        let executable = resource_agent_path(temporary.path());
        std::fs::create_dir_all(executable.parent().unwrap()).unwrap();
        std::fs::write(&executable, b"synthetic executable").unwrap();
        let root = temporary.path().join("user's library");
        let info = connection_info(temporary.path(), &root);
        assert!(info.available);
        assert_eq!(
            info.config["mcpServers"]["nero"]["command"],
            executable.to_string_lossy().as_ref()
        );
        assert_eq!(
            info.config["mcpServers"]["nero"]["args"],
            json!(["--data-dir", root.to_string_lossy(), "mcp"])
        );
        assert!(!root.exists());
        assert_eq!(quote(Path::new("a'b"), false), "'a'\\''b'");
        assert_eq!(quote(Path::new("a'b"), true), "'a''b'");
    }
}
