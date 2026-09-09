# Documentation site

Astro Starlight documentation, built with pnpm. Run commands from the repository root.

```sh
pnpm install
pnpm dev
```

Use `pnpm check` to check the project, `pnpm build` to build the static site, and
`pnpm preview` to serve the production build locally.

Edit pages in `docs/src/content/docs/`. The Swift relay does not depend on this project.

## Cloudflare Pages

Connect this repository to a Cloudflare Pages project using these settings:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Root directory | Repository root, leave blank |
| Build command | `pnpm build` |
| Build output directory | `docs/dist` |
| Environment variable | `NODE_VERSION=24.18.0` |
| Environment variable | `PNPM_VERSION=12.3.4` |

Cloudflare installs dependencies before running the build. Commit the root `pnpm-lock.yaml`
so deployments use the same dependency versions as local builds.

Set `SITE_URL` to the full production URL after choosing your Pages project name
or custom domain. Without it, the build uses Cloudflare's `CF_PAGES_URL`.
Local builds can omit both variables.

This site is static and needs no Cloudflare adapter, runtime bindings, or relay
credentials. Cloudflare hosts the documentation; the relay runs on your Mac.

See [Cloudflare's Astro guide](https://developers.cloudflare.com/pages/framework-guides/deploy-an-astro-site/).
