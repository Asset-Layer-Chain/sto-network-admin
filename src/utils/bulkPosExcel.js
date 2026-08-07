export const BULK_POS_REQUIRED_HEADERS = ['회원명', '연락처', '계약기간', '지갑주소', '지급 수량'];

const BULK_POS_HEADER_MATCHERS = {
  회원명: (header) => header === '회원명',
  연락처: (header) => header === '연락처',
  계약기간: (header) => header === '계약기간',
  지갑주소: (header) => header === '지갑주소',
  '지급 수량': (header) => header === '지급수량' || header === '지급량' || header === '수량' || header.includes('지급수량'),
};

const textDecoder = new TextDecoder('utf-8');
const EOCD_SIGNATURE = 0x06054b50;
const CENTRAL_DIRECTORY_SIGNATURE = 0x02014b50;
const LOCAL_FILE_SIGNATURE = 0x04034b50;

function toHex(buffer) {
  return Array.from(new Uint8Array(buffer)).map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function sha256File(file) {
  const buffer = await file.arrayBuffer();
  if (!globalThis.crypto?.subtle?.digest) {
    throw new Error('파일 해시를 계산할 수 없습니다. HTTPS 또는 localhost 환경에서 다시 시도해주세요.');
  }
  const digest = await globalThis.crypto.subtle.digest('SHA-256', buffer.slice(0));
  return { hash: toHex(digest), buffer };
}

function normalizeCell(value) {
  if (value === null || value === undefined) return '';
  return String(value).trim();
}

function normalizeHeader(value) {
  return normalizeCell(value)
    .replace(/[\s\u00a0]+/g, '')
    .replace(/[()（）]/g, '')
    .toLowerCase();
}

function normalizeAmountCell(value) {
  const text = normalizeCell(value).replace(/,/g, '').replace(/[\s\u00a0]+/g, '');
  const match = text.match(/^\+?(\d+)(?:\.(\d*))?$/);
  if (!match) return text;

  const integer = match[1].replace(/^0+(?=\d)/, '') || '0';
  const fraction = (match[2] || '').slice(0, 8);
  return fraction ? `${integer}.${fraction}` : integer;
}

function readUint32(view, offset) {
  return view.getUint32(offset, true);
}

function readUint16(view, offset) {
  return view.getUint16(offset, true);
}

function findEndOfCentralDirectory(view) {
  const min = Math.max(0, view.byteLength - 65557);
  for (let offset = view.byteLength - 22; offset >= min; offset -= 1) {
    if (readUint32(view, offset) === EOCD_SIGNATURE) return offset;
  }
  throw new Error('엑셀 파일 구조를 읽지 못했습니다. .xlsx 파일인지 확인해주세요.');
}

async function inflateRaw(bytes) {
  if (!globalThis.DecompressionStream) {
    throw new Error('현재 브라우저에서 .xlsx 압축 해제를 지원하지 않습니다. 최신 Chrome 또는 Edge에서 다시 시도해주세요.');
  }
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function readZipEntries(buffer) {
  const view = new DataView(buffer);
  const eocdOffset = findEndOfCentralDirectory(view);
  const entryCount = readUint16(view, eocdOffset + 10);
  let offset = readUint32(view, eocdOffset + 16);
  const entries = new Map();

  for (let index = 0; index < entryCount; index += 1) {
    if (readUint32(view, offset) !== CENTRAL_DIRECTORY_SIGNATURE) break;
    const compressionMethod = readUint16(view, offset + 10);
    const compressedSize = readUint32(view, offset + 20);
    const fileNameLength = readUint16(view, offset + 28);
    const extraLength = readUint16(view, offset + 30);
    const commentLength = readUint16(view, offset + 32);
    const localHeaderOffset = readUint32(view, offset + 42);
    const fileNameBytes = new Uint8Array(buffer, offset + 46, fileNameLength);
    const fileName = textDecoder.decode(fileNameBytes);

    const localOffset = localHeaderOffset;
    if (readUint32(view, localOffset) !== LOCAL_FILE_SIGNATURE) {
      throw new Error('엑셀 내부 파일을 읽지 못했습니다.');
    }
    const localFileNameLength = readUint16(view, localOffset + 26);
    const localExtraLength = readUint16(view, localOffset + 28);
    const dataOffset = localOffset + 30 + localFileNameLength + localExtraLength;
    const compressed = new Uint8Array(buffer, dataOffset, compressedSize);
    let data;
    if (compressionMethod === 0) data = compressed;
    else if (compressionMethod === 8) data = await inflateRaw(compressed);
    else throw new Error('지원하지 않는 엑셀 압축 형식입니다.');

    entries.set(fileName, data);
    offset += 46 + fileNameLength + extraLength + commentLength;
  }

  return entries;
}

function parseXml(bytes) {
  const xml = textDecoder.decode(bytes);
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  if (doc.querySelector('parsererror')) throw new Error('엑셀 XML을 해석하지 못했습니다.');
  return doc;
}

function getChildText(element, selector) {
  return element.querySelector(selector)?.textContent ?? '';
}

function columnIndexFromRef(ref) {
  const letters = String(ref || '').match(/^[A-Z]+/i)?.[0]?.toUpperCase() || '';
  let index = 0;
  for (const letter of letters) index = index * 26 + (letter.charCodeAt(0) - 64);
  return Math.max(0, index - 1);
}

function normalizeSheetTarget(target) {
  if (!target) return '';
  if (target.startsWith('/')) return target.slice(1);
  if (target.startsWith('xl/')) return target;
  return `xl/${target}`.replace(/\/\.\//g, '/');
}

function readSharedStrings(entries) {
  const bytes = entries.get('xl/sharedStrings.xml');
  if (!bytes) return [];
  const doc = parseXml(bytes);
  return Array.from(doc.getElementsByTagName('si')).map((si) => (
    Array.from(si.getElementsByTagName('t')).map((node) => node.textContent || '').join('')
  ));
}

function readFirstWorksheetPath(entries) {
  const workbookBytes = entries.get('xl/workbook.xml');
  const relsBytes = entries.get('xl/_rels/workbook.xml.rels');
  if (!workbookBytes || !relsBytes) throw new Error('엑셀 통합 문서 정보를 찾지 못했습니다.');

  const workbook = parseXml(workbookBytes);
  const firstSheet = workbook.getElementsByTagName('sheet')[0];
  const relId = firstSheet?.getAttribute('r:id') || firstSheet?.getAttribute('id');
  if (!relId) throw new Error('엑셀 첫 번째 시트를 찾지 못했습니다.');

  const rels = parseXml(relsBytes);
  const relationship = Array.from(rels.getElementsByTagName('Relationship')).find((item) => item.getAttribute('Id') === relId);
  const target = relationship?.getAttribute('Target');
  if (!target) throw new Error('엑셀 첫 번째 시트 경로를 찾지 못했습니다.');
  return normalizeSheetTarget(target);
}

function readCellValue(cell, sharedStrings) {
  const type = cell.getAttribute('t') || '';
  if (type === 'inlineStr') return getChildText(cell, 'is t');
  const rawValue = getChildText(cell, 'v');
  if (type === 's') return sharedStrings[Number(rawValue)] ?? '';
  if (type === 'b') return rawValue === '1' ? 'TRUE' : 'FALSE';
  return rawValue;
}

async function readFirstSheetRows(buffer) {
  const entries = await readZipEntries(buffer);
  const sheetPath = readFirstWorksheetPath(entries);
  const sheetBytes = entries.get(sheetPath);
  if (!sheetBytes) throw new Error('엑셀 첫 번째 시트 데이터를 찾지 못했습니다.');

  const sharedStrings = readSharedStrings(entries);
  const doc = parseXml(sheetBytes);
  const result = [];

  Array.from(doc.getElementsByTagName('row')).forEach((row) => {
    const rowIndex = Number(row.getAttribute('r') || result.length + 1) - 1;
    const cells = [];
    Array.from(row.getElementsByTagName('c')).forEach((cell) => {
      const colIndex = columnIndexFromRef(cell.getAttribute('r'));
      cells[colIndex] = readCellValue(cell, sharedStrings);
    });
    result[rowIndex] = cells;
  });

  return result.map((row) => row || []);
}

function findHeaderIndex(headers, requiredHeader) {
  const matcher = BULK_POS_HEADER_MATCHERS[requiredHeader] || ((header) => header === normalizeHeader(requiredHeader));
  return headers.findIndex((header) => matcher(header));
}

function findHeaderRow(rows) {
  const max = Math.min(rows.length, 10);
  for (let index = 0; index < max; index += 1) {
    const rawHeaders = rows[index].map(normalizeCell);
    const normalizedHeaders = rawHeaders.map(normalizeHeader);
    const headerIndexes = Object.fromEntries(
      BULK_POS_REQUIRED_HEADERS.map((header) => [header, findHeaderIndex(normalizedHeaders, header)])
    );
    const hasAll = BULK_POS_REQUIRED_HEADERS.every((header) => headerIndexes[header] >= 0);
    if (hasAll) return { index, headers: rawHeaders, headerIndexes };
  }
  return null;
}

export async function parseBulkPosExcel(file) {
  if (!file?.name?.toLowerCase?.().endsWith('.xlsx')) throw new Error('.xlsx 파일만 업로드할 수 있습니다.');
  const { hash, buffer } = await sha256File(file);
  const rows = await readFirstSheetRows(buffer);
  const headerRow = findHeaderRow(rows);
  if (!headerRow) {
    throw new Error(`엑셀 컬럼이 올바르지 않습니다. 필수 컬럼: ${BULK_POS_REQUIRED_HEADERS.join(', ')}`);
  }

  const { headerIndexes } = headerRow;

  const parsedRows = rows.slice(headerRow.index + 1)
    .map((row, offset) => {
      const rowNo = headerRow.index + offset + 2;
      return {
        rowNo,
        memberName: normalizeCell(row[headerIndexes['회원명']]),
        phone: normalizeCell(row[headerIndexes['연락처']]),
        contractPeriod: normalizeCell(row[headerIndexes['계약기간']]),
        walletAddress: normalizeCell(row[headerIndexes['지갑주소']]),
        amount: normalizeAmountCell(row[headerIndexes['지급 수량']]),
      };
    })
    .filter((row) => [row.memberName, row.phone, row.contractPeriod, row.walletAddress, row.amount].some(Boolean));

  if (parsedRows.length === 0) throw new Error('지급 대상 행이 없습니다.');
  if (parsedRows.length > 2000) throw new Error('한 번에 검증 가능한 행은 최대 2,000건입니다.');

  return {
    fileName: file.name,
    fileHash: hash,
    rows: parsedRows,
  };
}
