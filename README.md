<img src="Resources/AppIcon-1024.png" width="128" alt="Winnow icon: a smiling grain of wheat in front of two photos">

# Winnow

A personal, keyboard-first photo culling app for Apple Photos on Apple Silicon Macs.
The spec lives in the Winnow PRD v2 doc.

## Winnow (Alpha)

Open **build/Winnow.app**. Choose a library (it must be the System Photo Library; Winnow tells you if it isn't),
then pick a source in the sidebar and cull from the keyboard. Press **?** for every shortcut. Right-click any photo
for **Show in Photos**, which opens Photos with that photo selected.

| Key | Does | In Photos |
| --- | --- | --- |
| X or ⌫ | Reject | Adds it to the "Winnow – Rejected" album |
| U | Clear a reject | Leaves the "Winnow – Rejected" album |
| F | Favorite or unfavorite | Favorite |
| 1–5, 0 | Star rating, clear rating | Photos' own rating (macOS 27) |
| A, I | Accept the suggested rating; show Apple's scores for the photo | |
| H | Hide | Hides it |
| ← → ↑ ↓ | Move (decisions move on to the next photo automatically) | |
| Return, Esc | Grid ↔ single photo | |
| Space, Z | In the grid, Space shows the photo filling the window and Space again goes back; in a photo, 100% zoom on and off. Z zooms on the main face | |
| R | Rotate 90° clockwise | An edit in Photos: the original is kept, and Revert to Original restores it. ⌘Z rotates back |
| G | In Duplicates or Similar Shots: tick or untick the group, or all the groups selected with Shift ↑ ↓ or Shift-click. In Unreviewed: select or deselect the photo | |
| C, K | Compare burst frames or nearby shots; keep the focused one and reject the rest | |
| ⌘Z, ⇧⌘Z | Undo, redo | Reversed |

**Look-alikes.** In the background, Winnow fingerprints photos taken within 30 seconds of another
(Apple's Vision feature print) and groups the ones that look alike, in two lists: **Duplicates**
(near-identical copies with the same capture time: re-imports, edits saved twice) and **Similar Shots** (takes of the same moment). Every photo in a group looks
like every other one, and all were taken within a minute of each other; burst frames, however alike,
are similar shots. The suggested keeper leans
towards the bigger file: for duplicates it's the largest copy (most pixels, then biggest file); for
similar shots, file size counts twice as much as how good the photo looks, faces count as much as looks
(Photos' own face quality), and a take where someone's eyes are closed is never suggested while another
take has them open; it gets an "Eyes closed" label instead. To keep a different photo,
click **Keep** under it (or select it and press K); your picks are saved with the library. Groups are listed one section at a time with each
photo's time, dimensions and file size; ↑ ↓ move a group at a time, G ticks or unticks the
group (ticks are saved); Shift ↑ ↓ or Shift-click selects several groups so G ticks or unticks them all, and C compares it.

**Accept Suggested Ratings**, above Unreviewed, gives the selected photos that have no stars yet
their suggested rating in one step (A does it for one photo). Select them with Select All, the circle at a
photo's top left, ⌘-click, Shift-click or G; Shift-click on a selected photo deselects the run. Photos you've rated or rejected are left alone, the rated ones leave Unreviewed,
and ⌘Z undoes the lot.

**Reject suggestions** can be made more conservative or more aggressive with the slider under
Suggestions in the sidebar. While you drag, it previews how many photos would land in Suggested Rejects
and Best Shots. It moves every reject threshold and how much of the library Photos' curation protects;
stars don't change.

**Date Range** in the sidebar shows only the photos taken between two days (or a quick pick like Last
Year), for culling one trip or month at a time.

If macOS won't let Winnow read the library's database (it needs Full Disk Access for Apple's scores,
file sizes and faces), a banner says what's missing and opens the right System Settings pane.

**Merge** a group (or Select All, then Merge Selected) and the kept photo gets the group's best rating,
its Favorite and every album the others were in, like Photos' own duplicate merge. The others move to
Rejected, and merged groups leave the list. Nothing is deleted until you use Delete Rejected; ⌘Z
undoes a merge. The first run on a big library takes a while, shows its progress in
the sidebar, and picks up where it left off; after that only new photos are fingerprinted.

Rejected photos are only deleted when you click **Delete Rejected** in the toolbar: one batch, one macOS
confirmation, and they go to Recently Deleted for 30 days.

Ratings and Favorites live in Photos. Winnow keeps only its own data (rejects, where you were) in
`~/Library/Application Support/Winnow/`, one database per library.

Code: `Sources/Winnow` (the app), `Sources/WinnowKit` (decisions, their database, undo; unit-tested in
`Tests/WinnowKitTests`), `Sources/WinnowCore` (reading a library's own database).

## Phase 0 spike

The spike app answers which of Photos' own score columns exist on this macOS, how fast PhotoKit loads and
Vision scores photos, how closely Vision agrees with Photos, and how a batch delete feels. Its interface is
deliberately rough. Code: `Sources/WinnowSpike`.

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

Build either app with `./scripts/make-winnow-app.sh` or `./scripts/make-spike-app.sh`, and run the unit tests with `swift test`.

`winnow-scores` is a command-line front end to WinnowCore, used for automated tests:

```bash
swift run winnow-scores schema --library "PATH/TO/Library.photoslibrary"
```

## License

MIT. See [LICENSE](LICENSE).
