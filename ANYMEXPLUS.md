# AnymeX+ changes to AnymeX

AnymeX+ is [AnymeX](https://github.com/RyanYuuki/AnymeX) with Stremio built in. This file lists everything AnymeX+ adds or changes, so new AnymeX versions can be merged in without hunting for our edits.

**Based on:** RyanYuuki/AnymeX commit `033b388` (Nov 7 2026).

## Merging a new AnymeX version

1. Merge or copy the new AnymeX code over this repo, keeping `lib/plus/`, `beta/`, `scripts/`, `.github/`, `test/` and this file.
2. Re-apply the hooks in the table below to the AnymeX files they live in. Each hook is small and marked with an `AnymeX+` comment where possible.
3. Run `python3 scripts/replace_with_opacity.py $(grep -rl '\.withOpacity(' lib)` to redo the colour-call update.
4. Push to a `wip/...` branch first: the **Check (no release)** workflow analyzes the project and runs the tests without releasing anything. Then push to `beta`.
5. Update the "Based on" commit above.

## AnymeX+ code (`lib/plus/`)

Everything that is only AnymeX+ lives here; AnymeX never touches it.

| Path | What it is |
| --- | --- |
| `plus/stremio/` | Stremio account, addons, library sync, progress sync, anime matching, on-device cache |
| `plus/stremio/ui/` | Movies & TV tab, details page, Info tab, streams sheet, player bridge, account page |
| `plus/stremio_anime_episodes.dart` | Stremio streams on the anime Watch tab (source switch, episode list) |
| `plus/movie_watch_card.dart` | Movie card instead of "Episode 1" |
| `plus/simkl_auth_v2.dart` | Simkl OAuth 2 (PKCE) sign-in and token refresh |
| `plus/self_test.dart`, `plus/settings_self_test.dart` | Self Test page and its checks |
| `plus/app_channel.dart` | Stable vs beta build (from `.env`) |
| `plus/maybe_blur.dart` | Blur that is skipped when blur is 0 |

## Hooks in AnymeX files

| AnymeX file | AnymeX+ change |
| --- | --- |
| `main.dart` | Registers StremioService; Movies & TV tab; Firebase removed; startup steps run together; subtitle fonts, downloads, Gist sync and watch parties start after the first frame; beta window title |
| `controllers/settings/settings.dart` | Stremio tab; Anime tab folded into Home (one-time tab migration) |
| `controllers/services/anilist/anilist_data.dart` | AniList progress → Stremio |
| `controllers/services/mal/mal_service.dart` | MAL progress → Stremio |
| `controllers/services/simkl/simkl_service.dart`, `simkl_api.dart` | Simkl sign-in uses `plus/simkl_auth_v2.dart`; requests go through its client (refresh on 401) |
| `database/database.dart` | Beta keeps its own database folder on Windows |
| `screens/home_page.dart` | Search bar (opens the anime search) and anime discover rows on Home |
| `screens/anime/details/media_details_page.dart` | Movie wording on the continue bar; hidden in Stremio stream mode |
| `screens/anime/widgets/episode_section.dart` | Extensions / Stremio stream source switch |
| `screens/anime/widgets/episode_list_builder.dart` | Movie card; Stremio episodes open the Stremio streams sheet |
| `screens/anime/watch/controller/player_controller.dart` | Stremio playback + progress sync; iOS rotation fix (`landscapeForTilt`); tilt sensor only while unlocked; next episode's streams found early; subtitle fonts on open |
| `screens/library/controller/library_controller.dart`, `my_library.dart`, `widgets/library_deps.dart` | "Stremio" chip in the Library |
| `screens/library/widgets/history_model.dart` | History items from Stremio open the Stremio page |
| `screens/settings/sub_settings/settings_accounts.dart` | Stremio account in Accounts |
| `screens/settings/sub_settings/settings_ui.dart` | Stremio tab in the tab editor |
| `screens/settings/sub_settings/settings_about.dart` | Shows the beta tag as the version |
| `screens/settings/registry/settings_registry.dart` | Self Test page in settings |
| `utils/updater.dart` | Updates from this repo; beta app follows beta pre-releases |
| `utils/notification.dart` | Firebase push removed; local notifications set up on their own |
| `utils/external_font_loader.dart` | Subtitle fonts load after launch (`ensureBundledFonts`) |
| `utils/color_extractor.dart` | iOS crash fix when decoding poster colours |
| `utils/function.dart` | iOS swipe-back on pushed pages |
| `widgets/anime/media_header.dart` | Poster tap can be turned off (Stremio pages) |
| `widgets/common/reusable_carousel.dart` | Long-press actions for Stremio items |
| `widgets/common/navbar.dart`, `navbar/styles/*`, `widgets/header/header.dart` | No blur layer when blur is off |

**Removed from AnymeX:** `firebase_options.dart`, `services/fcm_service.dart` and the three Firebase packages (pushes can't reach a sideloaded build).

**Mechanical:** about 120 more AnymeX files differ only by `withOpacity(x)` → `withValues(alpha: x)` (step 3 above redoes it).

## Outside `lib/`

| Path | What it is |
| --- | --- |
| `.github/workflows/build.yml` | Builds iOS + Windows; `main` → release, `beta` → pre-release |
| `.github/workflows/check.yml` | `wip/*` branches: analyze + tests, no release |
| `.github/workflows/promote-beta.yml` | "Ship beta as release" button |
| `scripts/` | Version numbers, beta app renaming, beta icons, colour-call update |
| `beta/` | Beta icons |
| `test/` | Unit tests for AnymeX+ logic |
| `ios/`, `windows/` | App ID, name and icons for AnymeX+ |
