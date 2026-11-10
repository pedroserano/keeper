<img src="Resources/AppIcon-1024.png" width="128" alt="Keeper icon: a photo with a sparkle">

# Keeper

**Keeper looks after your Apple Photos library.** It helps you work through a big library from the
keyboard: pick the photos worth keeping, find duplicates and photos that came out sideways, and work
out when and where old photos were taken. It also tidies your albums.

Keeper is a Mac app for Apple silicon. It works on your Photos library itself, so every change it
makes shows up in Photos and on your other devices. Nothing is deleted without your say-so, and
nearly everything can be undone.

## What it does

**Culling**
- **Go through your photos fast.** Rate, reject, favorite and hide from the keyboard, in a grid, one
  photo at a time, or side by side.
- **Suggested ratings.** Stars suggested from Photos' own quality scores. Once you've rated enough
  photos, Keeper learns which of those scores match your taste.
- **Suggested Rejects and Best Shots.** The photos Photos rates worst and best, to look at first.

**Cleaning up**
- **Duplicates and Similar Shots.** Near-identical copies and bursts of the same moment, grouped,
  with the best photo to keep picked by rules you set.
- **Sideways Photos.** Photos that look sideways or upside down, found on your Mac and turned with
  one key.

**Dates**
- **Undated Photos.** Finds photos without a real date, like scanned prints, and estimates when each
  was taken.
- The estimate comes from the people in the photo and their ages, look-alike photos, the camera,
  filenames and albums, events you confirm, and where the photo was taken.

**Places**
- **Places and Outings.** Guesses where photos without a location were taken, from photos taken
  around the same time.
- **Outings.** Photos from one camera taken close together, placed with one search.

**Albums**
- **Suggested Albums.** Albums made from trips: photos taken in one place over a few weeks.
- **Missing from Albums.** Photos that belong in an album you already have.
- **Album Duplicates.** Copies of the same photo in one album.

**Changes you control**
- Every new date or place waits in **To Apply** until you apply it.
- **History** puts back the date or place a photo had before.

## Install

Keeper needs a Mac with Apple silicon (M1 or later) running macOS 27.

### Download the app

1. Download `Keeper-<version>-arm64.zip` from the latest
   [release](https://github.com/pedroserano/keeper/releases/latest), unzip it, and move **Keeper.app**
   to Applications.
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

That builds **build/Keeper.app** for Apple silicon. If your Mac has a free "Apple Development"
certificate (add your Apple ID in Xcode › Settings › Accounts), the script signs with it, and Photos
and Full Disk Access stay granted across rebuilds. Otherwise it signs ad hoc, and macOS may ask again
after each rebuild.

## Using Keeper

Open Keeper and choose your library. It must be the System Photo Library, and Keeper tells you if it
isn't. After that, Keeper opens the same library straight away. File › Choose Library (⌘O) switches
libraries.

The sidebar has every list and tool. **To Apply** and **History** are at the top, then your library,
suggestions, look-alikes, orientation, places, dates and albums. Press **?** on any screen for its
shortcuts.

### The same keys everywhere

| Key | Does |
| --- | --- |
| ← → ↑ ↓ | Move between photos |
| Return, ⌘I | The photo's details |
| Space | Show the photo filling the window; Space again goes back |
| Esc | Back out one step: zoom, then the selection |
| G, ⌘-click, Shift-click, drag | Select photos. Shift-click on a selected photo deselects the run |
| ⌘A, ⇧⌘A | Select every photo shown on this screen; deselect them |
| 1–5, 0 | Star rating in Photos; 0 clears it. Works on the Dates and Places screens too |
| F | Favorite or unfavorite |
| R | Rotate 90° clockwise: the selected photos, or else the current one (asks first above 10) |
| A, N | Accept Keeper's suggestion; turn it down (Don't Show Again) |
| ⌘Z, ⇧⌘Z | Undo, redo: ratings, rotations and selections, on the screen you're on |

**Right-click any photo** for the same menu in the same order everywhere:
1. Select
2. Get Info
3. Show in Photos
4. Set Date…
5. Set Location…
6. Rotate
7. Hide or Don't Show Again

Each screen leaves out only what doesn't apply there. When the photo is one of several selected, the
menu acts on all of them.

Photos show ♥ for a Favorite, the star rating, RAW and a location mark in the same corners
everywhere. **Squares / Whole Photos** and the size slider in the toolbar change every grid.

### Culling

| Key | Does | In Photos |
| --- | --- | --- |
| X or ⌫ | Reject | Adds it to the "Keeper – Rejected" album |
| U | Clear a reject | Leaves the "Keeper – Rejected" album |
| H | Hide or unhide | Hidden |
| Z | 100% zoom on the main face | |
| C, K | Compare burst frames or nearby shots; keep the focused one and reject the rest | |
| I | Show Photos' own scores for the photo | |
| ⌘1, ⌘2, ⌘3 | Grid, one photo (double-click opens one too), compare | |

Decisions move on to the next photo by themselves. **Rejected** lists every photo you've rejected.
They're only deleted when you click **Delete Rejected**, which takes one batch and one macOS
confirmation. They then stay in Recently Deleted for 30 days.

**Date Range** shows only the photos taken between two days, for one trip or month at a time.
**Sort** orders a list by when photos were taken or added.

**Selecting photos.** In every list but Duplicates and Similar Shots, select photos for a step on all
of them. **Accept Suggested Ratings** gives the selected photos without stars their suggested rating
(A does one photo). Esc or a click beside the photos deselects them all.

### Suggested ratings

Every photo Photos has analysed gets a suggested star rating, shown next to "Unrated" until you rate
it.

1. **One score per photo.** Keeper reads Photos' own scores from the library's database (see
   [Permissions](#permissions)). By default that's Photos' **curation score**, or its overall aesthetic
   score where there's no curation score.
2. **Stars by rank in your library.** The bottom 10% of analysed photos get ★, the next 20% ★★, the
   middle 40% ★★★, the next 20% ★★★★ and the top 10% ★★★★★.
3. **Learning your taste.** Once you've rated at least 50 photos with at least three different star
   values, Keeper fits a model of which mix of ten of Photos' scores best predicts your stars. It's
   used only when it agrees with your ratings clearly better than curation alone.
   - **When it learns:** when a library opens, when you click **Learn from My Ratings**, and when you
     leave **Rate to Calibrate**. Rate to Calibrate lists 150 unrated photos from worst to best, so a
     short session teaches it the most.
   - **What it saves:** `~/Library/Application Support/Keeper/Reports/rating-calibration.csv` has the
     numbers, with no per-photo data.

The slider under Suggestions makes reject suggestions more conservative or more aggressive. It never
changes stars.

### Duplicates and Similar Shots

In the background, Keeper fingerprints photos taken within 30 seconds of another, using Apple's
Vision feature print, and groups the ones that look alike:
- **Duplicates:** near-identical copies with the same capture time, such as re-imports or edits saved
  twice.
- **Similar Shots:** takes of the same moment, burst frames included.

**Choosing the photo to keep.** The keeper rules in **Keeper › Settings (⌘,)** pick the photo to keep
in each group. They're a list you turn on, drag into order and point either way. Examples:
- Rejected
- Eyes closed
- Dimensions
- File type
- Quality score
- Favorite
- Rating
- Album

The first rule where a group's photos differ decides, and the group's header says which one. To keep
another photo, click **Keep** under it, or press K.

**Merging.** **Merge** keeps that photo and gives it the group's best rating, its Favorite and every
album the others were in. The others move to Rejected, and ⌘Z undoes a merge. ↑ ↓ move a group at a
time, and G selects the group.

### Sideways Photos

Keeper checks every photo once from a small local preview, newest first, and lists the ones that
look sideways or upside down. Each shows the turn it proposes and how sure it is (↻ 90° · 87%).
- **What you can do:** A rotates a photo the way proposed, and N leaves it as it is. To do many at
  once, select them and use the bar.
- **How it turns them:** rotating is an edit in Photos, so **Image › Revert to Original** brings the
  original back. Live Photos stay live.

Each photo is judged from these cues:
- **Faces:** tilted faces.
- **People:** body pose, checked all four ways up.
- **Text:** read all four ways up.
- **Scenes:** an image-recognition network trained to tell which way a photo is turned.
- **Neighbouring shots:** photos from the same moment.

On 400 photos of a real library at 50% confidence, it found 88% of sideways photos and flagged none
that weren't turned. **Minimum confidence** in the sidebar trades more finds for more false alarms.
The network is Duarte Barbosa's
[deep-image-orientation-detection](https://github.com/duartebarbosadev/deep-image-orientation-detection)
(MIT), converted to Core ML by `scripts/convert-orientation-net.py`.

### Dates

**Undated Photos** finds photos with no date, an impossible date or a camera's factory date, and
scans whose files carry no capture date. Each gets a guess ("Summer 1976") and a confidence.
**Why?** lists every clue behind the guess.

The clues:
- **The photo itself:** filenames and album names, file formats and camera models, colour and print
  borders, and scenes (Christmas, snow, the beach).
- **The people in it:** how old they look, and their birth years.
- **Related photos:** look-alike photos, and dated photos of the same scene.
- **Location:** for a photo with a location, dated photos taken nearby on the same trip.
- **What you tell it:**
  - **Events:** photos from one occasion, which share one date. Keeper suggests events from photos
    that look alike, show the same people, or were taken in the same place.
  - **People:** birth years, or birthdays from Contacts.
  - **Cameras:** the years you used each camera.

Select the guesses that are right (A selects one and moves on, ⌘A all shown), or set the date yourself
with ⌘D. Then **Apply** writes the dates through PhotoKit, the same as *Adjust Date and Time* in
Photos. The original file isn't rewritten.

### Places

**Places** guesses where photos without a location were taken, from photos taken around the same
time. It also uses photos from the same trip and photos you've already placed.
- Only guesses Keeper is fairly sure of are shown.
- Search Apple Maps to set a place yourself, or click the map.
- **Set by You** lists the places you chose.

**Outings** groups photos from one camera taken within a couple of hours of each other, so one search
places them all.

Places is the one part of Keeper that uses the internet. Place names, and what you type in its search
box, go to Apple Maps. Only coordinates are sent.

### To Apply and History

Every new date and place waits in **To Apply** before anything changes in Photos. That includes:
- photos selected in Undated Photos and Places;
- right-click **Set Date…** and **Set Location…** on any screen;
- a new date for an event or a new place for an outing;
- History's fix for photos whose date was changed in Photos.

To take a photo out, right-click it and choose **Leave Out**. **Apply** writes everything at once.

**History** lists every batch of dates and places applied, newest first, each with **Undo**. It also
finds photos whose date was changed in Photos after Keeper set it, so you can keep that date or set
another.

### Albums

- **Suggested Albums:** photos taken in one place over no more than 30 days, named like
  "2026-08 Hartford" (you can rename them). Photos without a location join when Places is sure where
  they were taken. Make Album adds the album to Photos.
- **Missing from Albums:** photos in no album, taken during an album's days near where its photos were
  taken. Add to Album adds them; Not in Album stops them being suggested again.
- **Album Duplicates:** albums holding two exact copies of a photo. Remove from Album takes the later
  copy out of that album only. No photo is ever deleted from the library, and Put Back returns it.

### Your data

Ratings, Favorites, dates, places and albums live in Photos. Keeper stores only its own data (rejects,
selections, scans, guesses and history) in `~/Library/Application Support/Keeper/`, one folder per
library.

**Keeper › Settings › Reset** starts over:
- **Scan Again** redoes the look-alike and orientation scans.
- **Reset This Library** forgets what Keeper stored for the open library.
- **Reset Keeper** removes all of Keeper's data and settings.

None of them changes Photos. The first time you open Dates, Keeper copies anything you'd done in
Photo Date Guesser, the app this part came from, and leaves that app's files as they are.

## Permissions

Keeper asks for two, plus Contacts if you use birthdays in Dates:

- **Photos** (PhotoKit): the photos themselves, their dates, places, Favorite, Hidden, ratings and
  albums. Every change Keeper makes goes through it, so Photos stays in charge of its library.
- **Full Disk Access:** to read the library's own database (`database/Photos.sqlite` inside the
  `.photoslibrary` package). Photos access doesn't cover reading files in it. Keeper opens the
  database read-only and never changes it. It holds:
  - Photos' quality scores, behind the suggestions;
  - faces (closed eyes, face quality);
  - file details (size, dimensions, RAW, keywords, title, caption);
  - every photo's date and location, which makes counting and scanning fast.

Without Full Disk Access you can still cull, rate, reject, favorite and rotate, and Sideways Photos
works. A banner says what's missing and opens the right System Settings pane.

## For development

Build the app with `./scripts/make-keeper-app.sh`, and run the tests with `swift test`.

The code is in these modules:
- **`Sources/Keeper`:** the app.
- **`Sources/KeeperUI`:** the keys, menu, bars and marks every screen shares.
- **`Sources/KeeperKit`:** decisions, their database, undo.
- **`Sources/KeeperCore`:** reading a library's own database.
- **`Sources/KeeperOrientation`:** the sideways-photo cues.
- **`Sources/DateGuessCore`:** date and place clues and combining them.
- **`Sources/DateGuesser`:** the Dates, Places and Albums screens.

Tests are in `Tests/`.

`keeper-scores` is a command-line front end to KeeperCore, used for automated tests:

```bash
swift run keeper-scores schema --library "PATH/TO/Library.photoslibrary"
```

## License

MIT. See [LICENSE](LICENSE). Two bundled models have their own licences:
- **The orientation network:** MIT, `Resources/OrientationNet-LICENSE.txt`.
- **The face-age model:** based on [MiVOLO v2](https://huggingface.co/iitolstykh/mivolo_v2) by Maksim
  Kuprashevich, Irina Tolstykh et al. It's licensed
  [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/), which means it's free for
  non-commercial use with credit. It isn't covered by Keeper's MIT licence. What was changed is listed
  in `Resources/FaceAge-NOTICE.txt`.
