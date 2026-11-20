use std::process::Command;
use std::process::Stdio;
use std::time::Duration;

use codex_utils_cargo_bin::cargo_bin;
use codex_utils_cargo_bin::copy_executable;
use tempfile::tempdir;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncWriteExt;
use tokio::io::BufReader;

#[tokio::test]
async fn version_uses_runtime_package_manifest() -> anyhow::Result<()> {
    let package = tempdir()?;
    let bin_dir = package.path().join("bin");
    std::fs::create_dir(&bin_dir)?;
    let binary = bin_dir.join(format!("codex{}", std::env::consts::EXE_SUFFIX));
    copy_executable(&cargo_bin("codex")?, &binary)?;
    std::fs::write(
        package.path().join("codex-package.json"),
        r#"{"version":"2026.10.21-illumos.native-copy"}"#,
    )?;

    let output = Command::new(&binary).arg("--version").output()?;
    assert!(output.status.success(), "{output:?}");
    insta::assert_snapshot!(String::from_utf8(output.stdout)?, @"codex-cli 2026.10.21-illumos.native-copy");

    std::fs::create_dir(package.path().join("home"))?;
    let startup = Command::new(&binary)
        .args(["app-server", "--print-startup-config"])
        .env("CODEX_HOME", package.path().join("home"))
        .output()?;
    assert!(startup.status.success(), "{startup:?}");
    let startup: serde_json::Value = serde_json::from_slice(&startup.stdout)?;
    insta::assert_snapshot!(startup["appServerVersion"].as_str().expect("startup version"), @"2026.10.21-illumos.native-copy");

    let mut server = tokio::process::Command::new(binary)
        .args(["app-server", "--listen", "stdio://"])
        .env("CODEX_HOME", package.path().join("home"))
        .env_remove("CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    server
        .stdin
        .as_mut()
        .expect("server stdin")
        .write_all(
            b"{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"version_test\",\"version\":\"1\"}}}\n",
        )
        .await?;
    let mut lines = BufReader::new(server.stdout.take().expect("server stdout")).lines();
    let response = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(line) = lines.next_line().await? {
            let message: serde_json::Value = serde_json::from_str(&line)?;
            if message["id"] == 1 {
                return Ok::<_, anyhow::Error>(message);
            }
        }
        anyhow::bail!("server exited before initialize response")
    })
    .await??;
    let user_agent = response["result"]["userAgent"]
        .as_str()
        .expect("initialize user agent");
    insta::assert_snapshot!(user_agent.split_whitespace().next().expect("version token"), @"version_test/2026.10.21-illumos.native-copy");
    server.start_kill()?;
    server.wait().await?;
    Ok(())
}

#[test]
fn unpackaged_version_uses_build_identity() -> anyhow::Result<()> {
    let output = Command::new(cargo_bin("codex")?)
        .arg("--version")
        .output()?;
    assert!(output.status.success(), "{output:?}");
    // Bazel stamps the final executable separately from this test binary.
    let version = String::from_utf8(output.stdout)?;
    let identity = version
        .trim_end()
        .strip_prefix("codex-cli ")
        .expect("CLI version prefix");
    if cfg!(any(target_os = "illumos", target_os = "solaris"))
        && env!("CARGO_PKG_VERSION") != "0.0.0"
    {
        assert_eq!(identity, env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    assert!(
        identity == "dev"
            || (identity.len() == 40 && identity.bytes().all(|byte| byte.is_ascii_hexdigit())),
        "unexpected source build identity: {identity}",
    );
    Ok(())
}
