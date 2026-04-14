# Contributing

Thanks for helping improve macOS App Updater.

## Good first contributions

- fix incorrect or stale documentation
- improve error messages or help text
- tighten safety checks around package-manager calls
- add small, well-scoped flags that fit the script's current design

## Before you open a pull request

1. Keep changes focused. This repo is a single-script utility, so small PRs are easier to review.
2. Update `README.md` when behavior or flags change.
3. Update `CHANGELOG.md` for user-visible changes.
4. Validate the script locally:

```bash
bash -n update-all.sh
./update-all.sh --help >/dev/null
```

If you change execution behavior, include the exact command you used for testing and whether it was run with `--dry-run`.

## Pull request notes

Please include:

- what changed
- why it helps
- link the related issue, if applicable
- any macOS, Homebrew, npm, or `mas` assumptions
- log excerpts only after removing personal paths, usernames, tokens, and other sensitive details

Follow `.github/pull_request_template.md` for the summary, linked issue, and interface-governance checklist when changing contracts, fingerprints, checkpoints, or summary output.

## Scope guardrails

This project aims to stay simple:

- no background daemons
- no hidden telemetry
- no automatic remote uploads
- no destructive cleanup beyond the script's documented package-manager actions

When in doubt, prefer the smallest clear improvement.
