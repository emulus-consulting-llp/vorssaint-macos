# AI usage prototype source reference

This directory preserves selected source files from the local `temp-ai-usage-bar`
prototype. It is a reference for the planned AI usage integration, **not a complete
or runnable application**, and is not included in the Vorssaint build.

Source commit: `11bacaeb35028a5807f35137dc37feb480873ff4`.
Snapshot made on 2026-10-12. It also preserves the local executable-bit change to
`Scripts/agy-status.py`. The manifest records content hashes, executable flags,
and omitted paths.

The original prototype README and source comments are historical reference, not
verified statements about current providers, macOS releases, or this fork.

## Deliberate omissions

- `Resources/*.png`: prototype artwork, including a mark extracted from an installed app.
- `Sources/AIUsageBar/LogoAssets.swift`: embeds that artwork as base64.
- `design/`: prototype design exports, including bundled runtime code.
- Nested Git metadata and build output.

The original `temp-ai-usage-bar` directory, including its nested temporary
workspace, was removed during cleanup on 2026-10-12 after verifying that all
20 preserved files matched this reference. The earlier temporary working folder
and its local backups were also removed. Cloning GitHub restores this selected
source reference, not the complete prototype or its deliberately omitted files.

Do not run the prototype's install scripts as part of fork setup. Implement the
desired behavior in the main app's existing AI usage services and UI. Use original
or appropriately licensed assets when the feature is developed.
