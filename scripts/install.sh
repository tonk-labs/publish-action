#!/usr/bin/env bash
# Install the tonk CLI into the runner's temp directory and put it on PATH.
#
# TONK_VERSION: `latest`, `staging`, or any release tag. Uses tonk's own
# installer, which verifies the download against the release checksums.
set -euo pipefail

version="${TONK_VERSION:-latest}"
bin="${RUNNER_TEMP:?RUNNER_TEMP is not set}/tonk-bin"
mkdir -p "$bin"

# Any other value is a release tag: a version (`v0.7.0`) or a pinned
# build (`tonk-<hash>`, from tonk's "Pin CLI release" workflow).
case "$version" in
  latest) ;;
  staging) export TONK_CHANNEL=staging ;;
  *)
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
      { echo "::error::tonk-version must be latest, staging, or a release tag (got '$version')"; exit 1; }
    export TONK_RELEASE="$version"
    ;;
esac

export TONK_INSTALL_DIR="$bin"
curl -fsSL https://github.com/tonk-labs/tonk/releases/latest/download/install.sh | sh

# tonk's Linux build is linked by Nix: its ELF interpreter is a /nix/store
# path that a stock runner does not have, so the kernel refuses to start it
# ("required file not found"). Start it through the system loader instead.
# Its libraries (libc, libm, libgcc_s) resolve from the system; the build
# needs glibc 2.39, which ubuntu-24.04 has.
if [ "$(uname -s)" = Linux ] && ! "$bin/tonk" --version >/dev/null 2>&1; then
  loader=/lib64/ld-linux-x86-64.so.2
  if ! [ -x "$loader" ] || ! "$loader" "$bin/tonk" --version >/dev/null 2>&1; then
    echo "::error::the tonk binary does not run on this runner, even through $loader"
    exit 1
  fi
  mv "$bin/tonk" "$bin/tonk.elf"
  printf '#!/bin/sh\nexec %s %s "$@"\n' "$loader" "$bin/tonk.elf" >"$bin/tonk"
  chmod 0755 "$bin/tonk"
fi

echo "$bin" >>"$GITHUB_PATH"
"$bin/tonk" --version
