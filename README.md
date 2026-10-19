# NuvioFontManager (experimental)

A TrollStore/TrollFools-oriented arm64 tweak build for Nuvio iOS. The workflow builds a dylib, injects it into the downloaded Nuvio IPA, and publishes the IPA and dylib as GitHub Actions artifacts.

## Current scope

- Adds a floating `Aa` button to open Font Manager.
- Separate **Video** and **Interface** pages.
- Imports `.ttf`, `.otf`, and `.ttc` files through the iOS document picker and stores them under the app's Documents/NuvioFontManager folder.
- Video font selection attempts to hook `mpv_create`/`mpv_initialize` and set MPV's `sub-font` property.
- Interface font selection hooks UIKit's `UIFont` system/bold font factories.

## Important limitations

This is an experimental first build, not a claim that every Nuvio text element is covered. Nuvio 0.6.2 uses Compose/Skiko for much of its interface, so UIKit `UIFont` hooks do **not** guarantee that Compose-rendered text changes. A proper full interface-font implementation needs a verified hook in the exact Compose/Skiko font creation path for the targeted Nuvio build. Video-font application also depends on the MPV symbols being imported through rebinding and on the player's support for changing `sub-font` at runtime.

The workflow automatically downloads the first IPA URL listed in the repository's `cmp-rewrite/store.json`; no IPA upload or manual URL input is required. The URL must provide a valid IPA compatible with the injection script.

## Build

1. Fork/copy this directory into a GitHub repository.
2. Commit `Tweak.m`, `inject.py`, and `.github/workflows/build-nuvio-font-manager.yml`.
3. Open **Actions → Build Nuvio with Font Manager → Run workflow**.
4. Wait for the workflow to download the IPA, compile the dylib, inject it, and package the result.
5. Download the `Nuvio-FontManager.ipa` artifact.
6. Install with TrollStore. Keep the original IPA so you can revert if the injected app crashes.

The workflow removes the app's old `_CodeSignature` and does not sign the full IPA; TrollStore handles installation of the modified package.
