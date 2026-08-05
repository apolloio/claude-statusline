# Contributing

Thanks for helping improve `claude-statusline`.

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- Open an issue before making a large behavioral or architectural change.
- Report vulnerabilities through the private process in [SECURITY.md](SECURITY.md),
  not through a public issue.

## Development setup

Install Bash, `jq`, and [bats-core](https://github.com/bats-core/bats-core).
The statusline must remain compatible with the Bash 3.2 version shipped by
macOS and with both BSD and GNU command variants.

Run the project locally with:

```bash
bash statusline-command.sh < examples/input.json
```

## Making changes

- Treat [SPEC.md](SPEC.md) as the authoritative behavior contract.
- Keep the script dependency-free beyond the tools listed in the README.
- Preserve the two-line output contract and avoid adding work to every render
  when it can be deferred to an existing background path.
- Add or update Bats coverage for behavior changes.
- Update `SPEC.md` when behavior changes and user-facing documentation when
  configuration or output changes.

## Validation

Before submitting a pull request, run:

```bash
bash -n statusline-command.sh install.sh
bats tests/
git diff --check
```

Describe the user-visible outcome and any compatibility or security impact in
the pull request. Keep each pull request focused enough to review and revert
independently.
