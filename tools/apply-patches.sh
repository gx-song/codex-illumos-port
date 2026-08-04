#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: tools/apply-patches.sh CODEX_SOURCE

Verifies the pinned upstream Codex revision and applies the illumos patch set.
The source checkout must be clean.
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

source_root="$(cd "$1" && pwd)"
port_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_commit="$(tr -d '[:space:]' <"${port_root}/UPSTREAM_COMMIT")"

if ! git -C "${source_root}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a Git checkout: ${source_root}" >&2
  exit 2
fi

actual_commit="$(git -C "${source_root}" rev-parse HEAD)"
if [[ "${actual_commit}" != "${expected_commit}" ]]; then
  echo "Expected upstream ${expected_commit}, found ${actual_commit}." >&2
  exit 2
fi

if [[ -n "$(git -C "${source_root}" status --porcelain)" ]]; then
  echo "Codex source checkout is not clean: ${source_root}" >&2
  exit 2
fi

for patch in "${port_root}"/patches/*.patch; do
  echo "Applying $(basename "${patch}")"
  git -C "${source_root}" apply --check "${patch}"
  git -C "${source_root}" apply "${patch}"
done

echo "Applied illumos patches to ${source_root}"
