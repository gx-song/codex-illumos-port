#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/solaris/remote-smoke-test.sh SSH_HOST [EXPECTED_MODEL...]

Runs read-only deployment checks on an illumos/Solaris Codex host. The only
remote write is a temporary file under /tmp, which is removed before exit.

Environment:
  SOLARIS_SSH_PROXY_JUMP  Optional SSH jump host.
  CODEX_REMOTE_BIN        Codex path relative to $HOME or absolute.
                          Default: .local/bin/codex
  CODEX_REMOTE_HOME       Codex home relative to $HOME or absolute.
                          Default: .codex
  CODEX_EXPECTED_VERSION  Exact expected output from `codex --version`.
  CODEX_EXPECTED_SHA256   Expected SHA-256 digest of the remote binary.
  CODEX_EXPECT_FULL_CLI   Set to 1 to require the full CLI's app-server
                          subcommand. Default: 0
  REDACT_OUTPUT           Set to 1 before publishing the command output.
                          Suppresses host inventory, paths, usernames, and
                          model names from normal test output. SSH transport
                          errors still require manual review. Default: 0

When expected models are supplied, the model catalog must contain exactly that
set. Without model arguments, the script only verifies that the catalog is
valid and contains at least one model.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage
    exit 2
    ;;
esac

ssh_host="$1"
shift

remote_bin="${CODEX_REMOTE_BIN:-.local/bin/codex}"
remote_home="${CODEX_REMOTE_HOME:-.codex}"
expected_version="${CODEX_EXPECTED_VERSION:-}"
expected_sha256="${CODEX_EXPECTED_SHA256:-}"
expect_full_cli="${CODEX_EXPECT_FULL_CLI:-0}"
expected_version_name=""
expected_version_number=""
if [[ -n "${expected_version}" ]]; then
  case "${expected_version}" in
    *" "*)
      expected_version_name="${expected_version%% *}"
      expected_version_number="${expected_version#* }"
      ;;
    *)
      echo "CODEX_EXPECTED_VERSION must contain the command name and version." >&2
      exit 2
      ;;
  esac
fi
redact_output="${REDACT_OUTPUT:-0}"
case "${expect_full_cli}" in
  0|1) ;;
  *)
    echo "CODEX_EXPECT_FULL_CLI must be 0 or 1." >&2
    exit 2
    ;;
esac
case "${redact_output}" in
  0|1) ;;
  *)
    echo "REDACT_OUTPUT must be 0 or 1." >&2
    exit 2
    ;;
esac
ssh_command=(ssh)
if [[ -n "${SOLARIS_SSH_PROXY_JUMP:-}" ]]; then
  ssh_command+=(-J "${SOLARIS_SSH_PROXY_JUMP}")
fi
if [[ "${redact_output}" == "1" ]]; then
  ssh_command+=(-o LogLevel=ERROR)
fi

echo "== Codex illumos/Solaris deployment preflight =="
if [[ "${redact_output}" == "1" ]]; then
  echo "Host: <redacted>"
else
  echo "Host: ${ssh_host}"
fi

"${ssh_command[@]}" "${ssh_host}" sh -s -- \
  "${remote_bin}" \
  "${remote_home}" \
  "${redact_output}" \
  "${expected_version_name}" \
  "${expected_version_number}" \
  "${expected_sha256}" \
  "${expect_full_cli}" \
  "$@" <<'REMOTE'
set -u

passes=0
warnings=0
failures=0

pass() {
  passes=$((passes + 1))
  printf 'PASS  %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN  %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL  %s\n' "$1"
}

info() {
  printf 'INFO  %s\n' "$1"
}

resolve_home_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$HOME" "$1" ;;
  esac
}

sha256_file() {
  if command -v digest >/dev/null 2>&1; then
    digest -a sha256 "$1"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else
    return 127
  fi
}

remote_bin="$(resolve_home_path "$1")"
remote_home="$(resolve_home_path "$2")"
redact_output="$3"
expected_version_name="$4"
expected_version_number="$5"
expected_sha256="$6"
expect_full_cli="$7"
shift 7
expected_version=""
if [ -n "$expected_version_name" ] || [ -n "$expected_version_number" ]; then
  expected_version="$expected_version_name $expected_version_number"
fi

os_name="$(uname -s 2>/dev/null || true)"
os_release="$(uname -r 2>/dev/null || true)"
os_version="$(uname -v 2>/dev/null || true)"
if [ "$os_name" = "SunOS" ] && [ "$os_release" = "5.11" ]; then
  if [ "$redact_output" -eq 1 ]; then
    pass "host is SunOS 5.11"
  else
    pass "host is SunOS 5.11 (${os_version})"
  fi
else
  if [ "$redact_output" -eq 1 ]; then
    fail "expected a SunOS 5.11 host"
  else
    fail "expected SunOS 5.11, found ${os_name:-unknown} ${os_release:-unknown} ${os_version:-unknown}"
  fi
fi

arch="$(isainfo -n 2>/dev/null || uname -m 2>/dev/null || true)"
bits="$(isainfo -b 2>/dev/null || true)"
if [ "$arch" = "amd64" ] && [ "$bits" = "64" ]; then
  pass "host architecture is 64-bit amd64"
else
  fail "expected 64-bit amd64, found architecture=${arch:-unknown} bits=${bits:-unknown}"
fi

if [ -x "$remote_bin" ]; then
  if [ "$redact_output" -eq 1 ]; then
    pass "Codex binary is executable"
  else
    pass "Codex binary is executable: $remote_bin"
  fi
else
  if [ "$redact_output" -eq 1 ]; then
    fail "Codex binary is missing or not executable"
  else
    fail "Codex binary is missing or not executable: $remote_bin"
  fi
fi

if [ -e "$remote_bin" ]; then
  file_output="$(file "$remote_bin" 2>&1 || true)"
  [ "$redact_output" -eq 1 ] || info "$file_output"
  case "$file_output" in
    *ELF*64-bit*x86-64*|*ELF*64-bit*AMD64*)
      pass "Codex binary is a 64-bit x86 ELF"
      ;;
    *)
      fail "Codex binary does not look like a 64-bit x86 ELF"
      ;;
  esac

  ldd_output="$(ldd "$remote_bin" 2>&1)"
  ldd_status=$?
  if [ "$ldd_status" -ne 0 ]; then
    fail "ldd failed with status $ldd_status"
    [ "$redact_output" -eq 1 ] || printf '%s\n' "$ldd_output"
  elif printf '%s\n' "$ldd_output" | grep -Eiq 'not found|not found\)'; then
    fail "one or more shared libraries are missing"
    [ "$redact_output" -eq 1 ] || printf '%s\n' "$ldd_output"
  else
    pass "all dynamic libraries resolve"
  fi

  if [ -n "$expected_sha256" ]; then
    actual_sha256="$(sha256_file "$remote_bin" 2>/dev/null)"
    checksum_status=$?
    if [ "$checksum_status" -eq 0 ] && [ "$actual_sha256" = "$expected_sha256" ]; then
      pass "SHA-256 matches the local artifact"
    elif [ "$checksum_status" -eq 127 ]; then
      fail "no SHA-256 utility is available on the target"
    else
      fail "SHA-256 does not match the local artifact"
    fi
  fi
fi

if [ -x "$remote_bin" ]; then
  version_output="$("$remote_bin" --version 2>&1)"
  version_status=$?
  if [ "$version_status" -eq 0 ] \
    && [ -n "$version_output" ] \
    && { [ -z "$expected_version" ] || [ "$version_output" = "$expected_version" ]; }; then
    pass "--version runs: $version_output"
  elif [ "$version_status" -eq 0 ] && [ -n "$expected_version" ]; then
    fail "--version returned an unexpected version: $version_output"
  else
    fail "--version failed with status $version_status"
  fi

  help_output="$("$remote_bin" --help 2>&1)"
  help_status=$?
  if [ "$help_status" -eq 0 ] \
    && printf '%s\n' "$help_output" | grep -q '^Usage: codex ' \
    && printf '%s\n' "$help_output" | grep -q 'exec' \
    && printf '%s\n' "$help_output" | grep -q 'completion' \
    && printf '%s\n' "$help_output" | grep -q 'resume'; then
    pass "--help exposes the expected common CLI surface"
  else
    fail "--help is missing expected CLI surface"
  fi

  if [ "$expect_full_cli" -eq 1 ]; then
    app_server_help="$("$remote_bin" app-server --help 2>&1)"
    app_server_status=$?
    if [ "$app_server_status" -eq 0 ] \
      && printf '%s\n' "$app_server_help" | grep -q '^Usage: codex app-server '; then
      pass "app-server --help confirms the full CLI artifact"
    else
      fail "app-server subcommand is unavailable; this is not the expected full CLI"
    fi
  fi

  resume_help="$("$remote_bin" resume --help 2>&1)"
  resume_status=$?
  if [ "$resume_status" -eq 0 ] \
    && printf '%s\n' "$resume_help" | grep -q '^Usage: codex resume ' \
    && printf '%s\n' "$resume_help" | grep -q -- '--last'; then
    pass "resume --help accepts session IDs and --last"
  else
    fail "resume subcommand is unavailable or incomplete"
  fi

  exec_help="$("$remote_bin" exec --help 2>&1)"
  exec_status=$?
  if [ "$exec_status" -eq 0 ] \
    && printf '%s\n' "$exec_help" | grep -q '^Usage: codex exec ' \
    && printf '%s\n' "$exec_help" | grep -q 'review' \
    && printf '%s\n' "$exec_help" | grep -q -- '--json'; then
    pass "exec --help exposes non-interactive and review commands"
  else
    fail "exec subcommand is unavailable or incomplete"
  fi

  review_help="$("$remote_bin" exec review --help 2>&1)"
  review_status=$?
  if [ "$review_status" -eq 0 ] \
    && printf '%s\n' "$review_help" | grep -q '^Usage: codex exec review ' \
    && printf '%s\n' "$review_help" | grep -q -- '--uncommitted'; then
    pass "exec review --help exposes review targets"
  else
    fail "exec review subcommand is unavailable or incomplete"
  fi

  completion_output="$("$remote_bin" completion bash 2>&1)"
  completion_status=$?
  if [ "$completion_status" -eq 0 ] \
    && [ -n "$completion_output" ] \
    && printf '%s\n' "$completion_output" | grep -q 'codex'; then
    pass "completion generates a non-empty Bash script"
  else
    fail "completion generation failed"
  fi
fi

check_private_file() {
  file_kind="$1"
  checked_file="$2"
  if [ ! -f "$checked_file" ]; then
    if [ "$redact_output" -eq 1 ]; then
      fail "$file_kind file is missing"
    else
      fail "$file_kind file is missing: $checked_file"
    fi
    return
  fi

  mode="$(stat -c '%a' "$checked_file" 2>/dev/null || true)"
  owner="$(stat -c '%U' "$checked_file" 2>/dev/null || true)"
  case "$mode" in
    400|600)
      pass "$file_kind file permissions are $mode"
      ;;
    "")
      if [ "$redact_output" -eq 1 ]; then
        warn "could not determine $file_kind file permissions"
      else
        warn "could not determine permissions for $checked_file"
      fi
      ;;
    *)
      fail "$file_kind file permissions are $mode; expected 600 or 400"
      ;;
  esac
  if [ -n "$owner" ] && [ "$owner" = "$(id -un)" ]; then
    if [ "$redact_output" -eq 1 ]; then
      pass "$file_kind file is owned by the current user"
    else
      pass "$file_kind file is owned by $owner"
    fi
  elif [ -n "$owner" ]; then
    if [ "$redact_output" -eq 1 ]; then
      fail "$file_kind file is not owned by the current user"
    else
      fail "$file_kind file is owned by $owner, not $(id -un)"
    fi
  fi
}

config_file="$remote_home/config.toml"
catalog_file="$remote_home/model-catalog.json"
check_private_file "config" "$config_file"

temporary="${TMPDIR:-/tmp}/codex-illumos-smoke.$$"
expected_file="${temporary}.expected"
actual_file="${temporary}.actual"
cleanup() {
  rm -f "$temporary" "$expected_file" "$actual_file"
}
trap cleanup EXIT HUP INT TERM

if printf 'codex-illumos-smoke\n' >"$temporary" \
  && [ "$(cat "$temporary")" = "codex-illumos-smoke" ]; then
  pass "shell and temporary filesystem read/write work"
else
  fail "shell or temporary filesystem read/write failed"
fi

expected_model_count=$#
if [ -f "$catalog_file" ]; then
  check_private_file "catalog" "$catalog_file"
  : >"$actual_file"
  : >"$expected_file"
  for model in "$@"; do
    printf '%s\n' "$model" >>"$expected_file"
  done
  sort "$expected_file" -o "$expected_file"

  catalog_status=1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.models[] | .slug' "$catalog_file" 2>/dev/null \
      | sort >"$actual_file"
    catalog_status=$?
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c \
      'import json,sys; print("\n".join(m["slug"] for m in json.load(open(sys.argv[1]))["models"]))' \
      "$catalog_file" 2>/dev/null | sort >"$actual_file"
    catalog_status=$?
  fi

  actual_model_count="$(wc -l <"$actual_file" | tr -d ' ')"
  if [ "$catalog_status" -ne 0 ]; then
    fail "model catalog could not be parsed; install jq or python3 and validate its JSON"
  elif [ "$actual_model_count" -eq 0 ]; then
    fail "model catalog does not contain any model slugs"
  elif [ "$expected_model_count" -eq 0 ]; then
    pass "model catalog is valid and contains $actual_model_count model(s)"
    [ "$redact_output" -eq 1 ] || sed 's/^/INFO    model: /' "$actual_file"
  elif cmp -s "$expected_file" "$actual_file"; then
    pass "model catalog contains exactly the expected models"
    [ "$redact_output" -eq 1 ] || sed 's/^/INFO    model: /' "$actual_file"
  else
    fail "model catalog differs from the expected model set"
    if [ "$redact_output" -ne 1 ]; then
      sed 's/^/INFO    expected: /' "$expected_file"
      sed 's/^/INFO    actual:   /' "$actual_file"
    fi
  fi
elif [ "$expected_model_count" -gt 0 ]; then
  fail "model catalog is required when expected models are specified"
else
  warn "model catalog is absent; skipped static catalog validation"
fi

memory="$(prtconf 2>/dev/null | awk '/Memory size:/ { print $3 " " $4; exit }')"
disk="$(df -k "$HOME" 2>/dev/null | tail -1)"
if [ "$redact_output" -ne 1 ]; then
  [ -n "$memory" ] && info "physical memory: $memory"
  [ -n "$disk" ] && info "home filesystem: $disk"
fi
locale_name="${LC_ALL:-${LC_CTYPE:-${LANG:-unset}}}"
info "locale: $locale_name"

printf '\nRemote checks: %d passed, %d warnings, %d failed\n' \
  "$passes" "$warnings" "$failures"
[ "$failures" -eq 0 ]
REMOTE
remote_status=$?

if "${ssh_command[@]}" -tt "${ssh_host}" \
  'if test -t 0 && test -t 1 && test -c /dev/tty; then printf "PASS  SSH pseudo-terminal allocation works\n"; else printf "FAIL  SSH pseudo-terminal allocation failed\n"; exit 1; fi' \
  </dev/null
then
  pty_status=0
else
  pty_status=$?
fi

if [[ "$remote_status" -eq 0 && "$pty_status" -eq 0 ]]; then
  echo "Preflight result: PASS"
  exit 0
fi

echo "Preflight result: FAIL (remote=${remote_status}, pty=${pty_status})" >&2
exit 1
