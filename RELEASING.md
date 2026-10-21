# Publishing a version

Releases are built and signed locally. Private signing credentials stay on the
maintainer's machine; they are not committed or uploaded as release assets.

1. Choose a new visible version, such as `v1.02`. Update `pubspec.yaml` to a
   valid semantic version with an increased Android build code. Update Android
   `versionName` in `android/app/build.gradle.kts`, the About/footer labels in
   `lib/main.dart`, the README version/download link and `CHANGELOG.md`.
2. Write `release-notes/v1.02.md`, describing the actual changes, checks and
   limitations for that version. Keep older release notes and changelog entries.
3. Run application checks and relevant document/device checks. Build a signed
   release using the same private signing certificate as earlier versions.
   See the README release-signing instructions. Keep build symbols privately.
4. Commit and push the exact source used to build the APK to `main`.
5. With Python 3, Android SDK build tools and Git available, publish it:

```sh
python tool/publish_release.py --tag v1.02 --apk /path/to/app-release.apk --notes release-notes/v1.02.md
```

Use `--verify-only` first to check the package, app label, visible version,
Android build number, signing certificate, offline permission and 16 KB ZIP
alignment. The publisher certificate fingerprint is public; no private key is
embedded in this tool. Forks must change the repository destination and use
their own certificate fingerprint.

Authentication uses an existing Git credential helper or `GITHUB_TOKEN` set
locally with release write access. Never put a token in a command argument,
source file or commit. On Windows, the SDK can be found from `ANDROID_SDK_ROOT`,
`ANDROID_HOME`, local Android configuration or the usual installed SDK location.
Set `JAVA_HOME` to the Java runtime used for Android builds when needed.

The tool creates a draft for the exact pushed source commit, uploads the APK
and `SHA256SUMS.txt`, then publishes the release and marks it latest. It refuses
to overwrite an existing version. If an upload fails, the draft remains for
inspection/recovery; nothing is published until both uploads complete.

GitHub automatically provides source archives for the release tag. Every old
release keeps its APK, checksum and update notes. The README's **All versions**
link opens the full history; **Latest release** opens the newest release.

## Smaller downloads

Also build architecture-specific APKs for each release:

```sh
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=work/release-symbols
```

The Android Gradle configuration sets `force-version-code-ignoring-abi=true`,
so all variants use the same incrementing Android build number. This avoids an
architecture-based version-code multiplier preventing later universal updates.
Verify the produced APKs' package, version, certificate and native-library ABI.

Publish the universal and smaller APKs together (replace the sample version):

```sh
python tool/publish_release.py --tag v1.02 --apk /path/universal.apk --notes release-notes/v1.02.md --variant arm64-v8a=/path/arm64.apk --variant armeabi-v7a=/path/armv7.apk
```

The tool checks every variant's package, version, build number, signature,
alignment and native architecture before creating the draft. All APK hashes
are recorded in the release's `SHA256SUMS.txt`. Explain device choices and sizes
at the top of the release notes and in the README.
These variants retain the same features and offline resources; no Lite-mode
feature removal is involved. Existing release downloads remain available.

## Reader regression checks

Run the application and vendored Office Flutter test suites and Android integration scenarios before publishing. The v1.03 scenarios exercise EPUB positions/display settings, PDF contents/internal links, folder/tag persistence and actual raster-page Sinhala/English OCR. Repeat the v1.02 Office/text/search scenarios when changing those engines.

For JavaScript chart/format checks, install `@xmldom/xmldom` into an ignored local test directory, set `NODE_PATH` to that directory's `node_modules`, then run `node test/office_reader_extras.cjs`. This package is test-only and is not shipped in the Android app.

Verify a signed v1.02-to-v1.03 update without uninstalling: preserve document bytes, bookmarks/favorites and reading state. Never clear user data on a connected phone for this check. Record physical-device coverage separately from emulator results.
