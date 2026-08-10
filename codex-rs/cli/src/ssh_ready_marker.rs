#[cfg(any(target_os = "illumos", target_os = "solaris"))]
use std::io;
#[cfg(any(target_os = "illumos", target_os = "solaris", test))]
use std::io::Write;
#[cfg(any(target_os = "illumos", target_os = "solaris"))]
use std::process::Command;

const MARKER_LEN: usize = 8;

#[derive(Debug, Eq, PartialEq)]
struct DesktopMarker<'a> {
    encoded: &'a str,
    bytes: [u8; MARKER_LEN],
}

struct ShellMarkerOutput<'a> {
    succeeded: bool,
    bytes: &'a [u8],
}

#[cfg(any(target_os = "illumos", target_os = "solaris"))]
pub(crate) fn emit_desktop_marker_if_needed() -> io::Result<()> {
    let Ok(payload) = std::env::var("CODEX_REMOTE_PAYLOAD") else {
        return Ok(());
    };
    let Some(marker) = decode_desktop_marker(&payload) else {
        return Ok(());
    };

    let shell_output = Command::new("/bin/sh")
        .args([
            "-c",
            "printf '%b' \"$1\"",
            "codex-ssh-ready-marker-check",
            marker.encoded,
        ])
        .output()?;
    let mut stdout = io::stdout().lock();
    write_marker_if_needed(
        &marker,
        ShellMarkerOutput {
            succeeded: shell_output.status.success(),
            bytes: &shell_output.stdout,
        },
        &mut stdout,
    )
}

fn write_marker_if_needed(
    marker: &DesktopMarker<'_>,
    shell_output: ShellMarkerOutput<'_>,
    output: &mut impl Write,
) -> std::io::Result<()> {
    if shell_output.succeeded && shell_output.bytes == marker.bytes {
        return Ok(());
    }

    // ksh93 requires `\0ddd` for octal escapes in `printf %b`, while the
    // desktop SSH bootstrap currently sends `\ddd`.
    output.write_all(&marker.bytes)?;
    output.flush()
}

fn decode_desktop_marker(payload: &str) -> Option<DesktopMarker<'_>> {
    let encoded = payload.strip_prefix("printf '%b' '")?.split_once("'; ")?.0;
    let chunks = encoded.as_bytes().chunks_exact(4);
    if !chunks.remainder().is_empty() || chunks.len() != MARKER_LEN {
        return None;
    }

    let mut bytes = [0_u8; MARKER_LEN];
    for (output, chunk) in bytes.iter_mut().zip(chunks) {
        if chunk[0] != b'\\' || !chunk[1..].iter().all(|digit| matches!(digit, b'0'..=b'7')) {
            return None;
        }
        let value = u16::from(chunk[1] - b'0') * 64
            + u16::from(chunk[2] - b'0') * 8
            + u16::from(chunk[3] - b'0');
        *output = u8::try_from(value).ok()?;
    }

    Some(DesktopMarker { encoded, bytes })
}

#[cfg(test)]
#[path = "ssh_ready_marker_tests.rs"]
mod tests;
