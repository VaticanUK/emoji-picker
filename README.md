# Emoji Picker

A macOS menu-bar emoji picker modelled on the Windows one. Press **Opt + `.`**, pick an emoji, kaomoji, symbol, GIF or earlier clipboard item, and it is pasted into the app you were typing in. The panel opens next to your text cursor.

## Installing a release

Needs macOS 14 (Sonoma) or later, on an Apple Silicon or Intel Mac.

1. Download the latest `EmojiPicker-<version>.zip` from the [Releases page](https://github.com/VaticanUK/emoji-picker/releases/latest) and double-click it to unzip.
2. Move **EmojiPicker.app** to your Applications folder.
3. Open it. macOS will say it can't verify the app, because releases are signed with this project's own certificate rather than a paid Apple Developer ID. Click **Done**, then open System Settings → Privacy & Security, scroll down to the message about EmojiPicker, click **Open Anyway** and confirm. (Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/EmojiPicker.app`.)
4. Carry on from [First launch](#6-first-launch).

**Updating:** quit Emoji Picker from its menu, replace the app in Applications with the new one, and open it. You'll need **Open Anyway** again for each new version, but the Accessibility permission carries over, because every release is signed with the same certificate.

A release and a copy you built yourself have different signatures, so if you switch between them, grant Accessibility again (see [Accessibility permission](#accessibility-permission)).

## Building from source

### Requirements

- macOS 14 (Sonoma) or later.
- A Swift 6.0 or newer toolchain. The free Xcode Command Line Tools are enough; full Xcode isn't needed.
- A free GIPHY API key, only if you want GIFs (see [GIFs and the GIPHY key](#gifs-and-the-giphy-key)).

There are no other dependencies. Everything builds with Swift Package Manager.

### 1. Install the Command Line Tools

```sh
xcode-select --install
```

Skip this if they're already installed. Check that the toolchain is Swift 6.0 or newer:

```sh
swift --version
```

If it reports an older version, update the Command Line Tools in System Settings → General → Software Update. If you have full Xcode installed, `sudo xcode-select -s /Applications/Xcode.app` makes its newer toolchain the active one.

### 2. Get the code

```sh
git clone https://github.com/VaticanUK/emoji-picker.git
cd emoji-picker
```

Run every command below from this folder.

### 3. Create a local signing identity (once per Mac)

```sh
Scripts/create-signing-identity.sh
```

This creates a self-signed code-signing certificate. It never asks for a password and needs no admin rights.

Why it matters: macOS ties the Accessibility permission (see below) to the app's signature. With this identity, every rebuild has the same signature and keeps the permission. If you skip this step, the build is signed ad hoc, the build script prints a `WARNING`, and you'd have to grant Accessibility again after every rebuild.

Details:
- The identity is kept in its own keychain (`~/Library/Keychains/emoji-picker-signing.keychain-db`), not your login keychain.
- That keychain has a random per-Mac password, stored next to it in a file only your account can read, and it locks itself after 5 minutes.
- The certificate is self-signed and only works for local builds.
- Like any signing key that works without a prompt, it can be used by other software running as your user, which could then claim the app's Accessibility permission. Treat it as you would any local developer signing key.

Running the script again is safe. It does nothing if the identity already exists.

### 4. Build

```sh
Scripts/make-app.sh release
```

This builds `build/EmojiPicker.app` for your Mac's architecture. The first build takes a minute or two.

It should end with `Built …/build/EmojiPicker.app` and no `WARNING` line. To confirm it's signed with your identity rather than ad hoc:

```sh
codesign -d -r- build/EmojiPicker.app
```

The output should include `certificate leaf = H"…"`. If it shows `cdhash` instead, the build was signed ad hoc: run step 3, then build again.

Without `release`, `make-app.sh` makes a debug build. Use debug builds for development: they also log how long the picker takes to open.

### 5. Install and launch

```sh
mv build/EmojiPicker.app /Applications/
open /Applications/EmojiPicker.app
```

The app has no Dock icon. Look for the smiley in the menu bar.

### 6. First launch

1. **Accessibility.** macOS asks you to allow Emoji Picker to control your computer. Accept, then switch **Emoji Picker** on in System Settings → Privacy & Security → Accessibility. The app needs this to find your text cursor and to paste for you. See [Accessibility permission](#accessibility-permission) if picking still only copies.
2. **Start at login.** On first launch the app registers itself to start at login. You can turn that off in Settings.
3. **GIPHY key** (optional). Open Settings from the menu-bar icon and paste your key. See [GIFs and the GIPHY key](#gifs-and-the-giphy-key).
4. **Try it.** Click in any text field, press **Opt + `.`**, type `thumbs` and press Return.

### Rebuilding and reinstalling

```sh
Scripts/make-app.sh release
osascript -e 'quit app "EmojiPicker"'   # or Quit Emoji Picker from the menu-bar menu
rm -rf /Applications/EmojiPicker.app
mv build/EmojiPicker.app /Applications/
open /Applications/EmojiPicker.app
```

Quit the running app first, and remove the old copy before moving the new one in: `mv` onto an existing app bundle puts the new one inside it instead of replacing it.

Because the signature stays the same, the Accessibility permission, your settings, recently used items and clipboard history all carry over.

### Uninstalling

```sh
osascript -e 'quit app "EmojiPicker"'
rm -rf /Applications/EmojiPicker.app
rm -rf ~/Library/Application\ Support/EmojiPicker        # history, recents, GIPHY key
defaults delete com.emojipicker.app                        # settings
tccutil reset Accessibility com.emojipicker.app            # Accessibility entry
security delete-keychain ~/Library/Keychains/emoji-picker-signing.keychain-db
rm -f ~/Library/Keychains/emoji-picker-signing.pass       # signing identity
```

If you'd turned on start at login, also remove Emoji Picker from System Settings → General → Login Items.

## Accessibility permission

The app needs Accessibility access to find your text cursor and to paste for you. A first-run window explains this and opens the right pane in System Settings (Privacy & Security, Accessibility). Switch Emoji Picker on there.

Without it the picker still opens, but picking only copies the item and shows "Copied, press ⌘V".

**Switched on but still only copying?** macOS ties the switch to the exact signature of the build it was granted to. An entry left over from an older build, for example one signed ad hoc before you ran `create-signing-identity.sh`, looks switched on but doesn't count. Reset it and grant again:

```sh
tccutil reset Accessibility com.emojipicker.app
```

Then quit and reopen the app, accept the request, and switch Emoji Picker on. While access is missing, the menu-bar menu shows "Grant Accessibility…". To see why a paste was skipped, run `/usr/bin/log stream --predicate 'subsystem == "com.emojipicker.app"' --level info`.

## GIFs and the GIPHY key

GIFs come from GIPHY. Each user supplies their own free API key:

1. Get a key at https://developers.giphy.com/dashboard/ (Settings has a "Get a free key" link).
2. Paste it into Settings. It's stored in `~/Library/Application Support/EmojiPicker/giphy-key`, readable only by your account. (Not the Keychain: a self-signed local build looks like a new app to the Keychain after every rebuild, so it would ask for your login keychain password each time.)

The free key allows about 100 calls an hour, which is plenty for one person. The default content rating is PG-13; change it in Settings.

GIFs are provided by GIPHY ("Powered by GIPHY" is shown in the GIF tab), and GIPHY's API terms apply to your use of the key.

### Quoted search

Words in quotes must all match. For example, `"cat dancing"` finds GIFs whose text contains both "cat" and "dancing", while `cat dancing` lets GIPHY rank loosely. Matching ignores case and punctuation. An unbalanced quote runs to the end of the query, and empty quotes are ignored. Quoted searches load up to 5 pages of results to find matches.

## Shortcut

The default is Opt + `.`; change it in Settings (it needs at least one modifier, and Shift alone is rejected). Trade-off: Opt + `.` normally types `≥`, and this shortcut hides that while the app runs. Pick a different shortcut if you type `≥` often.

## Keyboard

The picker works like the Windows 11 one: Tab moves focus between areas, and the arrow keys work inside the focused area.

- **Areas:** the Emoji tab has search, the grid and the category bar. The Kaomoji, Symbols, GIF and Clipboard tabs have search and the content. Tab and Shift-Tab cycle through them, wrapping around. The picker always opens with search focused.
- **⌃Tab / ⌃⇧Tab** switch between the top tabs. Clicking a tab icon also works.
- **Search:** typing edits the query and ←/→ move the text cursor. ↓ moves into the grid. Return inserts the highlighted item (dimmed while search is focused), which is the first result after typing.
- **Grid or list:** the arrow keys move the highlight, ↑ on the top row returns to search, and Return inserts.
- **Category bar:** ←/→ move between 🕘, the categories and the skin-tone button (shown with an accent highlight). Return or Space on a category jumps there and focuses the grid; on the skin-tone button it opens the swatches, where ←/→ choose, Return picks and Esc cancels. ↑ returns to the grid.
- **Anywhere:** typing a character or pressing Backspace goes to search. Esc closes the skin-tone swatches if they're open, otherwise the picker.

## Clipboard history

The Clipboard tab keeps your last 25 unpinned items (plus any you pin). Items that password managers and clipboard tools mark as concealed, transient or auto-generated (the nspasteboard.org markers, plus 1Password's, KeeWeb's and a few others) are skipped, as are the app's own writes. History is stored only on your Mac, in `~/Library/Application Support/EmojiPicker/clipboard/` (permissions 0700, excluded from Time Machine backups). "Clear clipboard history" in the menu-bar menu removes everything unpinned from memory and disk.

## Development

### Running the tests

```sh
swift test -j 1
```

`-j 1` builds one file at a time. With parallel jobs the Command Line Tools sometimes fail to load the Swift Testing plugin ("plugin for module 'TestingMacros' not found"). The tests use Swift Testing, which is available with the Command Line Tools; XCTest isn't.

### Project layout

- `Sources/PickerCore/`: logic with no UI, all covered by tests (emoji catalog and search, GIF search and the quoted-search filter, clipboard history, placement, keyboard focus).
- `Sources/EmojiPicker/`: the AppKit app (hotkey, panel, tabs, paste, Settings).
- `Tests/PickerCoreTests/`: Swift Testing tests.
- `Scripts/`: building, signing, releasing and data generation.
- `.github/workflows/`: the release workflow.

### Watching the logs

```sh
/usr/bin/log stream --predicate 'subsystem == "com.emojipicker.app"' --level info
```

This shows open times (debug builds), why a paste was skipped, and GIF errors. Use the full path: zsh has a built-in `log` command that shadows it.

### Making a release

Releases are built, signed and published by GitHub Actions (`.github/workflows/release.yml`) on a macOS runner. The app works on both Apple Silicon and Intel.

One-time setup:

1. Run `Scripts/create-release-certificate.sh`. It creates the release certificate in `~/emoji-picker-release-certificate/` and prints what to do next.
2. Add the two repository secrets it names, `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`, with the `gh secret set` commands it prints or in the repository's Settings → Secrets and variables → Actions.
3. Keep the certificate and its password somewhere safe, such as a password manager, then delete the folder. GitHub secrets can't be read back. Every release must use the same certificate, or people have to grant Accessibility again after updating.

To publish a release, tag a commit and push the tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow then runs the tests, builds and signs the app, checks the signature, and creates a GitHub release with `EmojiPicker-1.0.0.zip` and its SHA-256 checksum. The tag (without the `v`) becomes the app's version. Running the workflow by hand from the Actions tab does the same, but attaches the zip to the run instead of publishing a release.

To build the same way locally: `UNIVERSAL=1 APP_VERSION=1.0.0 Scripts/make-app.sh release`.

### Updating the emoji data

`Sources/PickerCore/Resources/emoji.json` is generated and committed, so builds never download anything. To regenerate it from newer Unicode and CLDR releases:

```sh
mkdir -p /tmp/emoji-src && cd /tmp/emoji-src
curl -LO https://unicode.org/Public/emoji/latest/emoji-test.txt
curl -L -o annotations.json https://raw.githubusercontent.com/unicode-org/cldr-json/<tag>/cldr-json/cldr-annotations-full/annotations/en/annotations.json
curl -L -o derived.json https://raw.githubusercontent.com/unicode-org/cldr-json/<tag>/cldr-json/cldr-annotations-derived-full/annotationsDerived/en/annotations.json
cd -
swift Scripts/generate-emoji.swift /tmp/emoji-src/emoji-test.txt /tmp/emoji-src/annotations.json /tmp/emoji-src/derived.json > Sources/PickerCore/Resources/emoji.json
```

Replace `<tag>` with a [cldr-json release tag](https://github.com/unicode-org/cldr-json/releases), and update the versions in `Scripts/generate-emoji.swift` and `THIRD_PARTY_NOTICES.md`. Emoji newer than the installed macOS emoji font are hidden automatically at runtime, so the data can safely run ahead of the OS.

## Troubleshooting

- **"Apple could not verify EmojiPicker is free of malware".** Expected for a downloaded release. See step 3 of [Installing a release](#installing-a-release).
- **The build prints `WARNING: ad-hoc signed`.** The signing identity is missing. Run `Scripts/create-signing-identity.sh`, then build again.
- **Picking only copies ("Copied, press ⌘V").** Accessibility access is missing or stale. See [Accessibility permission](#accessibility-permission).
- **Opt + `.` types `≥`.** The app isn't running, or another app has claimed the shortcut. Check the menu bar for the smiley. If the menu says "Shortcut unavailable", pick another shortcut in Settings.
- **The GIF tab says the key was rejected.** Check you used a GIPHY *API* key, not an SDK key, and that it's still active in the GIPHY dashboard.
- **The app crashed.** Crash reports are in `~/Library/Logs/DiagnosticReports/` (files starting `EmojiPicker-`). Include the newest one when reporting a bug.

## Data sources and licences

- Emoji names and keywords: Unicode emoji-test.txt and CLDR English annotations, under the Unicode License v3.
- GIFs: GIPHY (see above).

Full details and licence text are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
