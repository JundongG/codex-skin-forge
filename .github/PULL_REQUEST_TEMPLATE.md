## Summary

Describe what changed and why.

## Security and privacy

- [ ] CDP remains bound to `127.0.0.1`.
- [ ] No customer assets, credentials, private paths, or account data are included.
- [ ] Installation does not download or execute remote code.
- [ ] Process and filesystem changes stay within the documented product scope.

## Validation

- [ ] `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\build-and-verify.ps1`
- [ ] Documentation updated where behavior changed.
- [ ] Visual changes tested on the relevant Codex version, when applicable.
