<!-- markdownlint-disable-file MD041 -->
## Summary

<!-- Describe the change and its purpose. Link any issue that it fixes. -->

## Screenshots

<!-- For UI changes, include before and after screenshots in light and dark
appearance. Use scripts/snapshot.sh to capture them. Delete this section if
the change does not affect the UI. -->

## Checklist

Check each applicable item before you submit the pull request:

- [ ] The pull request contains one change and explains its purpose.
- [ ] The title uses Conventional Commits, such as `feat:`, `fix:`, or `docs:`.
- [ ] Tests cover any behavior changes.
- [ ] `swift test --scratch-path .build/dev` passes. The build adds no warnings.
- [ ] `scripts/format.sh --check` passes on the changed paths.
- [ ] `ast-grep scan` passes on the changed paths.
- [ ] UI changes include before and after screenshots in light and dark appearance.
- [ ] Affected documentation is up to date, including `README.md`,
      `docs/DESIGN.md`, `docs/ARCHITECTURE.md`, and `CLAUDE.md`.
- [ ] The change adds no third-party packages.
