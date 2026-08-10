# Public Publishing Checklist

Use this checklist before pushing the port to a public GitHub repository,
opening a pull request, or attaching a binary to a release.

## Source provenance

- Record the upstream Codex commit used as the base.
- Preserve the repository license and notices.
- Keep the port changes in reviewable commits: platform code, build scripts,
  and documentation can be separate commits.
- Do not commit generated target files unless the upstream repository normally
  tracks them.

## Never publish

- API keys, bearer tokens, cookies, or authorization headers
- private gateway URLs or model catalog responses
- SSH usernames, hostnames, IP addresses, jump-host configuration, or aliases
- `~/.codex` contents, rollout files, session IDs, logs, or prompt history
- copied sysroots, system libraries, GCC runtimes, or target package archives
- locally built binaries inside the source commit

The included `config.toml` uses an environment-variable name only. Keep the
actual value outside the repository.

## Diff-focused checks

Inspect every changed and untracked file:

```sh
git status --short
git diff --check
git diff
git ls-files --others --exclude-standard
```

Search the port files and changed source for common private artifacts:

```sh
rg -n \
  '(Bearer |api[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?token)' \
  scripts/solaris codex-rs/tui/src/main_tests.rs

rg -n \
  '(/Users/|/home/[^$<]|/export/home/|user@([0-9]{1,3}\.){3}[0-9]{1,3})' \
  scripts/solaris codex-rs/tui/src/main_tests.rs
```

Review matches manually. Example environment-variable names and deliberately
synthetic test values are acceptable; real values are not.

For stronger scanning, install and run a secret scanner:

```sh
brew install gitleaks
gitleaks dir scripts/solaris --no-banner --redact
git diff | gitleaks stdin --no-banner --redact
```

Existing upstream tests may contain intentionally fake credentials, so scan
the new directory and the diff rather than treating every repository-wide
match as a leak.

Capture a shareable smoke-test log with host inventory redacted:

```sh
REDACT_OUTPUT=1 \
SOLARIS_SSH_PROXY_JUMP="$SOLARIS_SSH_PROXY_JUMP" \
  scripts/solaris/remote-smoke-test.sh "$TARGET_SSH"
```

## Generated artifacts

Before pushing, check for large or binary files:

```sh
find scripts/solaris -type f -size +1M -print
find scripts/solaris -type f -exec file {} \; | rg -v 'text|empty'
```

The local sysroot should remain outside the repository. The directory
`.gitignore` also rejects common sysroot archives and binary names, but it is
not a substitute for reviewing `git status`.

## Binary releases

A binary built against an illumos/Solaris sysroot is dynamically linked to
that userspace. If publishing it separately:

- state the target OS release and architecture
- include the upstream Codex commit and Rust/LLVM versions
- publish a checksum
- include `file` and `ldd` output with private paths removed
- explain that compatibility with other illumos distributions is not
  guaranteed
- do not bundle target system libraries unless their licenses permit it
- include the repository `LICENSE`, applicable notices, a modified-source link,
  and a third-party license report or SBOM

The illumos version uses SemVer build metadata such as
`0.148.0-alpha.5+illumos.8cabf5a6cf`. Publish it through the manual port release
process documented here. Do not use the upstream `rust-release.yml` workflow or
`scripts/install/install.sh`; their version validation intentionally rejects
this port-specific version format.

Generate a checksum on macOS:

```sh
shasum -a 256 \
  codex-rs/target/x86_64-unknown-illumos/release/codex
```

Use the `codex-tui` path instead only when publishing the standalone TUI
artifact.

## Final validation

Run:

```sh
just bazel-lock-update
just test -p codex-config
just test -p codex-feedback
just test -p codex-login
just test -p codex-aws-auth
just test -p codex-model-provider
just test -p codex-rmcp-client
just test -p codex-tui
just fix
just fmt
shellcheck \
  scripts/solaris/*.sh \
  scripts/solaris/ld.lld \
  scripts/solaris/clangd/*.sh \
  scripts/solaris/cross/*.sh \
  scripts/solaris/cross/bin/*
git diff --check
gitleaks dir scripts/solaris --no-banner --redact
git diff | gitleaks stdin --no-banner --redact
```

Then perform the cross-build, `remote-smoke-test.sh`, and
`CORE_FEATURE_TEST.md` on a clean target account or zone.
