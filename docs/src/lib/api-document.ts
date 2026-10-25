import document from '../../public/openapi.json';
import { createReference, type OperationView } from './openapi';

export const reference = createReference(document);

// Key order sets the resource order in navigation and overview links.
const guidance: Record<string, { description: string; guide: string }> = {
  Conversations: {
    description: 'Find conversations, mark them as read, and manage typing indicators.',
    guide: '/guides/conversations/',
  },
  Messages: {
    description: 'Read and send messages, update reactions, and track send requests.',
    guide: '/guides/messages/',
  },
  Media: {
    description: 'Upload files, inspect attachments, and download their bytes.',
    guide: '/guides/media/',
  },
  Events: {
    description: 'Follow live changes and resume an event stream after a disconnect.',
    guide: '/guides/events/',
  },
  Status: {
    description: 'Inspect the database, sender identity, and available capabilities.',
    guide: '/guides/status/',
  },
};

const groups = Map.groupBy(reference.operations, operation => {
  const tag = operation.tags[0];
  if (!tag || !Object.hasOwn(guidance, tag)) throw new Error(`Add guidance for the ${tag ?? 'untagged'} API resource.`);
  return tag;
});

/** Use the same resource groups for navigation, overview links, and generated pages. */
export const resources = Object.entries(guidance).filter(([name]) => groups.has(name)).map(([name, { description, guide }]) => {
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
  return { name, slug, href: `/api/${slug}/`, description, guide, operations: groups.get(name) ?? [] };
});

export function operationTitle(operation: OperationView): string {
  return operation.summary?.replace(/\.$/, '') ?? operation.id ?? `${operation.method} ${operation.path}`;
}
