use clap::Parser;
use pretty_assertions::assert_eq;

use super::Command;
use super::TopCli;
use super::merge_resume_command;
use super::prepare_exec_command;
use super::write_completion;

fn parse_resume(args: &[&str]) -> codex_tui::Cli {
    let parsed = TopCli::try_parse_from(args).expect("arguments should parse");
    let Command::Resume(command) = parsed.subcommand.expect("resume command should be present")
    else {
        panic!("expected resume command");
    };
    merge_resume_command(parsed.inner, command).expect("resume command should merge")
}

fn parse_exec(args: &[&str]) -> codex_exec::Cli {
    let parsed = TopCli::try_parse_from(args).expect("arguments should parse");
    let Command::Exec(command) = parsed.subcommand.expect("exec command should be present") else {
        panic!("expected exec command");
    };
    prepare_exec_command(command, &parsed.inner, parsed.config_overrides)
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

#[test]
fn exec_inherits_root_options_and_parses_exec_options() {
    let cli = parse_exec(&[
        "codex",
        "-c",
        "model_provider=root",
        "-m",
        "root-model",
        "-C",
        "/root/workspace",
        "exec",
        "-m",
        "exec-model",
        "--json",
        "inspect",
    ]);

    assert_eq!(cli.model.as_deref(), Some("exec-model"));
    assert_eq!(
        cli.cwd.as_deref(),
        Some(std::path::Path::new("/root/workspace"))
    );
    assert!(cli.json);
    assert_eq!(cli.prompt.as_deref(), Some("inspect"));
    assert_eq!(
        cli.config_overrides.raw_overrides,
        vec!["model_provider=root".to_string()]
    );
}

#[test]
fn exec_review_subcommand_is_available() {
    let cli = parse_exec(&["codex", "exec", "review", "--uncommitted"]);

    let Some(codex_exec::Command::Review(review)) = cli.command else {
        panic!("expected exec review command");
    };
    assert!(review.uncommitted);
}

#[test]
fn completion_includes_restored_commands() {
    let parsed =
        TopCli::try_parse_from(["codex", "completion", "bash"]).expect("arguments should parse");
    let Command::Completion(command) = parsed
        .subcommand
        .expect("completion command should be present")
    else {
        panic!("expected completion command");
    };
    let mut output = Vec::new();

    write_completion(command, &mut output);

    let output = String::from_utf8(output).expect("completion should be UTF-8");
    assert!(output.contains("exec"));
    assert!(output.contains("resume"));
}
