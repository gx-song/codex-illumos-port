use super::*;
use pretty_assertions::assert_eq;

#[test]
fn decodes_desktop_ssh_ready_marker() {
    assert_eq!(
        decode_desktop_marker("printf '%b' '\\224\\035\\225\\313\\233\\322\\260\\362'; PATH=/bin"),
        Some(DesktopMarker {
            encoded: "\\224\\035\\225\\313\\233\\322\\260\\362",
            bytes: [0x94, 0x1d, 0x95, 0xcb, 0x9b, 0xd2, 0xb0, 0xf2],
        })
    );
}

#[test]
fn rejects_malformed_desktop_ssh_ready_marker() {
    assert_eq!(
        decode_desktop_marker("printf '%b' '\\224\\035'; PATH=/bin"),
        None
    );
    assert_eq!(
        decode_desktop_marker("printf '%b' '\\224\\035\\225\\318\\233\\322\\260\\362'; PATH=/bin"),
        None
    );
    assert_eq!(
        decode_desktop_marker("printf '%b' '\\400\\035\\225\\313\\233\\322\\260\\362'; PATH=/bin"),
        None
    );
}

#[test]
fn preserves_boundary_marker_bytes() {
    assert_eq!(
        decode_desktop_marker("printf '%b' '\\000\\077\\100\\177\\200\\277\\300\\377'; PATH=/bin"),
        Some(DesktopMarker {
            encoded: "\\000\\077\\100\\177\\200\\277\\300\\377",
            bytes: [0x00, 0x3f, 0x40, 0x7f, 0x80, 0xbf, 0xc0, 0xff],
        })
    );
}

#[test]
fn does_not_repeat_marker_when_shell_output_matches() {
    let marker =
        decode_desktop_marker("printf '%b' '\\224\\035\\225\\313\\233\\322\\260\\362'; PATH=/bin")
            .expect("payload should contain a marker");
    let mut output = Vec::new();

    write_marker_if_needed(
        &marker,
        ShellMarkerOutput {
            succeeded: true,
            bytes: &marker.bytes,
        },
        &mut output,
    )
    .expect("matching shell output should succeed");

    assert_eq!(output, Vec::<u8>::new());
}

#[test]
fn repeats_marker_when_shell_output_is_incompatible() {
    let marker =
        decode_desktop_marker("printf '%b' '\\224\\035\\225\\313\\233\\322\\260\\362'; PATH=/bin")
            .expect("payload should contain a marker");
    let incompatible_output = br"\224\x1d\225";
    let mut output = Vec::new();

    write_marker_if_needed(
        &marker,
        ShellMarkerOutput {
            succeeded: true,
            bytes: incompatible_output,
        },
        &mut output,
    )
    .expect("marker fallback should succeed");

    assert_eq!(output, marker.bytes);
}
