# IslandNotes

An independent macOS menu-bar notebook built around a compact top-centre panel.

The current milestone includes:

- a notch-connected panel with an embedded tab rail and reduced-motion-aware expansion;
- dark, natural light, and system-following themes with Chinese and English interface text;
- top-centre click or hover activation;
- local multi-page Markdown notes with editable titles;
- a Markdown editor that renders inactive lines while keeping the source editable;
- a draggable file-reference shelf;
- a keep-awake switch;
- Markdown editing shortcuts; and
- an optional focus countdown and break reminder.

The visual target for the dark theme is `Design/island-notes-top-tabs-v3.png`.
Workspace data remains in the existing IslandNotes Application Support directory.

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
