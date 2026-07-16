# Security Policy

## Supported versions

The latest commit on `main` and the latest tagged release receive security fixes.

## Reporting a vulnerability

Please use GitHub Private Vulnerability Reporting:

https://github.com/JundongG/codex-skin-forge/security/advisories/new

Do not open a public issue containing exploit details, credentials, customer assets, or private paths.

Include:

- affected commit or release;
- Windows and Codex versions;
- reproduction steps using non-sensitive test data;
- expected and observed behavior;
- security impact;
- a suggested fix, if available.

You should receive an acknowledgement within seven days. Please allow time for a fix and coordinated disclosure.

## Security boundaries

The project is designed to:

- bind Chromium CDP to `127.0.0.1` on a random port;
- connect only to Codex `app://` renderer pages;
- avoid modifying WindowsApps, `app.asar`, or Codex signatures;
- avoid network downloads during customer installation;
- verify the copied OpenJS Node.js signature and version;
- verify customer package checksums and image metadata;
- avoid reading conversations, accounts, project files, API keys, or authentication data.
