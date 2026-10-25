import type { OpenAPIObject, ReferenceObject, SchemaObject, SchemaObjectValue } from '../vendor/openapi3-ts/openapi32';
import { schemaLink } from './openapi-references.ts';

export interface SchemaView {
  kind: 'schema' | 'any' | 'never';
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

/** Templates only render this view and never inspect or resolve the source document. */
export class SchemaIndex {
  private readonly document: OpenAPIObject;

  constructor(document: OpenAPIObject) { this.document = document; }

  prepare(schema: SchemaObject | ReferenceObject): SchemaView {
    if (typeof schema === 'boolean') return empty(schema ? 'any' : 'never');
    if (Object.keys(schema).length === 0) return empty('any');
    const value = schema as SchemaObjectValue;
    const view = empty('schema');
    if (value.$ref) view.reference = schemaLink(this.document, value.$ref);
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
      ({ name, required: required.has(name), schema: this.prepare(child) }),
    );
    const sections: [string, (SchemaObject | ReferenceObject)[] | undefined][] = [
      ['Each array item', value.items === undefined ? undefined : [value.items]],
      ['Other field values', typeof value.additionalProperties === 'object' ? [value.additionalProperties] : undefined],
      ['All of these', value.allOf], ['At least one of these', value.anyOf], ['Exactly one of these', value.oneOf],
      ['This shape must not match', value.not === undefined ? undefined : [value.not]],
      ['JSON string contents', value.contentSchema === undefined ? undefined : [value.contentSchema]],
    ];
    view.sections = sections.flatMap(([label, schemas]) => schemas === undefined ? [] : [
      { label, schemas: schemas.map(child => this.prepare(child)) },
    ]);
    view.closed = value.additionalProperties === false;
    if (value.examples) view.examples = formatJSON(value.examples);
    return view;
  }
}
