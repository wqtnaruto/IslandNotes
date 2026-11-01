# IslandNotes clean-room record

This repository contains a new implementation that was developed in an isolated
`CleanRoom` directory before replacing the previous `NotchNotes` implementation.
The previous source, assets, vendored dependencies, and tests were removed from
the working tree when this rewrite became the repository's primary application.

## Permitted requirements inputs

- Publicly described product behaviour: a local macOS Markdown notebook that
  opens below the top-centre camera area, provides a file shelf, and can keep
  the Mac awake.
- Behaviour requested by the project owner after the initial import: named
  tabs, click activation, Markdown editing shortcuts, and a break reminder.
- Apple platform documentation and independently written tests in this
  repository.

## Excluded inputs

- Source code from the initial imported NotchNotes snapshot.
- Original icons, screenshots, website text, names, and other branding assets.
- Copying implementation structure, identifiers, comments, or tests from the
  initial imported snapshot.

## Implementation note

The rewrite uses only Apple system frameworks and has no third-party runtime
dependencies. `IslandNotes` is a temporary working name and can be replaced
before release.

This record documents engineering process; it is not a legal opinion or a
guarantee that a court would treat the work as a formal clean-room rewrite.
