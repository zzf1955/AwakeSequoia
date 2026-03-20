# CLAUDE.md

中文回答用户

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

- name：AwakeSequoia

A macOS command-line tool that renders animated Sequoia-style live wallpaper videos. It generates a camera flythrough of a procedural forest of cylindrical trees using Metal rendering, with time-of-day lighting from Apple's built-in wallpaper assets.

**Platform requirement:** macOS 14+ only. Requires the system-installed `WallpaperSequoiaExtension.appex` bundle at `/System/Library/ExtensionKit/Extensions/` for Metal shaders, meshes (.usdc), and gradient textures (.exr).

## Build & Run

```bash
swift build                                    # Build
swift run AwakeSequoia                 # Render video (uses render_config.json)
swift run AwakeSequoia --live           # Run as live desktop wallpaper (menu bar app)
swift run AwakeSequoia --debug         # Debug mode: perspective frames + top-down views
swift run AwakeSequoia --config config_morning.json  # Use alternate config
swift run AwakeSequoia --start-hour 6 --end-hour 18 --output day_sweep.mov
bash bundle_app.sh                             # Build .app bundle (auto-enters live mode)
```

## Testing

```bash
bash test_engine.sh   # Runs 3 integration tests: video export, debug mode, day sweep
```

No unit test framework — `test_engine.sh` builds, renders, and checks output files exist.

## Architecture

### Rendering Pipeline (per frame)

```
WallpaperEngine.renderNextFrame()
  → advanceState()        # move camera forward, update dayProgress
  → updateFrontier()      # load/unload blocks as camera advances
  → CameraController.evaluate()  # path distance → camera position/orientation
  → ForestMap.instancesInRange()  # collect visible trees
  → ForestRenderer.render()       # Metal draw call → MTLTexture
  → VideoExporter.appendFrame()   # texture → HEVC .mov
```

### Core Components (Sources/)

- **WallpaperEngine** — Orchestrator. Owns all components, manages frame-by-frame rendering loop and dynamic block frontier (lookahead/trail loading/unloading).
- **ForestMap** — Procedural world. Generates tree instances per-block using seeded RNG (grid + jitter placement). Manages block load/unload and spatial queries via `SpatialGrid`.
- **PathPlanner** — Camera path generation. Per-block incremental pipeline: Bowyer-Watson Delaunay → Voronoi graph → Dijkstra (weighted by corridor width) → cubic uniform B-spline with C² continuity across block boundaries (tail control point stitching). Post-processes with collision resolution.
- **ForestRenderer** — Pure Metal rendering layer. Uses Apple's compiled shaders (`drawVertex`/`drawFragment`/`backgroundFragment`) from the system metallib. MSAA 4x, instanced drawing, gradient texture blending for sky/lighting.
- **CameraController** / **CameraState** — Converts path distance → 3D camera with configurable pitch, height, FOV. Produces view/projection matrices.
- **VideoExporter** — AVFoundation HEVC video writer, frame-by-frame from MTLTexture.
- **SceneLoader** — Loads .usdc meshes and .exr gradient textures from the system WallpaperSequoiaExtension bundle.
- **TreeInstance** / **SpatialGrid** — Tree data model (logical vs GPU `InstanceData`) and hash-grid for O(1) nearest-neighbor queries.
- **SolarPosition** — Maps dayProgress (0-1) to gradient texture pair + blend factor for time-of-day lighting.

### Live Wallpaper Mode (--live)

Menu bar app that renders the forest animation as a desktop wallpaper in real-time.

- **WallpaperWindow** — Desktop-level borderless window (`desktopWindow + 1`), ignores mouse, joins all spaces.
- **MetalLayerView** — NSView backed by CAMetalLayer for direct Metal rendering.
- **DisplayLinkDriver** — CVDisplayLink rendering loop with freeze/unfreeze and speed ramp-up.
  - `freeze()` — Pauses animation, resets engine, renders one static frame, drops FPS to 0.
  - `unfreeze()` — Restores FPS, starts gradual speed ramp-up (0 → 1 over 0.5s).
  - `startRamp()` — Speed ramp-up without full unfreeze (for Mission Control resume).
- **AppDelegate** — Manages lifecycle, menu bar UI, occlusion detection, Mission Control detection.

**Mission Control detection:** Polls `CGWindowListCopyWindowInfo` every 0.3s. Finds Dock PID via `NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")`, then checks if Dock has any window at layer >= 0 (Mission Control creates overlay windows at layer 18/20; normally all Dock windows are at negative desktop layers).

**State management:**
- Wallpaper occluded (full-screen app) → `freeze()` (stop rendering, save power)
- Wallpaper visible + no MC → `unfreeze()` (resume with speed ramp)
- MC enters while playing on desktop → continue animating (no pause)
- MC enters while frozen → stay paused
- MC exits + was paused → resume with speed ramp

### Key Design Patterns

- **Streaming frontier:** Blocks load ahead and unload behind the camera, enabling infinite-length renders without loading the whole world.
- **Incremental path planning:** Each block extends the path independently with C² B-spline continuity via 3-point tail stitching from the previous segment.
- **GPU data layout:** `InstanceData` is 16 bytes (x, z, rotation as Float; scaleRadial/scaleVertical as Float16) matching Apple's shader buffer index 2.
- **Deterministic generation:** Block seed = `baseSeed + hash(blockCoord)`, so the same block always generates the same trees.

## Configuration

All rendering parameters are in `render_config.json` (JSON, all fields optional with defaults in `EngineConfig`). Alternate configs: `config_morning.json`, `config_afternoon.json`, `config_noon.json`.

Key tuning parameters:
- `blockWidth` / `blockLength` — block dimensions in X and Z directions (default 13×16)
- `treeDensity` — forest trees per unit area (default 1.56; spacing = 1/√density)
- `speedPercent` — camera speed as % of one block/second
- `corridorAlpha` — Dijkstra weight exponent for corridor width preference (higher = prefer wider paths)
- `minClearance` — minimum distance from path to any tree
- `startClearHalfWidth` / `startClearDepth` — clear zone at starting point (removes trees)
- `dayProgress` / `dayProgressSpeed` — time-of-day and its rate of change
- `gradientUVOffset` / `gradientUVScale` / `gradientWashout` — color grading on gradient textures
