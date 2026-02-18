#!/bin/bash
# Run nude_detector.py using the same venv as run_telegram_bot.
# Does NOT create the venv; exits with 1 if venv does not exist.
# Usage: run_nude_detector.sh [nude_detector options] file1 [file2 ...]
# When invoked from nostr_media_uploader.sh, NOSTR_MEDIA_UPLOADER_SCRIPT_DIR is set to the
# repo directory (same folder as the original script/venv), so venv is found when run via symlink.

if [ -n "${NOSTR_MEDIA_UPLOADER_SCRIPT_DIR:-}" ] && [ -d "$NOSTR_MEDIA_UPLOADER_SCRIPT_DIR" ]; then
	SCRIPT_DIR="$NOSTR_MEDIA_UPLOADER_SCRIPT_DIR"
else
	# Resolve script path (follow symlinks) so SCRIPT_DIR is correct when invoked via symlink
	SCRIPT_PATH="$0"
	while [ -L "$SCRIPT_PATH" ]; do
		SCRIPT_DIR_LOOP=$(dirname "$SCRIPT_PATH")
		SCRIPT_PATH=$(readlink "$SCRIPT_PATH")
		case "$SCRIPT_PATH" in
			/*) ;;
			*) SCRIPT_PATH="${SCRIPT_DIR_LOOP}/${SCRIPT_PATH}" ;;
		esac
	done
	SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)
fi
NUDE_DETECTOR="$SCRIPT_DIR/nude_detector.py"

# Same OS/venv detection as run_telegram_bot.sh
OS_TYPE=""
if command -v uname >/dev/null 2>&1; then
    OS_NAME=$(uname -s)
    case "$OS_NAME" in
        Linux*)
            OS_TYPE="linux"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            OS_TYPE="windows"
            ;;
        *)
            OS_TYPE="linux"
            ;;
    esac
else
    if [ -d "/cygdrive" ] || [ -n "$WINDIR" ]; then
        OS_TYPE="windows"
    else
        OS_TYPE="linux"
    fi
fi

VENV_DIR="$SCRIPT_DIR/venv_${OS_TYPE}"

# On Cygwin/Windows, native Python needs Windows paths; convert with cygpath -w
convert_path_for_python() {
	local p="$1"
	if [ "$OS_TYPE" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
		cygpath -w "$p"
	else
		echo "$p"
	fi
}

get_venv_python() {
    if [ -f "$VENV_DIR/bin/python" ]; then
        echo "$VENV_DIR/bin/python"
    elif [ -f "$VENV_DIR/Scripts/python.exe" ]; then
        echo "$VENV_DIR/Scripts/python.exe"
    elif [ -f "$VENV_DIR/Scripts/python" ]; then
        echo "$VENV_DIR/Scripts/python"
    else
        echo ""
    fi
}

# Venv must exist; do not create it
if ! [ -d "$VENV_DIR" ]; then
    echo "Error: Virtual environment not found at $VENV_DIR" >&2
    exit 1
fi
if ! [ -f "$VENV_DIR/bin/activate" ] && ! [ -f "$VENV_DIR/Scripts/activate" ]; then
    echo "Error: Virtual environment invalid (no activate script) at $VENV_DIR" >&2
    exit 1
fi

VENV_PYTHON=$(get_venv_python)
if [ -z "$VENV_PYTHON" ] || ! [ -x "$VENV_PYTHON" ]; then
    echo "Error: Python not found in virtual environment $VENV_DIR" >&2
    exit 1
fi

if [ ! -f "$NUDE_DETECTOR" ]; then
    echo "Error: nude_detector.py not found at $NUDE_DETECTOR" >&2
    exit 1
fi

# On Windows/Cygwin, pass Windows paths to native Python so it can open files
NUDE_DETECTOR_PY=$(convert_path_for_python "$NUDE_DETECTOR")
if [ "$OS_TYPE" = "windows" ]; then
    CONVERTED_ARGS=()
    for arg in "$@"; do
        if [ -e "$arg" ]; then
            CONVERTED_ARGS+=("$(convert_path_for_python "$arg")")
        else
            CONVERTED_ARGS+=("$arg")
        fi
    done
    set -- "${CONVERTED_ARGS[@]}"
fi

exec "$VENV_PYTHON" "$NUDE_DETECTOR_PY" "$@"
