I would just like to note that this app is built using claude code. I do not know how to code but i wanted an app that combines functionality from both apps for my own personal use.

# AnymeX + Stremio

A personal build of [AnymeX](https://github.com/RyanYuuki/AnymeX) (anime/manga tracker and player) with Stremio built in:

- **Stremio account login**: email/password, or a code via stremio.com/link for Google/Apple/Facebook accounts
- **Your Stremio addons**, synced from your account (Cinemeta when logged out). Add or remove addons by URL.
- **Movies & TV tab**: Stremio Continue Watching, every addon catalog, and search
- **Details pages** with seasons, episodes, and the same watched checkmarks Stremio shows (long-press an episode to toggle it)
- **Streams from all your stream addons**, played in the AnymeX player. Torrent streams play through AnymeX's built-in torrent engine on iOS.
- **Progress sync back to Stremio**: anything you watch updates Stremio's Continue Watching and watched episodes, and advances to the next episode when you finish one. Anime watched through AniList/MAL is matched to its Stremio entry (Kitsu or IMDb, via ani.zip) and synced too.
- AniList, MyAnimeList, Simkl and Discord Rich Presence work as in upstream AnymeX.

Settings → Accounts → **Stremio** has the login, sync switches and addon list.

## Windows

Every push also runs **Actions → Build Windows EXE**, which publishes to the **latest-windows** release:
- `AnymeX-Stremio-Windows-Setup.exe`: installer (installs alongside official AnymeX)
- `AnymeX-Stremio-Windows-Portable.zip`: unzip and run `anymex.exe`, no install needed

Windows may show a SmartScreen warning because the app isn't code-signed. Click **More info → Run anyway**.

## Building the iOS app

Every push to `main` runs **Actions → Build iOS IPA**. It checks the code, builds an unsigned `.ipa`, and attaches it to the **latest-ios** release. Install it with Feather, AltStore or Sideloadly.

AniList login needs your own (free) AniList API client:
1. https://anilist.co/settings/developer → Create New Client, Redirect URL `anymex://callback`
2. In this repo: Settings → Secrets and variables → Actions → add `AL_CLIENT_ID` and `AL_CLIENT_SECRET`
3. Re-run the workflow

(Optional: `MAL_CLIENT_ID`/`MAL_CLIENT_SECRET`, `SIMKL_CLIENT_ID`/`SIMKL_CLIENT_SECRET`, `TMDB_API_KEY`.)

## Credits & licenses

- AnymeX © 2024 Ryan, MIT, see `LICENSE-AnymeX.md`
- Stremio library/watched-state formats follow [stremio-core](https://github.com/Stremio/stremio-core) (MIT)
- Not affiliated with Stremio or AnymeX
