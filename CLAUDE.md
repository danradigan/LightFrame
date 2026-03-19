# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

This is a macOS SwiftUI app (Swift 5, macOS 26.2+). Open `LightFrame.xcodeproj` in Xcode or build from CLI:

```bash
xcodebuild -project LightFrame.xcodeproj -scheme LightFrame -configuration Debug build
```

There are no tests, no linter, and no package manager dependencies.

## Architecture

**Single-AppState MVVM.** `AppState` is a `@MainActor ObservableObject` injected as `EnvironmentObject` into all views. It is the sole source of truth for collections, TVs, selections, filters, and upload state. It persists to `~/Library/Application Support/LightFrame/appstate.json`.

### Samsung TV Communication Stack

```
TVConnectionManager  (@MainActor, bridges UI ↔ network)
  └─ SamsungArtService  (high-level: upload, delete, slideshow)
      └─ SamsungConnection  (actor — WebSocket lifecycle, NOT @MainActor)
          ├─ WSS :8002 samsung.remote.control  (pairing/token, opened once)
          └─ WSS :8002 com.samsung.art-app     (persistent art channel)
```

- **SamsungArtProtocol** — builds the double-encoded JSON envelopes Samsung expects (JSON inside a string inside JSON)
- **SamsungArtParser** — parses responses, matches by UUID
- **TVDiscovery** — scans subnet port 8001 REST for `FrameTVSupport="true"`
- Samsung TVs use self-signed certs; `SSLBypassDelegate` handles this

### Key Invariant: selectedTV

`AppState.selectedTV` must **only** be written when the user explicitly picks a TV (plus load/add/remove). `TVConnectionManager` observes `$selectedTV` to switch connections — writing it for reachability updates causes a reconnect loop. `updateReachability()` mutates the `tvs[]` array instead.

### Photo Pipeline

- **PhotoScanner** — concurrent folder scan → reads EXIF mattes, pixel dimensions, generates ~30KB thumbnails
- **EXIFManager** — reads/writes matte tags to JPEG `ImageDescription` EXIF field (survives Lightroom edits)
- **UploadEngine** — sequential uploads (TV handles one command at a time), with duplicate detection, matte fallback on rejection, cancellation
- **SyncStore** — per-TV JSON (`sync-{tvID}.json`) mapping filename → contentID, avoiding TV queries on launch

### Matte System

`Matte` = `MatteStyle` + `MatteColor`. Raw string values must match Samsung API exactly (note: "burgandy" is Samsung's misspelling). Fallback chain on rejection: keep color → try shadowbox → try shadowbox+polar.

### UI Layout

`ContentView` is a three-column `NavigationSplitView`: sidebar (TVs, collections, filters) | photo grid (LazyVGrid, 16:9 aspect) | detail panel (matte preview/picker, actions). Footer has slideshow controls.

### Data Types

- **Photo** — local file with optional matte, optional tvContentID, thumbnail, dimensions
- **TVOnlyItem** — photo on TV with no local file (Samsung built-in art or uploaded from elsewhere)
- **Collection** — named folder of photos with security-scoped bookmark for sandbox access
- **TV** — IP, pairing token, WebSocket URLs, reachability flag
