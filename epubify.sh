#!/usr/bin/env bash
# =============================================================================
# Epubify -- Automated PDF to Markdown/EPUB conversion
# =============================================================================
# Copies PDFs from INPUT_DIR to STAGING_DIR, converts each one by running the
# pdf2epub container image, and writes the results to OUTPUT_DIR with tidied
# file and folder names.
#
# Pipeline:
#   1. Copy: INPUT_DIR -> STAGING_DIR (skipped if input is empty)
#   2. Convert: one container per PDF. STAGING_DIR is mounted at /data/input
#      and OUTPUT_DIR at /data/output, so the container never writes anywhere
#      except the output tree. Already-converted documents are skipped.
#   3. Tidy names: separators normalised and title case applied to the result
#      folder and its top-level files. Files inside images/ are left alone --
#      the generated markdown links to them by name.
#
# Errors are written lazily to OUTPUT_DIR/error_log.txt; the terminal only
# sees a "[WARN] See <log>" pointer. The log is not created on clean runs.
#
# Two conversion modes are offered at startup:
#   1. Markdown + EPUB -- pdf2epub prompts interactively for EPUB metadata
#      (title, author, language) per document, so this needs a real terminal.
#   2. Markdown only    -- passes --skip-epub and runs unattended.
#
# Verified against ghcr.io/overcuriousity/pdf2epub:latest on 06/08/2026: the
# :latest tag is published and pulls cleanly (8.8 GB), and pdf2epub does write
# its results to OUTPUT/<document name>/ as assumed below.
#
# The image ships a CUDA build of PyTorch (torch 2.13.0+cu130), so the model
# work can run on an NVIDIA card rather than the CPU -- the difference is
# minutes per document. That needs the NVIDIA container runtime on the host
# (nvidia-container-toolkit); see USE_GPU below.
#
# Requires: docker, perl. Other tools (find, sed, basename, mv, cp) are
# standard on any Linux system. `timeout` is used when present.
# =============================================================================

set -uo pipefail

# Where this script lives — used to find Dockerfile.gpu regardless of the
# directory you happen to run it from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ----- Configuration ---------------------------------------------------------

IMAGE="ghcr.io/overcuriousity/pdf2epub:latest"

# Fallback if the registry tag is unavailable. The upstream README documents
# publishing to ghcr.io, but I was not able to verify that a :latest tag has
# actually been pushed. If the pull fails, clone the repo and point this at the
# checkout; the script will build the image locally instead of dying.
BUILD_CONTEXT=""    # e.g. "/mnt/applications/Source/pdf2epub"

INPUT_DIR="/mnt/misc/Downloads/PDFs"
STAGING_DIR="/mnt/misc/Conversion/pdf2epub/1) Staging"
OUTPUT_DIR="/mnt/misc/Conversion/pdf2epub/2) Done"

# marker-pdf downloads its layout/OCR models on first run. This is a bind mount
# rather than a named Docker volume on purpose: the container runs as your UID
# (see --user below) and an empty named volume is created root-owned, which the
# container user could not then write to.
MODEL_CACHE="/mnt/misc/Conversion/pdf2epub/models"

# Mount the staging tree read-only. An explicit output path is passed to
# pdf2epub, so it should have no reason to write next to the source. Set this
# false if a conversion fails with a read-only filesystem error.
INPUT_READ_ONLY=true

# pdf2epub creates a directory inside its own site-packages at runtime. That
# works for the image's default root user, but this script runs the container
# as your UID (see --user below) and site-packages is root-owned, so the mkdir
# fails with "Permission denied: .../site-packages/static" and every single
# conversion dies before it starts. A writable tmpfs over that path gives it
# somewhere to write without running as root or leaving anything on the host.
# The directory does not exist in the image, so nothing is being masked.
# Update the Python version here if a future image ships a different one; set
# empty to disable the mount.
APP_STATIC_DIR="/usr/local/lib/python3.13/site-packages/static"

# Hand the container the GPU. The image's PyTorch is a CUDA build, so this is
# the difference between minutes and seconds per document -- but it only works
# if the host has the NVIDIA container runtime installed and wired into
# Docker:
#     sudo pacman -S nvidia-container-toolkit        (Arch/CachyOS)
#     sudo nvidia-ctk runtime configure --runtime=docker
#     sudo systemctl restart docker
# Without it `docker run --gpus all` fails outright, so rather than let every
# conversion die the script probes once at startup and quietly falls back to
# the CPU. Set false to force CPU even where a card is available.
USE_GPU=true

# GPU runs use a locally built variant of the image rather than the published
# one. PyTorch compiles its GPU kernels at runtime through Triton, and Triton
# shells out to a C compiler that the upstream image doesn't contain -- so a
# GPU run on the stock image dies with "Failed to find C compiler" before the
# first page, while CPU runs (which never take that path) are fine. The
# variant adds gcc and nothing else; see Dockerfile.gpu, which lives beside
# this script and is built automatically the first time a GPU run needs it.
GPU_IMAGE="epubify/pdf2epub:gpu"
GPU_DOCKERFILE="Dockerfile.gpu"

# Extra arguments appended to every pdf2epub invocation, e.g.
# EXTRA_ARGS=(--start-page 10 --max-pages 50)
EXTRA_ARGS=()

# Each conversion runs with a hard memory ceiling and a wall-clock timeout, so
# a malformed PDF that makes the model pipeline balloon gets killed locally
# instead of taking the desktop session with it. Leave either empty to disable.
CONTAINER_MEM_MAX="8G"
CONTAINER_TIMEOUT="2h"

PROCESS_DELAY=2
EXCLUDED_BASENAMES=(sample preview)

TIDY_NAMES=true     # normalise separators and apply title case to output

ERROR_LOG="$OUTPUT_DIR/error_log.txt"

# ----- Counters --------------------------------------------------------------

files_copied=0
files_failed=0
pdfs_found=0
pdfs_converted=0
pdfs_skipped=0
pdfs_failed=0
rename_errors=0

# Set by the mode menu.
INTERACTIVE=true
MODE_NAME=""
MODE_ARGS=()

# Set by process_pdf while a container is running. The EXIT trap force-removes
# the container and deletes the partially written result folder if the script
# is interrupted mid-conversion.
_current_container=""
_current_result_dir=""

# ----- Functions -------------------------------------------------------------

print_header() {
    local title="$1"
    local width=$(( ${#title} + 8 ))
    (( width < 50 )) && width=50
    local pad=$(( (width - ${#title}) / 2 ))
    local border
    border="$(printf '%*s' "$width" '' | tr ' ' '=')"
    # One blank line above the box, three below -- the trailing gap is the
    # single source of truth for header spacing, so callers must not add their
    # own blank line after a header.
    printf '\n%s\n%*s%s\n%s\n\n\n\n' "$border" "$pad" '' "$title" "$border"
}

pause_and_clear() {
    echo
    read -r -s -n1 -p "Press any key to continue . . . "
    echo
    clear
}

_log_initialised=false

_init_error_log() {
    # Writes a one-time session header to the error log. Called lazily from
    # warn/die so the file only appears on disk when a real error occurs.
    $_log_initialised && return 0
    _log_initialised=true
    mkdir -p "$(dirname "$ERROR_LOG")" 2>/dev/null
    {
        printf '\n%s\n' "============================================================"
        printf 'Epubify run started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        # USER is not exported by cron or systemd units; under `set -u` an
        # unguarded reference here would kill the script from inside the very
        # handler that is supposed to be reporting an error.
        printf 'Host: %s | User: %s | PID: %s\n' \
            "$(hostname)" "${USER:-$(id -un)}" "$$"
        printf 'Mode:      %s\n' "${MODE_NAME:-?}"
        printf 'Image:     %s\n' "$IMAGE"
        printf 'Input:     %s\n' "$INPUT_DIR"
        printf 'Staging:   %s\n' "$STAGING_DIR"
        printf 'Output:    %s\n' "$OUTPUT_DIR"
        printf 'Docker:    %s\n' "$(docker --version 2>&1 | head -1)"
        printf '%s\n\n' "============================================================"
    } >> "$ERROR_LOG"
}

_log_details() {
    # Appends a labelled details block (caller, optional context payload, and a
    # trailing blank line) to the error log. Used by die/warn when extra
    # context is available beyond the one-line summary.
    local details="$1"
    local caller="${FUNCNAME[2]:-MAIN}:${BASH_LINENO[1]:-0}"
    printf '  caller: %s\n' "$caller" >> "$ERROR_LOG"
    if [[ -n "$details" ]]; then
        printf '  details:\n' >> "$ERROR_LOG"
        printf '%s\n' "$details" | sed 's/^/    /' >> "$ERROR_LOG"
    fi
    printf '\n' >> "$ERROR_LOG"
}

die() {
    # Usage: die <message> [<details>]
    _init_error_log
    printf '[ERROR] See %s\n' "$ERROR_LOG" >&2
    printf '%s - ERROR: %s\n' "$(date '+%x %X')" "$1" >> "$ERROR_LOG"
    _log_details "${2:-}"
    exit 1
}

warn() {
    # Usage: warn <message> [<details>]
    _init_error_log
    printf '[WARN]  See %s\n' "$ERROR_LOG" >&2
    printf '%s - WARN: %s\n' "$(date '+%x %X')" "$1" >> "$ERROR_LOG"
    _log_details "${2:-}"
}

_on_exit() {
    if [[ -n "$_current_container" ]]; then
        docker rm -f "$_current_container" &>/dev/null
    fi
    # Guarded: only ever removes a subdirectory of OUTPUT_DIR, never the root.
    if [[ -n "$_current_result_dir" && -d "$_current_result_dir" \
          && "$_current_result_dir" == "$OUTPUT_DIR"/?* ]]; then
        rm -rf "$_current_result_dir"
    fi
}
trap '_on_exit' EXIT

check_path() {
    [[ -d "$1" ]] || die "Cannot find directory: $1 ($2)"
}

check_command() {
    command -v "$1" &>/dev/null || die "Cannot find command: $1 ($2)"
}

ensure_docker() {
    check_command docker "Docker CLI"
    local info_err
    if ! info_err="$(docker info 2>&1 >/dev/null)"; then
        die "Cannot talk to the Docker daemon" \
            "$info_err
Try: sudo systemctl start docker
And ensure your user is in the 'docker' group, or run this script with sudo."
    fi
}

ensure_image() {
    # Uses a locally present image if there is one, otherwise pulls, otherwise
    # builds from BUILD_CONTEXT. Only dies once all three have been tried.
    if docker image inspect "$IMAGE" &>/dev/null; then
        return 0
    fi

    echo "[SETUP] Image not present locally: $IMAGE"
    echo "[SETUP] Pulling (this is a large download on first run)..."
    local pull_err
    if pull_err="$(docker pull "$IMAGE" 2>&1)"; then
        echo "[SETUP] Pull complete."
        return 0
    fi

    if [[ -n "$BUILD_CONTEXT" && -f "$BUILD_CONTEXT/Dockerfile" ]]; then
        echo "[SETUP] Pull failed. Building locally from: $BUILD_CONTEXT"
        IMAGE="pdf2epub:local"
        docker build -t "$IMAGE" "$BUILD_CONTEXT" \
            || die "Local build failed" "Context: $BUILD_CONTEXT"
        echo "[SETUP] Build complete."
        return 0
    fi

    die "Could not obtain the pdf2epub image" \
        "$pull_err
The :latest tag may not have been published to ghcr.io. Clone the repository
and set BUILD_CONTEXT at the top of this script to the checkout path:
  git clone https://github.com/overcuriousity/pdf2epub.git"
}

_gpu_enabled=false

probe_gpu() {
    # Decides once per run whether --gpus all can be passed. Docker fails the
    # whole run if the NVIDIA runtime is missing, so this has to be settled
    # before any real work starts rather than discovered per document.
    $USE_GPU || { echo "[SETUP] GPU disabled in config -- using CPU."; return 0; }

    if docker run --rm --gpus all --entrypoint true "$IMAGE" &>/dev/null; then
        local name
        name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"

        # The GPU needs the gcc-carrying variant; build it once if it isn't
        # already here. A failed build is not fatal -- CPU still works.
        if ! docker image inspect "$GPU_IMAGE" &>/dev/null; then
            local dockerfile="$SCRIPT_DIR/$GPU_DOCKERFILE"
            if [[ ! -f "$dockerfile" ]]; then
                echo "[SETUP] ${name:-GPU} found, but $GPU_DOCKERFILE is missing -- using CPU."
                return 0
            fi
            echo "[SETUP] ${name:-GPU} found. Building $GPU_IMAGE (one-off, adds a C compiler)..."
            if ! docker build -q -f "$dockerfile" -t "$GPU_IMAGE" "$SCRIPT_DIR" &>/dev/null; then
                warn "GPU image build failed -- falling back to CPU" \
                     "Dockerfile: $dockerfile"
                echo "[SETUP] GPU image build failed -- using CPU."
                return 0
            fi
        fi

        IMAGE="$GPU_IMAGE"
        _gpu_enabled=true
        echo "[SETUP] GPU available -- using ${name:-NVIDIA GPU}."
    else
        echo "[SETUP] No usable GPU runtime -- falling back to CPU."
        echo "        For GPU acceleration install the NVIDIA container toolkit:"
        echo "          sudo pacman -S nvidia-container-toolkit"
        echo "          sudo nvidia-ctk runtime configure --runtime=docker"
        echo "          sudo systemctl restart docker"
    fi
}

choose_mode() {
    # pdf2epub prompts interactively for EPUB metadata and fails with an
    # EOFError if it cannot read from a terminal, so EPUB output and unattended
    # batching are mutually exclusive. The choice is made once per run.
    print_header "Select Conversion Mode"
    echo "  1) Markdown + EPUB  -- prompts for metadata on each document"
    echo "  2) Markdown only    -- unattended (--skip-epub)"
    echo

    local choice
    while true; do
        read -r -p "Choice [1-2]: " choice
        case "$choice" in
            1)
                if [[ ! -t 0 ]]; then
                    echo "EPUB mode needs a terminal; stdin is not a TTY." >&2
                    continue
                fi
                INTERACTIVE=true
                MODE_NAME="Markdown + EPUB"
                MODE_ARGS=()
                break
                ;;
            2)
                INTERACTIVE=false
                MODE_NAME="Markdown only"
                MODE_ARGS=(--skip-epub)
                break
                ;;
            *) echo "Enter 1 or 2." ;;
        esac
    done
    echo
    echo "Mode: $MODE_NAME"
    pause_and_clear
}

build_exclude_args() {
    # Builds `! -iname X.* ! -iname Y.* ...` from EXCLUDED_BASENAMES into the
    # named array.
    local -n _out=$1
    local name
    for name in "${EXCLUDED_BASENAMES[@]}"; do
        _out+=("!" "-iname" "${name}.*")
    done
}

copy_file_to_staging() {
    # Copies one PDF into STAGING_DIR, preserving its path relative to
    # INPUT_DIR. Existing names are suffixed name(1).pdf, name(2).pdf, etc.
    local source="$1"
    local rel="${source#"$INPUT_DIR"/}"
    local target="$STAGING_DIR/$rel"
    local dir stem ext counter=1

    dir="$(dirname "$target")"
    mkdir -p "$dir" || { warn "Cannot create staging folder: $dir"; ((files_failed++)); return 1; }

    if [[ -e "$target" ]]; then
        stem="$(basename "$target")"
        ext="${stem##*.}"
        stem="${stem%.*}"
        while [[ -e "$dir/${stem}(${counter}).${ext}" ]]; do
            ((counter++))
        done
        target="$dir/${stem}(${counter}).${ext}"
    fi

    local cp_err
    if cp_err="$(cp -- "$source" "$target" 2>&1)"; then
        ((files_copied++))
        printf '  %s\n' "$rel"
    else
        warn "Copy failed: $rel" "$cp_err"
        ((files_failed++))
        return 1
    fi
}

_docker_args() {
    # Populates a named array with the docker run arguments common to every
    # conversion. --user makes the container write as you rather than as root,
    # which is what stops the output tree coming back root-owned. HOME is
    # redirected into the model cache so that any library reaching for
    # ~/.cache has somewhere writable to land.
    local -n _args=$1
    local container="$2"
    local ro=""
    $INPUT_READ_ONLY && ro=":ro"

    _args=(
        run --rm
        --name "$container"
        --user "$(id -u):$(id -g)"
        -e "HOME=/models"
        -v "$STAGING_DIR:/data/input$ro"
        -v "$OUTPUT_DIR:/data/output"
        -v "$MODEL_CACHE:/models"
    )
    [[ -n "$CONTAINER_MEM_MAX" ]] && _args+=(--memory "$CONTAINER_MEM_MAX")
    [[ -n "$APP_STATIC_DIR" ]] && _args+=(--tmpfs "$APP_STATIC_DIR:rw,mode=1777")
    $_gpu_enabled && _args+=(--gpus all)
    $INTERACTIVE && _args+=(-i -t)
}

process_pdf() {
    local pdf="$1"
    local index="$2"
    local total="$3"

    local rel="${pdf#"$STAGING_DIR"/}"
    local stem
    stem="$(basename "$pdf")"
    stem="${stem%.*}"

    local result_dir="$OUTPUT_DIR/$stem"

    printf '[%d/%d] %s\n' "$index" "$total" "$rel"

    # pdf2epub writes OUTPUT/<document name>/ containing the markdown, the
    # EPUB, a metadata JSON and an images/ folder. Treat the presence of the
    # artefact this mode produces as proof the document is already done.
    #
    # Step 3 renames that folder, so a document converted on an earlier run is
    # now sitting under its tidied name. Both candidates have to be checked or
    # every subsequent run re-converts everything and then fails to rename the
    # result, leaving two copies of each document in the output tree.
    local -a candidates=("$result_dir")
    if $TIDY_NAMES; then
        local tidy_stem
        tidy_name tidy_stem "$stem"
        [[ -n "$tidy_stem" && "$tidy_stem" != "$stem" ]] \
            && candidates+=("$OUTPUT_DIR/$tidy_stem")
    fi

    local candidate existing pattern
    pattern='*.md'
    $INTERACTIVE && pattern='*.epub'
    for candidate in "${candidates[@]}"; do
        [[ -d "$candidate" ]] || continue
        existing="$(find "$candidate" -maxdepth 1 -name "$pattern" -print -quit 2>/dev/null)"
        if [[ -n "$existing" ]]; then
            echo "        Already converted -- skipping."
            echo
            ((pdfs_skipped++))
            return 0
        fi
    done

    local container="epubify_${$}_${index}"
    local -a docker_args
    _docker_args docker_args "$container"

    local -a timeout_cmd=()
    if [[ -n "$CONTAINER_TIMEOUT" ]] && command -v timeout &>/dev/null; then
        # --foreground so signals still reach an interactive session.
        timeout_cmd=(timeout --foreground "$CONTAINER_TIMEOUT")
    fi

    _current_container="$container"
    _current_result_dir="$result_dir"

    local status
    if $INTERACTIVE; then
        # Output is not piped: the metadata prompts need the terminal directly.
        "${timeout_cmd[@]}" docker "${docker_args[@]}" "$IMAGE" \
            "input/$rel" "output" "${MODE_ARGS[@]}" "${EXTRA_ARGS[@]}"
        status=$?
    else
        # Logs live in their own folder so they do not clutter the output root
        # or get picked up by the Step 3 pass over result directories.
        local log_dir="$OUTPUT_DIR/logs"
        mkdir -p "$log_dir" 2>/dev/null
        local log="$log_dir/${stem}.log"
        "${timeout_cmd[@]}" docker "${docker_args[@]}" "$IMAGE" \
            "input/$rel" "output" "${MODE_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1 \
            | tee "$log"
        status=${PIPESTATUS[0]}
    fi

    _current_container=""

    if (( status == 124 )); then
        warn "Timed out after $CONTAINER_TIMEOUT: $rel"
        ((pdfs_failed++))
        echo
        return 1
    elif (( status != 0 )); then
        warn "Conversion failed (exit $status): $rel" \
             "Container: $container
Mode: $MODE_NAME"
        ((pdfs_failed++))
        echo
        return 1
    fi

    # The exact output location is inferred from the upstream documentation
    # rather than observed here, so verify it rather than assuming.
    if [[ ! -d "$result_dir" ]]; then
        local listing
        listing="$(find "$OUTPUT_DIR" -maxdepth 1 -mindepth 1 2>/dev/null | head -20)"
        warn "Converted but no result folder at expected path: $result_dir" \
             "Output root currently contains:
$listing"
        ((pdfs_failed++))
        _current_result_dir=""
        echo
        return 1
    fi

    _current_result_dir=""
    ((pdfs_converted++))
    echo "        Done."
    echo
    sleep "$PROCESS_DELAY"
}

_perl_transform() {
    # Runs a perl one-liner against a single string, logging regex failures
    # rather than letting them corrupt a name. The result comes back through a
    # nameref rather than stdout: a command substitution would run the whole
    # function in a subshell, and the rename_errors increment would be lost.
    # Usage: _perl_transform <out_var> <label> <script> <input>
    local -n _tx_out=$1
    local label="$2" script="$3" input="$4"
    local err_file
    err_file="$(mktemp)"
    if ! _tx_out="$(printf '%s' "$input" | perl -pe "$script" 2>"$err_file")"; then
        warn "$label failed on: $input" "$(<"$err_file")"
        ((rename_errors++))
        _tx_out="$input"
        rm -f "$err_file"
        return 1
    fi
    rm -f "$err_file"
}

tidy_name() {
    # Normalises separators and applies title case to a bare name (no
    # extension). Title case only touches a lowercase letter that is not
    # preceded by a word character or an apostrophe, so acronyms survive
    # intact and "jack's" does not become "Jack'S".
    # Usage: tidy_name <out_var> <name>
    local -n _tn_out=$1
    local work="$2"
    _perl_transform work "Separator cleanup" \
        's/[._-]+/ /g; s/\s{2,}/ /g; s/^\s+|\s+$//g;' "$work"
    _perl_transform work "Title case" \
        's/(?<![\w'"'"'])([a-z])/\u$1/g;' "$work"
    _tn_out="$work"
}

do_rename() {
    # Renames a file or directory within its own parent. Refuses to clobber.
    local item="$1" new_name="$2"
    local parent
    parent="$(dirname "$item")"
    local target="$parent/$new_name"

    [[ "$item" == "$target" ]] && return 0

    if [[ -e "$target" ]]; then
        warn "Rename target already exists, skipping: $target"
        ((rename_errors++))
        return 1
    fi

    local mv_err
    if ! mv_err="$(mv -- "$item" "$target" 2>&1)"; then
        warn "Rename failed: $item" "$mv_err"
        ((rename_errors++))
        return 1
    fi
}

tidy_result() {
    # Tidies one result folder: its top-level files first, then the folder
    # itself. Anything under images/ is deliberately left untouched -- the
    # generated markdown references those files by their original names, and
    # renaming them would break every image link in the document.
    local result_dir="$1"
    local file name stem ext suffix known new_stem new_name

    while IFS= read -r -d '' file; do
        name="$(basename "$file")"
        if [[ "$name" == *.* ]]; then
            ext="${name##*.}"
            stem="${name%.*}"
        else
            ext=""
            stem="$name"
        fi

        # pdf2epub names its sidecar "<document>_metadata.json". Left to the
        # normal rules that underscore becomes a space and the word gets title
        # case -- "Some Doc Metadata.json" -- which reads fine but quietly
        # drops the suffix anything parsing these files would look for. Hold it
        # aside, tidy the document part, then put it back verbatim.
        suffix=""
        for known in _metadata; do
            if [[ "$stem" == *"$known" ]]; then
                suffix="$known"
                stem="${stem%"$known"}"
                break
            fi
        done

        tidy_name new_stem "$stem"
        [[ -z "$new_stem" ]] && continue
        new_name="$new_stem$suffix"
        [[ -n "$ext" ]] && new_name="$new_stem$suffix.$ext"
        do_rename "$file" "$new_name"
    done < <(find "$result_dir" -maxdepth 1 -type f -print0 2>/dev/null)

    name="$(basename "$result_dir")"
    tidy_name new_name "$name"
    [[ -n "$new_name" ]] && do_rename "$result_dir" "$new_name"
}

# ----- Initialisation --------------------------------------------------------

clear
print_header "Epubify"

ensure_docker
check_command perl "Perl"

check_path "$INPUT_DIR" "Input directory"
mkdir -p "$STAGING_DIR" || die "Cannot create staging directory: $STAGING_DIR"
mkdir -p "$OUTPUT_DIR"  || die "Cannot create output directory: $OUTPUT_DIR"
mkdir -p "$MODEL_CACHE" || die "Cannot create model cache directory: $MODEL_CACHE"

ensure_image
probe_gpu
choose_mode

# ----- Step 1: Copy from input -----------------------------------------------

print_header "STEP 1: Copying PDFs to Staging"

declare -a exclude_args=()
build_exclude_args exclude_args

mapfile -d '' input_pdfs < <(
    find "$INPUT_DIR" -mindepth 1 -type f -iname '*.pdf' "${exclude_args[@]}" -print0 2>/dev/null
)
mapfile -d '' staged_pdfs < <(
    find "$STAGING_DIR" -mindepth 1 -type f -iname '*.pdf' "${exclude_args[@]}" -print0 2>/dev/null
)

do_copy=true
if (( ${#input_pdfs[@]} == 0 )); then
    echo "No PDFs in input folder -- using whatever is already staged."
    do_copy=false
elif (( ${#staged_pdfs[@]} > 0 )); then
    printf 'Staging already holds %d PDF(s).\n\n' "${#staged_pdfs[@]}"
    read -r -p "Copy ${#input_pdfs[@]} more from input? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || do_copy=false
    echo
fi

if $do_copy; then
    for pdf in "${input_pdfs[@]}"; do
        copy_file_to_staging "$pdf"
    done
    printf '\nCopied %d file(s).\n' "$files_copied"
else
    echo "Copy step skipped."
fi
echo
pause_and_clear

# ----- Step 2: Convert -------------------------------------------------------

print_header "STEP 2: Converting"

mapfile -d '' pdfs < <(
    find "$STAGING_DIR" -mindepth 1 -type f -iname '*.pdf' "${exclude_args[@]}" -print0 2>/dev/null | sort -z
)
pdfs_found=${#pdfs[@]}

if (( pdfs_found == 0 )); then
    echo "Nothing to convert."
    echo
else
    printf 'Found %d PDF(s).\n\n' "$pdfs_found"
    index=0
    for pdf in "${pdfs[@]}"; do
        ((index++))
        process_pdf "$pdf" "$index" "$pdfs_found"
    done
fi
pause_and_clear

# ----- Step 3: Tidy names ----------------------------------------------------

print_header "STEP 3: Tidying Names"

if $TIDY_NAMES && (( pdfs_converted > 0 )); then
    echo "Normalising separators and applying title case..."
    while IFS= read -r -d '' result_dir; do
        tidy_result "$result_dir"
    done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name 'logs' -print0 2>/dev/null)
    echo "Cleanup complete."
elif ! $TIDY_NAMES; then
    echo "Name tidying disabled (TIDY_NAMES=false)."
else
    echo "Nothing converted this run -- skipping."
fi
echo
pause_and_clear

# ----- Final report ----------------------------------------------------------

print_header "Processing Complete"
printf 'Mode:              %s\n' "$MODE_NAME"
printf 'Image:             %s\n' "$IMAGE"
echo
printf 'PDFs found:        %d\n' "$pdfs_found"
printf 'PDFs converted:    %d\n' "$pdfs_converted"
printf 'PDFs skipped:      %d\n' "$pdfs_skipped"
echo  "------------------------"
printf 'Files copied:      %d\n' "$files_copied"
if $TIDY_NAMES; then
    echo "Name tidying:      Completed"
fi
if (( pdfs_failed + files_failed + rename_errors > 0 )); then
    echo
    (( pdfs_failed  > 0 )) && printf 'Conversions failed: %d\n' "$pdfs_failed"
    (( files_failed  > 0 )) && printf 'Copy failures:      %d\n' "$files_failed"
    (( rename_errors > 0 )) && printf 'Rename errors:      %d\n' "$rename_errors"
fi
echo
[[ -f "$ERROR_LOG" ]] && echo "Errors logged to:  $ERROR_LOG"
echo

if (( pdfs_found > 0 )); then
    read -r -p "Clean staging folder? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        echo "Cleaning staging folder..."
        find "$STAGING_DIR" -mindepth 1 -delete
        echo "Done."
    fi
fi
echo
print_header "Done"
read -r -s -n1 -p "Press any key to quit . . . "
echo
