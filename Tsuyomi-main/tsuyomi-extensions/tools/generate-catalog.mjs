// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { sign } from 'node:crypto';
import { isIP } from 'node:net';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import {
  assertExactKeys,
  assertObject,
  assertCodePointString,
  assertSafePositiveInteger,
  assertString,
  canonicalize,
  decodeBase64,
  ed25519PublicKeyBytes,
  parseJsonWithUniqueKeys,
  readEd25519PrivateKey,
  sha256,
} from './repository-format.mjs';

const FIXTURE_PUBLIC_KEY_BASE64 = 'ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=';
const MAX_CATALOG_BYTES = 1024 * 1024;
const MAX_PACKAGES = 512;
const MAX_PUBLISHERS = 32;
const KEY_ID = /^[A-Za-z0-9._-]{8,128}$/;
const SOURCE_ID = /^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$/;
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const SHA_256_HEX = /^[0-9a-f]{64}$/;
const COMMIT_SHA = /^[0-9a-f]{40}$/;
const UTC_INSTANT = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/;

const usage = `Usage:
  node tools/generate-catalog.mjs --input <catalog-input.json> --private-key <pkcs8.pem|der>
    --key-id <root-key-id> --now <UTC-instant> --output <index-v1.json>

The input is the unsigned signed-body configuration. The command validates the
repository wire limits, derives every publisher fingerprint from its base64 raw
Ed25519 key, and signs ASCII(\"tsuyomi-repository-v1\\0\") + UTF8(JCS(signed)).
--now is explicit so validation and output are reproducible. This command never
creates, persists, or publishes a signing key and refuses the public deterministic
test-fixture key.`;

const fail = (message) => {
  throw new Error(message);
};

const parseArguments = (argumentsList) => {
  const options = Object.create(null);
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === '--help') {
      process.stdout.write(`${usage}\n`);
      process.exit(0);
    }
    if (!['--input', '--private-key', '--key-id', '--now', '--output'].includes(argument)) fail(`Unknown option ${argument}`);
    const value = argumentsList[index + 1];
    if (value === undefined || value.startsWith('--')) fail(`${argument} requires a value`);
    if (options[argument] !== undefined) fail(`${argument} may only be supplied once`);
    options[argument] = value;
    index += 1;
  }
  for (const required of ['--input', '--private-key', '--key-id', '--now', '--output']) {
    if (options[required] === undefined) fail(`${required} is required`);
  }
  return options;
};

const parseInstant = (value, label) => {
  assertString(value, label, { min: 20, max: 24, pattern: UTC_INSTANT });
  const match = UTC_INSTANT.exec(value);
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) fail(`${label} must be a valid UTC instant`);
  const parsed = new Date(timestamp);
  const milliseconds = Number((match[7] ?? '').padEnd(3, '0'));
  if (parsed.getUTCFullYear() !== Number(match[1]) ||
      parsed.getUTCMonth() + 1 !== Number(match[2]) ||
      parsed.getUTCDate() !== Number(match[3]) ||
      parsed.getUTCHours() !== Number(match[4]) ||
      parsed.getUTCMinutes() !== Number(match[5]) ||
      parsed.getUTCSeconds() !== Number(match[6]) ||
      parsed.getUTCMilliseconds() !== milliseconds) {
    fail(`${label} must be a valid UTC calendar instant`);
  }
  return timestamp;
};
const assertJavaCompatibleHost = (hostname, label) => {
  const literal = hostname.startsWith('[') && hostname.endsWith(']') ? hostname.slice(1, -1) : hostname;
  if (isIP(literal) === 6) return;
  const labels = hostname.endsWith('.') ? hostname.slice(0, -1).split('.') : hostname.split('.');
  if (labels.length === 0 || labels.some((part) => !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(part))) {
    fail(`${label} must have a Java-compatible DNS or IPv6 host`);
  }
};


const assertHttpsUrl = (value, label) => {
  const raw = assertString(value, label, { min: 12, max: 4096 });
  if (!/^https:\/\//i.test(raw) || /[^\u0021-\u007e]|[\\#]/.test(raw) || /%(?![0-9A-Fa-f]{2})/.test(raw)) {
    fail(`${label} must be a raw ASCII HTTPS URI without whitespace, backslashes, or a fragment`);
  }
  const afterScheme = raw.slice(raw.indexOf('//') + 2);
  const suffixOffset = afterScheme.search(/[/?]/);
  const authority = suffixOffset === -1 ? afterScheme : afterScheme.slice(0, suffixOffset);
  const suffix = suffixOffset === -1 ? '' : afterScheme.slice(suffixOffset);
  if (authority.includes('@')) fail(`${label} must not include user info`);
  if (!/^(?:\/[A-Za-z0-9\-._~!$&'()*+,;=:@%]*)*(?:\?[A-Za-z0-9\-._~!$&'()*+,;=:@%/?]*)?$/.test(suffix)) {
    fail(`${label} must have Java-compatible raw path and query syntax`);
  }
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail(`${label} must be an HTTPS URL`);
  }
  if (url.protocol !== 'https:' || url.username !== '' || url.password !== '' || url.hostname === '' || url.port !== '' && Number(url.port) > 65535) {
    fail(`${label} must be an HTTPS URL without credentials`);
  }
  assertJavaCompatibleHost(url.hostname, label);
  const canonical = url.toString();
  if (canonical.length < 12 || canonical.length > 4096) fail(`${label} is outside the repository URI length bound`);
  return canonical;
};

const assertSemVer = (value, label) => {
  assertString(value, label, { min: 5, max: 128, pattern: SEMVER });
  const match = SEMVER.exec(value);
  for (const component of match.slice(1, 4)) {
    if (component.length > 10 || component.length === 10 && component > '2147483647') {
      fail(`${label} exceeds the host SemanticVersion integer range`);
    }
  }
  const preRelease = match[4];
  if (preRelease !== undefined) {
    for (const identifier of preRelease.split('.')) {
      if (/^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith('0')) {
        fail(`${label} has a numeric prerelease identifier with a leading zero`);
      }
    }
  }
  return value;
};

const semverComponents = (value) => {
  const match = SEMVER.exec(value);
  return [match[1], match[2], match[3], match[4] ?? null];
};

const compareNumericIdentifier = (left, right) => {
  if (left.length !== right.length) return left.length < right.length ? -1 : 1;
  if (left === right) return 0;
  return left < right ? -1 : 1;
};

const comparePreRelease = (left, right) => {
  if (left === right) return 0;
  if (left === null) return 1;
  if (right === null) return -1;
  const leftIdentifiers = left.split('.');
  const rightIdentifiers = right.split('.');
  const sharedLength = Math.min(leftIdentifiers.length, rightIdentifiers.length);
  for (let index = 0; index < sharedLength; index += 1) {
    const leftIdentifier = leftIdentifiers[index];
    const rightIdentifier = rightIdentifiers[index];
    if (leftIdentifier === rightIdentifier) continue;
    const leftNumeric = /^\d+$/.test(leftIdentifier);
    const rightNumeric = /^\d+$/.test(rightIdentifier);
    if (leftNumeric && rightNumeric) return compareNumericIdentifier(leftIdentifier, rightIdentifier);
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftIdentifier < rightIdentifier ? -1 : 1;
  }
  return leftIdentifiers.length < rightIdentifiers.length ? -1 : 1;
};

const compareSemVer = (left, right) => {
  const leftParts = semverComponents(left);
  const rightParts = semverComponents(right);
  for (let index = 0; index < 3; index += 1) {
    const comparison = compareNumericIdentifier(leftParts[index], rightParts[index]);
    if (comparison !== 0) return comparison;
  }
  return comparePreRelease(leftParts[3], rightParts[3]);
};

const assertDigestArray = (value, label, maximum) => {
  if (!Array.isArray(value) || value.length > maximum) fail(`${label} must contain at most ${maximum} digests`);
  const values = value.map((item, index) => assertString(item, `${label}[${index}]`, { min: 64, max: 64, pattern: SHA_256_HEX }));
  if (new Set(values).size !== values.length) fail(`${label} must not contain duplicate values`);
  return values;
};

const validatePublisher = (publisher, index) => {
  assertExactKeys(publisher, ['keyId', 'publicKey'], `publishers[${index}]`);
  const keyId = assertString(publisher.keyId, `publishers[${index}].keyId`, { min: 8, max: 128, pattern: KEY_ID });
  const publicKey = assertString(publisher.publicKey, `publishers[${index}].publicKey`, { min: 44, max: 44 });
  const publicKeyBytes = decodeBase64(publicKey, `publishers[${index}].publicKey`, 32);
  return { keyId, publicKey, fingerprint: sha256(publicKeyBytes) };
};

const validateLegacyMigration = (value, label) => {
  assertExactKeys(value, ['fromPublisherFingerprint', 'fromPackageSha256'], label);
  return {
    fromPublisherFingerprint: assertString(value.fromPublisherFingerprint, `${label}.fromPublisherFingerprint`, { min: 64, max: 64, pattern: SHA_256_HEX }),
    fromPackageSha256: assertString(value.fromPackageSha256, `${label}.fromPackageSha256`, { min: 64, max: 64, pattern: SHA_256_HEX }),
  };
};

const validatePackage = (candidate, index, publisherKeyIds) => {
  const label = `packages[${index}]`;
  assertObject(candidate, label);
  const baseKeys = ['id', 'name', 'version', 'summary', 'language', 'license', 'sourceUrl', 'sourceRevision', 'downloadUrl', 'size', 'sha256', 'hostApi', 'publisherKeyId'];
  const keys = Object.hasOwn(candidate, 'legacyMigration') ? [...baseKeys, 'legacyMigration'] : baseKeys;
  assertExactKeys(candidate, keys, label);
  const id = assertCodePointString(candidate.id, `${label}.id`, { min: 3, max: 128, pattern: SOURCE_ID });
  const name = assertCodePointString(candidate.name, `${label}.name`, { min: 1, max: 128 });
  const version = assertSemVer(candidate.version, `${label}.version`);
  const summary = assertCodePointString(candidate.summary, `${label}.summary`, { min: 1, max: 1024 });
  const language = assertCodePointString(candidate.language, `${label}.language`, { min: 1, max: 64 });
  const license = assertCodePointString(candidate.license, `${label}.license`, { min: 1, max: 128 });
  const sourceUrl = assertHttpsUrl(candidate.sourceUrl, `${label}.sourceUrl`);
  const sourceRevision = assertString(candidate.sourceRevision, `${label}.sourceRevision`, { min: 40, max: 40, pattern: COMMIT_SHA });
  const downloadUrl = assertHttpsUrl(candidate.downloadUrl, `${label}.downloadUrl`);
  const size = assertSafePositiveInteger(candidate.size, `${label}.size`, { max: 16 * 1024 * 1024 });
  const digest = assertString(candidate.sha256, `${label}.sha256`, { min: 64, max: 64, pattern: SHA_256_HEX });
  assertExactKeys(candidate.hostApi, ['minInclusive', 'maxExclusive'], `${label}.hostApi`);
  const minInclusive = assertSemVer(candidate.hostApi.minInclusive, `${label}.hostApi.minInclusive`);
  const maxExclusive = assertSemVer(candidate.hostApi.maxExclusive, `${label}.hostApi.maxExclusive`);
  if (compareSemVer(minInclusive, maxExclusive) >= 0) fail(`${label}.hostApi must have minInclusive < maxExclusive`);
  const publisherKeyId = assertString(candidate.publisherKeyId, `${label}.publisherKeyId`, { min: 8, max: 128, pattern: KEY_ID });
  if (!publisherKeyIds.has(publisherKeyId)) fail(`${label}.publisherKeyId does not name a catalog publisher`);
  const result = {
    id,
    name,
    version,
    summary,
    language,
    license,
    sourceUrl,
    sourceRevision,
    downloadUrl,
    size,
    sha256: digest,
    hostApi: { minInclusive, maxExclusive },
    publisherKeyId,
  };
  if (Object.hasOwn(candidate, 'legacyMigration')) result.legacyMigration = validateLegacyMigration(candidate.legacyMigration, `${label}.legacyMigration`);
  return result;
};

const options = parseArguments(process.argv.slice(2));
const rootKeyId = assertString(options['--key-id'], '--key-id', { min: 8, max: 128, pattern: KEY_ID });
const now = parseInstant(options['--now'], '--now');
const inputBytes = await readFile(resolve(options['--input']));
const input = parseJsonWithUniqueKeys(inputBytes.toString('utf8'), 'catalog input');
assertExactKeys(input, ['repositoryId', 'sequence', 'issuedAt', 'expiresAt', 'publishers', 'packages', 'revocations'], 'catalog input');

const repositoryId = assertCodePointString(input.repositoryId, 'repositoryId', { min: 3, max: 128, pattern: SOURCE_ID });
const sequence = assertSafePositiveInteger(input.sequence, 'sequence');
const issuedAt = assertString(input.issuedAt, 'issuedAt', { min: 20, max: 24, pattern: UTC_INSTANT });
const expiresAt = assertString(input.expiresAt, 'expiresAt', { min: 20, max: 24, pattern: UTC_INSTANT });
const issuedAtMillis = parseInstant(issuedAt, 'issuedAt');
const expiresAtMillis = parseInstant(expiresAt, 'expiresAt');
if (issuedAtMillis > now + 5 * 60 * 1000) fail('issuedAt is more than five minutes after --now');
if (expiresAtMillis <= now) fail('expiresAt must be after --now');
if (expiresAtMillis <= issuedAtMillis || expiresAtMillis - issuedAtMillis > 30 * 24 * 60 * 60 * 1000) fail('catalog lifetime must be positive and no more than 30 days');

if (!Array.isArray(input.publishers) || input.publishers.length > MAX_PUBLISHERS) fail(`publishers must contain at most ${MAX_PUBLISHERS} entries`);
const publishers = input.publishers.map(validatePublisher);
const publisherKeyIds = new Set(publishers.map((publisher) => publisher.keyId));
const fingerprints = new Set(publishers.map((publisher) => publisher.fingerprint));
if (publisherKeyIds.size !== publishers.length) fail('publishers must have unique keyId values');
if (fingerprints.size !== publishers.length) fail('publishers must have unique fingerprints');

if (!Array.isArray(input.packages) || input.packages.length > MAX_PACKAGES) fail(`packages must contain at most ${MAX_PACKAGES} entries`);
const packages = input.packages.map((candidate, index) => validatePackage(candidate, index, publisherKeyIds));
if (new Set(packages.map((candidate) => candidate.id)).size !== packages.length) fail('packages must have unique source IDs');

assertExactKeys(input.revocations, ['publisherFingerprints', 'packageDigests'], 'revocations');
const revocations = {
  publisherFingerprints: assertDigestArray(input.revocations.publisherFingerprints, 'revocations.publisherFingerprints', MAX_PUBLISHERS),
  packageDigests: assertDigestArray(input.revocations.packageDigests, 'revocations.packageDigests', MAX_PACKAGES),
};

const privateKey = readEd25519PrivateKey(await readFile(resolve(options['--private-key'])));
if (ed25519PublicKeyBytes(privateKey).toString('base64') === FIXTURE_PUBLIC_KEY_BASE64) {
  fail('The deterministic public test-fixture key is forbidden for production catalog generation');
}
const signed = { repositoryId, sequence, issuedAt, expiresAt, publishers, packages, revocations };
const signature = sign(null, Buffer.concat([
  Buffer.from('tsuyomi-repository-v1\0', 'ascii'),
  Buffer.from(canonicalize(signed), 'utf8'),
]), privateKey);
if (signature.length !== 64) fail('Ed25519 did not return a 64-byte signature');
const envelope = {
  format: 'tsuyomi-repository',
  version: 1,
  keyId: rootKeyId,
  signed,
  signature: signature.toString('base64'),
};
const outputBytes = Buffer.from(canonicalize(envelope), 'utf8');
if (outputBytes.length > MAX_CATALOG_BYTES) fail(`catalog exceeds ${MAX_CATALOG_BYTES} bytes`);
const output = resolve(options['--output']);
await mkdir(dirname(output), { recursive: true });
try {
  await writeFile(output, outputBytes, { flag: 'wx' });
} catch (error) {
  if (error.code === 'EEXIST') fail(`Refusing to overwrite existing output ${output}`);
  throw error;
}
process.stdout.write(`${sha256(outputBytes)}  ${output}\n`);
