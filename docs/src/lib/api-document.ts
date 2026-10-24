import document from '../../public/openapi.json';
import { createReference, type OperationView } from './openapi';

export const reference = createReference(document);

const guidance: Record<string, { description: string; guide: string; order: number }> = {
  Conversations: {
    description: 'Find conversations, mark them as read, and manage typing indicators.',
    guide: '/guides/conversations/',
    order: 0,
  },
  Messages: {
    description: 'Read and send messages, update reactions, and track send requests.',
    guide: '/guides/messages/',
    order: 1,
  },
  Media: {
    description: 'Upload files, inspect attachments, and download their bytes.',
    guide: '/guides/media/',
    order: 2,
  },
  Events: {
    description: 'Follow live changes and resume an event stream after a disconnect.',
    guide: '/guides/events/',
    order: 3,
  },
  Status: {
    description: 'Inspect the database, sender identity, and available capabilities.',
    guide: '/guides/status/',
    order: 4,
  },
};

const groups = new Map<string, OperationView[]>();
for (const operation of reference.operations) {
  const name = operation.tags[0] ?? 'Other';
  let operations = groups.get(name);
  if (!operations) {
    operations = [];
    groups.set(name, operations);
  }
  operations.push(operation);
}

/** Use the same resource groups for navigation, overview links, and generated pages. */
export const resources = [...groups].map(([name, operations]) => {
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
  return {
    name,
    slug,
    href: `/api/${slug}/`,
    description: guidance[name]?.description ?? `${name} endpoints.`,
    guide: guidance[name]?.guide ?? '/api-guide/',
    order: guidance[name]?.order ?? 100,
    operations,
  };
}).sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));

export function operationTitle(operation: OperationView): string {
  return operation.summary?.replace(/\.$/, '') ?? operation.id ?? `${operation.method} ${operation.path}`;
}
