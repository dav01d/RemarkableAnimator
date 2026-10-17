# Vellum package

`remarkable-animator/VELBUILD` is the recipe for [Vellum](https://github.com/vellum-dev/vellum), so the app
installs with `vellum add remarkable-animator`. It installs the committed `src/backend/entry`,
`src/resources.rcc`, `manifest.json` and `icon.png` into AppLoad's folder (the same files `deploy.ps1` copies).

## Publishing a version
1. Tag the release here: `git tag v0.2.0 && git push origin v0.2.0` (match `pkgver`).
2. Fork [vellum-dev/vellum](https://github.com/vellum-dev/vellum) and copy this folder to
   `packages/remarkable-animator/`.
3. In the fork: `./scripts/update-checksums.sh remarkable-animator` (fills in `sha512sums`), then
   `./scripts/lint-packages.sh remarkable-animator --apkbuild-lint` and
   `./scripts/build-package.sh remarkable-animator aarch64`.
4. Open the PR yourself, one package per PR. Vellum's rules: PRs must be opened by a person, an
   LLM-written description gets the PR closed, and commits must not carry AI `Co-Authored-By:` lines.
5. After review it lands in their testing repo: on the tablet, `vellum testing enable`,
   `vellum update && vellum add remarkable-animator@testing`, try it, comment `/ready-for-review` on the
   PR, then `vellum testing disable`.

For a packaging-only change bump `pkgrel`; for a new app version set `pkgver` and reset `pkgrel` to 0.
Maintainers may ask for `entry` to be built from `backend/pen.c` in the recipe instead of shipped prebuilt.
Purging (`VELLUM_PURGE=1`) also deletes the saved animations in `~/.local/share/remarkable-animator`.
