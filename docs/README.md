# Documentation site

Astro Starlight documentation, built with pnpm. Run commands from the repository root.

```sh
pnpm install
pnpm dev
```

Use `pnpm check` to check the project, `pnpm build` to build the static site, and
`pnpm preview` to serve the production build locally.

Edit pages in `docs/src/content/docs/`. The Swift relay does not depend on this project.

The single-page API reference lives in `docs/src/content/docs/api.mdx`.
The endpoint navigator reads the badges on that page. The reference does not
send live requests or store API tokens.

`docs/public/openapi.json` is generated, not handwritten. The prototype covers
`GET /v1/status` and `POST /v1/messages` only. Run `just openapi` to regenerate it
and `just check-openapi` to reject stale output. Swift CI runs that check.
The docs build consumes the checked-in output and needs no Swift toolchain.
See [the package guide](../Packages/HummingbirdOpenAPI/README.md) for the supported
models and current limits.

## Cloudflare Workers

Connect this repository to the `imsg-relay-docs` Worker using these build settings:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Root directory | Repository root, leave blank |
| Build command | `pnpm build` |
| Deploy command | `pnpm run deploy` |
| Environment variable | `NODE_VERSION=24.18.0` |
| Environment variable | `PNPM_VERSION=12.3.4` |
| Environment variable | `SITE_URL` set to the full production URL |

Cloudflare installs dependencies with the root `pnpm-lock.yaml`. The deploy command
uses the pinned Wrangler dependency and `docs/wrangler.jsonc` to upload `docs/dist`.
Do not use `npx wrangler deploy`: the deployment must use the installed pnpm dependency.

If the existing Cloudflare project keeps `docs` as its root directory, the same
`pnpm build` and `pnpm run deploy` commands work from there too.

For a manual deployment, authenticate Wrangler with your Cloudflare account, then
run `pnpm build` followed by `pnpm run deploy` from the repository root. To validate the
upload configuration without publishing, run:

```sh
pnpm --filter imessage-relay-docs exec wrangler deploy --dry-run
```

The site defaults to `https://imessage-relay.luxass.dev` for its sitemap and
canonical URLs. Set `SITE_URL` to use another deployment URL. Workers Builds
does not provide the Pages-specific `CF_PAGES_URL` fallback.

The site uses Workers Static Assets with Starlight's generated 404 page. It needs no Astro
Cloudflare adapter, Worker entry point, or relay credentials. The relay runs on your Mac.

See [Cloudflare's Astro guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/astro/).
