# Winnow

A personal, keyboard-first photo culling app for Apple Photos on Apple Silicon Macs.
The spec lives in the Winnow PRD v2 doc.

This repository is at **Phase 0**: a spike app and a baseline study that settle the open risks before the Alpha.

| Piece | Answers | Where |
| --- | --- | --- |
| Winnow Spike app | Which of Photos' own score columns exist on this macOS; how fast PhotoKit loads and Vision scores photos; how closely Vision agrees with Photos; how a batch delete feels | `Sources/WinnowSpike`, `Sources/WinnowCore` |
| Baseline study | How long culling takes in Photos.app today | `docs/phase0-baseline.md` |

## Using the spike app

Open **build/Winnow Spike.app** from Finder.

1. **Choose a library.** A window lists the Photos libraries on this Mac, like the one Photos shows when you hold ⌥.
   Use **Other Library…** to pick one it didn't find. You can switch any time with File › Choose Library (⌘O).
2. **Full Disk Access.** The first time, the app may say it can't read the library's database.
   Click **Open Privacy Settings**, add Winnow Spike, switch it on, and click **Try Again**.
   The app reads a temporary copy of the database and never changes your library.
3. **Score Columns…** lists the scores Apple Photos has stored for that library.
4. **Run** scores your most recent photos with Vision and compares the result with Photos' own score.
   This works only when the chosen library is the **System Photo Library**, because macOS only lets apps load
   photos from that one. If it isn't, the app says so and shows how to switch.
   Each run is saved to `Documents/Winnow/out/spike-run.csv`.
5. **Deleting** is off every time the app opens. Tick "Allow deleting (test library only)", click photos to mark
   them, then **Delete N Marked…**. There's one confirmation from Winnow and one from macOS, and the photos go
   to Recently Deleted for 30 days.

### Testing with a second library on this account

1. In Photos, choose File › New Library (or open Photos with ⌥ held) and make a library named something like
   "Winnow Test". Import a few hundred photos into it.
2. In that library, choose Photos › Settings › General › **Use as System Photo Library**. Leave iCloud Photos off.
3. In Winnow Spike, choose "Winnow Test". When you're done, switch your main library back to the system library the same way.

If your main library uses iCloud Photos, making another library the system one turns iCloud Photos off for it.
When you switch back, you have to turn it on again, and Photos re-checks the whole library against iCloud.

### Signing

Add your Apple ID in Xcode › Settings › Accounts to get a free "Apple Development" certificate. The build
signs with it automatically, so Photos and Full Disk Access permissions survive rebuilds. Without it, the app
is signed ad hoc, and macOS may ask for those permissions again after each rebuild.

## For development

The app is built from the Swift package:

```bash
./scripts/make-spike-app.sh
```

`winnow-scores` is a command-line front end to the same code, used for automated tests:

```bash
swift run winnow-scores schema --library "PATH/TO/Library.photoslibrary"
```
