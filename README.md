# FreeRot

A Flutter app for watching vertical short dramas: browse and search series, a TikTok-style vertical episode player, and a personal My List with watch history.

## Features

- **Home**: Continue Watching, Trending, category chips and an infinite series grid.
- **Search**: debounced search with recent searches.
- **Series detail**: synopsis, episode grid, Play / Continue, add to My List.
- **Player**: vertical pager with HLS playback (ExoPlayer on Android), a three-player pool with preloading, and the screen kept awake while watching.
- **My List**: saved series and history with progress bars, stored on the device.

## Build

Flutter lives at `~/development/flutter` and isn't on `PATH` by default:

```sh
export PATH="$HOME/development/flutter/bin:$PATH"
flutter pub get
flutter run                          # on a connected device or emulator
flutter build apk --release          # fat APK (all ABIs)
flutter build apk --split-per-abi    # smaller per-ABI APKs
```

Release builds are currently signed with the Flutter debug key, which is fine for sideloading but not for a store.

## Tests

```sh
flutter test                 # parser and library tests
LIVE=1 flutter test          # also runs the live network smoke tests
```

## Layout

- `lib/data/`: API client, parsers, request encryption and on-device library storage.
- `lib/ui/`: shell (bottom navigation), home, search, detail, player and My List screens.
- `test/`: unit tests with saved fixtures, plus opt-in live tests.
- `probes/`: research notes and Python clients for other drama sources.
- `branding/` and `assets/`: FreeRot logo and wordmark.
- `API_NOTES.md`: how the content API works.

Android package: `app.freerot`.
