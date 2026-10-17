# wonderbar commands and local search

Press ⌘L for the wonderbar, or ⇧⌘P to open commands directly.

- `>` searches browser commands. Examples: `> duplicate`, `> move tab to work`, `> split with`, and `> save split`.
- `@tabs` searches open tabs in the current profile, including its tabs in other windows.
- `@history` searches saved titles and addresses in the current profile.
- `@bookmarks` searches bookmarks, including saved split views.
- `@closed` searches the current window’s recently closed tabs in this profile. It uses the existing last-20 list, which lasts for the window’s session. Private sessions expose no searchable closed-tab records.

Type `@` to choose a scope. Tab accepts the selected scope when the caret is at the end of the field; Return opens a result. These modes do not send query text to remote suggestion providers. A scoped query with no result stays open instead of becoming a web search. Ordinary queries retain their existing behavior.

Commands are explicit and operate on live context. Closing a tab, replacing a split, or deleting a destination profile invalidates its old action. Moving a tab to another profile is the existing manual action; automatic site-to-profile routing is deferred.

## saved split views

Choose **save split view…** from either split tab’s context menu, or use `> save split`. The existing bookmark sheet shows both page addresses and a name. The saved bookmark remembers left/right order and divider position.

Open it from the wonderbar, bookmarks page, start-page favorites, or native bookmarks menu. It opens two new unpinned tabs in the current profile without replacing existing pages. Saved split bookmarks coexist with ordinary bookmarks to either page and are preserved by bookmark JSON export/import.

Site-to-profile routing and full-text history search are recorded for later in [TASKS.md](TASKS.md).
