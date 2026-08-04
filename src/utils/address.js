export function shortenAddress(address, head = 8, tail = 6) {
  const text = String(address || '').trim();
  if (!text) return '-';
  if (text.length <= head + tail + 3) return text;
  return `${text.slice(0, head)}...${text.slice(-tail)}`;
}
