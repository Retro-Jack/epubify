# Changelog

## v1.1.0 — 2026-08-06

First version to have actually been run. v1.0.0 was written without a machine to test on; three of its assumptions turned out to be wrong, and conversion failed outright on every document.

### Added
- **GPU acceleration.** The image ships a CUDA build of PyTorch (`torch 2.13.0+cu130`), so the model work can run on an NVIDIA card. `USE_GPU` (default `true`) probes once at startup — if the host has the NVIDIA container runtime it reports the card by name and passes `--gpus all`; if not, it prints the install commands and carries on using the CPU, because Docker fails the *whole run* on an unsupported `--gpus` rather than one document. Measured on an RTX 4070 Ti against the CPU baseline: an 8-page document went **90s → 10s**, and a 77-page scan's layout pass went from ~9 seconds *per page* to ~34 pages *per second*.
- **`Dockerfile.gpu`.** GPU runs use a locally built variant of the image. PyTorch compiles its GPU kernels at runtime through Triton, and Triton shells out to a C compiler the upstream image doesn't contain — so a GPU run on the stock image dies with `Failed to find C compiler` before the first page, while CPU runs (which never take that path) are unaffected. The variant adds `gcc` and nothing else, and is built automatically the first time a GPU run needs it.

### Fixed
- **Every conversion failed with a permission error.** pdf2epub creates a directory inside its own `site-packages` at runtime. That's fine for the image's default root user, but this script deliberately runs the container as your UID so the output tree doesn't come back root-owned — and `site-packages` is root-owned, so the `mkdir` failed with `[Errno 13] Permission denied: .../site-packages/static` and the document died before conversion started. A writable tmpfs is now mounted over that path (`APP_STATIC_DIR`), which costs nothing on the host, masks nothing in the image (the directory doesn't exist there), and keeps the non-root design intact.
- **The header comment claimed the image was CPU-only** and told you to install pdf2epub natively for GPU support. It isn't, and you don't.

### Changed
- **Two remaining assumptions confirmed by a real run** rather than left as caveats: the `:latest` tag on ghcr.io is published and pulls cleanly (8.8 GB), and pdf2epub does write its results to `OUTPUT/<document name>/`.

---

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
