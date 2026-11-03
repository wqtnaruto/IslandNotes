# IslandNotes

An independent macOS menu-bar notebook built around a compact top-centre panel.

The current milestone includes:

- a notch-connected panel with an embedded tab rail, reduced-motion-aware expansion, and a pin switch;
- dark, natural light, and system-following themes with Chinese interface text;
- top-centre click, hover, or file-drag activation;
- local multi-page Markdown notes with editable titles;
- a Markdown editor that renders inactive lines while keeping the source editable;
- a draggable file-reference shelf;
- an application-native screenshot picker with a persistent five-item recent history;
- a keep-awake switch;
- Markdown editing shortcuts (`Command-B`, `Command-I`, `Command-E`, `Command-K`, `Shift-Command-H`, `Shift-Command-L`);
- an optional focus countdown and break reminder that automatically reveals the panel when due; and
- a collapsed notch island capsule with a 2pt focus/keep-awake rim, compact countdown, pinned first-unchecked-task display, hover micro-expansion, and one-click task completion.

The visual target for the dark theme is `Design/island-notes-top-tabs-v3.png`.
The screenshot-history interaction is documented in `Design/island-notes-recent-screenshots-v1.png`.
Workspace data remains in the existing IslandNotes Application Support directory.

Use the camera button in the panel or press `Option-Command-2` to capture a region. Screenshots stay local and the oldest item is removed after the sixth successful capture.

## Run

```sh
swift run IslandNotes
```

## Test

```sh
swift test
```

## Package

```sh
./Scripts/package-app.sh
open dist.noindex/IslandNotes.app
```

The script creates an ad-hoc signed app and ZIP by default. Product metadata can
be changed without editing source:

```sh
PRODUCT_NAME="My App" BUNDLE_ID="com.example.myapp" VERSION="1.0.0" \
  ./Scripts/package-app.sh
```

Set `SIGN_IDENTITY` to a Developer ID Application identity for a distribution
build. Notarization is intentionally not automated yet.

The product name, icon, bundle identifier, and release packaging are deliberately
left for a later branding milestone.
