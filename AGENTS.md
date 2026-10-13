# Agent instructions

Rules for any coding agent working on SilvioSwinger, a World of Warcraft addon for the 2.4.3 client (The Burning Crusade).

## Changelog

`CHANGELOG.md` follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and is written in English.

- Every change that a player or a contributor would notice gets an entry under `## [Unreleased]`, in the same change that introduces it. Use the categories `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` and `Security`, in that order, and create a category only when it has entries.
- Write entries for players, not for the code: say what changed in the game or in the docs, not which function was edited.
- Changes nobody would notice (refactors with no visible effect, comment edits) don't need an entry.
- Never edit the sections of versions that were already released.

## Versioning and releases

The project follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). While the version is `0.y.z`, bump the minor (`0.y.0`) for new features or behavior players notice, and the patch (`0.y.z`) for fixes and documentation.

Only release when asked. To release:

1. Pick the next version from the entries under `[Unreleased]`.
2. Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today's date) and add a new empty `## [Unreleased]` above it.
3. Set `## Version: X.Y.Z` in `SilvioSwinger.toc`.
4. Update the links at the bottom of `CHANGELOG.md`: point `[Unreleased]` to `compare/vX.Y.Z...HEAD` and add `[X.Y.Z]: .../compare/v<previous>...vX.Y.Z`.
5. Commit with the message `Release X.Y.Z`.

Do not create tags or GitHub Releases by hand. When the version in `SilvioSwinger.toc` changes on `main`, `.github/workflows/release.yml` creates the `vX.Y.Z` tag, builds `SilvioSwinger-X.Y.Z.zip` and publishes the Release with the notes from that changelog section. The workflow fails if the section is missing or empty.

## Commits

- Commits are authored by the repository owner. Don't add `Co-Authored-By` trailers, "Generated with" lines or any other AI attribution to commits, tags, Releases or pull requests.
- Commit messages are in English, imperative mood ("Add …", "Fix …").

## Code

- Lua 5.1 and the WoW 2.4.3 API only (`this`-era widgets, `getglobal`, no `C_` namespaces). Check that any API you use existed in 2.4.3.
- Code comments are in Portuguese; keep that style.
- No user-visible text in `SilvioSwinger.lua` (the one exception is the `/silvio debug` output, which is technical and stays in English): add a key to every file in `Locales/` (English in `enUS.lua` first) and read it through `L`. Keep the same `%d`/`%s`/`%.1f` placeholders, in the same order, in every language.
- Spell names come from `GetSpellInfo(spellID)`, never hardcoded.

## Documentation

- `README.md` (English) and `README.<code>.md` for each locale must stay in sync: a change to one goes into all of them.
- The timeline images in `docs/` have one version per language (`swing-timeline.svg` for English, `swing-timeline.<code>.svg` for the others).
- Files that the game doesn't load are listed as `export-ignore` in `.gitattributes`, so they stay out of the Release zip. Add new non-addon files there.
