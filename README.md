# MiniSheet

> **Status: alpha.** MiniSheet is early software: expect rough edges and keep backups of important files. Releases are published as GitHub *pre-releases* (`alpha` → `beta` → `rc`), and the app updates itself between them.

A small, fast spreadsheet app for macOS for opening, reading and quickly editing CSV and Excel files. It works much like Google Sheets or Excel, without the weight.

Everything runs on your Mac. Files never leave your computer, and the only network request MiniSheet makes is an optional daily check for updates against this repository.

## Install with one command

```bash
curl -fsSL https://raw.githubusercontent.com/aibyos/minisheet/main/install.sh | bash
```

This downloads the newest release, installs it into Applications and opens it, with no extra confirmation step. Run the same command again at any time to update.

| Variant | Command |
|---|---|
| Build from source instead | `curl -fsSL https://raw.githubusercontent.com/aibyos/minisheet/main/install.sh \| bash -s -- --build` |
| A specific version | `… \| bash -s -- --version 0.1.0-alpha.1` |
| Uninstall (app + settings) | `… \| bash -s -- --uninstall` |

## Download manually

1. Go to [**Releases**](https://github.com/aibyos/minisheet/releases), open the newest release, and download **`MiniSheet-macOS.zip`**.
2. Unzip it and drag **MiniSheet.app** into your **Applications** folder.
3. **Confirm the first launch.** MiniSheet is distributed directly rather than through the Mac App Store, so macOS asks you to approve it once:
   - Open MiniSheet, then click **Done** in the dialog that appears.
   - Go to **System Settings → Privacy & Security** and click **Open Anyway** next to *"MiniSheet was blocked…"*.
   - Confirm with your password or Touch ID. Later launches and in-app updates open normally.

Requires macOS 12 or later. Runs on both Apple Silicon and Intel Macs.

**Updates** install from inside the app: **MiniSheet → Check for Updates…**, or automatically once a day if that's turned on in Settings.

**To make MiniSheet your default for a file type:** right-click a `.csv` or `.xlsx` file in Finder, choose **Get Info**, set **Open with** to MiniSheet, and click **Change All…**

## What it does

- **Files:** opens `.csv`, `.tsv`, `.xlsx`, `.xlsm` and `.xls`, and saves back to the same file with ⌘S. Macros in `.xlsm` files are kept.
- **Tabs:** each file gets a compact tab. Drag tabs to reorder them, and hover over a shortened tab to see the full file name.
- **Spreadsheet basics:** keyboard navigation, in-cell editing, copy and paste to and from Excel or Sheets, the fill handle, undo and redo, sorting, find, freezing the first row, multiple sheets, and a sum, average and count of the selected cells in the status bar.
- **Formulas:** `SUM`, `AVERAGE`, `COUNTIF`, `SUMIF`, `VLOOKUP`, `INDEX`/`MATCH`, `IF`, `IFERROR`, text functions and more. Click cells while typing a formula to insert their references.
- **Excel formatting is displayed:** fills, fonts, borders, number formats, merged cells and theme colours.
- **Notes and threaded comments** from Excel files show in hover popups and in a side panel.
- **Settings (⌘,):** appearance (System, Light or Dark), whether files open in a new tab or a new window, default zoom, freezing the first row on open, and automatic updates.

### Limitations

- Excel formatting is shown but not saved. Saving writes your data, formulas, comments and macros, without the formatting, and MiniSheet asks before it does so.
- Row heights, wrapped text, conditional formatting and charts aren't shown.
- `.xls` files can be opened, but they're saved as `.xlsx`.

## Build it yourself

You only need Apple's free command-line tools (`xcode-select --install`) or Xcode. No Docker or other containers are needed: macOS apps can only be built on macOS, and the build has no other dependencies.

The quickest route is the one-command installer with `--build` (see above). From a clone:

```bash
git clone https://github.com/aibyos/minisheet.git
cd minisheet
macos/build.sh            # builds for this Mac and installs to ~/Applications/MiniSheet.app
macos/build.sh --dist     # universal (Apple Silicon + Intel) build, zipped into build/
```

An app you build on your own Mac opens without the first-launch confirmation.

### How it's put together

| Path | What it is |
|---|---|
| `web/index.html` | The whole spreadsheet: grid, formula engine, Excel import/export and UI, as one self-contained page. You can also open it directly in a browser. |
| `web/xlsx.full.min.js` | [SheetJS](https://github.com/SheetJS/sheetjs), which reads and writes Excel files (Apache-2.0). |
| `macos/main.swift` | The native app: windows, tabs, menus, Settings, file open/save and the updater. It hosts the page in WebKit. |
| `macos/build.sh` | Compiles the Swift code and assembles `MiniSheet.app`. |
| `install.sh` | The one-command installer. It downloads a release or builds from source, and can also uninstall. |
| `.github/workflows/build.yml` | CI. It builds every push, and publishes a release when a version tag such as `v0.1.0-alpha.2` is pushed. |

### Releasing a new version

MiniSheet uses [semantic versions](https://semver.org) with pre-release labels while it matures:
`0.1.0-alpha.1` → `0.1.0-alpha.2` → … → `0.1.0-beta.1` → `0.1.0-rc.1` → `0.1.0`.

1. Set `CFBundleShortVersionString` in `macos/Info.plist` to the new version (e.g. `0.1.0-alpha.2`).
2. Commit, then tag and push:

   ```bash
   git tag v0.1.0-alpha.2 && git push origin v0.1.0-alpha.2
   ```

   The workflow builds the universal app and publishes the release. Tags with a `-alpha`, `-beta` or `-rc` suffix are marked as pre-releases. Installed copies pick the release up through the updater.

## License

MIT. See [LICENSE](LICENSE). Bundled third-party code is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
