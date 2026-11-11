#!/usr/bin/env bash
set -euo pipefail

platform="${1:-android}"
target="${2:-template_debug}"
case "$platform" in android|macos) ;; *) echo 'Use android or macos' >&2; exit 2;; esac
case "$target" in template_debug|template_release) ;; *) echo 'Use template_debug or template_release' >&2; exit 2;; esac
repo="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
source_dir="${VENDORS_BUILD_DIR:-/tmp/shared-vendors-source}"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --filter=blob:none --sparse --depth 1 --branch 5.1.0-stable \
    https://github.com/GodotVR/godot_openxr_vendors.git "$source_dir"
  git -C "$source_dir" sparse-checkout set plugin/src/main/cpp doc_classes thirdparty
  git -C "$source_dir" submodule update --init --depth 1 thirdparty/godot-cpp
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == 7afcd397e6206d9751b82100559ff39a93a8f59e ]]
if ! git -C "$source_dir" apply --reverse --check "$repo/native/openxr/group-sharing.patch" 2>/dev/null; then
  git -C "$source_dir" apply --check "$repo/native/openxr/group-sharing.patch"
  git -C "$source_dir" apply "$repo/native/openxr/group-sharing.patch"
fi
args=(platform="$platform" target="$target" arch=arm64
  custom_api_file=thirdparty/godot_cpp_gdextension_api/extension_api.json
  build_profile=thirdparty/godot_cpp_build_profile/build_profile.json)
if [[ "$platform" == android ]]; then
  args+=(ANDROID_HOME="${ANDROID_HOME:?Set ANDROID_HOME to your SDK containing ndk/28.1.13356709}" ndk_version=28.1.13356709)
  binary="android/$target/arm64/libgodotopenxrvendors.so"
else
  binary="macos/$target/libgodotopenxrvendors.macos.framework/libgodotopenxrvendors.macos"
fi
# ponytail: upstream shares generated files/object paths across platforms; build sequentially.
(cd "$source_dir" && scons "${args[@]}" -j6)
install -m 755 "$source_dir/demo/addons/godotopenxrvendors/.bin/$binary" \
  "$repo/addons/godotopenxrvendors/.bin/$binary"
if [[ "$platform" == android ]]; then
  flavor=debug
  [[ "$target" != template_release ]] || flavor=release
  python3 - "$repo/addons/godotopenxrvendors/.bin/android/$flavor/godotopenxr-meta-$flavor.aar" \
    "$repo/addons/godotopenxrvendors/.bin/$binary" <<'PY'
from pathlib import Path
import sys
from zipfile import ZipFile
archive, library = map(Path, sys.argv[1:])
entry = 'jni/arm64-v8a/libgodotopenxrvendors.so'
updated = archive.with_suffix('.tmp.aar')
with ZipFile(archive) as source, ZipFile(updated, 'w') as destination:
    assert entry in source.namelist(), 'Meta AAR has no arm64 library'
    for info in source.infolist():
        destination.writestr(info, library.read_bytes() if info.filename == entry else source.read(info))
updated.replace(archive)
PY
fi
