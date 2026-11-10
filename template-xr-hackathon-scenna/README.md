# Open Data XR Hackathon Template

> You do not need to build an XR app from scratch.
>
> This template already contains a small spatial dashboard. Your challenge is
> to show how real data can become easier to understand in space.

The demo requests live Val Gardena parking data from Open Data Hub once at
startup. If the request fails, it automatically uses one local JSON file. It
runs on desktop without a headset and is prepared for passthrough and hand
interaction on a compatible Meta Quest.

## Choose a level: only three places to edit

| Level | What you change | Open and select |
| --- | --- | --- |
| Base | Offline sample values | Edit `res://data/fallback_parking.json` |
| Intermediate | Card colors or bar height | `res://scenes/data_card.tscn` → **DataCard** |
| Advanced | API URL and JSON mapping | `res://scenes/main.tscn` → **DataSource** |

These common changes require no GDScript and all modify the same demo.

## First 10 minutes: run it on desktop

1. Install [Godot 4.7](https://godotengine.org/download/).
2. In the Project Manager, click **Import** and choose `godot/project.godot`.
3. Click **Import & Edit**.
4. Press the play button. Wait up to six seconds for data.
5. Click a card to show its details.

The source label says `LIVE`, `OFFLINE · LOCAL FALLBACK`, or `LOCAL · SAMPLE`.
Restart the demo to request fresh values.

## Base: edit the local JSON

1. In the **FileSystem** dock, double-click `scenes/main.tscn`.
2. In the **Scene** dock, select **DataSource**.
3. In the Inspector, open **1. Dataset** and disable **Use Live Data**.
4. Edit `data/fallback_parking.json` and save it.
5. Press play to run the project.

Re-enable **Use Live Data** when you want the REST request again.

Every local item has the same six fields:

```json
{
  "name": "Passo Sella",
  "value": 33,
  "capacity": 199,
  "unit": "free spaces",
  "status": "limited",
  "description": "33 of 199 parking spaces are free."
}
```

The bar height is `value / capacity`. The bundled sample uses `available`,
`limited`, and `full` as status text. The dashboard has six slots, so it shows
at most six items.

## Intermediate: change the card visually

1. In the **FileSystem** dock, double-click `scenes/data_card.tscn`.
2. Select the root **DataCard** node.
3. In **Quick Style**, change the direct **Available**, **Limited**, and **Full**
   color swatches. They control both the bar and status text.
4. For the background, expand **Background Material**, then change
   **Albedo > Color**.
5. Adjust **Maximum Bar Height**, save, and press play.

For small layout changes, select `NameLabel`, `ValueLabel`, or `StatusLabel` in
the Scene dock and change its position, font size, or color in the Inspector.
The scene contains the static layout; the script only inserts live text and bar
height at runtime.

## Run it on Meta Quest without controllers

Point with your **right hand** and pinch your thumb and index finger to select
a card. Controllers are not required.

Passthrough is configured to start with the XR session; there is no in-app
toggle.

### First-time Quest setup

1. Install the Godot 4.7 export templates from **Editor > Manage Export Templates**.
2. Follow Godot's [Android export setup](https://docs.godotengine.org/en/4.7/tutorials/export/exporting_for_android.html):
   install OpenJDK 17 and Android SDK, then set both paths in Godot.
3. Select **Project > Install Android Build Template** once. The OpenXR Vendors
   addon and runnable **Meta Quest** preset are already included.
4. Follow Meta's [device setup guide](https://developers.meta.com/horizon/documentation/native/android/mobile-device-setup/):
   enable Developer Mode, connect USB-C, and accept USB debugging in the headset.
5. Unlock the Quest and select its Android device button in Godot to run.

Keep hand tracking enabled on the headset, put the controllers down, and keep
your right hand visible to the headset cameras.

## Troubleshooting

- **My JSON changes do not appear:** select **DataSource** in `main.tscn` and
  disable **Use Live Data**.
- **The API always falls back:** check the URL, **Items Array Path**, and field
  paths. A wrong non-empty Capacity Path is treated as a mapping error.
- **My new color does not appear:** edit `scenes/data_card.tscn`, select its
  root **DataCard**, save, and run the project again.
- **Quest does not appear:** unlock it, check the USB data cable, and accept the
  debugging prompt inside the headset.
- **Pinch does not select:** enable hand tracking, put controllers down, use the
  right hand, and improve room lighting.
- **Passthrough does not appear:** it cannot be verified on desktop. Test the
  native build on a compatible headset.

## Verification and current limits

Verified with Godot 4.7: project import, desktop interaction, live and fallback
data, simulated right-hand selection, and Meta Quest debug APK export.

Still to verify on a physical headset: immediate passthrough, real hand pinch,
dashboard scale and readability. The project shows at most six cards and does
not refresh automatically.

## Use other datasets

Explore datasets on the [Open Data Hub API page](https://opendatahub.com/api/)
or in the [Data Browser](https://databrowser.opendatahub.com/).