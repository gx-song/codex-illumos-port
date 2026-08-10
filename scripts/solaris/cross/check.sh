#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/solaris/cross/check.sh [--ssh SSH_HOST]

Compiles and inspects C11 and C++17 probes. With --ssh, it also copies the
probes to the target host, runs them, and removes the remote temporary files.
EOF
}

ssh_host=""
case "${1:-}" in
  "")
    ;;
  --ssh)
    if [[ "$#" != "2" ]]; then
      usage
      exit 2
    fi
    ssh_host="$2"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  local source_dir
  local link_target

  while [[ -L "${source}" ]]; do
    source_dir="$(cd -P "$(dirname "${source}")" && pwd)"
    link_target="$(readlink "${source}")"
    if [[ "${link_target}" == /* ]]; then
      source="${link_target}"
    else
      source="${source_dir}/${link_target}"
    fi
  done
  cd -P "$(dirname "${source}")" && pwd
}

script_dir="$(resolve_script_dir)"
cross_env="$("${script_dir}/env.sh")"
eval "${cross_env}"
unset cross_env

printf 'Solaris cross environment: %s -> %s (%s)\n' \
  "$(uname -m)-$(uname -s)" "${SOLARIS_CLANG_TARGET}" "${SOLARIS_TARGET_OS}"
printf '  sysroot: %s\n' "${SOLARIS_SYSROOT}"
printf '  target GCC: %s\n' "${SOLARIS_GCC_PREFIX}"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-solaris-cross.XXXXXX")"
trap 'rm -rf "${probe_dir}"' EXIT

printf '%s\n' \
  '#include <stdio.h>' \
  'int main(void) {' \
  '    puts("solaris-c-ok");' \
  '    return 0;' \
  '}' \
  >"${probe_dir}/probe.c"
printf '%s\n' \
  '#include <iostream>' \
  '#include <string>' \
  '#include <vector>' \
  'int main() {' \
  '    const std::vector<std::string> words{"solaris", "cxx", "ok"};' \
  '    std::cout << words[0] << "-" << words[1] << "-" << words[2] << "\n";' \
  '    return 0;' \
  '}' \
  >"${probe_dir}/probe.cc"

"${CC}" -std=c11 -Wall -Wextra -Werror -fPIC \
  "${probe_dir}/probe.c" -o "${probe_dir}/probe-c"
"${CXX}" -std=c++17 -Wall -Wextra -Werror -fPIC \
  "${probe_dir}/probe.cc" -o "${probe_dir}/probe-cxx"

for probe in "${probe_dir}/probe-c" "${probe_dir}/probe-cxx"; do
  elf_header="$("${SOLARIS_READELF}" -h "${probe}")"
  program_headers="$("${SOLARIS_READELF}" -l "${probe}")"
  if ! grep -q 'Machine:.*X86-64' <<<"${elf_header}"; then
    echo "Probe is not an x86-64 ELF executable: ${probe}" >&2
    exit 1
  fi
  if ! grep -q '/lib/amd64/ld.so.1' <<<"${program_headers}"; then
    echo "Probe has the wrong runtime interpreter: ${probe}" >&2
    exit 1
  fi
done

echo "Local cross-compile checks passed:"
ls -lh "${probe_dir}/probe-c" "${probe_dir}/probe-cxx"

if [[ -n "${ssh_host}" ]]; then
  ssh_command=(ssh)
  scp_command=(scp)
  if [[ -n "${SOLARIS_SSH_PROXY_JUMP:-}" ]]; then
    ssh_command+=(-J "${SOLARIS_SSH_PROXY_JUMP}")
    scp_command+=(-o "ProxyJump=${SOLARIS_SSH_PROXY_JUMP}")
  fi
  "${ssh_command[@]}" "${ssh_host}" \
    'rm -rf .cache/codex-solaris-cross-check && mkdir -p .cache/codex-solaris-cross-check'
  "${scp_command[@]}" "${probe_dir}/probe-c" "${probe_dir}/probe-cxx" \
    "${ssh_host}:.cache/codex-solaris-cross-check/"
  "${ssh_command[@]}" "${ssh_host}" \
    'set -eu; .cache/codex-solaris-cross-check/probe-c; .cache/codex-solaris-cross-check/probe-cxx; ldd .cache/codex-solaris-cross-check/probe-cxx; rm -rf .cache/codex-solaris-cross-check'
  echo "Remote runtime checks passed on ${ssh_host}."
fi
