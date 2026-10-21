use std::process::Command;

use codex_utils_cargo_bin::cargo_bin;
use codex_utils_cargo_bin::copy_executable;
use tempfile::tempdir;

#[test]
fn version_uses_runtime_package_manifest() -> anyhow::Result<()> {
    let package = tempdir()?;
    let bin_dir = package.path().join("bin");
    std::fs::create_dir(&bin_dir)?;
    let binary = bin_dir.join(format!("codex{}", std::env::consts::EXE_SUFFIX));
    copy_executable(&cargo_bin("codex")?, &binary)?;
    std::fs::write(
        package.path().join("codex-package.json"),
        r#"{"version":"2026.10.21-illumos.native-copy"}"#,
    )?;

    let output = Command::new(binary).arg("--version").output()?;
    assert!(output.status.success(), "{output:?}");
    insta::assert_snapshot!(String::from_utf8(output.stdout)?, @"codex-cli 2026.10.21-illumos.native-copy");
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
    assert!(
        identity == "dev"
            || (identity.len() == 40 && identity.bytes().all(|byte| byte.is_ascii_hexdigit())),
        "unexpected source build identity: {identity}",
    );
    Ok(())
}
