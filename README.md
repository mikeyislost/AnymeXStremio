I would just like to note that this app is built using claude code. I do not know how to code but i wanted an app that combines functionality from both apps for my own personal use.

<div align="center">
<img src='assets/images/logo.png' alt='AnymeX+ Icon' style="border-radius: 50px; height: 150px; width: 150px;">

<p align="center">
  <img src="https://img.shields.io/badge/platforms-ios_windows-06599d?color=white&labelColor=black&style=for-the-badge"/>
  <a href="https://github.com/mikeyislost/AnymeXStremio/releases"><img src="https://img.shields.io/github/downloads/mikeyislost/AnymeXStremio/total?color=white&labelColor=black&label=Downloads&style=for-the-badge" alt="Downloads"></a>
</p>
</div>

# AnymeX+: AnymeX with Stremio

**AnymeX+** is a personal build of [AnymeX](https://github.com/RyanYuuki/AnymeX) with [Stremio](https://www.stremio.com/) built in, so anime, movies and TV live in one app.

- **Movies & TV tab:** Stremio Continue Watching, your addons' catalogs and search
- **Stremio account and addons:** sign in, and your addons come with you
- **Progress syncs both ways:** what you watch here shows in Stremio, and anime progress (AniList / MAL) updates Stremio too
- **Stremio library** in the Library tab, plus comments on movies and shows
- **AniList, MyAnimeList, Simkl and Discord** work as in AnymeX
- **Self Test** in Settings checks everything and saves a report

> [!IMPORTANT]
> AnymeX+ is a personal, unofficial build. It is not affiliated with AnymeX or Stremio, and it does not host or provide any content. Streams come from addons and extensions you add yourself.

## Downloads

<div align="center">
  <p>
    <a href="https://github.com/mikeyislost/AnymeXStremio/releases/latest"><img src="https://img.shields.io/github/v/release/mikeyislost/AnymeXStremio?color=white&labelColor=black&display_name=tag&style=for-the-badge&label=Latest" alt="Latest Release"/></a>
  </p>

### Windows
  <p>
    <a href="https://github.com/mikeyislost/AnymeXStremio/releases/latest"><img src="https://img.shields.io/badge/Installer-Setup.exe-white?style=for-the-badge&labelColor=black" alt="Windows installer"/></a>
    <a href="https://github.com/mikeyislost/AnymeXStremio/releases/latest"><img src="https://img.shields.io/badge/Portable-.zip-white?style=for-the-badge&labelColor=black" alt="Windows portable"/></a>
  </p>
</div>

<div align="center">

### iOS Sideloading Sources
  <p>
    <a href="https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://github.com/mikeyislost/AnymeXStremio/releases/latest/download/source.json"><img alt="AltStore Source" src="https://img.shields.io/badge/open_in_app-_?style=for-the-badge&label=AltStore&labelColor=black&color=white"></a>
    <a href="https://intradeus.github.io/http-protocol-redirector?r=feather://source/https://github.com/mikeyislost/AnymeXStremio/releases/latest/download/source.json"><img alt="Feather Source" src="https://img.shields.io/badge/open_in_app-_?style=for-the-badge&label=Feather&labelColor=black&color=white"></a>
    <a href="https://intradeus.github.io/http-protocol-redirector?r=sidestore://source?url=https://github.com/mikeyislost/AnymeXStremio/releases/latest/download/source.json"><img alt="SideStore Source" src="https://img.shields.io/badge/open_in_app-_?style=for-the-badge&label=SideStore&labelColor=black&color=white"></a>
    <a href="https://github.com/mikeyislost/AnymeXStremio/releases/latest/download/source.json"><img alt="Direct Source URL" src="https://img.shields.io/badge/copy_%2F_paste-_?style=for-the-badge&label=Direct%20Source%20URL&labelColor=black&color=white"></a>
  </p>
</div>

AnymeX+ uses its own bundle ID, so it installs next to the official AnymeX. The app checks for updates on launch.

<details>
<summary>Building it yourself</summary>

Every push to `main` builds iOS and Windows with GitHub Actions and publishes a release.

AniList login needs a free AniList API client:
1. Create a client at https://anilist.co/settings/developer with the redirect URL `anymex://callback`
2. Add `AL_CLIENT_ID` and `AL_CLIENT_SECRET` under Settings → Secrets and variables → Actions

Optional secrets: `MAL_CLIENT_ID` / `MAL_CLIENT_SECRET`, `SIMKL_CLIENT_ID` / `SIMKL_CLIENT_SECRET`, `TMDB_API_KEY`.
</details>

## Credits

- [AnymeX](https://github.com/RyanYuuki/AnymeX) by Ryan and contributors, the app this is built on (MIT, see [LICENSE-AnymeX.md](LICENSE-AnymeX.md))
- [stremio-core](https://github.com/Stremio/stremio-core), for how Stremio's library and watched state work
- Comments run on AnymeX's Commentum service

## License

MIT. See [LICENSE](LICENSE).
