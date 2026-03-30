# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 2.0.x | Yes |
| < 2.0 | No |

## Reporting a vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public issue
2. Email **silbercue@gmail.com** with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
3. You will receive a response within 48 hours

## Security measures in v2.0.0

- NSPredicate injection prevention in log filters (user input sanitized)
- License cache file permissions restricted to owner-only
- No secrets stored in binary or source code
- API tokens stored locally, never committed (`.gitignore` enforced)
- Full security audit passed (0 critical, 0 high findings)

## Scope

This policy covers the SilbercueSwift MCP server binary. Third-party dependencies (MCP SDK, SwiftNIO) have their own security policies.
