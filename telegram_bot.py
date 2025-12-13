#!/usr/bin/env python3
"""
Telegram bot that listens for links from the owner and calls nostr_media_uploader.sh
"""

import os
import re
import sys
import subprocess
import asyncio
import logging
import yaml
import argparse
from pathlib import Path
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes


# Configure logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Configuration
CONFIG_FILE = os.getenv('TELEGRAM_BOT_CONFIG', 'telegram_bot.yaml')

# URL regex pattern to match http/https links
URL_PATTERN = re.compile(
    r'http[s]?://(?:[a-zA-Z]|[0-9]|[$-_@.&+]|[!*\\(\\),]|(?:%[0-9a-fA-F][0-9a-fA-F]))+'
)


def load_config(config_path, use_firefox=True):
    """Load configuration from YAML file.
    
    Expected structure:
    bot_token: YOUR_BOT_TOKEN
    owner_id: YOUR_USER_ID
    script_path: ./nostr_media_uploader.sh
    channels:
      channel1:
        chat_id: -1001234567890
        profile_name: tarado
      channel2:
        chat_id: @channelname
        profile_name: another_profile
    """
    if not os.path.exists(config_path):
        logger.error(f"Configuration file not found: {config_path}")
        raise FileNotFoundError(f"Configuration file not found: {config_path}")
    
    with open(config_path, 'r', encoding='utf-8') as f:
        config_data = yaml.safe_load(f)
    
    if not config_data:
        raise ValueError("Configuration file is empty or invalid")
    
    # Validate required global settings
    if 'bot_token' not in config_data:
        raise ValueError("bot_token is required in configuration")
    if 'owner_id' not in config_data:
        raise ValueError("owner_id is required in configuration")
    
    return {
        'bot_token': config_data.get('bot_token'),
        'owner_id': int(config_data.get('owner_id', 0)),
        'script_path': config_data.get('script_path', './nostr_media_uploader.sh'),
        'cygwin_root': config_data.get('cygwin_root'),  # Optional: path to Cygwin installation
        'nostr_client_url': config_data.get('nostr_client_url'),  # Optional: URL template for nostr client links
        'channels': config_data.get('channels', {}),
        'use_firefox': use_firefox,
    }


def find_channel_config(config, chat_id=None, chat_username=None):
    """Find channel configuration matching the given chat_id or username.
    
    Returns the channel config dict if found, None otherwise.
    """
    channels = config.get('channels', {})
    
    if not chat_id and not chat_username:
        return None
    
    chat_id_str = str(chat_id) if chat_id else None
    chat_username_str = chat_username.lstrip('@') if chat_username else None
    
    # Search through channels for a match
    for channel_name, channel_config in channels.items():
        channel_chat_id = channel_config.get('chat_id')
        if not channel_chat_id:
            continue
        
        channel_chat_id_str = str(channel_chat_id).lstrip('@')
        
        # Match by numeric ID
        if chat_id_str and chat_id_str == channel_chat_id_str:
            logger.debug(f"Found channel config '{channel_name}' for chat_id={chat_id_str}")
            return channel_config
        
        # Match by username
        if chat_username_str and chat_username_str == channel_chat_id_str:
            logger.debug(f"Found channel config '{channel_name}' for username={chat_username_str}")
            return channel_config
    
    return None


def extract_urls(text):
    """Extract all URLs from a text message."""
    if not text:
        return []
    return URL_PATTERN.findall(text)


def extract_extra_text(text, urls):
    """Extract text remaining after URLs are removed."""
    if not text:
        return ""
    
    # Remove all URLs from text
    text_without_urls = text
    for url in urls:
        text_without_urls = text_without_urls.replace(url, '', 1)
    
    # Clean up extra whitespace
    extra_text = ' '.join(text_without_urls.split()).strip()
    return extra_text


def extract_event_id(output):
    """Extract event ID from nak output.
    
    nak outputs the event ID after creating an event. We need to find the actual
    Nostr event ID, not file hashes or other hex strings.
    
    The event ID is typically output by nak in JSON format or as a standalone hex string.
    We should exclude hex strings that appear in URLs (like blossom file hashes).
    """
    # First, collect all hex strings that appear in URLs to exclude them
    url_hex = set()
    for url_match in re.finditer(r'https?://[^\s\)]+', output):
        url = url_match.group(0)
        # Extract hex strings from URLs (these are file hashes, not event IDs)
        url_hex.update(re.findall(r'([0-9a-fA-F]{64})', url))
    
    # nak might output JSON with the event - look for complete JSON objects
    # Try to find JSON objects that contain "id", "kind", "pubkey" (event structure)
    json_object_pattern = r'\{[^{}]*"id"\s*:\s*"([0-9a-fA-F]{64})"[^{}]*"kind"\s*:\s*\d+[^{}]*\}'
    json_matches = re.findall(json_object_pattern, output, re.DOTALL)
    if json_matches:
        # Return the last JSON match (most likely the event from nak)
        event_id = json_matches[-1]
        if event_id not in url_hex:
            return event_id
    
    # Look for JSON with "id" field - nak might output just the event ID in JSON
    json_id_patterns = [
        r'\{\s*"id"\s*:\s*"([0-9a-fA-F]{64})"',  # JSON starting with id
        r'"id"\s*:\s*"([0-9a-fA-F]{64})"',  # JSON id field (but not in URLs)
    ]
    
    for pattern in json_id_patterns:
        matches = re.findall(pattern, output)
        if matches:
            # Return the last match that's not in a URL
            for event_id in reversed(matches):
                if event_id not in url_hex:
                    return event_id
    
    # Look for event ID after "Successfully published" or similar success messages
    # nak might output the event ID on a line after success message
    success_patterns = [
        r'Successfully published[^\n]*\n[^\n]*([0-9a-fA-F]{64})',
        r'published[^\n]*event[^\n]*\n[^\n]*([0-9a-fA-F]{64})',
        r'event[^\n]*created[^\n]*\n[^\n]*([0-9a-fA-F]{64})',
    ]
    
    for pattern in success_patterns:
        match = re.search(pattern, output, re.IGNORECASE | re.MULTILINE)
        if match:
            event_id = match.group(1)
            if event_id not in url_hex:
                return event_id
    
    # Look for hex strings near the end of output (nak usually outputs event ID at the end)
    # But exclude common file hashes that appear in URLs
    lines = output.split('\n')
    # Check last 30 lines for event ID
    for line in reversed(lines[-30:]):
        # Skip lines that contain URLs
        if re.search(r'https?://', line):
            continue
        hex_matches = re.findall(r'\b([0-9a-fA-F]{64})\b', line)
        if hex_matches:
            # Return the first match from this line that's not in URLs
            for hex_id in hex_matches:
                if hex_id not in url_hex:
                    return hex_id
    
    # Last resort: look for any 64-char hex string, but exclude ones in URLs
    all_hex = re.findall(r'\b([0-9a-fA-F]{64})\b', output)
    if all_hex:
        # Return the last hex that's not in a URL
        for hex_id in reversed(all_hex):
            if hex_id not in url_hex:
                return hex_id
    
    return None


async def encode_to_nevent(event_id_hex):
    """Encode event ID to nevent format using nak command."""
    if not event_id_hex or len(event_id_hex) != 64:
        return None
    
    try:
        process = await asyncio.create_subprocess_exec(
            'nak', 'encode', 'nevent', event_id_hex,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        stdout_bytes, stderr_bytes = await process.communicate()
        
        if process.returncode == 0 and stdout_bytes:
            # Decode and clean up output
            nevent = stdout_bytes.decode('utf-8', errors='replace').strip()
            # Take first line in case there are multiple lines
            nevent = nevent.split('\n')[0].strip()
            if nevent.startswith('nevent1'):
                return nevent
            else:
                logger.warning(f"nak encode nevent returned unexpected format: {nevent}")
        else:
            stderr = stderr_bytes.decode('utf-8', errors='replace') if stderr_bytes else ''
            logger.warning(f"nak encode nevent failed: {stderr}")
    except Exception as e:
        logger.warning(f"Failed to encode nevent using nak: {e}")
    
    return None


def is_cygwin():
    """Check if running on Cygwin."""
    try:
        # Check for Cygwin-specific environment or commands
        if os.path.exists('/usr/bin/cygpath') or os.path.exists('/cygdrive'):
            return True
        # Check OSTYPE environment variable
        if os.environ.get('OSTYPE', '').startswith('cygwin'):
            return True
        # Try to run cygpath to verify
        result = subprocess.run(
            ['cygpath', '-u', '/'],
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.returncode == 0:
            return True
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    
    return False


def find_cygwin_installation():
    """Find Cygwin installation directory.
    
    Returns the path to Cygwin root directory (e.g., C:\\cygwin64 or F:\\cygwin64),
    or None if not found.
    """
    # Common Cygwin installation locations
    common_paths = [
        r'C:\cygwin64',
        r'C:\cygwin',
        r'D:\cygwin64',
        r'D:\cygwin',
        r'E:\cygwin64',
        r'E:\cygwin',
        r'F:\cygwin64',
        r'F:\cygwin',
    ]
    
    # Check if CYGWIN_ROOT environment variable is set
    cygwin_root = os.environ.get('CYGWIN_ROOT') or os.environ.get('CYGWIN_HOME')
    if cygwin_root:
        cygwin_root = os.path.normpath(cygwin_root)
        if os.path.exists(cygwin_root):
            bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
            bash_path = os.path.normpath(bash_path)
            if os.path.exists(bash_path):
                return cygwin_root
    
    # Check common locations
    for cygwin_root in common_paths:
        cygwin_root = os.path.normpath(cygwin_root)
        bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
        bash_path = os.path.normpath(bash_path)
        if os.path.exists(bash_path):
            return cygwin_root
    
    # Try to detect from PATH if bash.exe is found
    try:
        # On Windows, prevent console window
        startupinfo = None
        if os.name == 'nt':
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = subprocess.SW_HIDE
        
        result = subprocess.run(
            ['where', 'bash.exe'] if os.name == 'nt' else ['which', 'bash'],
            capture_output=True,
            text=True,
            timeout=2,
            startupinfo=startupinfo
        )
        if result.returncode == 0:
            bash_exe_path = result.stdout.strip().split('\n')[0]
            # Extract Cygwin root from path (e.g., C:\cygwin64\bin\bash.exe -> C:\cygwin64)
            if 'cygwin' in bash_exe_path.lower():
                # Try common patterns
                for pattern in [r'\cygwin64\bin', r'\cygwin\bin']:
                    if pattern in bash_exe_path:
                        cygwin_root = bash_exe_path.split(pattern)[0]
                        cygwin_root = os.path.normpath(cygwin_root)
                        if os.path.exists(cygwin_root):
                            return cygwin_root
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    
    return None


def get_bash_path(config=None):
    """Get the correct bash path for the current environment.
    
    Args:
        config: Optional config dict that may contain 'cygwin_root'
    
    Returns:
        Path to bash executable (Windows path if running Windows Python, Unix path if running Cygwin Python)
    """
    cygwin_root = None
    # Detect Windows Python - check both os.name and sys.platform for reliability
    is_windows_python = (os.name == 'nt' or sys.platform.startswith('win'))
    
    # First, try to get from config
    if config and config.get('cygwin_root'):
        cygwin_root = config['cygwin_root']
        cygwin_root = os.path.normpath(cygwin_root)
        bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
        bash_path = os.path.normpath(bash_path)
        if os.path.exists(bash_path):
            logger.info(f"Using configured Cygwin bash: {bash_path}")
            return bash_path
        logger.warning(f"Configured cygwin_root '{cygwin_root}' not found or bash.exe missing at {bash_path}, trying auto-detection")
    
    # If running Windows Python, we MUST use Windows paths, even if Cygwin is detected
    if is_windows_python:
        # Find Cygwin installation
        if not cygwin_root:
            cygwin_root = find_cygwin_installation()
        
        if cygwin_root:
            # Normalize the path for Windows
            cygwin_root = os.path.normpath(cygwin_root)
            bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
            bash_path = os.path.normpath(bash_path)
            
            if os.path.exists(bash_path):
                logger.info(f"Using Cygwin bash from: {bash_path}")
                return bash_path
            else:
                logger.warning(f"Found Cygwin root at {cygwin_root} but bash.exe not found at {bash_path}")
        
        # Default to 'bash' (will use system PATH)
        logger.warning("Could not find Cygwin installation, falling back to 'bash' from PATH")
        return 'bash'
    
    # If running from within Cygwin Python, use Unix paths
    # Check if we're actually running from Cygwin (not just detecting Cygwin exists)
    if is_cygwin() and os.path.exists('/usr/bin/bash'):
        # Try common Cygwin bash locations
        cygwin_bash_paths = [
            '/usr/bin/bash',
            '/bin/bash',
        ]
        for bash_path in cygwin_bash_paths:
            if os.path.exists(bash_path):
                return bash_path
        # Fallback: try to find bash in PATH but prefer /usr/bin
        try:
            # On Windows, prevent console window
            startupinfo = None
            if os.name == 'nt':
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE
            
            result = subprocess.run(
                ['which', 'bash'],
                capture_output=True,
                text=True,
                timeout=2,
                startupinfo=startupinfo
            )
            if result.returncode == 0:
                bash_path = result.stdout.strip()
                if bash_path and os.path.exists(bash_path):
                    return bash_path
                return '/usr/bin/bash'
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
    
    # Default to 'bash' (will use system PATH)
    logger.warning("Could not determine bash path, falling back to 'bash' from PATH")
    return 'bash'


def convert_path_for_cygwin(path, config=None):
    """Convert Windows path to Cygwin path if running on Cygwin or using Cygwin bash.
    
    Args:
        path: Windows path to convert
        config: Optional config dict that may contain 'cygwin_root'
    
    Returns:
        Cygwin-style path if conversion is possible, original path otherwise
    """
    # If running from within Cygwin, use cygpath
    if is_cygwin():
        if not os.path.exists(path):
            return path
        
        try:
            # On Windows, prevent console window
            startupinfo = None
            if os.name == 'nt':
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE
            
            result = subprocess.run(
                ['cygpath', '-u', path],
                capture_output=True,
                text=True,
                timeout=5,
                startupinfo=startupinfo
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
    
    # If using Cygwin bash from Windows Python, convert path manually
    cygwin_root = None
    if config and config.get('cygwin_root'):
        cygwin_root = config['cygwin_root']
    else:
        cygwin_root = find_cygwin_installation()
    
    if cygwin_root and os.name == 'nt':
        # Convert Windows path to Cygwin path
        # e.g., F:\cygwin64\home\user\file -> /home/user/file
        # or F:\other\path\to\file -> /cygdrive/f/other/path/to/file
        cygwin_root_norm = os.path.normpath(cygwin_root).replace('\\', '/')
        path_norm = os.path.normpath(path).replace('\\', '/')
        
        # Check if path is within Cygwin root
        if path_norm.lower().startswith(cygwin_root_norm.lower()):
            # Path is within Cygwin, convert directly
            cygwin_path = path_norm[len(cygwin_root_norm):].replace('\\', '/')
            if cygwin_path.startswith('/'):
                return cygwin_path
            return '/' + cygwin_path
        else:
            # Path is outside Cygwin, use /cygdrive/X/... format
            # Extract drive letter (e.g., F:)
            drive_match = re.match(r'^([A-Za-z]):', path_norm)
            if drive_match:
                drive_letter = drive_match.group(1).lower()
                # Remove drive letter and convert
                rest_path = path_norm[2:].replace('\\', '/')
                return f'/cygdrive/{drive_letter}{rest_path}'
    
    return path


def build_command(profile_name, script_path, urls, extra_text, use_firefox=True, config=None):
    """Build the command to execute nostr_media_uploader.sh."""
    # Convert script path to absolute path
    script_path = Path(script_path)
    if not script_path.is_absolute():
        script_dir = Path(__file__).parent.absolute()
        script_path = script_dir / script_path
    
    script_path = str(script_path)
    
    # Convert to Cygwin path if needed (using config if available)
    script_path = convert_path_for_cygwin(script_path, config)
    
    # Get the correct bash path for the environment
    bash_path = get_bash_path(config)
    
    # Validate bash path exists
    if not os.path.exists(bash_path) and os.path.isabs(bash_path):
        raise FileNotFoundError(f"Bash executable not found: {bash_path}")
    
    logger.info(f"Using bash: {bash_path}")
    logger.info(f"Script path: {script_path}")
    
    # Build command: bash script_path -p profile_name [--firefox] url1 url2 ... "extra_text"
    cmd = [bash_path, script_path, '-p', profile_name]
    
    # Always add --firefox unless explicitly disabled
    if use_firefox:
        cmd.append('--firefox')
        logger.info("Adding --firefox parameter")
    
    # Add all URLs as separate arguments
    cmd.extend(urls)
    
    # Add extra text if present
    if extra_text:
        cmd.append(extra_text)
    
    return cmd


async def execute_script(cmd, cwd=None):
    """Execute the script and capture output."""
    try:
        # Log full command for debugging
        logger.info(f"Executing command: {cmd}")
        logger.info(f"Command string: {' '.join(str(arg) for arg in cmd)}")
        
        # Validate first argument (executable) exists if it's an absolute path
        executable = cmd[0] if cmd else None
        if executable and os.path.isabs(executable) and not os.path.exists(executable):
            error_msg = f"Executable not found: {executable}"
            logger.error(error_msg)
            return {
                'returncode': -1,
                'stdout': '',
                'stderr': error_msg,
                'success': False
            }
        
        # On Windows, prevent console window from appearing
        startupinfo = None
        if os.name == 'nt':
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = subprocess.SW_HIDE
        
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd or Path(__file__).parent,
            startupinfo=startupinfo
        )
        
        stdout_bytes, stderr_bytes = await process.communicate()
        
        # Decode bytes to strings
        stdout = stdout_bytes.decode('utf-8', errors='replace') if stdout_bytes else ''
        stderr = stderr_bytes.decode('utf-8', errors='replace') if stderr_bytes else ''
        
        # Log captured output for debugging
        logger.debug(f"Script returncode: {process.returncode}")
        logger.debug(f"Script stdout length: {len(stdout)} bytes")
        logger.debug(f"Script stderr length: {len(stderr)} bytes")
        if stdout:
            logger.debug(f"Script stdout (first 500 chars): {stdout[:500]}")
        if stderr:
            logger.debug(f"Script stderr (first 500 chars): {stderr[:500]}")
        
        return {
            'returncode': process.returncode,
            'stdout': stdout,
            'stderr': stderr,
            'success': process.returncode == 0
        }
    except Exception as e:
        logger.exception(f"Exception while executing script: {e}")
        return {
            'returncode': -1,
            'stdout': '',
            'stderr': str(e),
            'success': False
        }


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle incoming messages and process links from the owner."""
    # Handle both regular messages and channel posts
    message = update.message or update.channel_post
    edited_message = update.edited_message or update.edited_channel_post
    
    # Use edited message if available, otherwise use regular message
    message = edited_message or message
    
    if not message:
        # Not a message update, ignore
        return
    
    # Get config from context
    config = context.bot_data.get('config')
    if not config:
        logger.error("Configuration not found in bot_data")
        return
    
    # Check if message is from the owner
    # For regular messages: check from_user.id matches owner_id
    # For channel posts: check if sender_chat matches a configured channel
    is_owner = False
    channel_config = None
    
    if message.from_user:
        # Regular message - check if user ID matches owner_id
        is_owner = (message.from_user.id == config['owner_id'])
        if not is_owner:
            logger.info(f"Message from non-owner user {message.from_user.id}, ignoring")
            return
        # For regular messages, try to find channel config based on chat
        chat_id = message.chat.id if message.chat.id else None
        chat_username = message.chat.username if message.chat.username else None
        channel_config = find_channel_config(config, chat_id=chat_id, chat_username=chat_username)
    elif message.sender_chat:
        # Channel post - find matching channel config
        sender_chat_id = message.sender_chat.id
        sender_chat_username = message.sender_chat.username if message.sender_chat.username else None
        chat_id = message.chat.id if message.chat.id else None
        chat_username = message.chat.username if message.chat.username else None
        
        # Try to find channel config
        channel_config = find_channel_config(config, chat_id=sender_chat_id, chat_username=sender_chat_username)
        if not channel_config:
            channel_config = find_channel_config(config, chat_id=chat_id, chat_username=chat_username)
        
        if channel_config:
            is_owner = True
            logger.info(f"Channel post accepted: chat_id={sender_chat_id}, chat={chat_id}, found matching channel config")
        else:
            logger.info(f"Channel post from chat_id={sender_chat_id}, chat={chat_id}, no matching channel config found, ignoring")
            return
    else:
        logger.info("Message has no from_user or sender_chat, ignoring")
        return
    
    # Require channel configuration - no default profile
    if not channel_config:
        logger.info("No channel configuration found for this chat, ignoring")
        return
    
    # Get profile name from channel config (required, no default)
    profile_name = channel_config.get('profile_name')
    if not profile_name:
        logger.error(f"Channel config found but profile_name is missing, ignoring")
        return
    
    # Extract text from message
    text = message.text or message.caption or ""
    
    # Extract URLs
    urls = extract_urls(text)
    
    if not urls:
        logger.info("No URLs found in message")
        return
    
    # Extract extra text after URLs
    extra_text = extract_extra_text(text, urls)
    
    try:
        # Send acknowledgment
        status_msg = await message.reply_text(
            f"Processing {len(urls)} URL(s): {urls[0][:50]}{'...' if len(urls[0]) > 50 else ''}..."
        )
        
        # Build command
        cmd = build_command(
            profile_name,
            config['script_path'],
            urls,
            extra_text,
            config.get('use_firefox', True),
            config
        )
        
        # Execute script
        result = await execute_script(cmd)
        
        # Format response
        if result['success']:
            # Log stdout/stderr for debugging
            logger.info(f"Script execution successful. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
            if result['stdout']:
                logger.debug(f"Full stdout: {result['stdout']}")
            if result['stderr']:
                logger.debug(f"Full stderr: {result['stderr']}")
            
            # Try to extract event ID and convert to nevent
            # Check both stdout and stderr, as the script might output to either
            event_id = None
            nevent = None
            
            # Try stdout first
            if result['stdout']:
                event_id = extract_event_id(result['stdout'])
                if event_id:
                    logger.info(f"Extracted event ID from stdout: {event_id}")
            
            # If not found in stdout, try stderr
            if not event_id and result['stderr']:
                event_id = extract_event_id(result['stderr'])
                if event_id:
                    logger.info(f"Extracted event ID from stderr: {event_id}")
            
            # Encode to nevent if we found an event ID
            if event_id:
                nevent = await encode_to_nevent(event_id)
                logger.info(f"Encoded to nevent: {nevent}")
            else:
                logger.warning(f"Could not extract event ID from stdout or stderr. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
                if result['stdout']:
                    logger.warning(f"stdout content (first 500 chars): {result['stdout'][:500]}")
                if result['stderr']:
                    logger.warning(f"stderr content (first 500 chars): {result['stderr'][:500]}")
            
            if nevent:
                # Format response with nostr client link if configured
                if config.get('nostr_client_url'):
                    # Format the client URL with the nevent
                    # Common formats: https://snort.social/e/{nevent} or https://primal.net/e/{nevent}
                    client_url_template = config['nostr_client_url']
                    # Replace {nevent} placeholder if present, otherwise append nevent
                    if '{nevent}' in client_url_template:
                        client_url = client_url_template.format(nevent=nevent)
                    else:
                        # If no placeholder, append /e/nevent or just nevent depending on URL
                        if client_url_template.endswith('/'):
                            client_url = f"{client_url_template}e/{nevent}"
                        else:
                            client_url = f"{client_url_template}/e/{nevent}"
                    
                    # Create clickable link using Markdown format
                    response_msg = f"✅ [View on Nostr]({client_url})\n\n`{nevent}`"
                    await status_msg.edit_text(response_msg, parse_mode='Markdown')
                    logger.info(f"Successfully processed URLs: {urls}, nevent: {nevent}, client_url: {client_url}")
                else:
                    # Return only the nevent formatted ID if no client URL configured
                    await status_msg.edit_text(nevent)
                    logger.info(f"Successfully processed URLs: {urls}, nevent: {nevent}")
            else:
                # Fallback if we couldn't extract/encode event ID
                logger.warning(f"Could not extract event ID from output for URLs: {urls}")
                success_msg = f"✅ Successfully processed {len(urls)} URL(s)"
                if event_id:
                    success_msg += f"\nEvent ID: {event_id} (could not encode to nevent)"
                await status_msg.edit_text(success_msg)
        else:
            # Combine stderr and stdout for error messages (bash scripts often use both)
            error_parts = []
            if result['stderr']:
                error_parts.append(f"Error:\n{result['stderr']}")
            if result['stdout']:
                error_parts.append(f"Output:\n{result['stdout']}")
            
            error_msg = "\n\n".join(error_parts) if error_parts else "Unknown error"
            
            # Telegram has a 4096 character limit per message, so limit to ~3500 to leave room for prefix
            MAX_ERROR_LENGTH = 3500
            if len(error_msg) > MAX_ERROR_LENGTH:
                # Truncate but keep the most important part (usually the end has the actual error)
                truncated_msg = error_msg[:MAX_ERROR_LENGTH]
                # Try to truncate at a newline if possible
                last_newline = truncated_msg.rfind('\n')
                if last_newline > MAX_ERROR_LENGTH * 0.8:  # If we can find a newline in the last 20%
                    truncated_msg = truncated_msg[:last_newline]
                error_display = f"❌ Error processing URL(s)\n\n{truncated_msg}\n\n... (truncated, full error in logs)"
            else:
                error_display = f"❌ Error processing URL(s)\n\n{error_msg}"
            
            await status_msg.edit_text(error_display)
            logger.error(f"Error processing URLs {urls}")
            logger.error(f"stderr: {result['stderr']}")
            logger.error(f"stdout: {result['stdout']}")
            
    except Exception as e:
        logger.exception(f"Exception while processing message: {e}")
        await message.reply_text(f"❌ Exception occurred: {str(e)}")


def main() -> None:
    """Start the bot."""
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description='Telegram bot for nostr_media_uploader')
    parser.add_argument('--no-firefox', action='store_true',
                        help='Disable --firefox parameter when calling nostr_media_uploader.sh')
    parser.add_argument('--config', default=CONFIG_FILE,
                        help=f'Path to configuration file (default: {CONFIG_FILE})')
    args = parser.parse_args()
    
    # Determine if Firefox should be used
    use_firefox = not args.no_firefox
    
    # Load configuration
    try:
        config = load_config(args.config, use_firefox=use_firefox)
    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        return
    
    if not config['bot_token']:
        logger.error("TELEGRAM_BOT_TOKEN not set in configuration")
        return
    
    if config['owner_id'] == 0:
        logger.error("TELEGRAM_OWNER_ID not set in configuration")
        return
    
    # Create application
    application = Application.builder().token(config['bot_token']).build()
    
    # Store config in bot_data for access in handlers
    application.bot_data['config'] = config
    
    # Add message handler
    # With multi-channel support, we listen to all chats and filter in the handler
    # based on channel configuration and owner_id
    message_filter = filters.TEXT | filters.CAPTION
    
    application.add_handler(MessageHandler(message_filter, handle_message))
    
    # Start the bot
    logger.info("Starting bot...")
    logger.info(f"Owner ID: {config['owner_id']}")
    logger.info(f"Script path: {config['script_path']}")
    logger.info(f"Use Firefox: {config.get('use_firefox', True)}")
    channels = config.get('channels', {})
    if channels:
        logger.info(f"Configured channels: {len(channels)}")
        for channel_name, channel_config in channels.items():
            chat_id = channel_config.get('chat_id', 'N/A')
            profile_name = channel_config.get('profile_name', 'N/A')
            logger.info(f"  - {channel_name}: chat_id={chat_id}, profile_name={profile_name}")
    else:
        logger.info("No channels configured - will only process messages from owner")
    logger.info("Bot is ready and listening for messages...")
    
    # Run the bot
    application.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == '__main__':
    main()

