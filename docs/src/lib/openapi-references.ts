import type { OpenAPIObject, ReferenceObject } from '../vendor/openapi3-ts/openapi32';

const schemaPrefix = '#/components/schemas/';

export function schemaAnchor(name: string) { return `schema-${encodeURIComponent(name)}`; }

/** The Swift exporter only emits schema references, so any other Reference Object is unexpected. */
export function inline<Value extends object>(value: Value | ReferenceObject): Value {
  if ('$ref' in value) throw new Error(`Only schema references are supported: ${value.$ref}`);
  return value;
}

/** Link a schema reference to its component. Schema links stay finite instead of expanding recursive models. */
export function schemaLink(document: OpenAPIObject, reference: string) {
  if (!reference.startsWith(schemaPrefix)) {
    throw new Error(`Schema references must point to components/schemas: ${reference}`);
  }
  const name = decodeURIComponent(reference.slice(schemaPrefix.length)).replaceAll('~1', '/').replaceAll('~0', '~');
  if (!Object.hasOwn(document.components?.schemas ?? {}, name)) {
    throw new Error(`Unresolved OpenAPI reference: ${reference}`);
  }
  return { name, anchor: schemaAnchor(name) };
}
