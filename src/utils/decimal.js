export const STOC_DECIMAL_SCALE = 8;
export const STOC_MAX_INTEGER_DIGITS = 15;
export const STOC_MAX_AMOUNT = '999999999999999.99999999';

const DECIMAL_PATTERN = /^([+-]?)(\d+)(?:\.(\d+))?$/;
const STOC_AMOUNT_PATTERN = /^(?:0|[1-9]\d{0,14})(?:\.\d{1,8})?$/;

function splitDecimal(value) {
  const text = String(value ?? '').trim();
  const match = text.match(DECIMAL_PATTERN);
  if (!match) return null;
  return {
    negative: match[1] === '-',
    integer: match[2],
    fraction: match[3] || '',
  };
}

export function decimalToScaledBigInt(value, scale = STOC_DECIMAL_SCALE) {
  const parsed = splitDecimal(value);
  if (!parsed || parsed.fraction.length > scale) return null;

  const integer = parsed.integer.replace(/^0+(?=\d)/, '') || '0';
  const fraction = parsed.fraction.padEnd(scale, '0');
  const magnitude = BigInt(`${integer}${fraction}` || '0');
  return parsed.negative ? -magnitude : magnitude;
}

export function isValidStocAmount(value) {
  const text = String(value ?? '').trim();
  if (!STOC_AMOUNT_PATTERN.test(text)) return false;
  const scaled = decimalToScaledBigInt(text);
  const max = decimalToScaledBigInt(STOC_MAX_AMOUNT);
  return scaled !== null && max !== null && scaled > 0n && scaled <= max;
}

export function calculateStocBalance(balance, amount, sign = 1) {
  const balanceScaled = decimalToScaledBigInt(balance);
  const amountScaled = decimalToScaledBigInt(amount || '0');
  if (balanceScaled === null || amountScaled === null) return null;
  return balanceScaled + (sign < 0 ? -amountScaled : amountScaled);
}

export function formatScaledDecimal(value, scale = STOC_DECIMAL_SCALE) {
  if (typeof value !== 'bigint') return '0';
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const digits = absolute.toString().padStart(scale + 1, '0');
  const integer = digits.slice(0, -scale) || '0';
  const fraction = digits.slice(-scale).replace(/0+$/, '');
  const grouped = integer.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${negative ? '-' : ''}${grouped}${fraction ? `.${fraction}` : ''}`;
}

export function formatDecimal(value, maximumFractionDigits = STOC_DECIMAL_SCALE) {
  const parsed = splitDecimal(value);
  if (!parsed) return '0';

  const integer = (parsed.integer.replace(/^0+(?=\d)/, '') || '0')
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const fraction = parsed.fraction
    .slice(0, Math.max(0, maximumFractionDigits))
    .replace(/0+$/, '');
  const isZero = /^0(?:\.0*)?$/.test(`${parsed.integer}.${parsed.fraction}`);
  return `${parsed.negative && !isZero ? '-' : ''}${integer}${fraction ? `.${fraction}` : ''}`;
}
