<img src="Resources/AppIcon-1024.png" width="128" alt="Keeper icon: a photo with a sparkle">

# Keeper

A personal, keyboard-first photo culling app for Apple Photos on Apple Silicon Macs.
Keeper used to be called Winnow. The spec lives in the Winnow PRD v2 doc.

## Install

Keeper needs a Mac with Apple silicon (M1 or later) running macOS 27. There's no Intel version.

### Download the app

1. Download `Keeper-<version>-arm64.zip` from the latest
   [release](https://github.com/pedroserano/keeper/releases/latest), unzip it, and move **Keeper.app** to
   Applications.
2. Keeper isn't notarized (it's signed ad hoc), so macOS won't open it the first time. Open
   **System Settings › Privacy & Security** and click **Open Anyway** next to Keeper, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Keeper.app
   ```

3. Open Keeper and allow Photos access, then Full Disk Access when it asks (see
   [Permissions](#permissions)).

### Build from source

You need Xcode, or just its Command Line Tools, with Swift 6.

```bash
git clone https://github.com/pedroserano/keeper.git
```

```bash
cd keeper && ./scripts/make-keeper-app.sh
```

That builds a release version for Apple silicon at **build/Keeper.app**; move it to Applications or open it
from there. If your Mac has a free "Apple Development" certificate (add your Apple ID in Xcode › Settings ›
Accounts), the script signs with it, and Photos and Full Disk Access stay granted across rebuilds;
otherwise it signs ad hoc and macOS may ask again after each rebuild.

## Using Keeper

Open **Keeper**. Choose a library (it must be the System Photo Library; Keeper tells you if it isn't),
then pick a source in the sidebar and cull from the keyboard. After the first time, Keeper reopens the last
library straight away; the chooser comes back only if that library is gone (on a drive that isn't connected,
say), and File › Choose Library (⌘O) switches. Press **?** for every shortcut. Right-click any photo
for **Show in Photos**, which opens Photos with that photo selected.

| Key | Does | In Photos |
| --- | --- | --- |
| X or ⌫ | Reject | Adds it to the "Keeper – Rejected" album |
| U | Clear a reject | Leaves the "Keeper – Rejected" album |
| F | Favorite or unfavorite | Favorite |
| 1–5, 0 | Star rating, clear rating | Photos' own rating (macOS 27) |
| A, I | Accept the suggested rating (in Sideways Photos: rotate the way proposed); show Apple's scores for the photo | |
| N | In Sideways Photos: not sideways, leave it as it is | |
| H | Hide | Hides it |
| ← → ↑ ↓ | Move (decisions move on to the next photo automatically) | |
| Return, Esc | Grid ↔ single photo | |
| Space, Z | In the grid, Space shows the photo filling the window and Space again goes back; in a photo, 100% zoom on and off. Z zooms on the main face | |
| R | Rotate 90° clockwise | An edit in Photos: the original is kept, and Revert to Original restores it. ⌘Z rotates back |
| G | In Duplicates or Similar Shots: tick or untick the group, or all the groups selected with Shift ↑ ↓ or Shift-click. In other lists: select or deselect the photo | |
| C, K | Compare burst frames or nearby shots; keep the focused one and reject the rest | |
| ⌘A, Esc | Select every photo in the list; deselect them | |
| ⌘Z, ⇧⌘Z | Undo, redo | Reversed |

**Look-alikes.** In the background, Keeper fingerprints photos taken within 30 seconds of another
(Apple's Vision feature print) and groups the ones that look alike, in two lists: **Duplicates**
(near-identical copies with the same capture time: re-imports, edits saved twice) and **Similar Shots** (takes of the same moment). Every photo in a group looks
like every other one, and all were taken within a minute of each other; burst frames, however alike,
are similar shots. The photo to keep in each group is picked by rules. **Keeper › Settings… (⌘,)** holds the **keeper rules**: a list you
check, order (drag) and point either way, as in other duplicate finders. Each says which photos to
mark (not keep): Rejected, Eyes (closed), Dimensions, File Type (non RAW+HEIC), File Size, Quality
Score, Face Quality, Favorite, Rating, Album, Missing, Portrait, HDR, Live Photos, Keywords, Title,
Caption, Geo Location, Metadata, Referenced, File Name, Capture, Created and Modified Date. The first
checked rule where a group's photos differ picks the keeper; sizes within 5% count as the same, so
with the default order a RAW original wins when it's about as big as the biggest copy. The group
header says which rule decided. To keep a different photo,
click **Keep** under it (or select it and press K); your picks are saved with the library. Groups are listed one section at a time with each
photo's time, dimensions and file size; ↑ ↓ move a group at a time, G ticks or unticks the
group (ticks are saved); Shift ↑ ↓ or Shift-click selects several groups so G ticks or unticks them all, and C compares it.

**Selecting photos.** In every list but Duplicates and Similar Shots (which pick whole groups),
photos can be selected for a bulk step. **Accept Suggested Ratings** gives the selected photos that have no stars yet
their suggested rating in one step (A does it for one photo). Select them with ⌘A (every photo in the list),
the circle at a photo's top left, ⌘-click, Shift-click, G, or a click-and-drag across them (⌘ or Shift adds to
the selection); Shift-click on a selected photo deselects the run,
and Esc or a click in the space around the photos deselects them all. The bar with the button appears once photos are selected. Photos you've rated or rejected are left alone, the rated ones leave Unreviewed,
and ⌘Z undoes the lot. **Rejected**, in the sidebar, lists every photo you've rejected; there the
button is **Unreject Selected**.

### How suggested ratings are made

Every photo Photos has analysed gets a suggested star rating, shown in a grey capsule next to "Unrated"
until you rate it (A takes it, Accept Suggested Ratings takes it for a selection).

1. **One score per photo.** Keeper reads Photos' own scores from the library's database (see
   Permissions). By default the score is Photos' **curation score**, its estimate of how much a photo is
   worth showing, or its overall aesthetic score where there's no curation score.
2. **Stars by where the photo ranks in your library**, not by a fixed cut-off: the bottom 10% of analysed
   photos get ★, the next 20% ★★, the middle 40% ★★★, the next 20% ★★★★ and the top 10% ★★★★★.
   So the stars are relative to this library, and the same score can get different stars in another one.
3. **Learning your taste.** Once you've rated at least 50 photos in Photos (any app, any time) with at
   least three different star values, Keeper fits a model to them: which mix of ten of Photos' scores
   (overall, curation, failure, noise, blurriness, exposure, sharp subject, composition, lighting,
   tasteful blur) best predicts the stars you gave, using ridge regression. It's tested on ratings it
   wasn't fitted to (5-fold cross-validation, Spearman rank agreement), and used instead of the curation
   score only when it agrees with your ratings clearly better than curation alone. Step 2 then ranks
   photos by the model's prediction.

   It learns when a library opens, when you click **Learn from My Ratings** in the sidebar, and each time
   you leave **Rate to Calibrate**, which lists 150 unrated photos spread evenly from worst to best score,
   so a short session teaches it the most. The sidebar says which it's using and how well each agrees
   with you; `~/Library/Application Support/Keeper/Reports/rating-calibration.csv` has
   the numbers and the model's weights (no per-photo data).

Photos that Photos hasn't analysed yet (new imports, a library it hasn't processed) get no suggestion. The
aggressiveness slider below changes reject suggestions only, never stars.

**Reject suggestions** can be made more conservative or more aggressive with the slider under
Suggestions in the sidebar. While you drag, it previews how many photos would land in Suggested Rejects
and Best Shots. It moves every reject threshold and how much of the library Photos' curation protects;
stars don't change.

### Sideways photos

**Sideways Photos**, in the sidebar, lists photos that look sideways or upside down, each with the turn
Keeper proposes and how sure it is (↻ 90° · 87%), surest first. Select them and click **Rotate Selected**
(or press A for one photo), and each turns the way shown on it; ⌘Z turns them all back. **Not Sideways**
(N) leaves photos as they are, and they stop showing until they change.

In the background, after the look-alikes scan, Keeper checks every photo once from a small local preview
(nothing is downloaded), newest first. The first run on a big library takes hours. It shows its progress in
the sidebar, pauses when the Mac runs hot, and picks up where it left off; after that only new and changed
photos are checked. Screenshots, and photos Photos won't let an app edit, are skipped.

Each photo is judged from four cues, which vote on the turn that makes it upright:

- **Faces**: Vision finds faces at any angle and reports how far each is tilted. A face tilted about 90°
  means the photo needs a quarter turn. Faces are the strongest cue.
- **People**: body pose, checked all four ways up. The way where the neck is above the hips gets the credit.
- **Text**: checked all four ways up. The way with the most real dictionary words gets the credit, since
  Vision reads upside-down text as gibberish and can't read sideways text at all.
- **Scenes**: an image-recognition network (MobileNetV3) fine-tuned to tell which way a photo is turned,
  for landscapes, buildings and objects. Most photos in a library are upright, so it's weighed by realistic
  odds (90% upright, 4.5% each way sideways, 1% upside down). On photos it never saw in training, it found
  about half of the sideways ones with no upright photos wrongly flagged at 50% confidence; on its own it
  almost never proposes upside down, which faces, people and text still do.

The percentage is how clearly the cues agree, not the chance a proposal is right. **Minimum confidence**,
under Orientation in the sidebar (50% to start), shows fewer, surer proposals when raised, or more
sideways photos with a few false alarms when lowered.

Rotating is an edit in Photos, as with R: the original isn't touched, **Image › Revert to Original** in
Photos brings it back, and the photo keeps its date, place, albums, keywords and people. Live Photos stay
live.

The detection and the network come from ApplePhotosRotator, an app by the same author that does only
this.

**Date Range** in the sidebar shows only the photos taken between two days (or a quick pick like Last
Year), for culling one trip or month at a time.

**Merge** a group (or Select All, then Merge Selected) and the kept photo gets the group's best rating,
its Favorite and every album the others were in, like Photos' own duplicate merge. The others move to
Rejected, and merged groups leave the list. Nothing is deleted until you use Delete Rejected; ⌘Z
undoes a merge. The first run on a big library takes a while, shows its progress in
the sidebar, and picks up where it left off; after that only new photos are fingerprinted.

Rejected photos are only deleted when you click **Delete Rejected** in the toolbar: one batch, one macOS
confirmation, and they go to Recently Deleted for 30 days.

Ratings and Favorites live in Photos. Keeper stores only its own data (rejects, where you were, scans) in
`~/Library/Application Support/Keeper/`, one database per library. **Keeper › Settings › Reset** starts over:
**Scan Again** redoes the look-alike and orientation scans, **Reset This Library** forgets everything Keeper
stored for the open library, and **Reset Keeper** removes all its data and settings. None of them changes
Photos. Coming from Winnow, the first launch moves its data and settings over and renames the
"Winnow – Rejected" album to "Keeper – Rejected".

Code: `Sources/Keeper` (the app), `Sources/KeeperOrientation` (the sideways-photo cues; the network is
`Resources/OrientationNet.mlpackage`), `Sources/KeeperKit` (decisions, their database, undo; unit-tested in
`Tests/KeeperKitTests`), `Sources/KeeperCore` (reading a library's own database).

### Permissions

Keeper asks for two:

- **Photos** (PhotoKit): the photos themselves, their dates, Favorite, Hidden, ratings and albums, and
  writing your decisions back. Everything Keeper changes goes through this, so Photos stays in charge of
  its library.
- **Full Disk Access**: to read the library's own database (`database/Photos.sqlite` inside the
  `.photoslibrary` package). macOS protects that package, and Photos access doesn't cover reading files in
  it. The database holds what PhotoKit doesn't share:
  - Photos' quality scores (aesthetic, curation, blur, exposure, noise…), behind Suggested Rejects, Best
    Shots, the star suggestions and the Quality Score keeper rule;
  - faces: closed eyes and face quality;
  - file details: original size and dimensions, file type (the RAW tag), keywords, title, caption, and
    whether the original is on this Mac, which most keeper rules use;
  - which library is the System Photo Library, checked when you open one.

  Keeper opens it read-only and never changes it.

Without Full Disk Access you can still cull, rate, reject, favorite and rotate, and Sideways Photos works in full (it needs only Photos access); a banner says what's missing
and opens the right System Settings pane. Suggestions and the file details are missing, and Duplicates and
Similar Shots still find look-alikes but have little for their keeper rules to go on. Granting it later and
reopening the library brings them back.

## For development

Build the app with `./scripts/make-keeper-app.sh`, and run the unit tests with `swift test`.

`keeper-scores` is a command-line front end to KeeperCore, used for automated tests:

```bash
swift run keeper-scores schema --library "PATH/TO/Library.photoslibrary"
```

## License

MIT. See [LICENSE](LICENSE).
