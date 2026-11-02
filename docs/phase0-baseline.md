# Phase 0 baseline: culling in Photos.app

Goal: measure how long culling takes today, so Winnow's "70% less time" and "60 decisions per minute" targets have a real number to beat.

## Setup

- Use the **test user account** and its copy of the library, never your real library.
- Make three sets of 200 photos each as albums: `Baseline A`, `Baseline B`, `Baseline C`.
  Pick a mix: one recent phone roll, one older roll with bursts, one with lots of screenshots.
- Close other apps. Plug in the Mac.

## Each run

1. Open the album in Photos.app, select the first photo and start a stopwatch.
2. For every photo, decide **keep** (do nothing), **favorite** (`.`) or **delete** (`⌘⌫`).
   Use whatever keys and views you normally would.
3. Stop the stopwatch at the last photo. Don't empty Recently Deleted.
4. Write the row below.

| Run | Album | Photos | Minutes | Deleted | Favorited | Notes (what slowed you down) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Baseline A | 200 | | | | |
| 2 | Baseline B | 200 | | | | |
| 3 | Baseline C | 200 | | | | |

**Decisions per minute** = 200 ÷ minutes. Winnow's Alpha gate is 60, and its v1.0 goal is 70% less time than the average of these three runs.

After the runs, restore the deleted photos from Recently Deleted (select them, then Recover), so the same albums can be used again for the Beta comparison.
