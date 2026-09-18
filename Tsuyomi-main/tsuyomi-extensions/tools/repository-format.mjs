// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { createHash, createPrivateKey, createPublicKey } from 'node:crypto';

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const MAX_ZIP_U32 = 0xffffffff;

const fail = (message, offset = undefined) => {
  const location = offset === undefined ? '' : ` at byte ${offset}`;
  throw new TypeError(`${message}${location}`);
};

const assertUnicodeScalarString = (value, label) => {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) fail(`${label} contains an unpaired high surrogate`);
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) fail(`${label} contains an unpaired high surrogate`);
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      fail(`${label} contains an unpaired low surrogate`);
    }
  }
};

const isJsonObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/** RFC 8785 JSON Canonicalization Scheme for I-JSON values. */
export const canonicalize = (value) => {
  const ancestors = new Set();

  const write = (current) => {
    if (current === null || typeof current === 'boolean') return JSON.stringify(current);
    if (typeof current === 'string') {
      assertUnicodeScalarString(current, 'JSON string');
      return JSON.stringify(current);
    }
    if (typeof current === 'number') {
      if (!Number.isFinite(current)) fail('JSON number must be finite');
      return JSON.stringify(current);
    }
    if (Array.isArray(current)) {
      if (ancestors.has(current)) fail('JSON value contains a cycle');
      ancestors.add(current);
      const output = `[${current.map(write).join(',')}]`;
      ancestors.delete(current);
      return output;
    }
    if (isJsonObject(current)) {
      if (ancestors.has(current)) fail('JSON value contains a cycle');
      ancestors.add(current);
      const keys = Object.keys(current).sort();
      const output = `{${keys.map((key) => {
        assertUnicodeScalarString(key, 'JSON object key');
        return `${JSON.stringify(key)}:${write(current[key])}`;
      }).join(',')}}`;
      ancestors.delete(current);
      return output;
    }
    fail(`Unsupported canonical JSON value ${typeof current}`);
  };

  return write(value);
};

/** Parses JSON without accepting duplicate object keys or invalid Unicode scalar strings. */
export const parseJsonWithUniqueKeys = (input, label = 'JSON') => {
  if (typeof input !== 'string') fail(`${label} must be text`);
  let offset = 0;

  const whitespace = () => {
    while (offset < input.length && /[\u0009\u000a\u000d\u0020]/.test(input[offset])) offset += 1;
  };
  const expect = (token) => {
    if (!input.startsWith(token, offset)) fail(`${label} expected ${JSON.stringify(token)}`, offset);
    offset += token.length;
  };
  const string = () => {
    const start = offset;
    expect('"');
    while (offset < input.length) {
      const character = input[offset];
      if (character === '"') {
        offset += 1;
        let parsed;
        try {
          parsed = JSON.parse(input.slice(start, offset));
        } catch {
          fail(`${label} has an invalid string`, start);
        }
        assertUnicodeScalarString(parsed, `${label} string`);
        return parsed;
      }
      if (character === '\\') {
        offset += 1;
        if (offset >= input.length) fail(`${label} has an incomplete escape`, start);
        const escape = input[offset];
        if (escape === 'u') {
          const hex = input.slice(offset + 1, offset + 5);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) fail(`${label} has an invalid Unicode escape`, offset);
          offset += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape)) fail(`${label} has an invalid escape`, offset);
        offset += 1;
        continue;
      }
      if (character.charCodeAt(0) < 0x20) fail(`${label} has an unescaped control character`, offset);
      offset += 1;
    }
    fail(`${label} has an unterminated string`, start);
  };
  const number = () => {
    const match = input.slice(offset).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (match === null) fail(`${label} has an invalid number`, offset);
    offset += match[0].length;
    const parsed = Number(match[0]);
    if (!Number.isFinite(parsed)) fail(`${label} number is outside the finite JSON range`, offset);
    return parsed;
  };
  const value = () => {
    whitespace();
    const character = input[offset];
    if (character === '"') return string();
    if (character === '{') {
      offset += 1;
      whitespace();
      const result = Object.create(null);
      if (input[offset] === '}') {
        offset += 1;
        return result;
      }
      while (true) {
        whitespace();
        if (input[offset] !== '"') fail(`${label} object key must be a string`, offset);
        const key = string();
        if (Object.hasOwn(result, key)) fail(`${label} has duplicate key ${JSON.stringify(key)}`, offset);
        whitespace();
        expect(':');
        result[key] = value();
        whitespace();
        if (input[offset] === '}') {
          offset += 1;
          return result;
        }
        expect(',');
      }
    }
    if (character === '[') {
      offset += 1;
      whitespace();
      const result = [];
      if (input[offset] === ']') {
        offset += 1;
        return result;
      }
      while (true) {
        result.push(value());
        whitespace();
        if (input[offset] === ']') {
          offset += 1;
          return result;
        }
        expect(',');
      }
    }
    if (character === 't') {
      expect('true');
      return true;
    }
    if (character === 'f') {
      expect('false');
      return false;
    }
    if (character === 'n') {
      expect('null');
      return null;
    }
    return number();
  };

  const parsed = value();
  whitespace();
  if (offset !== input.length) fail(`${label} has trailing content`, offset);
  return parsed;
};

export const assertObject = (value, label) => {
  if (!isJsonObject(value)) fail(`${label} must be an object`);
  return value;
};

export const assertExactKeys = (value, keys, label) => {
  assertObject(value, label);
  const expected = new Set(keys);
  const actual = Object.keys(value);
  const unknown = actual.find((key) => !expected.has(key));
  if (unknown !== undefined) fail(`${label} has unknown field ${JSON.stringify(unknown)}`);
  const missing = keys.find((key) => !Object.hasOwn(value, key));
  if (missing !== undefined) fail(`${label} is missing field ${JSON.stringify(missing)}`);
  return value;
};

export const assertString = (value, label, { min = 1, max = 1024, pattern = undefined } = {}) => {
  if (typeof value !== 'string') fail(`${label} must be a string`);
  assertUnicodeScalarString(value, label);
  const byteLength = Buffer.byteLength(value, 'utf8');
  if (byteLength < min || byteLength > max) fail(`${label} must be ${min}..${max} UTF-8 bytes`);
  if (pattern !== undefined && !pattern.test(value)) fail(`${label} is invalid`);
  return value;
};
export const assertCodePointString = (value, label, { min = 1, max = 1024, pattern = undefined } = {}) => {
  if (typeof value !== 'string') fail(`${label} must be a string`);
  assertUnicodeScalarString(value, label);
  const count = [...value].length;
  if (count < min || count > max) fail(`${label} must be ${min}..${max} Unicode code points`);
  if (pattern !== undefined && !pattern.test(value)) fail(`${label} is invalid`);
  return value;
};


export const assertSafePositiveInteger = (value, label, { max = Number.MAX_SAFE_INTEGER } = {}) => {
  if (!Number.isSafeInteger(value) || value < 1 || value > max) fail(`${label} must be a positive safe JSON integer`);
  return value;
};

export const sha256 = (value) => createHash('sha256').update(value).digest('hex');

export const decodeBase64 = (value, label, expectedLength) => {
  assertString(value, label, { min: 4, max: 256, pattern: /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/ });
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64') !== value) fail(`${label} is not canonical base64`);
  if (expectedLength !== undefined && bytes.length !== expectedLength) fail(`${label} must decode to ${expectedLength} bytes`);
  return bytes;
};

export const readEd25519PrivateKey = (bytes, label = 'private key') => {
  let key;
  try {
    key = bytes.subarray(0, 5).toString('ascii') === '-----'
      ? createPrivateKey({ key: bytes, format: 'pem', type: 'pkcs8' })
      : createPrivateKey({ key: bytes, format: 'der', type: 'pkcs8' });
  } catch {
    fail(`${label} must be a readable PKCS#8 PEM or DER key`);
  }
  if (key.asymmetricKeyType !== 'ed25519') fail(`${label} must be an Ed25519 key`);
  return key;
};

export const ed25519PublicKeyBytes = (privateKey) => {
  const encoded = createPublicKey(privateKey).export({ format: 'der', type: 'spki' });
  if (encoded.length !== ED25519_SPKI_PREFIX.length + 32 || !encoded.subarray(0, ED25519_SPKI_PREFIX.length).equals(ED25519_SPKI_PREFIX)) {
    fail('Ed25519 public key has an unexpected encoding');
  }
  return encoded.subarray(ED25519_SPKI_PREFIX.length);
};

export const assertArchivePath = (value, label = 'archive path') => {
  if (typeof value !== 'string') fail(`${label} must be a string`);
  assertUnicodeScalarString(value, label);
  if (value.length > 1024 || value.trim() === '' || value.normalize('NFC') !== value || value.includes('\\') || value.startsWith('/') || value.split('/').some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must be a normalized relative slash path`);
  }
  return value;
};

const crcTable = Array.from({ length: 256 }, (_, value) => {
  let crc = value;
  for (let bit = 0; bit < 8; bit += 1) crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
  return crc >>> 0;
});

const crc32 = (bytes) => {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
};

/** Writes a reproducible ZIP archive with stored entries and fixed metadata. */
export const zipStore = (entries) => {
  const names = new Set();
  const localParts = [];
  const centralParts = [];
  let offset = 0;

  for (const [name, content] of entries) {
    assertArchivePath(name);
    if (names.has(name)) fail(`ZIP has duplicate entry ${JSON.stringify(name)}`);
    names.add(name);
    if (!Buffer.isBuffer(content)) fail(`ZIP entry ${JSON.stringify(name)} must be bytes`);
    if (content.length > MAX_ZIP_U32) fail(`ZIP entry ${JSON.stringify(name)} is too large`);
    const nameBytes = Buffer.from(name, 'utf8');
    if (nameBytes.length > 0xffff) fail(`ZIP entry ${JSON.stringify(name)} name is too long`);
    const crc = crc32(content);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0x21, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(content.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, nameBytes, content);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(content.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(0x81a40000, 38);
    central.writeUInt32LE(offset, 42);
    centralParts.push(central, nameBytes);
    offset += local.length + nameBytes.length + content.length;
    if (offset > MAX_ZIP_U32) fail('ZIP archive is too large');
  }

  if (entries.length > 0xffff) fail('ZIP has too many entries');
  const centralBytes = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...localParts, centralBytes, end]);
};
