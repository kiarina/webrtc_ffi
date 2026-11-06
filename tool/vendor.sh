#!/usr/bin/env bash
# Replaces third_party/ with the pinned native sources (no git metadata).
#   tool/vendor.sh
# The versions are the single source of truth here; THIRD_PARTY_NOTICES.md
# lists the same ones.
set -euo pipefail
LIBDATACHANNEL=v0.24.6
MBEDTLS=v3.6.7

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone -q --depth 1 --branch "$LIBDATACHANNEL" --recurse-submodules --shallow-submodules \
  https://github.com/paullouisageneau/libdatachannel "$tmp/libdatachannel"
git clone -q --depth 1 --branch "$MBEDTLS" --recurse-submodules --shallow-submodules \
  https://github.com/Mbed-TLS/mbedtls "$tmp/mbedtls"

# Record what the submodules resolved to, then drop what the build never reads.
(cd "$tmp/libdatachannel" && git submodule status --recursive) > "$tmp/libdatachannel-submodules.txt"
(cd "$tmp/mbedtls" && git submodule status --recursive) > "$tmp/mbedtls-submodules.txt"
find "$tmp/libdatachannel" "$tmp/mbedtls" -name .git -prune -exec rm -rf {} +
rm -rf "$tmp/libdatachannel/"{deps/json,examples,test,pages,.github} \
  "$tmp/libdatachannel/deps/libsrtp/"{test,doc,fuzzing,.github} \
  "$tmp/libdatachannel/deps/usrsctp/"{programs,fuzzer,.github} \
  "$tmp/libdatachannel/deps/libjuice/"{test,.github} \
  "$tmp/libdatachannel/deps/plog/"{samples,doc,.github} \
  "$tmp/mbedtls/"{tests,programs,docs,doxygen,.github} \
  "$tmp/mbedtls/framework/"{tests,docs,data_files,.github}

rm -rf "$root/third_party"
mkdir -p "$root/third_party"
mv "$tmp/libdatachannel" "$tmp/mbedtls" "$root/third_party/"
{
  echo "libdatachannel $LIBDATACHANNEL"
  sed 's/^/  /' "$tmp/libdatachannel-submodules.txt"
  echo "mbedtls $MBEDTLS"
  sed 's/^/  /' "$tmp/mbedtls-submodules.txt"
} > "$root/third_party/VERSIONS.txt"
cat "$root/third_party/VERSIONS.txt"
