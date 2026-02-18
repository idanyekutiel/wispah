# Release Wispah Flow

Create and push a new release with date-based versioning (`YYYY.MM.DD` format).

## Steps

1. **Verify clean working tree**
   ```bash
   git status
   ```
   Abort if there are uncommitted changes — ask the user to commit or stash first.

2. **Determine the new version**
   - Base: today's date as `YYYY.MM.DD` (e.g., `2026.02.19`)
   - Check existing tags:
     ```bash
     git tag -l "v$(date +%Y.%m.%d)*"
     ```
   - If `v{date}` doesn't exist → version is `{date}` (e.g., `2026.02.19`)
   - If `v{date}` exists → use `{date}.2`
   - If `v{date}.2` exists → use `{date}.3`, etc.

3. **Update Info.plist**
   ```bash
   plutil -replace CFBundleShortVersionString -string "{version}" Info.plist
   plutil -replace CFBundleVersion -string "{version}" Info.plist
   ```

4. **Commit version bump**
   ```bash
   git add Info.plist
   git commit -m "Release v{version}"
   ```

5. **Create and push tag**
   ```bash
   git tag "v{version}"
   git push origin main
   git push origin "v{version}"
   ```

6. **Confirm** — tell the user the release workflow has been triggered and link to the Actions page.

## Version Format

| Scenario | Version |
|----------|---------|
| First release of the day | `2026.02.19` |
| Second release same day | `2026.02.19.2` |
| Third release same day | `2026.02.19.3` |

## Notes

- The tag push triggers `.github/workflows/release.yml` automatically
- Release workflow builds universal binary, signs, notarizes, and creates a GitHub Release
- Only works when GitHub secrets are configured (Developer ID cert, Apple notarization creds)
- Dev builds don't have `WispahBuildTag` in Info.plist — the release workflow injects it
