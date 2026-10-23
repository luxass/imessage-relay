import type {
  ContentObject, HeaderObject, OpenAPIObject, OperationObject, ParameterObject, PathItemObject,
  ResponseObject, SecurityRequirementObject,
} from '../vendor/openapi3-ts/openapi32';
import { inline, schemaAnchor } from './openapi-references.ts';
import { SchemaIndex, formatJSON, type SchemaView } from './openapi-schema.ts';

export type { SchemaView } from './openapi-schema.ts';

export interface MediaView {
  type: string;
  schema?: SchemaView;
  itemSchema?: SchemaView;
  example?: string;
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
  /** Each entry is one alternative way to authenticate. Empty means no authentication. */
  security: string[];
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
  if (!isRecord(input) || typeof input.openapi !== 'string' || !/^3\.2\.\d+$/.test(input.openapi)
    || !isRecord(input.info) || typeof input.info.title !== 'string' || typeof input.info.version !== 'string') {
    throw new Error('The API reference needs an OpenAPI 3.2 document with title and version metadata.');
  }
}

/** Normalize once at build time. Astro components consume display data, not untyped OpenAPI dictionaries. */
export function createReference(input: unknown): ReferenceView {
  assertDocumentMetadata(input);
  return new ReferenceBuilder(input).build();
}

class ReferenceBuilder {
  private readonly schemas: SchemaIndex;

  private readonly document: OpenAPIObject;

  constructor(document: OpenAPIObject) {
    this.document = document;
    this.schemas = new SchemaIndex(document);
  }

  build(): ReferenceView {
    const operations: OperationView[] = [];
    const anchors = new Set<string>();
    for (const [path, raw] of Object.entries(this.document.paths ?? {})) {
      if (!path.startsWith('/')) continue;
      const item = inline<PathItemObject>(raw);
      for (const method of methods) {
        if (!item[method]) continue;
        const operation = this.operation(path, method.toUpperCase(), item[method], item);
        if (anchors.has(operation.anchor)) throw new Error(`Duplicate operation anchor: ${operation.anchor}`);
        anchors.add(operation.anchor);
        operations.push(operation);
      }
    }
    return {
      title: this.document.info.title, version: this.document.info.version, openapi: this.document.openapi,
      servers: this.document.servers?.map(server => server.url) ?? [], operations,
      security: Object.entries(this.document.components?.securitySchemes ?? {}).map(([name, raw]) => {
        const scheme = inline(raw);
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
      const parameter = inline<ParameterObject>(raw);
      const name = parameter.in === 'header' ? parameter.name.toLowerCase() : parameter.name;
      parameters.set(`${parameter.in}:${name}`, parameter);
    }
    const body = operation.requestBody ? inline(operation.requestBody) : undefined;
    const responses = Object.entries(operation.responses ?? {}).filter(([status]) => /^(default|[1-5](\d\d|XX))$/.test(status)).map(([code, raw]) => {
      const response = inline<ResponseObject>(raw);
      return { code, response, headers: this.headers(response) };
    });
    const commonHeaders = this.commonHeaders(responses.map(response => response.headers));
    const groups = new Map<string, ResponseGroup>();
    for (const { code, response, headers } of responses) {
      const specific = new Map([...headers].filter(([name]) => !commonHeaders.has(name)));
      const success = code.startsWith('2');
      const headerKey = specific.size ? JSON.stringify([...specific]) : '';
      const key = `${success}:${JSON.stringify(response.content ?? {})}:${headerKey}`;
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
      [name.toLowerCase(), { name, header: inline<HeaderObject>(raw) }],
    ));
  }

  private commonHeaders(responses: Map<string, { name: string; header: HeaderObject }>[]) {
    const common = new Map(responses[0] ?? []);
    for (const response of responses.slice(1)) {
      for (const [name, value] of common) {
        const other = response.get(name);
        if (!other || JSON.stringify(value.header) !== JSON.stringify(other.header)) common.delete(name);
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
      const media = inline(raw);
      return { type, example: Object.hasOwn(media, 'example') ? formatJSON(media.example) : undefined,
        schema: media.schema === undefined ? undefined : this.schemas.prepare(media.schema),
        itemSchema: media.itemSchema === undefined ? undefined : this.schemas.prepare(media.itemSchema) };
    });
  }

  private security(requirements: SecurityRequirementObject[]): string[] {
    // An empty requirement object makes authentication optional, so it contributes no listed alternative.
    return requirements.filter(requirement => Object.keys(requirement).length > 0).map(requirement =>
      Object.entries(requirement).map(([name, scopes]) => scopes.length ? `${name} (${scopes.join(', ')})` : name).join(' + '),
    );
  }
}
