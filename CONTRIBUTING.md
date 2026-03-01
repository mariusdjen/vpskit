# Contributing to vpskit

Thanks for wanting to contribute! Here are the project rules.

## Conventions

### Language

- All user-facing text in scripts is in **French with accents**
- Commit messages are in English
- Comments in code can be in French or English

### Code style

- No emojis, no Unicode symbols
- ASCII indicators: `[INFO]`, `[OK]`, `[WARN]`, `[ERR]`, `[>]`
- No em dashes, use regular dashes
- Remote scripts are written to a temporary file (mktemp), sent via scp, executed via ssh
- Placeholders: `__NAME__` replaced by sed with `|` as delimiter

### Tests

Before submitting:

```bash
bash -n setup.sh
bash -n deploy.sh
bash -n status.sh
bash -n backup.sh
bash -n vpskit.sh
```

## How to contribute

1. Fork the project
2. Create a branch (`git checkout -b my-feature`)
3. Commit your changes
4. Push the branch (`git push origin my-feature`)
5. Open a Pull Request

## Report a bug

Use [GitHub Issues](https://github.com/mariusdjen/vpskit/issues) with the bug report template.

## Suggest a feature

Use [GitHub Issues](https://github.com/mariusdjen/vpskit/issues) with the feature request template.
