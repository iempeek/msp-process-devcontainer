#!/usr/bin/env bash
# =============================================================================
# .devcontainer/protoc-rsp-wrapper.sh
#
# Stand-in for the protoc that Grpc.Tools ships, wired in via
# Protobuf_ProtocFullPath (containerEnv in devcontainer.json).
#
# Grpc.Tools always invokes protoc with a single @response-file argument. The
# linux_arm64 protoc builds (seen with Grpc.Tools 2.80.0 and 2.81.1) segfault
# (exit 139) on ANY @file in this devcontainer, even one holding only
# `--version`, while the same arguments passed directly work. Every backend
# project with <Protobuf> items (AlertManager.Grpc.Common) therefore fails to
# build on Apple Silicon. This wrapper expands the response file itself and
# execs the real protoc with plain arguments.
# =============================================================================
set -euo pipefail

case "$(uname -m)" in
  aarch64 | arm64) arch=linux_arm64 ;;
  x86_64 | amd64) arch=linux_x64 ;;
  *) echo "protoc-rsp-wrapper: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

nuget_root="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
real=$(ls -d "$nuget_root"/grpc.tools/*/tools/"$arch"/protoc 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$real" ]; then
  echo "protoc-rsp-wrapper: no Grpc.Tools protoc for $arch under $nuget_root - run dotnet restore first" >&2
  exit 1
fi

args=()
for a in "$@"; do
  if [[ $a == @* && -f ${a#@} ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      [[ -n $line ]] && args+=("$line")
    done < "${a#@}"
  else
    args+=("$a")
  fi
done

exec "$real" "${args[@]}"
