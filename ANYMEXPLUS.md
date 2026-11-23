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
| `plus/stremio/builtin_rows.dart` | Movies & TV rows the app provides itself from TMDB (trending, popular, in theaters, top rated, streaming services, genres), so the tab works without catalog addons; listed in Edit layout |
| `plus/stremio/ui/` | Movies & TV tab, details page, Info tab, streams sheet (`stremio_streams_sheet.dart`), downloads (`stremio_download.dart`), player bridge, account page |
| `plus/stremio_anime_episodes.dart` | Stremio streams on the anime Watch tab (source switch, episode list) |
| `plus/movie_watch_card.dart` | Movie card instead of "Episode 1" |
| `plus/episode_hold.dart` | Long-press on an anime episode: mark watched up to it, mark as not watched (removes the mark kept on the device and steps list progress back), or choose a source (what long-press did before); unit-tested |
| `plus/episode_order.dart` | Puts an extension's episode list oldest first when AnymeX's reversal left it backwards (wrong numbers, titles and episode played); unit-tested |
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
| `plus/for_you/` | "For you" rows: `ranking.dart` (shared scoring, unit-tested; disliked titles count against), `anime_for_you.dart` (Home: AniList list, scores, favourites, Like/Love/Dislike, AniList recommendations + AI Picks), `movies_for_you.dart` (Movies & TV: Stremio library/history + Like/Love/Dislike, TMDB recommendations), `taste.dart` (Like/Love/Dislike and "Not interested", saved on the device), `for_you_row.dart` (the rows), `taste_buttons.dart` (Like/Love/Dislike on the Movies & TV and anime pages; Simkl rating) |
| `plus/card_menu.dart` | One card menu for anime and Movies & TV (long-press on iPhone, right-click on Windows): Open, Play next episode, Library, Like/Love/Dislike, Not interested |
| `plus/skip_times.dart` | Skip intro / recap / credits on Movies & TV from TheIntroDB (v4, by IMDb id) or the video's chapter marks; fills the player's AniSkip times |
| `plus/up_next.dart` | "Up next" card on Movies & TV episodes: countdown from the credits, else a Next episode button from your watched point |
| `plus/mini_player.dart` | Windows mini player (small, always on top, see-through slider); ends by itself when the window gets big another way (snap, Win+Up) |
| `plus/pc_video_quality.dart` | PC picture quality: mpv draws at the window's real pixel size (`PlusPcVideoSize` around the video, fit mode only) and mpv's high-quality scaling + debanding (no added grain) |
| `plus/external_player_pc.dart` | External player on Windows: opens the stream in mpv / VLC / MPC-HC / PotPlayer (with headers where possible) instead of the browser |
| `plus/focus_watch.dart` | Windows: logs focus changes ([focus] lines in app_logs.txt) to track down the window losing focus to a game |
| `plus/desktop_volume.dart` | PC volume and brightness: bar buttons `volume`/`brightness` (`PlusSliderButton`; hover: the button's box swells then grows upwards with a slider), mouse wheel (Shift = brightness), Up/Down/M keys, brightness as a dark layer over the video |
| `plus/error_log.dart` | Last 50 errors kept on the device (from `Logger.e`, secrets blanked), shown in the Self Test |
| `plus/backup.dart` | After AnymeX restores a backup, AnymeX+ settings (already in it) take effect without a restart |
| `plus/row_perf.dart` | Smoother rows: AnymeX's card animation plays only when a row first shows; rows load small posters (TMDB w342, Metahub medium) |
| `plus/layout/` | Edit layout: `layout_model.dart` (rows, row looks, ordering; unit-tested), `layout_store.dart` (saved per page), `row_scope.dart` (a row's look, read by `ReusableCarousel`), `page_rows.dart` (Home and Manga rows, Movies & TV rows on Home (`mv:` keys), filtered AniList rows, Stremio catalog rows), `home_layout.dart` (Home and Manga drawn from your layout), `layout_editor.dart` (the Edit layout screen, Library defaults too) |
| `plus/everything_library.dart` | Library's "Everything" chip: anime and Movies & TV together with the same status filters (Watching, Completed, Paused, Dropped, Planning) and Anime / Movies / Series; merge and status logic unit-tested |
| `plus/windows_update.dart` | Windows in-app update: installer saved to the temp folder and started straight from the app, silently over the installed copy (same folder and install mode, no license page, log in the temp folder); the installer reopens the app (a `[Run]` line added in build.yml); the next start removes the installer or says the update didn't install; old installers in Downloads removed |
| `plus/search_tabs.dart` | Movies & TV tab on the anime search page |
| `plus/simkl_send_all.dart` | "Send everything to Simkl" (Movies & TV history and AniList anime list) |
| `plus/airplay.dart` | Casting extras. iPhone AirPlay: a hidden Apple player (native side in `ios/Runner/AppDelegate.swift`, `PlusAirPlay`) sends the video to the TV and the cast sheet shows our remote (play/pause, seek, ±10 s, change TV, stop → the player resumes there); streams that need headers go through the cast proxy. Finding TVs on iPhone: Bonjour for Chromecasts and AirPlay TVs, then each AirPlay TV is asked directly for DLNA (unicast SSDP); "Add a TV by IP address" (saved). DLNA gets the real file type (MKV → `video/x-matroska`) |
| `plus/mkv_audio.dart` | Casting MKVs with the audio picked in the app: the cast proxy rewrites the file's track list (picked audio first and the only default, same size, so seeking works); changing audio while casting re-casts at the TV's spot |
| `plus/tv/` | Remote for the AnymeX+ TV app (LG webOS, in the repo's `tv/` folder): `tv_link.dart` (a small server the TV app connects to; remote presses, "play this", the TV's reports), `lg_link.dart` (LG's phone link, used to open the TV app and hand it this device's address), `tv_remote_page.dart` (Settings → TV Remote), `tv_play.dart` (Play on TV from the player's cast sheet: the video goes to the TV app, the player's own controls become the remote, the TV's position drives tracking, next episode follows; header streams and downloads go through the cast proxy), `subtitle_vtt.dart` (SRT/ASS → WebVTT for the TV app, unit-tested; the link serves it at `/sub/<name>.vtt`), `tv_sync.dart` (what the TV app needs to browse by itself, locked with AES-GCM), `tv_anime.dart` (anime on the TV app: your Home's anime rows go over in the sync; the TV app then finds and plays anime through your Stremio addons by itself. Also kept, unused by the TV app for now: answering the TV's requests for a show's episodes from an extension and playing one through this device) |
| `plus/webos.dart`, `plus/tvui/` | The whole app on the LG TV (LG's flutter-webOS SDK, built by `tv-flutter-app.yml`; test branch). `webos.dart`: is this the TV, native library paths. `tvui/`: the TV layout — `tv_shell.dart` (left menu, tabs, remote keys), `tv_widgets.dart` (cards, rows that wrap, buttons, Left at the edge as Back), `tv_home.dart`, `tv_categories.dart`, `tv_library.dart`, `tv_search.dart`, `tv_settings.dart` (accounts incl. Stremio sign-in by code), `tv_details.dart`, `tv_data.dart` (AniList / Stremio / TMDB data for cards), `tv_playable.dart` (what plays: film, series or anime matched to Stremio ids), `tv_sources.dart` (sources from your Stremio addons, direct links only), `tv_player.dart` (LG's player via `video_player`: controls, subtitles, speed, episodes, skip intro, next episode, progress to Stremio/AniList), `tv_local_proxy.dart` (`plus/tv/tv_proxy.dart` served on the TV itself for links that need headers) |
| `plus/splash_gate.dart` | When the splash gives way to Home (as soon as AniList has loaded; 0.8–3 s) |

## Hooks in AnymeX files

| AnymeX file | AnymeX+ change |
| --- | --- |
| `main.dart` | Registers StremioService; Movies & TV tab; Firebase removed; startup steps run together; subtitle fonts, downloads, Gist sync and watch parties start after the first frame; launch timing; splash ends when Home is ready (`plus/splash_gate.dart`, short fade); print() kept out of the log file; beta window title; TV link starts on computers (`PlusTvLink.autoStart`) |
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
| `screens/home_page.dart` | Search bar (opens the anime search) and anime discover rows on Home; with AniList, Home is `PlusHomeLayoutSliver` (your layout); nearby rows stay built (`cacheExtent` 1200) |
| `screens/manga/home_page.dart` | With AniList, the Manga tab is `PlusMangaLayout` (your layout) |
| `screens/search/search_view.dart` | Results wrapped in `PlusSearchTabs` (Anime / Movies & TV) |
| `screens/anime/details/media_details_page.dart` | Movie wording on the continue bar; hidden in Stremio stream mode; comments built as you scroll; Like / Love / Dislike on the Overview tab (`PlusAnimeTasteRow`) |
| `screens/anime/widgets/comments/comments_section.dart` | `asSliver` mode: comments are built as you scroll |
| `screens/anime/details/controller/media_details_controller.dart` | `_convertEpisodes` returns `plusOldestFirst(data)` (`plus/episode_order.dart`) |
| `screens/anime/widgets/episode_section.dart` | Extensions / Stremio stream source switch |
| `screens/anime/widgets/episode_list_builder.dart` | Movie card; Stremio episodes open the Stremio streams sheet; long-press on an episode opens `PlusEpisodeHold` (set progress / choose a source) |
| `screens/anime/watch/controller/player_controller.dart` | Stremio playback + progress sync (also when the app goes to the background); iOS rotation fix (`landscapeForTilt`); tilt sensor only while unlocked; next episode's streams found early; subtitle fonts on open; after a show is marked Completed, `RatePrompt` asks for a score when the player closes; Movies & TV skip times (`plusAttachSkipTimes`) at the top of `_initializeAniSkip`; leaving the player ends the mini player; Play on TV (`plus/tv/tv_play.dart`): while `PlusTvPlay.instance.takes(this)`, `play`/`pause`/`togglePlayPause`/`_seekTo`/segment skips act on the TV, the position listener is skipped, `showSheetWithPause` doesn't resume, `_switchMedia` hands the new video to the TV, and `plusRemoteTick`/`plusRemoteEnded`/`plusPauseLocal` let the TV's position drive tracking and next episode; `onClose` stops the TV; `_initializePlayer` ends with `PlusTvPlay.instance.playerReady(this)` (an episode the TV app asked for goes straight to the TV) |
| `screens/anime/watch/controls/bottom_controls.dart` | `volume`/`brightness` buttons in `buttonWidgets` (compact group) + `plusAddVolumeButtonIds` puts them first on the right until settings place them; Audio track button icon changed (was the same speaker icon as volume) |
| `screens/settings/sub_settings/settings_player.dart` | Bottom controls list: Volume and Brightness entries (PC only), added at the start of the right side; Audio entry icon |
| `utils/external_player.dart` | Windows branch → `PlusExternalPlayerPc.launch` |
| `screens/anime/watch/player/media_kit_player.dart` | `PlusPcVideo.applyMpvOptions(mpv)` after the cache options |
| `screens/anime/watch/watch_view.dart` | `PlusUpNext` card; mini player (`PlusMiniPlayerOverlay`, controls hidden while it's on); PC volume/brightness (`PlusDesktopDim` above the video, `PlusDesktopWheel` above the tap layer, `PlusDesktopKeys` for Up/Down/M) |
| `services/cast/widgets/cast_device_dialog.dart` | `PlusCastExtras` (AirPlay, add TV by IP) above the device list; the body scrolls (list spilled out of the landscape sheet) |
| `services/cast/cast_service.dart` | iPhone Chromecast search uses `PlusAirPlay.findChromecasts` (Bonjour); `_plusDirectDlna` in the search (DLNA asked directly); `castMedia` calls `PlusMkvAudio.castStarted`; Google Cast waits for the receiver (`plusWaitForCastReceiver`) instead of 1.2 s, sends the real file type, reports LOAD_FAILED; DLNA `mime` from `plusDetectMime` |
| `services/cast/cast_v2_client.dart` | Follows the default media receiver's transportId, not whichever app is listed first |
| `services/cast/cast_proxy_server.dart` | Downloaded files are served with their real file type (`plusMimeFromPath`); remote streams pass through `PlusMkvAudio.wrap` |
| `ios/Runner/AppDelegate.swift`, `ios/Runner/Info.plist` (not under `lib/`) | `PlusAirPlay` (hidden AirPlay player + Bonjour) appended and registered; local network permission text, `_googlecast._tcp` / `_airplay._tcp`, background audio (AirPlay keeps going with the phone locked) |
| `utils/logger.dart` | `Logger.e` also feeds `PlusErrorLog` |
| `controllers/services/backup_restore/backup_restore_service.dart` | `PlusBackup.afterRestore()` after a restore |
| `screens/library/controller/library_controller.dart`, `my_library.dart`, `widgets/library_deps.dart` | "Everything" chip in the Library (`plus/everything_library.dart`, remembered) |
| `screens/library/widgets/history_model.dart` | History items from Stremio open the Stremio page |
| `screens/settings/sub_settings/settings_accounts.dart` | Stremio account in Accounts; "Send everything to Simkl" |
| `screens/settings/sub_settings/settings_ui.dart` | Stremio tab in the tab editor; "Edit layout" entry |
| `screens/settings/sub_settings/settings_about.dart` | Shows the beta tag as the version |
| `screens/settings/registry/settings_registry.dart` | Self Test and TV Remote pages in settings |
| `utils/updater.dart` | Updates from this repo; beta app follows beta pre-releases; Windows updates install silently from the temp folder (`plus/windows_update.dart`) |
| `utils/notification.dart` | Firebase push removed; local notifications set up on their own |
| `utils/external_font_loader.dart` | Subtitle fonts load after launch (`ensureBundledFonts`) |
| `utils/function.dart` | iOS swipe-back on pushed pages |
| `widgets/anime/media_header.dart` | Poster tap can be turned off (Stremio pages) |
| `widgets/common/reusable_carousel.dart` | Long-press actions for Stremio items; right-click opens `PlusCardMenu`; card animation only when the row first shows (`PlusRowPerf.shouldAnimate`); a row's name, order, item count, card style, size and grid view from Edit layout (`PlusRowScope`) |
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
