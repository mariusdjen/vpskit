# Security Policy

## Reporting a vulnerability

If you find a security vulnerability, please open a [GitHub issue](https://github.com/mariusdjen/vpskit/issues) or contact the maintainer directly.

Do not include sensitive details (credentials, server IPs) in public issues. Use a private channel if the vulnerability could be exploited before a fix is released.

## Security practices

This project follows strict security practices across all scripts:

### Input sanitization
- **`sed_escape()`** - All user inputs are escaped before use in `sed` substitutions to prevent injection.
- **`read_state_var()`** - Configuration files are read with `grep` + `cut`, never with `source` or `eval`, to prevent arbitrary code execution.

### Remote script execution
- Scripts sent to the VPS use **quoted heredocs** (`<< 'EOF'`) to prevent variable expansion in templates.
- Placeholders (`__NAME__`) are replaced with `sed` using escaped values.
- Remote temp files use **`mktemp`** (unpredictable names), are set to **chmod 700**, and are deleted after execution.

### File permissions
- Session files (`~/.ssh/.vpskit-local`): **chmod 600**
- S3 credentials (`~/.ssh/.vpskit-s3`): **chmod 600**
- `.env` files: **chmod 600**
- Remote scripts: **chmod 700**

### Downloaded code
- All downloads use **HTTPS only**.
- Language files are validated with **`bash -n`** (syntax check) before being sourced.
- GPG signature verification is used where available (e.g. Caddy repository).

### Temporary files
- All scripts use **`mktemp`** for temporary files.
- A **`trap cleanup EXIT`** ensures temp files are removed even on error.

### Secrets
- S3 Secret Access Key input is **masked** (`read -s`).
- Credentials are written with `printf`, not heredocs, to prevent `$` expansion.

## Architecture decisions

- **`curl | bash`** is used for initial installation. This is a deliberate trade-off common in CLI tools (Docker, Homebrew, rustup). It is mitigated by HTTPS-only URLs and syntax validation.
- The project targets **initial VPS setup** where the user has root access. Scripts are designed to run once, not as long-running services.

## Supported versions

Only the latest version on the `main` branch receives security updates.
