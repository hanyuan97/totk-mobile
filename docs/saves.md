# Saves

**English** | [简体中文](saves.zh-CN.md)

## Where saves live

The active save directory is `work/save/` inside the project, not inside the app bundle. It has the same layout as the game's console save data (`slot_00/` … `slot_05/`, `option.sav`, album, picture book and `storage/`).

When the game mounts the save, the host clones it to `work/save.work/`. Each time the game commits, the complete working copy is published back to `work/save/` with an APFS clone and a directory swap, so `work/save/` always holds a complete, consistent snapshot. An uncommitted working copy left behind by a crash is discarded on the next mount. Writers hold the exclusive lock `work/save.lock`. The implementation is in `host/filesystem.c`.

> [!WARNING]
> Changes made to `work/save/` while the game is running are **not** merged; the game's next commit replaces them. Quit the game before you copy, import or edit saves, and do not point sync tools at this directory; use the built-in iCloud sync below instead.

## iCloud sync

The Mac and iPhone / iPad can share saves through iCloud Drive. No paid developer account is needed: the app writes to an ordinary iCloud Drive folder.

- **Mac:** when iCloud Drive is on, the game uses `iCloud Drive/Zelda-Mobile/` automatically. macOS may ask once for permission to access iCloud Drive. `ZELDA_CLOUD_SAVE=off` turns sync off; `ZELDA_CLOUD_SAVE=<folder>` uses a different folder.
- **iPhone / iPad:** the first launch asks you to choose a folder. Pick (or create) the same `Zelda-Mobile` folder in iCloud Drive. *Not Now* asks again on the next launch; *Don't Sync* stops asking. `./script/ios.sh launch --cloud-setup` brings the question back.

How it works (`host/cloud_save.m`):

- `work/save/` stays the live save and the transaction above is unchanged. Sync only ever reads a published snapshot or replaces the save while the game has not mounted it.
- Each device publishes its own `<device>.zmsave` (the whole save in one archive) and `<device>.json` (hash, device name, time and the history of saves it descends from). It never writes another device's files, so iCloud never has two writers for one file.
- A save is published 20 seconds after the game saves, when the window closes and when the iOS app goes to the background.
- At launch, before the game reads the save, a newer save from another device replaces the local one only when the local save has not changed since the last sync. The local save is first moved to `work/save-backups/<time>-before-icloud` (the newest 10 are kept).
- If both devices played since they last synced, the game asks which save to continue. The other save is not deleted: each device backs up its own copy before taking another device's save.
- Every archive is checked against its SHA-256 hash before it is used, so a half-downloaded file is never loaded. If iCloud has not delivered the save after 30 seconds, the game starts with the local save; any conflict is offered on a later launch.

Do not play on two devices at the same time. Sync cannot lock across devices, so you would be asked to choose between the two saves on the next launch.

## Back up

Quit the game, then copy the whole directory, for example:

```sh
mkdir -p work/save-backups
cp -Rc work/save "work/save-backups/$(date +%Y%m%d-%H%M%S)"
```

`cp -c` makes an APFS clone, which is instant and takes no extra space until files change.

## Import a save from your console

1. Export the *Tears of the Kingdom* save data from your own console with a save manager.
2. Quit the game and back up `work/save/` as shown above.
3. Keep the original export untouched, for example in `local/save-imports/` (ignored by Git).
4. Replace the contents of `work/save/` with a copy of the exported save directory.

Saves from earlier game versions load in v1.4.3; the game upgrades them itself. If you replace only a `progress.sav`, the matching caption and thumbnail stay old, so the save list may show the wrong place name until the game saves again.

## iPhone / iPad

With iCloud sync on, the device picks up the Mac save on its first launch, so no transfer is needed. Without it, `./script/ios.sh transfer seed` copies the Mac save to the device once. After that the device keeps its own independent copy and nothing is written back to the Mac. The transfer refuses to overwrite a different save that already exists on the device.
