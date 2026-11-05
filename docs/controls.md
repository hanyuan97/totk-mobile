# Controls and settings

**English** | [简体中文](controls.zh-CN.md)

## Mac keyboard

| Action | Key |
| --- | --- |
| Move / camera | W A S D / I J K L |
| A / B / X / Y | X / Z / R / F (X confirms, Z goes back) |
| D-pad | Arrow keys |
| L / R, ZL / ZR | Q / E, Shift / Space |
| Inventory (+) / map (−) | Return / Tab |
| Left / right stick click | C / V |
| Control panel / performance overlay | ⌘, / ⌘P |
| Full screen | ⌃⌘F |

## Xbox controller

Xbox controllers connect automatically over Bluetooth or USB while the game window is in front. Menu (≡) is +, View is −. When the stick is deflected it takes priority over held keyboard keys. Rumble uses a curve calibrated for Xbox controllers.

## Control panel

Open it with ⌘, or **View → Controls**. Settings are saved to `work/settings.json` (override the path with `ZELDA_SETTINGS`).

The game language follows the system's preferred languages (Traditional Chinese, Simplified Chinese, Japanese, Korean, English, French, German, Italian, Spanish, Dutch or Russian; otherwise US English). To pick another one, quit the game and add `"language"` to `work/settings.json` with one of `ja`, `en-US`, `en-GB`, `fr`, `fr-CA`, `de`, `it`, `es`, `es-419`, `nl`, `ru`, `ko`, `zh-Hans`, `zh-Hant`.

| Setting | Values | Notes |
| --- | --- | --- |
| Frame rate | 30 / 60 / 90 FPS | Default 60. A target is not a guarantee; pre-rendered movies still play at 30 |
| Resolution | Original / 1080 / 720 / 640 | **Original** keeps the game's own dynamic resolution. Fixed modes render the scene at 1920×1080, 1280×720 or 1136×640 |
| Native | 1x / 1.5x / 2x | Draws the game's render targets at this multiple of the resolution above while the game still sees its own sizes (1080 at 2x = 3840×2160), so edges and distant detail come out sharper. GPU cost grows with the pixel count. Shadow maps and small blur targets stay 1x. Applies at once |
| MetalFX | Off / Window / 4K | Spatially upscales only the final image: **Window** to the window's pixel size, **4K** to 3840×2160 and then fitted to the window. Both apply only when the window has more pixels than the game image |
| Shaders | Background / Wait | Default **Background**: a shader or pipeline the game has not used before is prepared on other threads while the frame goes on without the draws that need it, so an effect seen for the first time can appear a few frames late instead of stalling the game. **Wait** keeps the earlier behavior. Also in **View → Compile New Shaders in Background** |
| Fullscreen, Sound, Performance | Off / On | Performance shows the overlay |
| Rumble | Off / On | Off stops rumble immediately; turning it back on does not replay old pulses. **Test** only checks the host output |
| Gyro aiming | Off / On | Default On. A controller with a gyro (DualSense, DualShock 4, Pro Controller) drives the game's motion sensor, so the game's own **Motion Controls** option (aiming the bow, the camera) works; the panel's controller line says whether the connected controller has one. Off stops the sensors and the game's sensor lies still. Saved as `"motion_controls"` |

Older settings files are migrated automatically: `896p`/`balanced` become Original, `performance` becomes 720, the removed `480p` becomes 640, an old MetalFX On becomes Window, and old rumble strengths read as On. Unknown fields are kept.

## Cheats

Atmosphère-format cheat files (the `.txt` files cheat sites share for a Switch) work on the Mac and the iPhone, with the engine taken from nxnative (see THIRD_PARTY_NOTICES.md). The file must be for this game's build: put `277178B7DBA1B6D4.txt` (update 1.4.3) in `work/cheats`; the Atmosphère tree (`atmosphere/contents/0100F2C0115B6000/cheats/…`) under that folder works too. `DM_CHEATS=<folder>` names another folder.

- **Mac:** the **Cheats** menu lists every cheat as a checkmark row (an on / off pair is one row), with **Cheats On** as the master switch, **Reload Cheats** after editing the file, and **Open Cheats Folder**. The choices are kept in `<build>.enabled` beside the file.
- **iPhone:** the settings sheet (gear button) has a Cheats section with the same switches. The folder is `work/cheats` in the app's Documents, which the Files app shows under On My iPhone. Cheats that change the game's code cannot run on the iPhone (its code pages are signed) and are shown off with that reason; cheats that change values work.
- A cheat that would overwrite an instruction this project rewrote to run the game on Apple hardware is refused and shown off with the reason (`script/cheat_words.py` lists those words), so it cannot crash the game that way.
- If the game stops while cheats are on, the next launch on the Mac starts with every cheat off; **Restore Saved Cheats** turns them back on.

## Startup screen

Until the game can draw without stalling, a startup screen covers the window with one progress bar that only moves forward. It shows the current stage: checking the shader libraries, compiling the ones that are missing (a long step on the first launch), starting the game, then loading the shaders and building the pipelines recorded on earlier runs. Stages with a counter show it, for example `Building pipelines 4,000 / 8,452`. The screen fades into the game when the warm-up ends.

## Performance overlay

The overlay (⌘P) shows FPS and target, render size, CPU, GPU time and memory. Its top-right corner shows the shader warm-up state: `Checking shaders`, `Shaders N%`, `Pipelines N%`, `Warming up` while the total is not yet known, and `Compiling shaders` when a new library or pipeline is created during play. The percentage refers to the current stage only.

## iPhone and iPad

The app opens on a launcher: the game's icon and Play on the left, the settings on the right (language, frame rate 30 or 60, render resolution, background shader compilation — see Shaders above — sound, controller rumble, gyro aiming, the performance panel and the iCloud Drive folder for cloud saves). The settings are saved in the app's `Documents/work/settings.json`, separate from the Mac; the language takes effect at the next start.

Gyro aiming uses the iPhone's own gyro, as a Switch held in handheld, while no hardware controller sends motion; a controller with a gyro takes over while it does. The game's **Motion Controls** option decides what the motion is used for.

Without a hardware controller, a virtual gamepad in Switch button positions is shown (adapted from nxnative, see THIRD_PARTY_NOTICES.md). The button at the top centre switches between two layouts and the choice is kept:

| Layout | Controls |
| --- | --- |
| 3D (the default) | Everything of 2D, plus a D-pad inward of and below the movement stick, L3 and R3 in the top row inward of ZL and ZR, and the camera stick: a touch landing in the right third of the screen on no key holds it, centred where it lands, and its centre follows the thumb once it passes the stick's radius |
| 2D | ZL above L in the top-left corner, ZR above R in the top-right, − and + at the top centre, the movement stick in the bottom-left corner (it appears where the thumb lands within a circle twice its size around its resting place, follows the thumb past the rim and returns to rest on release) and A B X Y in the bottom-right corner (A on the right); a thumb can roll from one key to the next |

The gear key right of + opens the same settings as the launcher (except the language and the cloud folder); changes apply at once. While a hardware controller is connected only the gear key remains.

The performance panel shows FPS and target; tap it to expand render size, app CPU, GPU time and physical memory. Auto-lock is suspended while the game is in front.
