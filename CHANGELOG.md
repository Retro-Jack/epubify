# Changelog

## v1.0.0 — 2026-08-06

First release.

### Added
- **PDF → Markdown/EPUB conversion via [pdf2epub](https://github.com/overcuriousity/pdf2epub) in Docker.** One container per document, with staging mounted at `/data/input` and the output tree at `/data/output` so nothing is ever written next to the source. Containers run as the invoking user's UID, which keeps the output tree from coming back root-owned.
- **Three-step pipeline** — copy from the input folder to staging (preserving relative paths, collisions suffixed `name(1).pdf`), convert, then tidy names. Already-converted documents are skipped, including ones the tidy step renamed on an earlier run.
- **Two conversion modes,** chosen once per run: *Markdown + EPUB*, where pdf2epub prompts for EPUB metadata per document and so needs a terminal, and *Markdown only* (`--skip-epub`), which runs unattended.
- **Name tidying** — separators normalised and title case applied to each result folder and its top-level files. Files under `images/` are left alone, since the generated markdown links to them by name.
- **Guard rails per conversion** — a hard memory ceiling (`CONTAINER_MEM_MAX`, default 8G) and a wall-clock timeout (`CONTAINER_TIMEOUT`, default 2h), so a malformed PDF that makes the model pipeline balloon is killed locally instead of taking the desktop session with it.
- **Lazy error log** — errors go to `error_log.txt` in the output folder with a per-run header (mode, image, paths, Docker version); the terminal only shows a pointer. The file isn't created on clean runs. Failures warn and continue rather than aborting the batch.
- **Interrupt safety** — an EXIT trap force-removes the running container and deletes the partially written result folder, so a cancelled run leaves nothing half-converted behind.
- **Image bootstrap** — uses a local image if present, otherwise pulls, otherwise builds from `BUILD_CONTEXT` if one is configured, and only then gives up.
