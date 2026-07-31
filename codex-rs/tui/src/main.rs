use clap::Parser;
use clap::Subcommand;
use codex_arg0::Arg0DispatchPaths;
use codex_arg0::arg0_dispatch_or_else;
use codex_config::LoaderOverrides;
use codex_tui::AppExitInfo;
use codex_tui::Cli;
use codex_tui::ExitReason;
use codex_tui::run_main;
use codex_utils_cli::CliConfigOverrides;
use std::io::Write;
use supports_color::Stream;

fn format_exit_messages(exit_info: AppExitInfo, color_enabled: bool) -> Vec<String> {
    let is_fatal = matches!(&exit_info.exit_reason, ExitReason::Fatal(_));
    let AppExitInfo {
        token_usage,
        thread_id,
        resume_hint,
        ..
    } = exit_info;

    let mut lines = Vec::new();
    if !token_usage.is_zero() {
        lines.push(token_usage.to_string());
    }

    if let Some(resume_cmd) = resume_hint {
        let command = if color_enabled {
            format!("\u{1b}[36m{resume_cmd}\u{1b}[39m")
        } else {
            resume_cmd
        };
        lines.push(format!("To continue this session, run {command}"));
    } else if is_fatal && let Some(thread_id) = thread_id {
        lines.push(format!("Session ID: {thread_id}"));
    }

    lines
}

#[derive(Parser, Debug)]
#[command(
    subcommand_negates_reqs = true,
    bin_name = "codex",
    override_usage = "codex [OPTIONS] [PROMPT]\n       codex [OPTIONS] <COMMAND> [ARGS]"
)]
struct TopCli {
    #[clap(flatten)]
    config_overrides: CliConfigOverrides,

    #[clap(flatten)]
    inner: Cli,

    #[command(subcommand)]
    subcommand: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Resume a previous interactive session.
    Resume(ResumeCommand),
}

#[derive(Parser, Debug)]
struct ResumeCommand {
    /// Session id (UUID) or session name.
    #[arg(value_name = "SESSION_ID")]
    session_id: Option<String>,

    /// Continue the most recent session without showing the picker.
    #[arg(long, default_value_t = false)]
    last: bool,

    /// Show all sessions instead of filtering by the current directory.
    #[arg(long = "all", default_value_t = false)]
    show_all: bool,

    /// Include non-interactive sessions in the picker and --last selection.
    #[arg(long, default_value_t = false)]
    include_non_interactive: bool,

    #[clap(flatten)]
    inner: Cli,
}

fn merge_resume_command(mut inner: Cli, command: ResumeCommand) -> anyhow::Result<Cli> {
    let ResumeCommand {
        session_id,
        last,
        show_all,
        include_non_interactive,
        inner: resume_inner,
    } = command;
    let resume_session_id = if last && resume_inner.prompt.is_none() {
        inner.prompt = session_id;
        None
    } else {
        if last && session_id.is_some() && resume_inner.prompt.is_some() {
            anyhow::bail!("--last accepts a prompt or a session id with a prompt, but not both");
        }
        session_id
    };

    inner.resume_picker = resume_session_id.is_none() && !last;
    inner.resume_last = last;
    inner.resume_session_id = resume_session_id;
    inner.resume_show_all = show_all;
    inner.resume_include_non_interactive = include_non_interactive;

    let Cli {
        prompt,
        strict_config,
        shared,
        approval_policy,
        web_search,
        no_alt_screen,
        config_overrides,
        ..
    } = resume_inner;
    inner.shared.apply_subcommand_overrides(shared.into_inner());
    if strict_config {
        inner.strict_config = true;
    }
    if let Some(approval_policy) = approval_policy {
        inner.approval_policy = Some(approval_policy);
    }
    if web_search {
        inner.web_search = true;
    }
    if no_alt_screen {
        inner.no_alt_screen = true;
    }
    if let Some(prompt) = prompt {
        inner.prompt = Some(prompt);
    }
    inner
        .config_overrides
        .raw_overrides
        .extend(config_overrides.raw_overrides);

    Ok(inner)
}

fn main() -> anyhow::Result<()> {
    arg0_dispatch_or_else(|arg0_paths: Arg0DispatchPaths| async move {
        let top_cli = TopCli::parse();
        let mut inner = match top_cli.subcommand {
            Some(Command::Resume(command)) => merge_resume_command(top_cli.inner, command)?,
            None => top_cli.inner,
        };
        inner
            .config_overrides
            .raw_overrides
            .splice(0..0, top_cli.config_overrides.raw_overrides);
        let exit_info = run_main(
            inner,
            arg0_paths,
            LoaderOverrides::default(),
            /*explicit_remote_endpoint*/ None,
        )
        .await?;
        let is_fatal = match &exit_info.exit_reason {
            ExitReason::Fatal(message) => {
                eprintln!("ERROR: {message}");
                true
            }
            ExitReason::UserRequested => false,
        };

        let color_enabled = supports_color::on(Stream::Stdout).is_some();
        for line in format_exit_messages(exit_info, color_enabled) {
            println!("{line}");
        }
        if is_fatal {
            std::io::stdout().flush()?;
            std::process::exit(1);
        }
        Ok(())
    })
}

#[cfg(test)]
#[path = "main_tests.rs"]
mod tests;
