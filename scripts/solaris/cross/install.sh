#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/solaris/cross/install.sh [PREFIX]

Installs the reusable C/C++ and Rust cross environment under PREFIX.
The default prefix is $HOME/.local.
EOF
}

case "${1:-}" in
  "")
    prefix="${HOME}/.local"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    if [[ "$#" != "1" ]]; then
      usage
      exit 2
    fi
    prefix="$1"
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
solaris_dir="$(cd "${script_dir}/.." && pwd)"
mkdir -p "${prefix}"
prefix="$(cd "${prefix}" && pwd)"

install_root="${prefix}/libexec/solaris-cross"
command_dir="${prefix}/bin"
doc_dir="${prefix}/share/doc/solaris-cross"
mkdir -p "${install_root}/bin" "${command_dir}" "${doc_dir}"

install -m 755 "${script_dir}/env.sh" "${install_root}/env.sh"
install -m 755 "${script_dir}/check.sh" "${install_root}/check.sh"
install -m 755 "${script_dir}/bin/clang" "${install_root}/bin/clang"
install -m 755 "${script_dir}/bin/clang++" "${install_root}/bin/clang++"
install -m 755 "${script_dir}/bin/ld.lld" "${install_root}/bin/ld.lld"
install -m 644 "${script_dir}/toolchain.cmake" "${install_root}/toolchain.cmake"
install -m 644 "${script_dir}/README.md" "${doc_dir}/README.md"
install -m 644 "${solaris_dir}/USAGE.zh-CN.md" "${doc_dir}/USAGE.zh-CN.md"

ln -sfn ../libexec/solaris-cross/env.sh "${command_dir}/solaris-cross-env"
ln -sfn ../libexec/solaris-cross/check.sh "${command_dir}/solaris-cross-check"

echo "Installed Solaris cross environment:"
echo "  tools: ${install_root}"
echo "  commands: ${command_dir}/solaris-cross-env"
echo "            ${command_dir}/solaris-cross-check"
echo "  documentation: ${doc_dir}/USAGE.zh-CN.md"
echo
echo "Activate it with:"
echo "  eval \"\$(${command_dir}/solaris-cross-env)\""
