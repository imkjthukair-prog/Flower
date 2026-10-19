# Flower · وردة

A macOS menu-bar file converter. Drag a file, hold a modifier key, and drop onto an option in the wheel.

- **Shift:** convert files; image options include JPEG, PNG, HEIC and PDF. Multiple images dropped onto PDF become one PDF.
- **Command:** AirDrop and supported compression.
- **Control:** additional file actions.

[Download Flower 0.2.4 for Apple Silicon](https://github.com/imkjthukair-prog/Flower/releases/download/v0.2.4/Flower-Friends.zip)

## Install

1. Download and unzip `Flower-Friends.zip`.
2. Move `Flower.app` into Applications, or your own `~/Applications` folder if you do not have administrator access.
3. Open Flower. It runs in the menu bar; a large app window does not need to stay open.
4. If macOS blocks this unrecognized app, review the source and release details. Only if you trust it, use the normal **System Settings → Privacy & Security → Open Anyway** flow and approve it yourself. Do not disable Gatekeeper or remove quarantine attributes.
5. Drag a disposable image in Finder, hold Shift, then drop it onto JPEG or PDF. Hold Command for AirDrop or Compress.

Quit other copies of Flower or the original Tangerine while using the modifier gestures. Outputs are saved beside their sources under unique names; the original files are preserved. AirDrop opens the native recipient picker, where you choose the recipient.

## Compatibility and release status

This is an experimental **0.2.4 pre-release for Apple Silicon Macs**. Intel Macs are not supported. The declared minimum is macOS 13, but testing was performed on macOS 27; older macOS releases have not been verified. Liquid Glass styling requires macOS 26 or later, with fallback styling on earlier versions.

This build is locally ad-hoc signed. It is **not Developer ID signed or notarized**. Downloading successfully is not proof that it will launch on every Mac. Conversion fidelity and format coverage have limits; review generated files before relying on them. PNG and HEIC compression preserve their formats, and an unchanged copy is saved if a smaller result is unavailable. Audio compression produces MP3.

## Source and resource origins

`Flower-Source.zip` contains the Swift source authored for this reconstruction, its build script, and installation/provenance documentation. It excludes bundled binary resources, local history, diagnostics, and personal files. Building it requires the Resources directory from the matching Flower app; see `BUILD.txt` inside the source ZIP.

Flower is an independently prepared reconstruction, not the original Tangerine source or an official Tangerine release. The supplied app retains some original-specific conversion helpers, templates, and feedback audio, as well as third-party components. These retain their original rights and licenses. **No blanket open-source or redistribution license is granted for the complete app or source package.** See `RESOURCE-PROVENANCE.txt` in the source ZIP and the notices retained in `Flower.app/Contents/Resources`. No independent public redistribution permission is asserted for original-specific assets or helper code.

## Verify the download

Expected SHA-256 of `Flower-Friends.zip`:

```text
840887adb7f0f1aab2727f1a180a2c2776d07bec846bdc407d3eb2a17042f6fd
```

Check it with `shasum -a 256 Flower-Friends.zip`. Release assets also include `SHA256SUMS.txt` and an installation prompt in `INSTALL-WITH-AI.txt`.
