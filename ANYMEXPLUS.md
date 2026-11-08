# AnymeX+ changes to AnymeX

AnymeX+ is [AnymeX](https://github.com/RyanYuuki/AnymeX) with Stremio built in. This file lists everything AnymeX+ adds or changes, so new AnymeX versions can be merged in without hunting for our edits.

**Based on:** RyanYuuki/AnymeX commit `dc8142e` (Nov 8 2026).

A weekly check (**AnymeX updates** workflow) opens an issue here when AnymeX has new commits, listing the files and which ones AnymeX+ changes. It also tries the merge on the `wip/anymex-update` branch and runs the checks: when the issue says **Ready**, the **Ship AnymeX update to beta** workflow puts it in a beta; otherwise it lists the files that clash.

## Merging a new AnymeX version

Usually the weekly check does this (see above). By hand, for a merge that clashes:

1. `git merge` AnymeX's `main` into `beta` (on a `wip/...` branch).
2. In clashing files, keep AnymeX's code and re-apply the hooks in the table below. Each hook is small and marked with an `AnymeX+` comment where possible.
3. Leave AnymeX's own code as it is (for example its `withOpacity` colour calls): every line we change in AnymeX's files is a line that can clash at the next merge.
4. Push the `wip/...` branch first: the **Check (no release)** workflow analyzes the project and runs the tests without releasing anything. Then push to `beta`.
5. Update the "Based on" commit above.

## AnymeX+ code (`lib/plus/`)

Everything that is only AnymeX+ lives here; AnymeX never touches it.

| Path | What it is |
| --- | --- |
| `plus/stremio/` | Stremio account, addons, library sync, progress sync, anime matching, on-device cache. `stremio_service.dart` is split into parts: `stremio_service_sync.dart` (tracker progress → Stremio, which entry an anime uses), `stremio_service_playback.dart` (anime streams, playback reports, Continue Watching), `stremio_service_anilist.dart` (Stremio watches → AniList/Simkl) |
| `plus/stremio/ui/` | Movies & TV tab, details page, Info tab, streams sheet (`stremio_streams_sheet.dart`), downloads (`stremio_download.dart`), player bridge, account page |
| `plus/stremio_anime_episodes.dart` | Stremio streams on the anime Watch tab (source switch, episode list) |
| `plus/movie_watch_card.dart` | Movie card instead of "Episode 1" |
| `plus/simkl_auth_v2.dart` | Simkl OAuth 2 (PKCE) sign-in and token refresh |
| `plus/self_test.dart` (+ parts `self_test_basics.dart`, `self_test_stremio.dart`, `self_test_other.dart`), `plus/settings_self_test.dart` | Self Test page and its checks |
| `plus/app_channel.dart` | Stable vs beta build (from `.env`) |
| `plus/maybe_blur.dart` | Blur that is skipped when blur is 0 |
| `plus/launch_timer.dart` | Launch time shown in the Self Test |
| `plus/continue_watching_row.dart` | Home's Continue Watching row with Movies & TV in it, newest first, no doubles |
| `plus/custom_lists.dart` | Your AniList custom anime lists as Home rows |
| `plus/list_card_badge.dart` | Your score next to your progress on Library cards |
| `plus/rate_prompt.dart` | "Rate it?" sheet after the player marks a show Completed |
| `plus/missed_sequels.dart` | "Missed sequels" Home row (sequels of completed AniList anime not on your list) |
| `plus/for_you/` | "For you" rows: `ranking.dart` (shared scoring, unit-tested), `anime_for_you.dart` (Home: AniList list, scores, favourites, AniList recommendations + AI Picks), `movies_for_you.dart` (Movies & TV: Stremio library/history + Like/Love, TMDB recommendations), `taste.dart` (Like/Love and "Not interested", saved on the device), `for_you_row.dart` (the rows), `taste_buttons.dart` (Like/Love on the Movies & TV page; Simkl rating) |
| `plus/row_perf.dart` | Smoother rows: AnymeX's card animation plays only when a row first shows; rows load small posters (TMDB w342, Metahub medium) |
| `plus/splash_gate.dart` | When the splash gives way to Home (as soon as AniList has loaded; 0.8–3 s) |

## Hooks in AnymeX files

| AnymeX file | AnymeX+ change |
| --- | --- |
| `main.dart` | Registers StremioService; Movies & TV tab; Firebase removed; startup steps run together; subtitle fonts, downloads, Gist sync and watch parties start after the first frame; launch timing; splash ends when Home is ready (`plus/splash_gate.dart`, short fade); print() kept out of the log file; beta window title |
| `controllers/settings/settings.dart` | Stremio tab; Anime tab folded into Home (one-time tab migration) |
| `controllers/discord/discord_rpc.dart` | iPhone: connection kept through Control Center / app switcher, reconnects when Discord closes it (op 7/9, close codes), stale sockets ignored, waits for sign-in before a status update, last sequence number kept; the last status is put back after a reconnect; Movies & TV titles link to IMDb/Kitsu and say Movie/Show |
| `controllers/services/anilist/anilist_data.dart` | AniList progress → Stremio; Home's Continue Watching row is `PlusContinueWatchingRow`; For you, custom-list rows and Missed sequels after the list rows |
| `controllers/services/anilist/anilist_auth.dart` | Anime list query also asks `isCustomList`; `_setAnimeListData` hands the lists to `PlusCustomLists` |
| `widgets/media_items/media_item.dart` | Library card badge from `listCardBadge` (progress + your score) |
| `controllers/services/mal/mal_service.dart` | MAL progress → Stremio |
| `controllers/services/simkl/simkl_service.dart`, `simkl_api.dart` | Simkl sign-in uses `plus/simkl_auth_v2.dart`; requests go through its client (refresh on 401) |
| `database/database.dart` | Beta keeps its own database folder on Windows |
| `windows/runner/main.cpp` (not under `lib/`) | Sign-in browser (WebView2) data in `%LOCALAPPDATA%\AnymeXStremio\WebView2` instead of next to the exe |
| `database/kv_helper.dart` | A missing setting is no longer logged as an error |
| `controllers/services/storage/storage_manager_service.dart` | Over the image-cache limit, the oldest images are removed instead of all of them |
| `screens/home_page.dart` | Search bar (opens the anime search) and anime discover rows on Home; nearby rows stay built (`cacheExtent` 1200) |
| `screens/anime/details/media_details_page.dart` | Movie wording on the continue bar; hidden in Stremio stream mode; comments built as you scroll |
| `screens/anime/widgets/comments/comments_section.dart` | `asSliver` mode: comments are built as you scroll |
| `screens/anime/widgets/episode_section.dart` | Extensions / Stremio stream source switch |
| `screens/anime/widgets/episode_list_builder.dart` | Movie card; Stremio episodes open the Stremio streams sheet |
| `screens/anime/watch/controller/player_controller.dart` | Stremio playback + progress sync (also when the app goes to the background); iOS rotation fix (`landscapeForTilt`); tilt sensor only while unlocked; next episode's streams found early; subtitle fonts on open; after a show is marked Completed, `RatePrompt` asks for a score when the player closes |
| `screens/library/controller/library_controller.dart`, `my_library.dart`, `widgets/library_deps.dart` | "Stremio" chip in the Library |
| `screens/library/widgets/history_model.dart` | History items from Stremio open the Stremio page |
| `screens/settings/sub_settings/settings_accounts.dart` | Stremio account in Accounts |
| `screens/settings/sub_settings/settings_ui.dart` | Stremio tab in the tab editor |
| `screens/settings/sub_settings/settings_about.dart` | Shows the beta tag as the version |
| `screens/settings/registry/settings_registry.dart` | Self Test page in settings |
| `utils/updater.dart` | Updates from this repo; beta app follows beta pre-releases |
| `utils/notification.dart` | Firebase push removed; local notifications set up on their own |
| `utils/external_font_loader.dart` | Subtitle fonts load after launch (`ensureBundledFonts`) |
| `utils/function.dart` | iOS swipe-back on pushed pages |
| `widgets/anime/media_header.dart` | Poster tap can be turned off (Stremio pages) |
| `widgets/common/reusable_carousel.dart` | Long-press actions for Stremio items; card animation only when the row first shows (`PlusRowPerf.shouldAnimate`) |
| `widgets/common/navbar.dart`, `navbar/styles/*`, `widgets/header/header.dart` | No blur layer when blur is off |

**Removed from AnymeX:** `firebase_options.dart`, `services/fcm_service.dart` and the three Firebase packages (pushes can't reach a sideloaded build).


## Outside `lib/`

| Path | What it is |
| --- | --- |
| `.github/workflows/build.yml` | Builds iOS + Windows; `main` → release, `beta` → pre-release |
| `.github/workflows/check.yml` | `wip/*` branches: analyze + tests, no release |
| `.github/workflows/promote-beta.yml` | "Ship beta as release" button |
| `.github/workflows/upstream-check.yml` | Weekly check for new AnymeX commits: tries the merge, runs the checks, keeps an issue up to date |
| `.github/workflows/ship-anymex-update.yml` | "Ship AnymeX update to beta" button (after a Ready merge) |
| `packages/rhttp/cargokit/build_pod.sh`, `cmake/cargokit.cmake` | `ANYMEXPLUS_CARGOKIT_DIR` lets CI keep the compiled Rust library between builds |
| `packages/rhttp/rust/Cargo.lock` | Pins rhttp's Rust packages |
| `scripts/` | Version numbers, beta app renaming, beta icons |
| `beta/` | Beta icons |
| `test/` | Unit tests for AnymeX+ logic |
| `ios/`, `windows/` | App ID, name and icons for AnymeX+; iOS 15 minimum |
