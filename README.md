# Epubify

A bash script that automates PDF → Markdown/EPUB conversion using [pdf2epub](https://github.com/overcuriousity/pdf2epub) in Docker. It copies PDFs from a downloads folder to a staging folder, runs one container per document, and writes the results to an output folder with tidied file and folder names.

Each converted document lands in its own folder containing the markdown, an `images/` folder, a metadata JSON, and — in EPUB mode — the EPUB itself.

## Requirements

- **Docker** — the conversion runs in a container; the daemon must be running and your user should be in the `docker` group (or run the script with sudo)
- `perl` — used for filename cleanup (standard on most Linux systems)
- `timeout` — used when present, to cap runaway conversions

The container image (`ghcr.io/overcuriousity/pdf2epub:latest`) is pulled automatically on first run. It's a large download, and pdf2epub also fetches its layout/OCR models the first time it converts anything — both are one-off.

> **CPU only.** The published image ships a CPU PyTorch build, so a CUDA GPU will sit idle regardless. For GPU acceleration, install pdf2epub natively with a CUDA PyTorch build instead of using this script.

## Configuration

Edit the variables at the top of `epubify.sh` to match your environment:

| Variable | Description |
|---|---|
| `IMAGE` | Container image to run (default: `ghcr.io/overcuriousity/pdf2epub:latest`) |
| `BUILD_CONTEXT` | Optional path to a pdf2epub checkout; used to build the image locally if the pull fails |
| `INPUT_DIR` | Folder holding the PDFs to convert — **must exist**, the script stops if it doesn't |
| `STAGING_DIR` | Staging folder for PDFs awaiting conversion (created if missing) |
| `OUTPUT_DIR` | Root for converted documents (created if missing) |
| `MODEL_CACHE` | Where pdf2epub's downloaded models are kept between runs (created if missing) |
| `INPUT_READ_ONLY` | Mount the staging tree read-only (default: `true`) — set `false` if a conversion fails with a read-only filesystem error |
| `EXTRA_ARGS` | Extra arguments appended to every pdf2epub invocation, e.g. `(--start-page 10 --max-pages 50)` |
| `CONTAINER_MEM_MAX` | Hard memory ceiling per conversion (default: `8G`); empty disables |
| `CONTAINER_TIMEOUT` | Wall-clock limit per conversion (default: `2h`); empty disables |
| `PROCESS_DELAY` | Seconds to pause between conversions (default: `2`) |
| `EXCLUDED_BASENAMES` | Filenames (without extension) to skip, e.g. `sample`, `preview` |
| `TIDY_NAMES` | Normalise separators and apply title case to output names (default: `true`) |

## Usage

```bash
./epubify.sh
```

Run with no arguments. There are no flags or positional parameters.

At startup you choose a **conversion mode**:

1. **Markdown + EPUB** — pdf2epub prompts for EPUB metadata (title, author, language) on each document, so this needs a real terminal and can't be left unattended.
2. **Markdown only** — passes `--skip-epub` and runs without prompting.

The script then pauses between each of the three steps, and finishes with a summary and the option to empty the staging folder.

## How It Works

**Step 1 — Copy.** PDFs are copied from `INPUT_DIR` to `STAGING_DIR`, preserving their paths relative to the input root. Name collisions become `name(1).pdf`, `name(2).pdf`, and so on. If the input folder is empty the step is skipped and whatever is already staged is used; if staging already holds PDFs you're asked before more are copied.

**Step 2 — Convert.** One container per PDF, with staging mounted at `/data/input` and the output tree at `/data/output`, so nothing is ever written next to the source. Containers run as your UID, which is what stops the output coming back root-owned, and `HOME` is redirected into the model cache so any library reaching for `~/.cache` has somewhere writable to land. Each conversion gets a memory ceiling and a wall-clock timeout. Documents that have already been converted are detected and skipped — including ones step 3 renamed on an earlier run, which is checked explicitly so repeat runs don't produce two copies of everything.

**Step 3 — Tidy names.** Separators are normalised and title case applied to each result folder and its top-level files. Title case only touches a lowercase letter not preceded by a word character or an apostrophe, so acronyms survive and `jack's` doesn't become `Jack'S`. Anything inside `images/` is deliberately left alone, since the generated markdown links to those files by name.

## Errors

Errors are written to `error_log.txt` in the output folder; the terminal only shows a `[WARN] See <log>` pointer. The log isn't created at all on a clean run, and each run appends a header with the mode, image, paths and Docker version used.

A failed conversion doesn't stop the run — the document is counted as failed and the next one starts. Interrupting the script mid-conversion force-removes the running container and deletes the partially written result folder, so nothing half-converted is left behind.
