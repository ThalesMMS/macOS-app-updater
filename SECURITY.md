# Security Policy

## Supported versions

This project does not publish stable tagged releases yet.

Security fixes should be proposed against the current default branch.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Instead:

1. Use GitHub private vulnerability reporting for this repository, if it is enabled.
2. If that setting is not enabled yet, contact the maintainer privately through GitHub.
3. Include a clear description, affected environment, reproduction steps, and impact.
4. Avoid posting secrets, tokens, private file paths, or full local inventories unless they are essential and safely redacted.

### Safe Harbor / Authorization

Good-faith security research and reasonable attempts to identify vulnerabilities under "Reporting a vulnerability" are authorized when they stay within this repository and this script's documented behavior. The maintainer will not pursue legal action for research that follows the responsible disclosure steps above, avoids data exfiltration, and does not disrupt services or access systems, accounts, package-manager data, or local files without permission.

Authorized testing is limited to your own clones, machines, accounts, and test data, or environments where you have explicit permission. If you encounter sensitive data or an unexpected third-party impact, stop testing and report privately through GitHub private vulnerability reporting or by contacting the maintainer privately through GitHub.

## What counts as security-sensitive here

Examples include:

- command injection or unsafe shell execution
- accidental disclosure of local paths, package lists, or logs
- unsafe handling of tokens or credentials from package managers
- behavior that could delete or overwrite user data unexpectedly

Thanks for reporting issues responsibly.
