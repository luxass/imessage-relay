import type { OpenAPIObject, ReferenceObject, SchemaObject } from '../vendor/openapi3-ts/openapi32';

export function isReference(value: unknown): value is ReferenceObject {
  return value !== null && typeof value === 'object' && '$ref' in value && typeof value.$ref === 'string';
}

export function schemaAnchor(name: string) { return `schema-${encodeURIComponent(name)}`; }

/** Shared by the build-time document view. Schema links stay finite instead of expanding recursive models. */
export class ReferenceIndex {
  private readonly pointers = new Map<string, unknown>();
  private readonly objects = new Map<string, object>();
  private readonly links = new Map<string, { name: string; anchor: string; schema: SchemaObject }>();

  private readonly document: OpenAPIObject;

  constructor(document: OpenAPIObject) { this.document = document; }

  lookup(reference: string): unknown {
    if (this.pointers.has(reference)) return this.pointers.get(reference);
    if (!reference.startsWith('#/')) throw new Error(`Only local OpenAPI references are supported: ${reference}`);
    let value: unknown = this.document;
    // URI decoding precedes JSON Pointer token splitting: an encoded slash is still a pointer separator.
    const pointer = decodeURIComponent(reference.slice(2));
    for (const token of pointer.split('/')) {
      const key = token.replaceAll('~1', '/').replaceAll('~0', '~');
      if (!value || typeof value !== 'object' || !Object.hasOwn(value, key)) {
        throw new Error(`Unresolved OpenAPI reference: ${reference}`);
      }
      value = (value as Record<string, unknown>)[key];
    }
    this.pointers.set(reference, value);
    return value;
  }

  resolve<Value extends object>(value: Value | ReferenceObject, chain?: Set<string>): Value {
    if (!isReference(value)) return value;
    const active = chain ?? new Set<string>();
    if (active.has(value.$ref)) throw new Error(`Circular OpenAPI object reference: ${value.$ref}`);
    let target = this.objects.get(value.$ref);
    if (!target) {
      const raw = this.lookup(value.$ref);
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new Error(`Reference does not point to an OpenAPI object: ${value.$ref}`);
      }
      active.add(value.$ref);
      target = this.resolve(raw, active);
      active.delete(value.$ref);
      this.objects.set(value.$ref, target);
    }
    if (!('summary' in value) && !('description' in value)) return target as Value;
    // Reference Object summary/description override the target without mutating the document or cached target.
    return { ...target, ...('summary' in value ? { summary: value.summary } : {}),
      ...('description' in value ? { description: value.description } : {}) } as Value;
  }

  schema(reference: string) {
    const cached = this.links.get(reference);
    if (cached) return cached;
    const segments = decodeURIComponent(reference.slice(2)).split('/').map(part => part.replaceAll('~1', '/').replaceAll('~0', '~'));
    if (!reference.startsWith('#/') || segments[0] !== 'components' || segments[1] !== 'schemas' || !segments[2]) {
      throw new Error(`Schema references must point to components/schemas: ${reference}`);
    }
    const target = this.lookup(reference);
    if (typeof target !== 'boolean' && (!target || typeof target !== 'object' || Array.isArray(target))) {
      throw new Error(`Reference does not point to a schema: ${reference}`);
    }
    const link = { name: segments.slice(2).join('/'), anchor: schemaAnchor(segments[2]), schema: target as SchemaObject };
    this.links.set(reference, link);
    return link;
  }
}
