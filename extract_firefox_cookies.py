#!/usr/bin/env python3
"""
Extract all cookies from Firefox and save them in Mozilla/Netscape cookie format.

This script reads cookies from Firefox's SQLite database and exports them
in the standard Netscape HTTP Cookie File format.
"""

import os
import sqlite3
import sys
from pathlib import Path
from datetime import datetime


def find_firefox_profile():
    """Find the default Firefox profile directory on Windows."""
    appdata = os.getenv('APPDATA')
    if not appdata:
        raise Exception("APPDATA environment variable not found")
    
    firefox_profiles = Path(appdata) / "Mozilla" / "Firefox" / "Profiles"
    
    if not firefox_profiles.exists():
        raise Exception(f"Firefox profiles directory not found: {firefox_profiles}")
    
    # Find the default profile (usually ends with .default-release or .default)
    profiles = list(firefox_profiles.glob("*.default*"))
    if not profiles:
        # Try any profile directory
        profiles = [p for p in firefox_profiles.iterdir() if p.is_dir()]
    
    if not profiles:
        raise Exception("No Firefox profiles found")
    
    # Prefer default-release, then default, then first available
    default_profile = None
    for profile in profiles:
        if '.default-release' in profile.name:
            default_profile = profile
            break
    
    if not default_profile:
        for profile in profiles:
            if '.default' in profile.name:
                default_profile = profile
                break
    
    if not default_profile:
        default_profile = profiles[0]
    
    return default_profile


def get_cookies_from_database(profile_path):
    """Extract cookies from Firefox's cookies.sqlite database."""
    cookies_db = profile_path / "cookies.sqlite"
    
    if not cookies_db.exists():
        raise Exception(f"Cookies database not found: {cookies_db}")
    
    # Firefox may lock the database, so we'll try to copy it first
    import shutil
    import tempfile
    
    temp_db = None
    try:
        # Try to open the database directly first
        try:
            conn = sqlite3.connect(str(cookies_db))
            cursor = conn.cursor()
        except sqlite3.OperationalError:
            # If locked, copy to temp location
            temp_db = tempfile.NamedTemporaryFile(delete=False, suffix='.sqlite')
            temp_db.close()
            shutil.copy2(cookies_db, temp_db.name)
            conn = sqlite3.connect(temp_db.name)
            cursor = conn.cursor()
        
        # Query cookies
        cursor.execute("""
            SELECT host, path, isSecure, expiry, name, value, isHttpOnly
            FROM moz_cookies
            ORDER BY host, path, name
        """)
        
        cookies = cursor.fetchall()
        conn.close()
        
        return cookies
    finally:
        if temp_db and os.path.exists(temp_db.name):
            os.unlink(temp_db.name)


def format_cookie_line(host, path, is_secure, expiry, name, value, is_http_only):
    """
    Format a cookie in Netscape HTTP Cookie File format.
    
    Format: domain flag path secure expiration name value
    
    - domain: The domain that created the cookie
    - flag: TRUE if all machines within a given domain can access the cookie
    - path: The path within the domain for which the cookie is valid
    - secure: TRUE if the cookie should only be transmitted over secure connections
    - expiration: The expiration date of the cookie as a Unix timestamp
    - name: The name of the cookie
    - value: The value of the cookie
    """
    # Determine if domain flag should be TRUE (subdomain access) or FALSE (exact host)
    # If host starts with '.', it's a domain cookie (TRUE), otherwise FALSE
    domain_flag = "TRUE" if host.startswith('.') else "FALSE"
    
    # Ensure host starts with a dot for domain cookies
    if domain_flag == "TRUE" and not host.startswith('.'):
        domain = '.' + host
    else:
        domain = host
    
    # Convert secure flag
    secure_flag = "TRUE" if is_secure else "FALSE"
    
    # Convert expiry (already a Unix timestamp in Firefox)
    expiration = int(expiry) if expiry else 0
    
    # Format: domain \t flag \t path \t secure \t expiration \t name \t value
    return f"{domain}\t{domain_flag}\t{path}\t{secure_flag}\t{expiration}\t{name}\t{value}"


def extract_cookies(output_file=None):
    """Extract all Firefox cookies and save to file."""
    if output_file is None:
        output_file = "firefox_cookies.txt"
    
    print("Finding Firefox profile...")
    profile_path = find_firefox_profile()
    print(f"Found profile: {profile_path}")
    
    print("Reading cookies from database...")
    cookies = get_cookies_from_database(profile_path)
    print(f"Found {len(cookies)} cookies")
    
    print(f"Writing cookies to {output_file}...")
    with open(output_file, 'w', encoding='utf-8') as f:
        # Write Netscape cookie file header
        f.write("# Netscape HTTP Cookie File\n")
        f.write("# This is a generated file! Do not edit.\n")
        f.write(f"# Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write("\n")
        
        # Write each cookie
        for cookie in cookies:
            host, path, is_secure, expiry, name, value, is_http_only = cookie
            line = format_cookie_line(host, path, is_secure, expiry, name, value, is_http_only)
            f.write(line + "\n")
    
    print(f"Successfully exported {len(cookies)} cookies to {output_file}")
    return output_file


def main():
    """Main entry point."""
    output_file = None
    
    if len(sys.argv) > 1:
        output_file = sys.argv[1]
    
    try:
        extract_cookies(output_file)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

