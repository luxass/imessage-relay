import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import tailwindcss from '@tailwindcss/vite';
import { resources } from './src/lib/api-document';

export default defineConfig({
  site: process.env.SITE_URL || process.env.CF_PAGES_URL,
  vite: { plugins: [tailwindcss()] },
  integrations: [
    starlight({
      title: 'iMessage Relay',
      customCss: ['./src/styles/global.css'],
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/luxass/imessage-relay' }],
      editLink: { baseUrl: 'https://github.com/luxass/imessage-relay/edit/main/docs/' },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', slug: 'index' },
            { label: 'Install and run', slug: 'getting-started' },
            { label: 'Configuration', slug: 'configuration' },
          ],
        },
        {
          label: 'Guides',
          collapsed: true,
          items: [
            { label: 'API basics', slug: 'api-guide' },
            { label: 'Conversations', slug: 'guides/conversations' },
            { label: 'Messages and sending', slug: 'guides/messages' },
            { label: 'Uploads and downloads', slug: 'guides/media' },
            { label: 'Live events', slug: 'guides/events' },
            { label: 'Cursors and pagination', slug: 'pagination' },
            { label: 'Service status', slug: 'guides/status' },
          ],
        },
        {
          label: 'API reference',
          items: [
            { label: 'Overview', slug: 'api' },
            ...resources.map(resource => ({ label: resource.name, link: resource.href })),
            { label: 'Model schemas', link: '/api/schemas/' },
          ],
        },
        {
          label: 'Support',
          collapsed: true,
          items: [
            { label: 'Error responses', slug: 'guides/errors' },
            { label: 'Troubleshooting', slug: 'troubleshooting' },
          ],
        },
        {
          label: 'Development',
          collapsed: true,
          items: [{ label: 'Build and release', slug: 'development' }],
        },
      ],
    }),
  ],
});
