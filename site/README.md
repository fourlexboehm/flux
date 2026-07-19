# Flux website

A single-page marketing site for the Flux DAW. Pure static HTML/CSS/JS — no build
step, no dependencies. Designed to be served from **Codeberg Pages**.

```
site/
├── index.html   # the page
├── style.css    # all styling
├── app.js         # detects the visitor's OS, spotlights the right download
├── screenshot.jpg # real Flux session-view screenshot (hero image)
├── favicon.svg    # logo / tab icon
├── og.svg         # social-share preview image
└── README.md      # this file
```

## Preview locally

```sh
cd site
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy to Codeberg Pages

Codeberg serves static files from a branch named **`pages`** in any repo, at
`https://<user>.codeberg.page/<repo>/`. For this repo that is:

> **https://fellowtraveler.codeberg.page/flux/**

Pages serves from the **root** of the `pages` branch, so the site files must sit
at the top level of that branch (not inside `site/`).

### One-time setup (orphan `pages` branch)

Run from the repo root:

```sh
# Create a clean, history-free branch that contains ONLY the site
git subtree split --prefix site -b pages
git push origin pages
```

That publishes the contents of `site/` at the root of the `pages` branch.
Within a minute or two the site is live at the URL above.

> Alternatively, do it by hand:
> ```sh
> git checkout --orphan pages
> git rm -rf .
> git checkout main -- site && mv site/* . && rmdir site
> git commit -am "Publish site"
> git push origin pages
> ```

### Updating the site later

Edit files in `site/` on `main`, commit, then re-sync the `pages` branch:

```sh
git push origin `git subtree split --prefix site main`:pages --force
```

## Download links

The download buttons point at the repo's **releases**:

- `https://codeberg.org/fellowtraveler/flux/releases/latest` — newest build
- `https://codeberg.org/fellowtraveler/flux/releases` — all versions

Releases are built and published automatically by
`.forgejo/workflows/release.yaml` when a version tag is pushed.

## Custom domain (optional)

Add a `.domains` file (one hostname per line) to the `pages` branch and create the
matching DNS record. See <https://docs.codeberg.org/codeberg-pages/>.
