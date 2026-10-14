# loaf working rules

- Treat interface and interaction polish as part of the implementation. Respect Reduce Motion and Reduce Transparency.
- Keep `tests/` and `scripts/` local and ignored. Never force-add them. Before pushing a release, verify `git ls-files tests scripts` returns no files.
- Do not add Copilot or other automated co-author trailers to commits. Preserve Owen's authorship.
- Clean generated artifacts after every test run and release. Delete disposable test `.app` bundles and compiled test executables once their processes exit; preserve test sources, fixtures, downloaded extension packages, logs, and compact verification reports.
- Remove obsolete release build caches, duplicate exported apps, and notarization ZIPs. Keep the latest signed/notarized release, the previous release needed for rollback or an active crash investigation, their source provenance and crash symbols, and the compact DMGs/deltas required by Sparkle. Keep the current development build while it is needed for guarded testing.
- Do not delete `/Applications/loaf.app`, browsing data, credentials, source files, unique backups, or running build/test output. Check actual free disk space before and after substantial cleanup.
- Run native UI and memory stress tests sequentially in disposable profiles and ordinary desktop windows. Keep an independent memory/deadline guard for profile-switch stress tests; do not run them while system memory pressure is elevated.
- Increment the build number for each published binary. Verify signing, notarization, full/delta signatures, live download bytes, update feed, and release notes before reporting a release as shipped.
- Use `brioche` as the release-family tag for 1.x versions, not as a prefix in individual release headlines.
