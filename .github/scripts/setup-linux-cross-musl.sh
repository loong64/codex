#!/usr/bin/env bash
# Prepare shared target headers/libraries and ABI-specific musl/GNU toolchains.
set -euo pipefail

: "${TARGET:?TARGET environment variable is required}"
: "${GITHUB_ENV:?GITHUB_ENV environment variable is required}"
: "${GITHUB_PATH:?GITHUB_PATH environment variable is required}"
cross_cflags=""
cross_image=debian:trixie
case "${TARGET}" in
  loongarch64-unknown-linux-musl)
    cross_arch=loongarch64
    cross_platform=loong64
    cross_image=ghcr.io/loong64/debian:trixie
    cross_cflags=-mcmodel=medium
    ;;
  riscv64gc-unknown-linux-musl)
    cross_arch=riscv64
    cross_platform=riscv64
    ;;
  aarch64-unknown-linux-musl)
    cross_arch=aarch64
    cross_platform=arm64
    ;;
  x86_64-unknown-linux-musl)
    cross_arch=x86_64
    cross_platform=amd64
    ;;
  *) echo "Unsupported Linux cross target: ${TARGET}" >&2; exit 1 ;;
esac
cross_image="${CROSS_CONTAINER_IMAGE:-${cross_image}}"
cross_gnu="${cross_arch}-linux-gnu"
cross_musl="${cross_arch}-linux-musl"
cross_target_key="${TARGET//-/_}"
cross_cargo_key="${cross_target_key^^}"
build_root="${RUNNER_TEMP:?}/codex-musl-tools-${TARGET}"
sysroot="${build_root}/musl-sysroot"
mkdir -p "${sysroot}" "${build_root}/bin"
zig_bin="$(command -v zig)"

sudo apt-get update
sudo apt-get install -y --no-install-recommends llvm libclang-dev cmake make pkg-config gcc g++

docker run --rm --platform "linux/${cross_platform}" \
  --mount "type=bind,src=${sysroot},dst=/sysroot" \
  --env "CROSS_MUSL=${cross_musl}" --env "CROSS_GNU=${cross_gnu}" "${cross_image}" sh -ec '
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      musl-dev linux-libc-dev libc6-dev gcc libasound2-dev
    cp -a --parents /usr/include /usr/lib/${CROSS_MUSL} /usr/lib/${CROSS_GNU} /usr/lib/gcc /usr/lib/linux /sysroot/
    for path in /lib /lib64 /usr/lib64 /usr/lib/ld-linux*; do
      if [ -e "$path" ]; then cp -a --parents "$path" /sysroot/; fi
    done
  '
sudo chown -hR "$(id -u):$(id -g)" "${sysroot}"

# Zig 0.14 builds its bundled CRT with the default code model even when the
# driver receives -mcmodel=medium. Rebuild the matching startup source explicitly:
# codex-app-server can place __libc_start_main more than 128 MiB from _start_c.
if [[ "${cross_arch}" == loongarch64 ]]; then
  zig_lib_dir="$("${zig_bin}" env | python3 -c 'import json, os, sys; print(os.path.abspath(json.load(sys.stdin)["lib_dir"]))')"
  musl_source="${zig_lib_dir}/libc/musl"
  "${zig_bin}" cc -target "${cross_musl}" -mcmodel=medium \
    -O2 -fno-sanitize=undefined -fno-stack-protector -ffreestanding \
    -I "${musl_source}/arch/loongarch64" \
    -I "${musl_source}/src/internal" -I "${musl_source}/src/include" \
    -c "${musl_source}/crt/crt1.c" -o "${sysroot}/usr/lib/${cross_musl}/crt1.o"
fi

# An explicit libc installation prevents Zig from injecting its default CRT.
# Use the target musl libraries already extracted above, with our rebuilt crt1.o.
cat > "${build_root}/libc.conf" <<EOF
include_dir=${sysroot}/usr/include/${cross_musl}
sys_include_dir=${sysroot}/usr/include/${cross_musl}
crt_dir=${sysroot}/usr/lib/${cross_musl}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

# OpenSSL uses this compiler directly and does not consume target CFLAGS.
cat > "${build_root}/bin/${cross_musl}-gcc" <<EOF
#!/usr/bin/env bash
export ZIG_LIBC="${build_root}/libc.conf"
exec "${zig_bin}" cc -target ${cross_musl} ${cross_cflags} -fno-sanitize=undefined \\
  -idirafter "${sysroot}/usr/include" \\
  -idirafter "${sysroot}/usr/include/${cross_gnu}" "\$@"
EOF
chmod +x "${build_root}/bin/${cross_musl}-gcc"


# GNU voice builds share the sysroot but select the GNU CRT and include paths.
gnu_target="${TARGET%-musl}-gnu"
gnu_key="${gnu_target//-/_}"
gnu_cargo_key="${gnu_key^^}"
gcc_dir="$(dirname "$(find "${sysroot}/usr/lib/gcc/${cross_gnu}" -name libgcc.a -print -quit)")"
cat > "${build_root}/gnu-libc.conf" <<EOF
include_dir=${sysroot}/usr/include
sys_include_dir=${sysroot}/usr/include/${cross_gnu}
crt_dir=${sysroot}/usr/lib/${cross_gnu}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${gcc_dir}
EOF
for pair in cc:gcc c++:g++; do
  cat > "${build_root}/bin/${cross_gnu}-${pair#*:}" <<EOF
#!/bin/sh
export ZIG_LIBC="${build_root}/gnu-libc.conf"
exec "${zig_bin}" ${pair%%:*} "\$@" -target ${cross_gnu}
EOF
  chmod +x "${build_root}/bin/${cross_gnu}-${pair#*:}"
done
for tool in ar ranlib; do
  printf '#!/bin/sh\nexec "%s" %s "$@"\n' "${zig_bin}" "${tool}" > "${build_root}/bin/${cross_gnu}-${tool}"
  chmod +x "${build_root}/bin/${cross_gnu}-${tool}"
done
# Relocate GNU metadata instead of applying a sysroot to the separate voice SDK.
python3 - "${sysroot}" "${cross_gnu}" <<'PYCONFIG'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
libdir = root / f"usr/lib/{sys.argv[2]}"
for path in libdir.glob("*.so"):
    if not path.is_symlink() and path.read_bytes().startswith(b"/* GNU ld script"):
        path.write_text(re.sub(r"(?<![\w/])/(?:usr/)?lib(?:64)?/", lambda m: str(root) + m[0], path.read_text()))
for path in (libdir / "pkgconfig").glob("*.pc"):
    path.write_text(re.sub(r"(?m)^(\w+)=/usr", lambda m: m[1] + "=" + str(root / "usr"), path.read_text()))
PYCONFIG

{
  echo "CC_${gnu_key}=${build_root}/bin/${cross_gnu}-gcc"
  echo "CXX_${gnu_key}=${build_root}/bin/${cross_gnu}-g++"
  echo "AR_${gnu_key}=${build_root}/bin/${cross_gnu}-ar"
  echo "RANLIB_${gnu_key}=${build_root}/bin/${cross_gnu}-ranlib"
  echo "CFLAGS_${gnu_key}=-pthread"
  echo "CXXFLAGS_${gnu_key}=-pthread"
  echo "CARGO_TARGET_${gnu_cargo_key}_LINKER=${build_root}/bin/${cross_gnu}-gcc"
  echo "PKG_CONFIG_LIBDIR_${gnu_key}=${sysroot}/usr/lib/${cross_gnu}/pkgconfig"
  echo "PKG_CONFIG_SYSROOT_DIR_${gnu_key}=/"
  # Keep build-time tools on the host while native dependencies target the selected architecture.
  echo "HOST_CC=cc"
  echo "HOST_CXX=c++"
  echo "BUILD_CC=cc"
  echo "SHARED=no"
  echo "CFLAGS_${cross_target_key}=-pthread ${cross_cflags} -idirafter${sysroot}/usr/include -idirafter${sysroot}/usr/include/${cross_gnu}"
  echo "CXXFLAGS_${cross_target_key}=-pthread ${cross_cflags} -idirafter${sysroot}/usr/include -idirafter${sysroot}/usr/include/${cross_gnu}"
  # Let the target compiler supply our CRT instead of Rust's bundled startup objects.
  echo "CARGO_TARGET_${cross_cargo_key}_RUSTFLAGS=-C target-feature=+crt-static -C link-self-contained=no"
  if [[ "${cross_arch}" == loongarch64 ]]; then
    echo "JEMALLOC_SYS_WITH_LG_PAGE=16"
  fi
  echo "OBJCOPY=$(command -v llvm-objcopy)"
  echo "STRIP=$(command -v llvm-strip)"
  echo "BINDGEN_EXTRA_CLANG_ARGS_${cross_target_key}=--sysroot=${sysroot} -isystem ${sysroot}/usr/include/${cross_musl} -idirafter ${sysroot}/usr/include/${cross_gnu}"
} >> "${GITHUB_ENV}"
echo "${build_root}/bin" >> "${GITHUB_PATH}"
