import type { ReferenceObject, SchemaObject, SchemaObjectValue } from '../vendor/openapi3-ts/openapi32';
import { ReferenceIndex } from './openapi-references.ts';

export interface SchemaView {
  kind: 'schema' | 'any' | 'never' | 'truncated';
  reference?: { name: string; anchor: string };
  type?: string;
  description?: string;
  constant?: string;
  values: string[];
  defaultValue?: string;
  constraints: { label: string; value: string }[];
  properties: { name: string; required: boolean; schema: SchemaView }[];
  sections: { label: string; schemas: SchemaView[] }[];
  closed: boolean;
  examples?: string;
}

const constraintNames = [
  ['minimum', 'Minimum'], ['maximum', 'Maximum'], ['exclusiveMinimum', 'Greater than'], ['exclusiveMaximum', 'Less than'],
  ['multipleOf', 'Multiple of'], ['minLength', 'Minimum length'], ['maxLength', 'Maximum length'], ['pattern', 'Pattern'],
  ['minItems', 'Minimum items'], ['maxItems', 'Maximum items'], ['uniqueItems', 'Unique items'],
  ['minProperties', 'Minimum fields'], ['maxProperties', 'Maximum fields'], ['contentMediaType', 'Encoded content type'],
] as const;

export function formatJSON(value: unknown): string { return JSON.stringify(value, null, 2) ?? 'undefined'; }

function empty(kind: SchemaView['kind']): SchemaView {
  return { kind, values: [], constraints: [], properties: [], sections: [], closed: false };
}

/** Prepare each schema once. Templates only render this view and never inspect or resolve the source document. */
export class SchemaIndex {
  private readonly cache = new WeakMap<object, SchemaView>();
  private readonly references = new Map<string, SchemaView>();
  private readonly active = new WeakSet<object>();
  private readonly any = empty('any');
  private readonly never = empty('never');

  private readonly index: ReferenceIndex;

  constructor(index: ReferenceIndex) { this.index = index; }

  prepare(schema: SchemaObject | ReferenceObject, depth = 0): SchemaView {
    if (typeof schema === 'boolean') return schema ? this.any : this.never;
    if (depth > 24) return empty('truncated');
    if (this.active.has(schema)) throw new Error('Inline schema cycles must use $ref.');
    const cached = this.cache.get(schema);
    if (cached) return cached;
    const keys = Object.keys(schema);
    if (keys.length === 0) { this.cache.set(schema, this.any); return this.any; }
    // Most references are identical leaf nodes repeated across operation responses. Intern them by URI too.
    if (schema.$ref && keys.length === 1) {
      let reference = this.references.get(schema.$ref);
      if (!reference) {
        reference = { ...empty('schema'), reference: this.index.schema(schema.$ref) };
        this.references.set(schema.$ref, reference);
      }
      this.cache.set(schema, reference);
      return reference;
    }
    this.active.add(schema);
    try {
      const view = this.object(schema, depth);
      this.cache.set(schema, view);
      return view;
    } finally {
      this.active.delete(schema);
    }
  }

  private object(schema: SchemaObjectValue | ReferenceObject, depth: number): SchemaView {
    const value = schema as SchemaObjectValue;
    const view = empty('schema');
    if (value.$ref) view.reference = this.index.schema(value.$ref);
    if (value.type) {
      view.type = Array.isArray(value.type) ? value.type.join(' | ') : value.type;
      if (value.format) view.type += ` (${value.format})`;
    }
    view.description = value.description;
    if (Object.hasOwn(value, 'const')) view.constant = formatJSON(value.const);
    if (Object.hasOwn(value, 'default')) view.defaultValue = formatJSON(value.default);
    view.values = value.enum?.map(formatJSON) ?? [];
    view.constraints = constraintNames.filter(([key]) => Object.hasOwn(value, key)).map(([key, label]) =>
      ({ label, value: typeof value[key] === 'string' ? value[key] : formatJSON(value[key]) }),
    );
    const required = new Set(value.required ?? []);
    view.properties = Object.entries(value.properties ?? {}).map(([name, child]) =>
      ({ name, required: required.has(name), schema: this.prepare(child, depth + 1) }),
    );
    const sections: [string, (SchemaObject | ReferenceObject)[] | undefined][] = [
      ['Each array item', value.items === undefined ? undefined : [value.items]],
      ['Other field values', typeof value.additionalProperties === 'object' ? [value.additionalProperties] : undefined],
      ['All of these', value.allOf], ['At least one of these', value.anyOf], ['Exactly one of these', value.oneOf],
      ['This shape must not match', value.not === undefined ? undefined : [value.not]],
      ['JSON string contents', value.contentSchema === undefined ? undefined : [value.contentSchema]],
    ];
    view.sections = sections.flatMap(([label, schemas]) => schemas === undefined ? [] : [
      { label, schemas: schemas.map(child => this.prepare(child, depth + 1)) },
    ]);
    view.closed = value.additionalProperties === false;
    if (value.examples) view.examples = formatJSON(value.examples);
    return view;
  }
}
