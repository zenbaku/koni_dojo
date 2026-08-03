# Docs site

The documentation website for koni_dojo: [Astro
Starlight](https://starlight.astro.build/). An **isolated Node project**: it has
its own `package.json`/`node_modules` and never touches the Dart package (the
same way `playground/` is the isolated Flutter corner).

Built and deployed to GitHub Pages by `.github/workflows/deploy-docs.yml` on
push to `main`, served at **https://zenbaku.github.io/koni_dojo/**.
(One-time: repo Settings → Pages → Source = "GitHub Actions".)

## Local development

```sh
cd docs-site
npm install        # first time
npm run dev        # live-reload dev server
npm run build      # static build → dist/
npm run preview    # serve the built dist/
```

Or from the repo root: `task docs` (dev) / `task docs-build` (static build).

## Content

Pages are Markdown/MDX in `src/content/docs/`; the sidebar and site config are
in `astro.config.mjs`. The site re-presents the repo's docs for the web and
links back to the canonical deep references (`docs/*.md`) on GitHub: those
stay authoritative; this site is the front door.
