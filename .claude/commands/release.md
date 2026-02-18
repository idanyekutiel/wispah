# Release Wispah Flow

Create and push a new release with date-based versioning (`YYYY.MM.DD` format).

**IMPORTANT:** Always wait for explicit user approval before running `git push`.

## Steps

1. **Verify clean working tree**
   ```bash
   git status
   ```
   Abort if there are uncommitted changes - ask the user to commit or stash first.

2. **Determine the new version**
   - Base: today's date as `YYYY.MM.DD` (e.g., `2026.02.19`)
   - Check existing tags:
     ```bash
     git tag -l "v$(date +%Y.%m.%d)*"
     ```
   - If `v{date}` doesn't exist -> version is `{date}` (e.g., `2026.02.19`)
   - If `v{date}` exists -> use `{date}.2`
   - If `v{date}.2` exists -> use `{date}.3`, etc.

3. **Write release notes**
   - Review all commits since the last release tag:
     ```bash
     PREV_TAG=$(git tag --sort=-v:refname | head -1)
     git log --pretty=format:"%s" "$PREV_TAG"..HEAD
     ```
   - Write a human-friendly `RELEASE_NOTES.md` in the repo root using this format:

     ```markdown
     ## Installation

     1. Download the DMG below
     2. Open it and drag Wispah to Applications
     3. Launch Wispah Flow from Applications

     ## Changelog

     - Human-friendly description of change 1
     - Human-friendly description of change 2
     - etc.

     ## Requirements

     - macOS 13.0 or later
     - Microphone permission
     - Accessibility permission
     - Screen Recording permission (optional)
     - Free Groq API key ([get one here](https://console.groq.com/keys))
     ```

   - The Changelog section should be **written by you**, not raw commit messages. Translate commits into user-facing language: what changed, what's new, what got fixed. Group related commits into single bullets. Skip internal-only changes (README tweaks, CI fixes, refactors with no user impact).

4. **Update Info.plist**
   ```bash
   plutil -replace CFBundleShortVersionString -string "{version}" Info.plist
   plutil -replace CFBundleVersion -string "{version}" Info.plist
   ```

5. **Commit version bump + release notes**
   ```bash
   git add Info.plist RELEASE_NOTES.md
   git commit -m "Release v{version}"
   ```

6. **Create tag**
   ```bash
   git tag "v{version}"
   ```

7. **Ask user for approval to push**, then:
   ```bash
   git push origin main
   git push origin "v{version}"
   ```

8. **Confirm** - tell the user the release workflow has been triggered and link to the Actions page.

## Version Format

| Scenario | Version |
|----------|---------|
| First release of the day | `2026.02.19` |
| Second release same day | `2026.02.19.2` |
| Third release same day | `2026.02.19.3` |

## Release Title Format

`Wispah Flow Version {version}` (e.g., "Wispah Flow Version 2026.02.19")

## Notes

- The tag push triggers `.github/workflows/release.yml` automatically
- Release workflow reads `RELEASE_NOTES.md` from the repo for the GitHub Release body
- Works without Apple Developer secrets (ad-hoc signing fallback)
- With secrets configured: Developer ID signed + Apple notarized
- Dev builds don't have `WispahBuildTag` in Info.plist - the release workflow injects it
