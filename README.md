# Winnow

A personal, keyboard-first photo culling app for Apple Photos on Apple Silicon Macs.
The spec lives in the Winnow PRD v2 doc.

This repository is at **Phase 0**: two throwaway spikes and a baseline study that settle the open risks before the Alpha.

| Piece | Answers | Where |
| --- | --- | --- |
| `winnow-scores` | Which Photos.sqlite score columns exist on this macOS, and how closely Vision's scores agree with them | `Sources/WinnowScores` |
| Winnow Spike app | PhotoKit image load speed, Vision scoring speed, how a batch delete feels | `Sources/WinnowSpike` |
| Baseline study | How long culling takes in Photos.app today | `docs/phase0-baseline.md` |

## One-time setup

1. **Test user account.** In System Settings › Users & Groups, add a standard user (for example "Winnow Test").
   Log in to it, copy your library into its `~/Pictures` (or open a copy with Photos while holding ⌥),
   make it the System Photo Library (Photos › Settings › General), and leave iCloud Photos **off**.
2. **Signing.** In Xcode › Settings › Accounts, add your Apple ID. That creates a free "Apple Development"
   certificate. The build script picks it up automatically, so permissions survive rebuilds.
   Without it, builds are signed ad hoc and macOS may ask for Photos access again after each rebuild.
3. **Full Disk Access** for the score tool. Add the Terminal app you'll run it from in
   System Settings › Privacy & Security › Full Disk Access.

## Run the spikes (in the test account)

```bash
swift build -c release
```

Map the score columns (copies the database to a temp folder first; the library is never opened directly):

```bash
.build/release/winnow-scores schema
```

```bash
.build/release/winnow-scores export
```

Score photos with Vision. This writes `~/Documents/Winnow/out/vision-scores.csv`:

```bash
./scripts/make-spike-app.sh && open "build/Winnow Spike.app"
```

Compare the two rankings:

```bash
.build/release/winnow-scores compare out/photos-scores.csv out/vision-scores.csv
```

To try the batch delete, launch with deletes enabled. Do this **only in the test account**:

```bash
open "build/Winnow Spike.app" --args --allow-delete
```

Click photos to mark them, then press "Delete N rejected". macOS shows one confirmation for the whole batch.

## What to record for the Phase 0 gate

- The `schema` output and `out/score-schema-macos-*.json`: which columns exist on this macOS
- The Spike app's status line: photos per second, median load and score times
- The `compare` result: Spearman correlation and the bottom-20% overlap
- The three baseline runs from `docs/phase0-baseline.md`
