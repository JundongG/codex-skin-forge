# Contributing

Thanks for helping improve Codex Skin Forge.

## Before opening a change

- Keep the project unofficial and avoid OpenAI logos or language that implies endorsement.
- Never commit customer photos, account data, API keys, tokens, private project paths, or paid design assets.
- Keep the CDP endpoint loopback-only and target only Codex `app://` renderer pages.
- Do not introduce installers that download and execute remote scripts.
- Preserve the safe handoff: normal installation must never force-close Codex.

## Development workflow

1. Create a branch from `main`.
2. Make a focused change.
3. Run the Windows validation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\build-and-verify.ps1
```

4. Update documentation and tests when behavior changes.
5. Open a pull request using the repository template.

## Theme contributions

A public theme must not contain unlicensed people, brands, fonts, screenshots, or generated assets. Source templates must remain unshippable until a customer image is supplied, and customer package generation must continue to enforce rights confirmation, dimensions, file type, size, and checksum validation.

## Security changes

Changes that affect CDP binding, process management, package integrity, runtime signature validation, path containment, or uninstall behavior require an explanation of the threat model and a regression test.

Do not disclose vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md).
