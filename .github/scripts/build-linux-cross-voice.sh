#!/usr/bin/env bash
# Cross-compile voice on the host using the sysroot prepared with the musl tools.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP environment variable is required}"
app_target="${APP_TARGET:?APP_TARGET environment variable is required}"
voice_target="${app_target%-musl}-gnu"
case "${voice_target}" in
  loongarch64-unknown-linux-gnu|riscv64gc-unknown-linux-gnu) ;;
  *) echo "Unsupported cross voice target: ${voice_target}" >&2; exit 1 ;;
esac
voice_key="${voice_target//-/_}"
cc_key="CC_${voice_key}"
cxx_key="CXX_${voice_key}"
ar_key="AR_${voice_key}"
ranlib_key="RANLIB_${voice_key}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rust_version="$(python3 -c 'import pathlib, sys, tomllib; print(tomllib.loads(pathlib.Path(sys.argv[1]).read_text())["toolchain"]["channel"])' "${repo_root}/codex-rs/rust-toolchain.toml")"
build_root="$(mktemp -d "${RUNNER_TEMP}/codex-voice-${app_target}.XXXXXX")"
output="${RUNNER_TEMP}/signed-voice/${app_target}"
export GITHUB_SHA="${GITHUB_SHA:-$(git -C "${repo_root}" rev-parse HEAD)}"
export STABLE_GIT_COMMIT="${GITHUB_SHA}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${build_root}/cargo-target}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
mkdir -p "${build_root}/source" "${build_root}/archives" "${output}"
echo "Cross-compiling ${app_target} voice in ${build_root}"

# Cargo may refresh its lockfile; keep that work outside the release checkout.
tar -C "${repo_root}" --exclude=.git --exclude=target --exclude=dist --exclude=node_modules \
  --exclude=.cargo-home --exclude='.zig-cache' --exclude='.venv' --exclude='.ruff_cache' --exclude='bazel-*' \
  -cf - . | tar -C "${build_root}/source" -xf -

python3 - "${repo_root}" "${build_root}/archives" <<'PY'
import hashlib
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "third_party/voice"))
from prepare_sources import MANIFEST, load_sources

for source in load_sources(MANIFEST.read_bytes()):
    archive = Path(sys.argv[2]) / source.archive
    subprocess.run(["curl", "-fsSL", "--retry", "3", source.url, "-o", str(archive)], check=True)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != source.sha256:
            raise ValueError(f"SHA-256 mismatch: {source.name}")

PY

rustup target add --toolchain "${rust_version}" "${voice_target}"
cd "${build_root}/source"
python3 third_party/voice/build_cross.py \
  --archives "${build_root}/archives" --output "${build_root}/native-prefix" --target "${voice_target}" \
  --cc "${!cc_key}" --cxx "${!cxx_key}" \
  --ar "${!ar_key}" --ranlib "${!ranlib_key}" \
  --build-cc "$(command -v "${HOST_CC:-cc}")" --build-cxx "$(command -v "${HOST_CXX:-c++}")" \
  --cmake "$(command -v cmake)" --make "$(command -v make)" --pkg-config "$(command -v pkg-config)" \
  --shell /bin/bash --jobs "${CARGO_BUILD_JOBS}"
printf 'STABLE_GIT_COMMIT %s\n' "${GITHUB_SHA}" > "${build_root}/workspace-status.txt"
python3 - "${build_root}" "${voice_target}" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, "third_party/voice")
from prepare_built_runtime import prepare_built
root = Path(sys.argv[1])
prepare_built(root / "native-prefix/prefix", root / "native-prefix/built.json",
              root / "workspace-status.txt", sys.argv[2], root / "runtime", sdk_output=root / "sdk")
PY
python3 third_party/voice/cargo_ci.py stage \
  --sdk "${build_root}/sdk" --runtime "${build_root}/runtime" --output "${build_root}/cargo-inputs" \
  --target "${voice_target}"
GITHUB_ENV="${build_root}/cargo.env" python3 third_party/voice/cargo_ci.py configure \
  --root "${build_root}/cargo-inputs" --target "${voice_target}"
while IFS= read -r assignment; do export "${assignment?}"; done < "${build_root}/cargo.env"
cd codex-rs
cargo +"${rust_version}" build --release --target "${voice_target}" -p codex-voice-host
cd ..
python3 third_party/voice/release_runtime.py stage \
  --target "${voice_target}" --source "${build_root}/runtime" --output "${output}/runtime"
cp "${CARGO_TARGET_DIR}/${voice_target}/release/codex-voice-host" "${output}/codex-voice-host"
chmod 0755 "${output}/codex-voice-host"
python3 third_party/voice/release_runtime.py seal --target "${voice_target}" --output "${output}/runtime"
echo "${app_target} voice package inputs are ready in ${output}"
