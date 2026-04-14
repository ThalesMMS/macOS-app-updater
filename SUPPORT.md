# Support

## Best place to start

- **Bug report:** open the bug report form with reproduction steps
- **Feature idea:** open the feature request form with the use case
- **Sensitive problem:** follow `SECURITY.md` instead of opening a public issue

## Before opening an issue

Please try:

```bash
bash -n update-all.sh
./update-all.sh --help
./update-all.sh --dry-run
```

If the problem is package-manager specific, also capture the relevant tool versions, for example:

```bash
sw_vers
brew --version
npm --version
mas version
```

## FAQ

### Does this script need `sudo`?

No. The script is designed to avoid `sudo`.

### Is there a safe preview mode?

Yes. Use `./update-all.sh --dry-run` first.

### What should I include in a bug report?

- the exact command you ran
- what you expected
- what happened instead
- your macOS and tool versions
- a **redacted** log excerpt if helpful

### What should I redact?

Remove usernames, home-directory paths, tokens, email addresses, machine names, and anything else you would not want posted publicly.
