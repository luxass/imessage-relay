import type {
  ContentObject, ExampleObject, HeaderObject, MediaTypeObject, OpenAPIObject, OperationObject,
  ParameterObject, PathItemObject, ResponseObject, SecurityRequirementObject, SecuritySchemeObject,
} from '../vendor/openapi3-ts/openapi32';
import { ReferenceIndex, schemaAnchor } from './openapi-references.ts';
import { SchemaIndex, formatJSON, type SchemaView } from './openapi-schema.ts';

export { schemaAnchor } from './openapi-references.ts';
export type { SchemaView } from './openapi-schema.ts';

export interface MediaView {
  type: string;
  schema?: SchemaView;
  itemSchema?: SchemaView;
  examples: { name: string; value?: string; externalURL?: string }[];
}
export interface FieldView {
  name: string;
  location?: string;
  required: boolean;
  description?: string;
  schema?: SchemaView;
  media: MediaView[];
}
export interface ResponseGroup {
  success: boolean;
  statuses: { code: string; description?: string }[];
  headers: FieldView[];
  media: MediaView[];
}
export interface OperationView {
  path: string;
  method: string;
  id?: string;
  anchor: string;
  summary?: string;
  description?: string;
  tags: string[];
  security: string;
  parameters: FieldView[];
  body?: { required: boolean; description?: string; media: MediaView[] };
  commonHeaders: FieldView[];
  responses: ResponseGroup[];
}
export interface ReferenceView {
  title: string;
  version: string;
  openapi: string;
  servers: string[];
  security: { name: string; type: string; description?: string; usage: string }[];
  operations: OperationView[];
  schemas: { name: string; anchor: string; schema: SchemaView }[];
}

const methods = ['get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace', 'query'] as const;
function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** The artifact is validated by Swift. This boundary checks its version and required page metadata, not JSON instances. */
function assertDocumentMetadata(input: unknown): asserts input is OpenAPIObject {
  if (!isRecord(input) || typeof input.openapi !== 'string' || !/^3\.[12]\.\d+$/.test(input.openapi)
    || !isRecord(input.info) || typeof input.info.title !== 'string' || typeof input.info.version !== 'string') {
    throw new Error('The API reference needs an OpenAPI 3.1 or 3.2 document with title and version metadata.');
  }
}

/** Normalize once at build time. Astro components consume display data, not untyped OpenAPI dictionaries. */
export function createReference(input: unknown): ReferenceView {
  assertDocumentMetadata(input);
  return new ReferenceBuilder(input).build();
}

class ReferenceBuilder {
  private readonly references: ReferenceIndex;
  private readonly schemas: SchemaIndex;
  private readonly signatures = new WeakMap<object, string>();

  private readonly document: OpenAPIObject;

  constructor(document: OpenAPIObject) {
    this.document = document;
    this.references = new ReferenceIndex(document);
    this.schemas = new SchemaIndex(this.references);
  }

  build(): ReferenceView {
    const operations: OperationView[] = [];
    const anchors = new Set<string>();
    for (const [path, raw] of Object.entries(this.document.paths ?? {})) {
      if (!path.startsWith('/')) continue;
      const item = this.references.resolve<PathItemObject>(raw);
      for (const method of methods) {
        const operation = item[method];
        if (operation) operations.push(this.operation(path, method.toUpperCase(), operation, item));
      }
      for (const [method, operation] of Object.entries(item.additionalOperations ?? {})) {
        operations.push(this.operation(path, method, operation, item));
      }
    }
    for (const operation of operations) {
      if (anchors.has(operation.anchor)) throw new Error(`Duplicate operation anchor: ${operation.anchor}`);
      anchors.add(operation.anchor);
    }
    return {
      title: this.document.info.title, version: this.document.info.version, openapi: this.document.openapi,
      servers: this.document.servers?.map(server => server.url) ?? [], operations,
      security: Object.entries(this.document.components?.securitySchemes ?? {}).map(([name, raw]) => {
        const scheme = this.references.resolve<SecuritySchemeObject>(raw);
        const usage = scheme.type === 'http' ? `Authorization: ${scheme.scheme?.toLowerCase() === 'bearer' ? 'Bearer <token>' : scheme.scheme}`
          : scheme.type === 'apiKey' ? `${scheme.in}: ${scheme.name}` : scheme.type;
        return { name, type: scheme.type, description: scheme.description, usage };
      }),
      schemas: Object.entries(this.document.components?.schemas ?? {}).map(([name, schema]) =>
        ({ name, anchor: schemaAnchor(name), schema: this.schemas.prepare(schema) }),
      ),
    };
  }

  private operation(path: string, method: string, operation: OperationObject, item: PathItemObject): OperationView {
    const parameters = new Map<string, ParameterObject>();
    for (const raw of [...(item.parameters ?? []), ...(operation.parameters ?? [])]) {
      const parameter = this.references.resolve<ParameterObject>(raw);
      const name = parameter.in === 'header' ? parameter.name.toLowerCase() : parameter.name;
      parameters.set(`${parameter.in}:${name}`, parameter);
    }
    const body = operation.requestBody ? this.references.resolve(operation.requestBody) : undefined;
    const responses = Object.entries(operation.responses ?? {}).filter(([status]) => /^(default|[1-5](\d\d|XX))$/.test(status)).map(([code, raw]) => {
      const response = this.references.resolve<ResponseObject>(raw);
      return { code, response, headers: this.headers(response) };
    });
    const commonHeaders = this.commonHeaders(responses.map(response => response.headers));
    const groups = new Map<string, ResponseGroup>();
    for (const { code, response, headers } of responses) {
      const specific = new Map([...headers].filter(([name]) => !commonHeaders.has(name)));
      const success = code.startsWith('2');
      const headerKey = specific.size ? JSON.stringify([...specific]) : '';
      const key = `${success}:${this.signature(response.content ?? {})}:${headerKey}:${this.signature(response.links ?? {})}`;
      let group = groups.get(key);
      if (!group) {
        group = { success, statuses: [], headers: this.headerFields(specific), media: this.media(response.content) };
        groups.set(key, group);
      }
      group.statuses.push({ code, description: response.description ?? response.summary });
    }
    return {
      path, method, id: operation.operationId, anchor: `operation-${encodeURIComponent(operation.operationId ?? `${method}-${path}`)}`,
      summary: operation.summary, description: operation.description, tags: operation.tags ?? [],
      security: this.security(operation.security ?? this.document.security ?? []),
      parameters: [...parameters.values()].map(parameter => ({
        name: parameter.name, location: parameter.in, required: parameter.in === 'path' || parameter.required === true,
        description: parameter.description, schema: parameter.schema === undefined ? undefined : this.schemas.prepare(parameter.schema),
        media: this.media(parameter.content),
      })),
      body: body ? { required: body.required === true, description: body.description, media: this.media(body.content) } : undefined,
      commonHeaders: this.headerFields(commonHeaders), responses: [...groups.values()],
    };
  }

  private headers(response: ResponseObject): Map<string, { name: string; header: HeaderObject }> {
    return new Map(Object.entries(response.headers ?? {}).map(([name, raw]) =>
      [name.toLowerCase(), { name, header: this.references.resolve<HeaderObject>(raw) }],
    ));
  }

  private commonHeaders(responses: Map<string, { name: string; header: HeaderObject }>[]) {
    const common = new Map(responses[0] ?? []);
    for (const response of responses.slice(1)) {
      for (const [name, value] of common) {
        const other = response.get(name);
        if (!other || this.signature(value.header) !== this.signature(other.header)) common.delete(name);
      }
    }
    return common;
  }

  private headerFields(headers: Map<string, { name: string; header: HeaderObject }>): FieldView[] {
    return [...headers.values()].map(({ name, header }) => ({
      name, required: header.required === true, description: header.description,
      schema: header.schema === undefined ? undefined : this.schemas.prepare(header.schema), media: this.media(header.content),
    }));
  }

  private media(content?: ContentObject): MediaView[] {
    return Object.entries(content ?? {}).map(([type, raw]) => {
      const media = this.references.resolve<MediaTypeObject>(raw);
      const examples: MediaView['examples'] = [];
      if (Object.hasOwn(media, 'example')) examples.push({ name: 'Example', value: formatJSON(media.example) });
      for (const [name, raw] of Object.entries(media.examples ?? {})) {
        const example = this.references.resolve<ExampleObject>(raw);
        // Prefer the OAS 3.2 dataValue field, while retaining legacy value examples.
        const valueKey = ['dataValue', 'value'].find(key => Object.hasOwn(example, key));
        examples.push({ name: example.summary ?? name, externalURL: example.externalValue,
          value: example.serializedValue ?? (valueKey ? formatJSON(example[valueKey]) : undefined) });
      }
      return { type, examples,
        schema: media.schema === undefined ? undefined : this.schemas.prepare(media.schema),
        itemSchema: media.itemSchema === undefined ? undefined : this.schemas.prepare(media.itemSchema) };
    });
  }

  private security(requirements: SecurityRequirementObject[]): string {
    if (!requirements.length) return 'None';
    return requirements.map(requirement => Object.entries(requirement).map(([name, scopes]) =>
      scopes.length ? `${name} (${scopes.join(', ')})` : name,
    ).join(' + ') || 'None').join(' or ');
  }

  private signature(value: object): string {
    let signature = this.signatures.get(value);
    if (signature === undefined) { signature = JSON.stringify(value); this.signatures.set(value, signature); }
    return signature;
  }
}
