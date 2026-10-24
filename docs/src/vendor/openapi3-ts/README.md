# Vendored OpenAPI types

These are declaration-only files from [openapi3-ts](https://github.com/metadevpro/openapi3-ts).
Hono’s `@hono/zod-openapi` also uses that package for OpenAPI types.
We use its OpenAPI 3.2 model because the exported document uses 3.2 streaming fields.

Source revision: `7b9684f8353b1e1f9c1904a6e64feb205f985aff`.
The upstream package declares version `4.6.2` at this revision.
The MIT license is preserved in `LICENSE`. No package or runtime dependency was added.

The files were generated with the existing TypeScript 6.0.3 compiler from these unmodified upstream files:

- `src/model/openapi32.ts`
- `src/model/oas-common.ts`
- `src/model/specification-extension.ts`

To reproduce the declarations, fetch those files from the pinned revision into one temporary directory.
Use the existing compiler with `--declaration --emitDeclarationOnly --target es2022 --module esnext --moduleResolution bundler`.
Copy the three emitted `.d.ts` files here. Keep upstream interfaces intact rather than maintaining a local subset.
Import them with `import type` only. The declarations contain no executable implementation.

SHA-256 of the upstream source files, in the order above:

```text
59d68e004b4a575830c6ea4d156e3e23722acc9a98a79a3dd248c286e0baad30
9ad9dac2c83ae498690d814da749a955c3efc5a1bbc0ae70623fc46f3ee75184
56fc12372d2f4b62845bafe447ac9e39cb5ce3e9d7f6ea7971966972007de294
```
