export function highlight(text: string, query: string): string {
  if (!query) return text;
  const idx = text.toLowerCase().indexOf(query.toLowerCase());
  if (idx === -1) return text;
  return (
    text.slice(0, idx) +
    '<mark>' +
    text.slice(idx, idx + query.length) +
    '</mark>' +
    text.slice(idx + query.length)
  );
}
