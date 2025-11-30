# Contributing to Nostr Media Uploader

Thank you for your interest in contributing! This document provides guidelines and information for contributors.

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Follow existing code style and patterns
- Test your changes before submitting

## How to Contribute

### Reporting Issues

When reporting issues, please include:
- Operating system and version
- Script version or commit hash
- Steps to reproduce
- Error messages (full output)
- Relevant configuration (without sensitive keys)

### Submitting Changes

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/my-feature`
3. **Make your changes**:
   - Follow existing code style
   - Maintain cross-platform compatibility (Linux/Cygwin)
   - Add appropriate error handling
   - Update documentation if needed
4. **Test your changes**:
   - Test on your platform
   - Verify error handling works correctly
   - Check that scripts still function with existing configurations
5. **Commit your changes**:
   - Use clear, descriptive commit messages
   - Keep commits focused and atomic
6. **Push to your fork**: `git push origin feature/my-feature`
7. **Create a Pull Request**

## Code Style

### Bash Scripting Guidelines

- Use `local` for all function variables
- Use `readonly` for constants
- Prefer functions over repeated code blocks
- Use meaningful variable names
- Add comments for complex logic
- Follow existing indentation (tabs for this project)

### Function Guidelines

- Keep functions focused and small
- Use return variables for complex returns (avoid global state)
- Document function parameters and return values
- Handle errors explicitly

### Platform Compatibility

- Always test on both Linux and Cygwin (if possible)
- Use `OS_TYPE` variable for platform-specific code
- Use `convert_path_for_tool()` for path conversion
- Avoid platform-specific commands when possible

## Testing

Before submitting:
1. Test the main functionality works
2. Test error cases (missing dependencies, invalid inputs)
3. Verify cross-platform compatibility
4. Check that configuration files work correctly

## Documentation

When adding features:
- Update README.md if user-facing
- Update example_env if new configuration options
- Add usage examples if applicable
- Update CHANGELOG.md for significant changes

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (Girino's Anarchist License).

## Questions?

Open an issue with the "question" label for clarification on any aspect of contributing.

