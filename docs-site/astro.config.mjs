// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Project site at https://zenbaku.github.io/koni_dojo — `base` prefixes
// every URL so it works under the repo subpath on GitHub Pages.
export default defineConfig({
  site: 'https://zenbaku.github.io',
  base: '/koni_dojo',
  integrations: [
    starlight({
      title: 'Dojo',
      logo: { src: './src/assets/koni_dojo_icon.png', alt: 'Dojo' },
      favicon: '/favicon.png',
      description:
        'Dojo (the koni_dojo package) — a pure-Dart engine that turns a JSON config into a live HTML or JSON-API scraping source, with no per-site code.',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/zenbaku/koni_dojo',
        },
      ],
      editLink: {
        baseUrl:
          'https://github.com/zenbaku/koni_dojo/edit/main/docs-site/',
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', link: '/' },
            { label: 'Quickstart', link: '/start/quickstart/' },
            { label: 'Core ideas', link: '/start/concepts/' },
          ],
        },
        {
          label: 'Architecture',
          items: [
            { label: 'The engine', link: '/architecture/engine/' },
            { label: 'The pipeline', link: '/architecture/pipeline/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Config format', link: '/reference/config-format/' },
            { label: 'Workspaces', link: '/reference/workspaces/' },
            { label: 'Tooling & tasks', link: '/reference/tooling/' },
          ],
        },
      ],
    }),
  ],
});
