import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: process.env.SITE_URL || process.env.CF_PAGES_URL,
  integrations: [
    starlight({
      title: 'imessage-relay',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/luxass/imessage-relay' }],
      editLink: { baseUrl: 'https://github.com/luxass/imessage-relay/edit/main/docs/' },
      sidebar: [
        { label: 'Overview', slug: 'index' },
        { label: 'Getting started', slug: 'getting-started' },
        { label: 'Configuration', slug: 'configuration' },
        { label: 'API reference', slug: 'api' },
        { label: 'Pagination', slug: 'pagination' },
        { label: 'Troubleshooting', slug: 'troubleshooting' },
        { label: 'Development and releases', slug: 'development' },
      ],
    }),
  ],
});
