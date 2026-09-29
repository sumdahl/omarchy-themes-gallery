# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Omarchy shell bar-widget plugin (`sumiran.theme-gallery`, Quickshell/QML) that browses the bjarneo/omarchy-themes wallpaper collection and applies any of its 5 theme variants as a native Omarchy theme. No build step, no npm deps — `package.json` only holds test scripts.

## Commands

```sh
npm test                    # JS: node --test tests/Model.test.js (Node 22 built-in runner)
npm run test:py             # Python: python3 -m unittest discover -s tests/python -v
npm run test:qml            # qmllint + omarchy plugin validate ./  (local only; needs Omarchy/Quickshell)
npm run test:all

# single tests
node --test --test-name-pattern='bucketRes' tests/Model.test.js
python3 -m unittest discover -s tests/python -k <pattern>          # e.g. -k TestSec, -k slug

python3 -m py_compile bin/*.py
omarchy-shell shell rescanPlugins   # hot-reload the plugin after edits
```

CI (`.github/workflows/ci.yml`) runs only py_compile + JS + Python tests (Python 3.11 and 3.13). QML lint and `omarchy plugin validate` cannot run on GitHub runners — run `npm run test:qml` locally before a release.

## Architecture

Three layers, communicating via subprocess stdout:

- **`BarWidget.qml`** — the bar button (``, JetBrainsMono Nerd Font). Left-click toggles the panel, right-click launches `aether`. It keeps `Panel` loaded even when closed, which is why the AUTO random-apply `Timer` in `Panel.qml` keeps firing while the gallery is hidden.
- **`Panel.qml`** — the whole UI (search, filter rail, grid, detail, MODE/AUTO bar), key handling, an `IpcHandler` (target `sumiran.theme-gallery`: `open`/`close`/`toggle`), and several `Process` objects that run the `bin/*.py` scripts (paths resolved via `Qt.resolvedUrl("bin/" + name)`) and parse their stdout with `StdioCollector`.
- **`Model.js`** — `.pragma library` pure functions (resolution bucketing, `prep`, `apply` filtering + live facet counts, variant helpers). Keep filtering/data logic here so it stays unit-testable; tests load it through `vm` after stripping the pragma line, so compare cross-realm objects via `JSON.stringify`.
- **`bin/`** — stdlib-only Python 3.11+ (uses `tomllib`):
  - `fetch-manifest.py` downloads ~35 MB `wallpapers.js`, slims it to a compact JSON (`p/t/tone/color/tags/w/h/thumb/med/pal/th[5]`) and caches it at `~/.cache/sumiran.theme-gallery/manifest.json` (24 h TTL; non-forced refresh falls back to stale cache when offline, forced `R` refresh is strict).
  - `apply-theme.py <slug> <base> <ct> <bg> [fallbackP]` writes `colors.toml` + background atomically into `~/.config/omarchy/themes/<slug>/`, falls back to the original wallpaper on 403, then runs `omarchy theme set` and the panel confirms via `omarchy theme current`.
  - `set-wallpaper.py` — Wallpaper mode: image only, via wallpaper cache → `omarchy-theme-bg-set`, never touches `colors.toml`. Cache pruned to ~1 GiB / 300 files, keeping the currently linked background.
  - `_sec.py` — shared hardening used by all scripts: https + host allowlist (`wallpapers.hel1.your-objectstorage.com`, `bjarneo.github.io`), byte ceilings on every download, total download deadline, magic-byte image sniffing, slug/relpath validation, and slim-manifest shape validation before caching/printing. Route new network or filesystem-writing code through these helpers.

Script filenames contain dashes, so tests import them with `importlib` (`load_module` in `tests/python/test_bin.py`); tests never hit the network (`http_get` is mocked) and use an isolated `HOME`.

## Conventions

- No hardcoded `/home/...` paths — use `Qt.resolvedUrl`, `~`/`expanduser`, `StandardPaths`.
- `manifest.json` must pass `omarchy plugin validate ./`; keep its `version` in sync with `package.json`.
- Workflow is TDD: every reviewed bug has a regression assertion in `tests/`; add one for new fixes.
- Panel is laid out at 1020×720; the grid's right edge is anchored to the panel (no width arithmetic) — keep it that way so new controls can't push thumbnails out.
