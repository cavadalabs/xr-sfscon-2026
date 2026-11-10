# Third-party assets, addons and licenses

Everything in this repository that we did not create ourselves, with the
license we ship it under. Where our records are incomplete, that is stated
plainly instead of guessed.

## Godot addons

| Addon | License | Source |
| --- | --- | --- |
| `xr-demo-suite/addons/godot-xr-tools/` | MIT License (bundled `LICENSE` file) | https://github.com/godot-xr-tools/godot-xr-tools |
| `xr-demo-suite/addons/godotopenxrvendors/` | No license file is bundled inside the addon folder; the upstream repository (https://github.com/GodotVR/godot_openxr_vendors) documents its terms. We ship the vendor SDK binaries as distributed by that project — review their redistribution terms before commercial redistribution. | https://github.com/GodotVR/godot_openxr_vendors |

## 3D catalog assets (`xr-demo-suite/assets/`)

Provenance is tracked per item in `xr-demo-suite/data/industrial_models.json`
under each item's `source` key. Current distribution:

### CC0-1.0 (public domain) — 17 items

Free to use without attribution. Source files come from public 3D model
marketplaces and archives; the catalog records the source file name.

### CC-BY-4.0 (attribution required) — 8 items

`robot_arm_ultralight`, `robotic_arm_welder_light`, `electric_motor`,
`nx47_datacore_droid`, `f1_rocketdine_engine`, `centrifugal_pump`,
`le9_engine`, `mule_robot_light`.

> **Attribution gap:** our catalog records the license but **not the original
> author or source URL** for these eight items. We are tracking this in our
> internal catalogue cleanup. Until attribution is restored upstream in the
> JSON, treat these items as "attribution pending" and do not redistribute
> them in a commercial product without resolving the author.

### Our own work — 17 items

16 items are labeled `Project reconstruction; product names and designs belong
to the manufacturer` and 1 is `Original project asset`. The reconstructions
are our own Blender models; the underlying product names and designs remain
the property of their manufacturers. Products of third-party brands
(partner showcases) are **excluded from this public repository entirely**
and only exist in the private project with the manufacturers' knowledge.

## Digital-twin and motion data

- `xr-demo-suite/assets/models/noi/` — our own reconstruction of the NOI
  Techpark buildings, built for this project (all rights reserved, see
  `LICENSE`).
- `xr-demo-suite/data/noi_buildings.json`, `noi_rooms.json`,
  `noi_selection_regions.json`, `noibot-motion.json` — project data authored
  by us.

## Fonts, icons, audio

No third-party fonts or audio files are shipped. Icons are project SVGs; UI
audio comes from the Godot XR Tools addon (MIT, above).

## Open Data

The hackathon template fetches live parking data from the
**Open Data Hub (Provincia Autonoma di Bolzano —
https://opendata.provincia.bz.it/)**. That data is public; reuse is subject to
the dataset's own license as published by the provider.
