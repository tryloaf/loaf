# extension compatibility

Chrome extension support remains experimental. Install Tampermonkey from the Chrome Web Store through loaf's extension settings, then add scripts through its dashboard. Enabling a manager allows the scripts you add to run on its approved websites. Reload existing pages after adding a script.

The compatibility layer implements the Manifest V3 `userScripts` registration API used by Tampermonkey: `register`, `update`, `unregister`, `getScripts`, `configureWorld`, `getWorldConfigurations`, and `resetWorldConfiguration`.

- Registrations and world settings are stored locally with the extension, separately for each profile. They survive extension reloads and app restarts. Removing the extension removes its registrations.
- Inline and packaged JavaScript sources, match patterns, excluded matches, inclusion/exclusion globs, and child frames are supported. Script batches are validated before any registration changes are saved.
- `USER_SCRIPT` runs in a separate WebKit world for each manager and world ID. `MAIN` runs in the page. User worlds receive manager messaging only when configured, without the extension's tabs, storage, or native messaging APIs.
- Manager messages and ports carry the actual extension tab and frame IDs. Revoked or expired website permissions prevent subsequent injection and native message delivery. Disabled managers stop subsequent injection; reload pages to remove changes a script has already made.
- A small, guarded Tampermonkey adapter handles its worker startup timing, repeated installation events on restore, and Chrome-specific internal resource protocols. The original verified package remains unchanged. Existing runtime copies migrate when enabled again. loaf starts the manager worker on restoration so saved scripts can reconnect.

## limits

`userScripts.execute` and Firefox's older `userScripts.onBeforeScript` API are not implemented. `document_idle` uses WebKit's document-end timing. Arbitrary per-world CSP enforcement is unavailable: known permissive Tampermonkey policies are accepted using WebKit's app-owned world behavior, including dynamic evaluation; stricter custom policies are rejected. Accepted policies do not independently restrict `eval`.

Other extension APIs still depend on WebKit. Some Tampermonkey network interception and CSP modification features can report a `dNr` diagnostic. Support for a manager does not guarantee every userscript or GM API works.

Shazam 2.7.0 omits its declared developer-tools page and font styles. Its runtime copy drops the missing page reference and uses the macOS system font. Song recognition requires Chrome's `tabCapture` API, which loaf does not implement. The popup shows that limitation and handles failed capture without passing an invalid stream to Web Audio; saved history remains accessible. Existing installations migrate on restoration or when re-enabled. The original package and approved permissions stay unchanged.

## verification

The integration check installs the signed Tampermonkey Chrome package and imports a real script that uses `GM_setValue` and `GM_getValue`. It also checks isolated and main worlds, frame IDs, runtime messages and ports, URL matching, atomic registration, partial updates, permission revocation, profile isolation, disabling, and restoration.

Build the Debug app into `build/DerivedData`, then run:

```sh
./scripts/test-userscript-compatibility.sh
```

The check uses temporary profiles and a local HTTP fixture. It downloads the current Tampermonkey package when no cached fixture exists, then verifies the developer and Chrome Web Store signatures before loading it. Tampermonkey 5.5.1 passed during development.
