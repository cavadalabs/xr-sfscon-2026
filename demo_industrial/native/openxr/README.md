# Meta group anchor sharing

Minimal patch against Godot OpenXR Vendors **5.1.0-stable**, commit
`7afcd397e6206d9751b82100559ff39a93a8f59e`. Reuses the FB entities, manager,
query and sharing extension; adds the META group sharing extensions.
No Meta Platform SDK or per-user login is used.

Public GDScript API:

- `OpenXRFbSpatialEntitySharingExtension.is_spatial_entity_group_sharing_supported()`
- `entity.share_with_group(group_uuid: String) -> bool`: initiate sharing an existing
  entity whose SHARABLE component has finished enabling. Completion signal
  `openxr_meta_spatial_entity_group_shared(succeeded: bool, result: int)`.
- `query.query_by_group(group_uuid: String)`: configure a cloud group query. Set
  `query.timeout` in seconds, connect
  `openxr_fb_spatial_entity_query_completed_with_result(results: Array, result: int)`,
  then call `query.execute()`. Feed returned entities to the existing anchor manager.
  Negative result codes are OpenXR errors; the original completion signal remains.

Enable `xr/openxr/extensions/meta/anchor_sharing` so the extension is registered
and the export adds `com.oculus.permission.IMPORT_EXPORT_IOT_MAP_DATA`.
Group sharing needs the user's spatial-data sharing permission and connectivity
to Meta's anchor service. Publishing UUIDs/poses over the LAN alone does not
transfer the physical localization map. Saving to cloud is not a prerequisite
for `xrShareSpacesMETA`.

The patch also propagates native query failures, accumulates query result batches,
uses OpenXR nanoseconds for timeouts, and releases pending callback references on
session loss. It invalidates anchor poses when localization fails so callers can
suspend interactions instead of accepting stale tracking. UUIDs and group query limits are checked before calling native APIs.

## Rebuild

Prerequisites: SCons, Git, Xcode for macOS, Android NDK **28.1.13356709** for Android.
Run builds sequentially: upstream shares generated files between targets.

```sh
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools native/openxr/build.sh android
native/openxr/build.sh macos
/Applications/Godot.app/Contents/MacOS/Godot --headless --xr-mode off --path . --script native/openxr/check_group_api.gd
```

The script stages source outside the repo, applies the patch, and copies the arm64
library into the existing addon. Android exports take the library from the Meta
AAR: the script replaces its arm64 entry too, preserving other contents. Pass `template_release` as the second argument
when preparing a release build. Other platforms retain the original addon binary.
Optional `VENDORS_BUILD_DIR` selects a different source/build cache directory.

References: [Meta native spatial anchors](https://developers.meta.com/horizon/documentation/native/android/openxr-spatial-anchors-api-ref/),
[Khronos group filter](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrSpaceGroupUuidFilterInfoMETA.html),
[Godot Vendors source](https://github.com/GodotVR/godot_openxr_vendors/tree/5.1.0-stable).
