// Shared shell helpers: turning what a reader typed into something to
// navigate to. Used by the address bar and the home surface, so a search
// behaves the same in both places.

// The template comes from the default search engine's resolved searchUrl
// (getSearchEngines), parked by AuraShell. `{searchTerms}` is the only
// placeholder left to substitute.
const SEARCH_TEMPLATE_KEY: string = 'auraSearchUrlTemplate';

const FALLBACK_SEARCH_PREFIX: string = 'https://www.bing.com/search?q=';

export function normalizeAddress(value: string): string {
  const input = value.trim();
  if (input.length === 0) {
    return '';
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(input)) {
    return input;
  }
  if (/\s/.test(input) || !input.includes('.')) {
    return searchUrlFor(input);
  }
  return `https://${input}`;
}

function searchUrlFor(query: string): string {
  const encoded = encodeURIComponent(query);
  const template = String(AppStorage.get(SEARCH_TEMPLATE_KEY) ?? '');
  if (template.length > 0 && template.includes('{searchTerms}')) {
    return template.replace('{searchTerms}', encoded);
  }
  return `${FALLBACK_SEARCH_PREFIX}${encoded}`;
}
