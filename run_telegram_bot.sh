#!/bin/bash

# Script to run the Telegram bot with virtual environment management
# Checks if venv exists, creates/updates it if needed, then runs the bot

SCRIPT_DIR=$(dirname "$0")
BOT_SCRIPT="$SCRIPT_DIR/telegram_bot.py"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"

# Detect OS and set venv directory accordingly
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
            # Default to linux for other Unix-like systems
            OS_TYPE="linux"
            ;;
    esac
else
    # If uname not available, try to detect from environment
    if [ -d "/cygdrive" ] || [ -n "$WINDIR" ]; then
        OS_TYPE="windows"
    else
        OS_TYPE="linux"
    fi
fi

VENV_DIR="$SCRIPT_DIR/venv_${OS_TYPE}"

# Find working Python executable (try python3 first, then python)
# Check if command exists AND actually works (not a Windows stub)
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" >/dev/null 2>&1; then
        # Try to get version to verify it actually works
        # Redirect both stdout and stderr to check for Windows stub messages
        version_output=$("$cmd" --version 2>&1)
        exit_code=$?
        # Check if it succeeded and doesn't contain Windows stub messages
        if [ $exit_code -eq 0 ] && ! echo "$version_output" | grep -qiE "Microsoft Store|instalar|configurações|não foi encontrado|not found"; then
            PYTHON_CMD="$cmd"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo "Error: Python 3 not found or not working."
    echo ""
    echo "The 'python3' or 'python' commands exist but appear to be Windows stubs."
    echo "Please install Python 3 from https://www.python.org/downloads/"
    echo "or ensure Python is properly installed and in your PATH."
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_CMD" --version 2>&1)
echo "Detected OS: $OS_TYPE"
echo "Using Python: $PYTHON_CMD ($PYTHON_VERSION)"
echo "Virtual environment: $VENV_DIR"

# Check if bot script exists
if [ ! -f "$BOT_SCRIPT" ]; then
    echo "Error: telegram_bot.py not found at $BOT_SCRIPT"
    exit 1
fi

# Check if requirements file exists
if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo "Error: requirements.txt not found at $REQUIREMENTS_FILE"
    exit 1
fi

# Function to check if venv exists and is valid
venv_exists() {
    if [ -d "$VENV_DIR" ] && ([ -f "$VENV_DIR/bin/activate" ] || [ -f "$VENV_DIR/Scripts/activate" ]); then
        return 0
    fi
    return 1
}

# Function to create venv
create_venv() {
    echo "Creating virtual environment..."
    $PYTHON_CMD -m venv "$VENV_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create virtual environment"
        exit 1
    fi
    echo "Virtual environment created successfully"
}

# Function to activate venv
activate_venv() {
    if [ -f "$VENV_DIR/bin/activate" ]; then
        source "$VENV_DIR/bin/activate"
    elif [ -f "$VENV_DIR/Scripts/activate" ]; then
        # Windows/Cygwin path
        source "$VENV_DIR/Scripts/activate"
    else
        echo "Error: Could not find venv activation script"
        exit 1
    fi
}

# Function to get Python executable from venv
get_venv_python() {
    if [ -f "$VENV_DIR/bin/python" ]; then
        echo "$VENV_DIR/bin/python"
    elif [ -f "$VENV_DIR/Scripts/python.exe" ]; then
        # Windows/Cygwin path
        echo "$VENV_DIR/Scripts/python.exe"
    elif [ -f "$VENV_DIR/Scripts/python" ]; then
        echo "$VENV_DIR/Scripts/python"
    else
        echo ""
    fi
}

# Function to update pip and install requirements
setup_venv() {
    VENV_PYTHON=$(get_venv_python)
    if [ -z "$VENV_PYTHON" ]; then
        echo "Error: Could not find Python executable in virtual environment"
        exit 1
    fi
    
    echo "Updating pip..."
    "$VENV_PYTHON" -m pip install --upgrade pip --quiet
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to update pip"
        exit 1
    fi
    
    echo "Installing requirements..."
    "$VENV_PYTHON" -m pip install -r "$REQUIREMENTS_FILE"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install requirements"
        exit 1
    fi
    
    echo "Virtual environment setup complete"
}

# Function to check if requirements are installed
requirements_installed() {
    VENV_PYTHON=$(get_venv_python)
    if [ -z "$VENV_PYTHON" ]; then
        return 1
    fi
    
    # Check if telegram module is installed
    "$VENV_PYTHON" -c "import telegram" >/dev/null 2>&1
    return $?
}

# Main logic
if venv_exists; then
    echo "Virtual environment found at $VENV_DIR"
    activate_venv
    echo "Activated virtual environment"
    
    # Check if requirements are installed
    if ! requirements_installed; then
        echo "Requirements not found in virtual environment, installing..."
        setup_venv
    else
        echo "Requirements already installed"
    fi
else
    echo "Virtual environment not found"
    create_venv
    activate_venv
    setup_venv
fi

# Verify we're in the venv
if [ -z "$VIRTUAL_ENV" ]; then
    echo "Warning: VIRTUAL_ENV not set, but continuing..."
fi

# Run the bot using the venv's Python
VENV_PYTHON=$(get_venv_python)
if [ -z "$VENV_PYTHON" ]; then
    echo "Warning: Could not find venv Python, using system Python"
    PYTHON_RUN_CMD="$PYTHON_CMD"
else
    PYTHON_RUN_CMD="$VENV_PYTHON"
fi

echo "Starting Telegram bot..."
$PYTHON_RUN_CMD "$BOT_SCRIPT" "$@"

