# Publishing to winget

The manifests in `<version>/` here are the source of truth for the
`dlnilsson.dygmate` winget package. The copies that actually ship live in
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) under
`manifests/d/dlnilsson/dygmate/<version>/`.

## Releasing a new version

1. Bump `.version` in `build.zig.zon`, copy the previous manifest directory to
   `packaging/winget/<new-version>/`, and update `PackageVersion` and the
   `InstallerUrl` version in the copies.

2. Tag and push — CI (`.github/workflows/release.yml`) builds both platforms
   and creates the GitHub Release with `SHA256SUMS.txt`:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

   (Local fallback: `scripts/release.sh` on Linux or `scripts/release.ps1` on
   Windows produces the same artifacts in `dist/`, then
   `gh release create v0.1.0 dist/*`.)

3. Copy the Windows zip's hash from the release's `SHA256SUMS.txt` into
   `InstallerSha256` in `dlnilsson.dygmate.installer.yaml`.

## Validating locally

```powershell
winget validate --manifest packaging/winget/0.1.0

# One-time, elevated: allow installing from local manifests.
winget settings --enable LocalManifestFiles

winget install --manifest packaging/winget/0.1.0
dygmate --once        # from a fresh shell; alias is on PATH
dygmate-tray
winget uninstall dlnilsson.dygmate
```

## Submitting to microsoft/winget-pkgs

Easiest is [wingetcreate](https://github.com/microsoft/winget-create) — it
forks winget-pkgs and opens the PR under your GitHub account:

```powershell
winget install wingetcreate

# First release (interactive; prefills from the installer URL):
wingetcreate new https://github.com/dlnilsson/dygma-battery-tray/releases/download/v0.1.0/dygmate-0.1.0-windows-x86_64.zip

# Later releases (one command):
wingetcreate update dlnilsson.dygmate --version 0.2.0 --urls <new-zip-url> --submit
```

Manual alternative: fork winget-pkgs, copy these three files to
`manifests/d/dlnilsson/dygmate/0.1.0/`, and open a PR.

After submission the winget-pkgs pipeline validates the manifest
automatically; respond to any `[Policy]`/bot comments on the PR. Once merged
(typically a few days), `winget install dlnilsson.dygmate` works everywhere.

Note: the package is portable — winget puts `dygmate` and `dygmate-tray` on
PATH but creates no Start Menu entry or autostart. Users who want the tray at
login can create a shortcut to `dygmate-tray` in `shell:startup`.
