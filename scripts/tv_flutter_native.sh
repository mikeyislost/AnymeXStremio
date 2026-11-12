#!/usr/bin/env bash
# Builds the native libraries AnymeX+ needs on an LG TV (CI only):
#   libisar.so  (Isar database core, isar-community tag 3.3.0-dev.3)
#   librhttp.so (packages/rhttp's Rust part)
# with LG's webOS NDK as the C compiler and linker. Output: $1 (folder).
set -euo pipefail
OUT=$(realpath -m "${1:-native}")
mkdir -p "$OUT"

# The NDK's settings, read in a subshell so they don't leak into host builds.
eval "$(bash -c '. "$WEBOS_FLUTTER_NDK_ENV" >/dev/null 2>&1; declare -p CC CXX AR CFLAGS CXXFLAGS LDFLAGS SDKTARGETSYSROOT PATH 2>/dev/null' | sed 's/^declare -x /W_/; s/^declare -- /W_/')"
export PATH="$W_PATH"
echo "CC=$W_CC"
echo "CFLAGS=$W_CFLAGS"
echo "sysroot=$W_SDKTARGETSYSROOT"

if echo "$W_CC $W_CFLAGS" | grep -q "float-abi=hard"; then T=armv7-unknown-linux-gnueabihf; else T=armv7-unknown-linux-gnueabi; fi
echo "Rust target: $T"
rustup target add "$T"
TU=$(echo "$T" | tr 'a-z-' 'A-Z_'); tu=$(echo "$T" | tr '-' '_')

cat > /tmp/webos-cc <<EOF
#!/bin/sh
exec $W_CC $W_CFLAGS "\$@" $W_LDFLAGS
EOF
cat > /tmp/webos-cxx <<EOF
#!/bin/sh
exec $W_CXX $W_CXXFLAGS "\$@" $W_LDFLAGS
EOF
chmod +x /tmp/webos-cc /tmp/webos-cxx
export "CARGO_TARGET_${TU}_LINKER=/tmp/webos-cc"
export "CC_${tu}=/tmp/webos-cc" "CXX_${tu}=/tmp/webos-cxx" "AR_${tu}=$(echo "$W_AR" | awk '{print $1}')"
CLANG_TARGET=$(echo "$T" | sed 's/armv7-unknown-linux/armv7-linux/')
export BINDGEN_EXTRA_CLANG_ARGS="--target=$CLANG_TARGET --sysroot=$W_SDKTARGETSYSROOT"

# Isar core
rm -rf /tmp/isar-src
git clone -q --depth 1 --branch 3.3.0-dev.3 https://github.com/isar-community/isar-community.git /tmp/isar-src
(cd /tmp/isar-src/packages/isar_core_ffi && ISAR_VERSION=3.3.0-dev.3 cargo build --release --target "$T")
find /tmp/isar-src -path "*$T/release/*" -name 'libisar*.so' | head -n 1 | xargs -I{} cp {} "$OUT/libisar.so"

# rhttp
(cd packages/rhttp/rust && cargo build --release --target "$T")
cp "packages/rhttp/rust/target/$T/release/librhttp.so" "$OUT/librhttp.so"

file "$OUT"/*.so
ls -la "$OUT"
