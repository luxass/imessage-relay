# Documentation site

Astro Starlight documentation, built with pnpm. Run commands from the repository root.

```sh
pnpm install
pnpm dev
```

Use `pnpm check` to check the project, `pnpm build` to build the static site, and
`pnpm preview` to serve the production build locally.

Edit pages in `docs/src/content/docs/`. The Swift relay does not depend on this project.

## Styling

Use Tailwind utility classes in Astro components. `src/styles/global.css` loads the theme and utilities.
It skips Tailwind's global reset (Preflight), so Starlight keeps its existing styles.
Use Starlight's `--sl-*` color variables to match the light and dark themes.

## Generated API reference

The API page renders `docs/public/openapi.json`. Swift models and endpoint declarations generate that file.
Do not edit its fields or maintain a second schema in Markdown. `.gitattributes` marks it as generated for GitHub reviews.

After a model, endpoint, or API version changes, run these commands on the development Mac:

```sh
just openapi
just check-openapi
pnpm check
pnpm build
```

The exporter does not start the server or read Relay configuration. It needs no Messages permissions or database files.
The artifact check compares bytes and never overwrites the file.

Swift package and contract tests cover the generated API description and HTTP behavior.
`pnpm check` checks the Astro components and TypeScript types. `pnpm build` builds the static reference.
There is no separate documentation test suite.

`docs/src/content/docs/api-guide.mdx` introduces the API. Task guides live in `docs/src/content/docs/guides/`.
The sidebar separates setup, guides, API reference, support, and development. Existing setup and guide entry URLs remain available.

`src/lib/api-document.ts` groups operations from the artifact. The sidebar, overview, and resource pages use those same groups.
`src/pages/api/[resource].astro` generates a page for each resource. `src/pages/api/schemas.astro` provides model filtering and linked definitions.
The reference prepares indexed display data once at build time and links to schema definitions instead of expanding references recursively.
Identical response bodies share a section. Common headers appear once per operation, with every status code and description retained.
The templates do not repeatedly resolve references or interpret the source JSON.

The standard OpenAPI 3.2 types are vendored from `openapi3-ts`, the package also used by Hono's `@hono/zod-openapi`.
The pinned revision and MIT license live in `src/vendor/openapi3-ts/`. No runtime dependency was added.
Read [the design notes](./openapi-design.md) for the specification basis, helpers, tests, and route-local declaration option.

Cloudflare consumes the committed JSON and does not need Swift. The build publishes the same file at `/openapi.json`.

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

Set `SITE_URL` before building to generate the sitemap and canonical URLs. Workers
Builds does not provide the Pages-specific `CF_PAGES_URL` fallback. Local builds
can omit `SITE_URL`.

The site uses Workers Static Assets with Starlight's generated 404 page. It needs no Astro
Cloudflare adapter, Worker entry point, or relay credentials. The relay runs on your Mac.

See [Cloudflare's Astro guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/astro/).
