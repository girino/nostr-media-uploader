# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Security Considerations

### Key Management

**Never commit keys to the repository.** All keys should be stored in environment files in `~/.nostr/`, which are never committed to git.

Supported key formats:
- **NSEC keys** (recommended): Encoded but not encrypted - keep files secure
- **NCRYPT keys**: Password-encrypted - more secure
- **KEY format**: OpenSSL-encrypted - requires password

### Environment Files

Environment files in `~/.nostr/` should:
- Have restricted permissions: `chmod 600 ~/.nostr/*`
- Never be shared or committed to repositories
- Be backed up securely if needed

### History Files

History files (`.history`) contain:
- SHA256 hashes of processed files
- URLs that have been processed

These files are not sensitive but should be kept private to prevent others from seeing what content you've processed.

## Reporting a Vulnerability

If you discover a security vulnerability:

1. **Do not** open a public issue
2. Contact the maintainer directly (via Nostr or repository contact)
3. Provide details about the vulnerability
4. Allow time for a fix before public disclosure

## Security Best Practices

1. **Use encrypted keys** when possible (NCRYPT or KEY format)
2. **Restrict file permissions**: `chmod 600 ~/.nostr/*`
3. **Keep dependencies updated**: Regularly update gallery-dl, yt-dlp, etc.
4. **Review configurations**: Periodically review your configuration files
5. **Use secure networks**: Be cautious when using on public networks

## Historical Security Notes

All hardcoded keys have been removed from git history. The repository has been cleaned starting from commit 72e1fbf, which is the first commit without hardcoded keys.

If you're using an older version or fork, ensure you:
1. Rotate any keys that may have been exposed
2. Update to the latest version with clean history
3. Review your configuration files

