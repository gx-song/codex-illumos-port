use clap::Parser;
use pretty_assertions::assert_eq;

use super::Command;
use super::TopCli;
use super::merge_resume_command;

fn parse_resume(args: &[&str]) -> codex_tui::Cli {
    let parsed = TopCli::try_parse_from(args).expect("arguments should parse");
    let Command::Resume(command) = parsed.subcommand.expect("resume command should be present");
    merge_resume_command(parsed.inner, command).expect("resume command should merge")
}

#[test]
fn resume_session_id_sets_direct_resume() {
    let cli = parse_resume(&["codex", "resume", "00000000-0000-4000-8000-000000000001"]);

    assert_eq!(
        cli.resume_session_id.as_deref(),
        Some("00000000-0000-4000-8000-000000000001")
    );
    assert!(!cli.resume_picker);
    assert!(!cli.resume_last);
}

#[test]
fn resume_without_target_opens_picker() {
    let cli = parse_resume(&["codex", "resume"]);

    assert!(cli.resume_picker);
    assert!(!cli.resume_last);
    assert_eq!(cli.resume_session_id, None);
}

#[test]
fn resume_last_accepts_prompt() {
    let cli = parse_resume(&["codex", "resume", "--last", "continue from here"]);

    assert!(cli.resume_last);
    assert_eq!(cli.prompt.as_deref(), Some("continue from here"));
    assert_eq!(cli.resume_session_id, None);
}

#[test]
fn resume_forwards_scoped_options() {
    let cli = parse_resume(&[
        "codex",
        "resume",
        "--all",
        "--include-non-interactive",
        "--search",
        "-m",
        "example/model-a",
        "session-name",
        "continue",
    ]);

    assert_eq!(cli.resume_session_id.as_deref(), Some("session-name"));
    assert_eq!(cli.prompt.as_deref(), Some("continue"));
    assert!(cli.resume_show_all);
    assert!(cli.resume_include_non_interactive);
    assert!(cli.web_search);
    assert_eq!(cli.model.as_deref(), Some("example/model-a"));
}
