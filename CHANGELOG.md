# Changelog

All notable changes to SilvioSwinger are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

While the version is `0.y.z`, the addon is still taking shape: a minor bump (`0.y.0`) may change behavior that players notice, and a patch bump (`0.y.z`) only fixes things or touches documentation.

## Releasing

1. Move the entries under **Unreleased** to a new version section with today's date.
2. Update `## Version:` in `SilvioSwinger.toc` to the same number.
3. Update the compare links at the bottom of this file.
4. Commit and push to `main`. The Release workflow creates the `vX.Y.Z` tag and publishes a GitHub Release with this section as notes and `SilvioSwinger-X.Y.Z.zip` attached.

The full rules for agents and contributors are in [AGENTS.md](AGENTS.md).

## [Unreleased]

### Added

- Every release is published on GitHub Releases with a ready-to-install `SilvioSwinger-X.Y.Z.zip`, whose folder is already named `SilvioSwinger`.
- `AGENTS.md` with the changelog, versioning and coding rules for contributors and coding agents.
- The twist damage breakdown shows how many hits or procs of each part landed, e.g. `hit 2233 (2) + SoC 975 (1) + SoB 1857 (3) [1 Extra]`.
- Extra attacks from any source (Reckoning, Windfury Totem, Hand of Justice, extra-attack weapons...) are recognized and counted as hits. The seal procs they cause are added to each seal, and the number of extra attacks is shown at the end, e.g. `[2 Extra]`.
- `/silvio debug`: diagnostic mode that prints every combat log event of the twist to chat, with timing, target, damage, crits and how the addon counted it (including the source of each extra attack), plus whether the bundle became a twist. Turns off on `/reload`.
- Update notice: the addon swaps its version with other SilvioSwinger users in your guild, party, raid or battleground, and if someone has a newer one, says so once in chat with the link to the latest release.
- A "Recommended macro" section in every README: one key for Judgement + Seal of Command, since Judgement is off the global cooldown. It skips Judgement when there is no living hostile target.

### Changed

- The install instructions in every README now start from the Release zip.
- The damage breakdown is shown after `=` instead of between parentheses, since each part now has its own count in parentheses.
- In English, the damage message is shorter: `TWIST DMG: 5065 = ...` instead of `TWIST DAMAGE: 5065  (...)`.
- The damage message shows up about one second after the last hit of the swing, so late seal procs make it into the total.

### Fixed

- Part of the twist damage could be left out of the total: seal procs that the server sent late (spell batching) were split off into a separate bundle and dropped. Hits and procs are now grouped by the time they happened on the server, not by when they reached the client.

## [0.3.0] - 2026-10-13

### Added

- Localization. The addon follows the client language by default, falling back to English, and any missing text in a translation shows up in English.
- Translations: English (`enUS`, also used by `enGB`), Português (Brasil) (`ptBR`), Čeština (`csCZ`), Deutsch (`deDE`), Español (`esES`, also used by `esMX`), Français (`frFR`) and Русский (`ruRU`).
- **Language** menu in the options panel and the `/silvio lang <code|auto>` command. The change applies immediately, without `/reload`.
- Saved setting `locale` (default `auto`).
- The version number is shown in the options panel title and in the `/silvio` status output.
- README in every supported language, with a language bar at the top, and a localized timeline image for each one.
- This changelog.

### Changed

- The default README is now in English. The Portuguese version moved to `README.ptBR.md`.
- The interface is in English unless the client language has a translation or another language is picked in the panel. Players who want Portuguese must choose **Português (Brasil)**, since there is no ptBR 2.4.3 client.
- In Portuguese, the damage message reads `DANO DO TWIST` instead of `TWIST DAMAGE`.

## [0.2.0] - 2026-10-13

### Added

- Turning the sound on, in the panel or with `/silvio sound`, plays a preview so you can check it works.

### Fixed

- The twist sound could not be heard. It used the checkbox click, which is quiet and gets lost in combat; it now plays the minimap ping.

## [0.1.2] - 2026-10-13

### Fixed

- Options panel sliders were drawn off screen, in a second column beyond the panel's width. Everything is now in a single column inside a scroll frame.

## [0.1.1] - 2026-10-13

### Added

- README with a swing timeline image and diagrams of the recommendation logic and the streak rules.

## [0.1.0] - 2026-10-13

### Added

- First version: seal twisting helper for Retribution Paladins on the 2.4.3 client.
- Swing timer bar with the twist window, the latency zone and the last free GCD line.
- "Now" and "next" spell icons with instructions (Prepare SoC, Crusader Strike, Wait, TWIST!, Judgement + SoC).
- Twist streak (PERFECT, TOO EARLY, LATE) with best streak.
- `TWIST DAMAGE` message at the top of the screen with the hit + seals breakdown.
- Options panel and `/silvio` / `/ss` commands.

[Unreleased]: https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/releases/tag/v0.1.0
