#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: tools/fetch-sysroot.sh SSH_HOST [DESTINATION]

Copies Solaris or illumos development headers and libraries over SSH. The
default destination is $HOME/.cache/codex/solaris-sysroot.

Set SOLARIS_SSH_PROXY_JUMP when the target is reached through an SSH jump host.
EOF
}

case "${1:-}" in
  -h|--help|"")
    usage
    [[ -n "${1:-}" ]] && exit 0
    exit 2
    ;;
esac

ssh_host="$1"
destination="${2:-${HOME}/.cache/codex/solaris-sysroot}"
parent="$(dirname "${destination}")"
mkdir -p "${parent}"
temporary="$(mktemp -d "${parent}/solaris-sysroot.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

ssh_args=()
if [[ -n "${SOLARIS_SSH_PROXY_JUMP:-}" ]]; then
  ssh_args+=(-J "${SOLARIS_SSH_PROXY_JUMP}")
fi

echo "Fetching Solaris sysroot from ${ssh_host}..."
ssh "${ssh_args[@]}" "${ssh_host}" '
  cd / || exit
  release=$(uname -r)
  version=$(uname -v)
  if [ "$release" != "5.11" ]; then
    echo "Expected Solaris or illumos with SunOS 5.11, found $(uname -s) $release $version." >&2
    exit 2
  fi
  if [ "$(isainfo -b 2>/dev/null)" != "64" ]; then
    echo "Expected a 64-bit x86 Solaris or illumos host." >&2
    exit 2
  fi
  for required in usr/include usr/lib/amd64 lib/amd64; do
    if [ ! -d "$required" ]; then
      echo "Missing required sysroot directory: /$required" >&2
      exit 2
    fi
  done
  set -- usr/include usr/lib lib
  if [ -f etc/release ]; then
    set -- "$@" etc/release
  fi
  found_gcc=0
  if [ -d usr/gcc ]; then
    set -- "$@" usr/gcc
    found_gcc=1
  fi
  for gcc_tree in opt/local/gcc*; do
    if [ -d "$gcc_tree" ]; then
      set -- "$@" "$gcc_tree"
      found_gcc=1
    fi
  done
  if [ "$found_gcc" -ne 1 ]; then
    echo "Missing a GCC runtime under /usr/gcc or /opt/local/gcc*." >&2
    exit 2
  fi
  tar -cf - "$@"
' | tar -xf - -C "${temporary}"

for required_file in usr/include/assert.h usr/include/sys/types.h; do
  if [[ ! -f "${temporary}/${required_file}" ]]; then
    echo "Remote host did not provide ${required_file}; install development headers." >&2
    exit 2
  fi
done

if [[ -e "${destination}" ]]; then
  backup="${destination}.previous"
  rm -rf "${backup}"
  mv "${destination}" "${backup}"
fi
if ! mv "${temporary}" "${destination}"; then
  if [[ -n "${backup:-}" && -e "${backup}" && ! -e "${destination}" ]]; then
    mv "${backup}" "${destination}"
  fi
  exit 1
fi
trap - EXIT

echo "Solaris sysroot saved to ${destination}"
