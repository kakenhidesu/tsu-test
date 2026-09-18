// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import { execFile as execFileCallback } from 'node:child_process';
import { createPublicKey, verify } from 'node:crypto';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import {
  assertArchivePath,
  assertCodePointString,
  assertExactKeys,
  assertObject,
  assertSafePositiveInteger,
  assertString,
  canonicalize,
  decodeBase64,
  ed25519PublicKeyBytes,
  parseJsonWithUniqueKeys,
  readEd25519PrivateKey,
  sha256,
} from './repository-format.mjs';

const execFile = promisify(execFileCallback);
const toolsDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryId = 'org.tsuyomi.extensions';
const catalogBranch = 'repository';
const catalogPath = 'index-v1.json';
const catalogLifetimeMillis = 14 * 24 * 60 * 60 * 1000;
const renewalWindowMillis = 7 * 24 * 60 * 60 * 1000;
const maximumBundleBytes = 64 * 1024 * 1024;
const maximumCatalogBytes = 1024 * 1024;
const maximumSourceArchiveBytes = 64 * 1024 * 1024;
const maximumHxpBytes = 16 * 1024 * 1024;
const maximumFileBytes = 8 * 1024 * 1024;
const maximumUncompressedBytes = 32 * 1024 * 1024;
const maximumPackageCount = 512;
const maximumPublisherCount = 32;
const keyIdPattern = /^[A-Za-z0-9._-]{8,128}$/;
const sourceIdPattern = /^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$/;
const commitPattern = /^[0-9a-f]{40}$/;
const digestPattern = /^[0-9a-f]{64}$/;
const semverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const instantPattern = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/;
const ed25519SpkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');

const fail = (message) => {
  throw new Error(message);
};

const exactly = (value, keys, label) => assertExactKeys(value, keys, label);

const parseInstant = (value, label) => {
  assertString(value, label, { min: 20, max: 24, pattern: instantPattern });
  const match = instantPattern.exec(value);
  const milliseconds = Number((match[7] ?? '').padEnd(3, '0'));
  const timestamp = Date.parse(value);
  const parsed = new Date(timestamp);
  if (!Number.isFinite(timestamp) ||
      parsed.getUTCFullYear() !== Number(match[1]) ||
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

const assertKeyId = (value, label) => assertString(value, label, { min: 8, max: 128, pattern: keyIdPattern });
const assertCommit = (value, label) => assertString(value, label, { min: 40, max: 40, pattern: commitPattern });
const assertDigest = (value, label) => assertString(value, label, { min: 64, max: 64, pattern: digestPattern });

const assertSemVer = (value, label) => {
  assertString(value, label, { min: 5, max: 128, pattern: semverPattern });
  const match = semverPattern.exec(value);
  for (const component of match.slice(1, 4)) {
    if (component.length > 10 || component.length === 10 && component > '2147483647') fail(`${label} exceeds the host SemanticVersion integer range`);
  }
  if (match[4] !== undefined) {
    for (const identifier of match[4].split('.')) {
      if (/^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith('0')) fail(`${label} has a numeric prerelease identifier with a leading zero`);
    }
  }
  return value;
};

const compareNumericIdentifier = (left, right) => {
  if (left.length !== right.length) return left.length < right.length ? -1 : 1;
  return left === right ? 0 : left < right ? -1 : 1;
};

const compareSemVer = (left, right) => {
  const leftMatch = semverPattern.exec(left);
  const rightMatch = semverPattern.exec(right);
  for (let index = 1; index <= 3; index += 1) {
    const comparison = compareNumericIdentifier(leftMatch[index], rightMatch[index]);
    if (comparison !== 0) return comparison;
  }
  const leftPreRelease = leftMatch[4] ?? null;
  const rightPreRelease = rightMatch[4] ?? null;
  if (leftPreRelease === rightPreRelease) return 0;
  if (leftPreRelease === null) return 1;
  if (rightPreRelease === null) return -1;
  const leftParts = leftPreRelease.split('.');
  const rightParts = rightPreRelease.split('.');
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const leftPart = leftParts[index];
    const rightPart = rightParts[index];
    if (leftPart === undefined || rightPart === undefined) return leftPart === undefined ? -1 : 1;
    if (leftPart === rightPart) continue;
    const leftNumeric = /^\d+$/.test(leftPart);
    const rightNumeric = /^\d+$/.test(rightPart);
    if (leftNumeric && rightNumeric) return compareNumericIdentifier(leftPart, rightPart);
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftPart < rightPart ? -1 : 1;
  }
  return 0;
};

const assertCanonicalBase64 = (value, label, maximumBytes) => {
  assertString(value, label, { min: 0, max: Math.ceil(maximumBytes / 3) * 4 + 4, pattern: /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/ });
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64') !== value) fail(`${label} is not canonical base64`);
  if (bytes.length > maximumBytes) fail(`${label} exceeds ${maximumBytes} bytes`);
  return bytes;
};

const assertHttpsUrl = (value, label) => {
  assertString(value, label, { min: 12, max: 4096 });
  if (!/^https:\/\//.test(value) || /[^\u0021-\u007e]|[\\#]/.test(value) || /%(?![0-9A-Fa-f]{2})/.test(value)) fail(`${label} must be a raw ASCII HTTPS URI without whitespace, backslashes, or a fragment`);
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`${label} must be an HTTPS URL`);
  }
  if (url.protocol !== 'https:' || url.username !== '' || url.password !== '' || url.hash !== '' || url.port !== '') fail(`${label} must be an HTTPS URL without credentials, fragments, or a non-default port`);
  if (url.toString() !== value) fail(`${label} must be canonical`);
  return value;
};

const assertRepository = (value) => {
  assertString(value, 'repository', { min: 3, max: 200, pattern: /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/ });
  const [owner, name] = value.split('/');
  if (owner === '.' || owner === '..' || name === '.' || name === '..') fail('repository is invalid');
  return value;
};

const assertPublisher = (publisher, index) => {
  exactly(publisher, ['keyId', 'publicKey', 'fingerprint'], `catalog publishers[${index}]`);
  const keyId = assertKeyId(publisher.keyId, `catalog publishers[${index}].keyId`);
  const publicKey = decodeBase64(publisher.publicKey, `catalog publishers[${index}].publicKey`, 32).toString('base64');
  const fingerprint = assertDigest(publisher.fingerprint, `catalog publishers[${index}].fingerprint`);
  if (sha256(Buffer.from(publicKey, 'base64')) !== fingerprint) fail(`catalog publishers[${index}].fingerprint does not bind publicKey`);
  return { keyId, publicKey, fingerprint };
};

const assertLegacyMigration = (value, label) => {
  exactly(value, ['fromPublisherFingerprint', 'fromPackageSha256'], label);
  return {
    fromPublisherFingerprint: assertDigest(value.fromPublisherFingerprint, `${label}.fromPublisherFingerprint`),
    fromPackageSha256: assertDigest(value.fromPackageSha256, `${label}.fromPackageSha256`),
  };
};
const sameLegacyMigration = (left, right) => {
  if (left === undefined || right === undefined) return left === right;
  return left.fromPublisherFingerprint === right.fromPublisherFingerprint && left.fromPackageSha256 === right.fromPackageSha256;
};


const assertCatalogPackage = (candidate, index, publisherKeyIds) => {
  const label = `catalog packages[${index}]`;
  assertObject(candidate, label);
  const baseKeys = ['id', 'name', 'version', 'summary', 'language', 'license', 'sourceUrl', 'sourceRevision', 'downloadUrl', 'size', 'sha256', 'hostApi', 'publisherKeyId'];
  exactly(candidate, Object.hasOwn(candidate, 'legacyMigration') ? [...baseKeys, 'legacyMigration'] : baseKeys, label);
  const id = assertCodePointString(candidate.id, `${label}.id`, { min: 3, max: 128, pattern: sourceIdPattern });
  const name = assertCodePointString(candidate.name, `${label}.name`, { min: 1, max: 128 });
  const version = assertSemVer(candidate.version, `${label}.version`);
  const summary = assertCodePointString(candidate.summary, `${label}.summary`, { min: 1, max: 1024 });
  const language = assertCodePointString(candidate.language, `${label}.language`, { min: 1, max: 64 });
  const license = assertCodePointString(candidate.license, `${label}.license`, { min: 1, max: 128 });
  const sourceUrl = assertHttpsUrl(candidate.sourceUrl, `${label}.sourceUrl`);
  const sourceRevision = assertCommit(candidate.sourceRevision, `${label}.sourceRevision`);
  const downloadUrl = assertHttpsUrl(candidate.downloadUrl, `${label}.downloadUrl`);
  const size = assertSafePositiveInteger(candidate.size, `${label}.size`, { max: maximumHxpBytes });
  const packageDigest = assertDigest(candidate.sha256, `${label}.sha256`);
  exactly(candidate.hostApi, ['minInclusive', 'maxExclusive'], `${label}.hostApi`);
  const minInclusive = assertSemVer(candidate.hostApi.minInclusive, `${label}.hostApi.minInclusive`);
  const maxExclusive = assertSemVer(candidate.hostApi.maxExclusive, `${label}.hostApi.maxExclusive`);
  if (compareSemVer(minInclusive, maxExclusive) >= 0) fail(`${label}.hostApi must have minInclusive < maxExclusive`);
  const publisherKeyId = assertKeyId(candidate.publisherKeyId, `${label}.publisherKeyId`);
  if (!publisherKeyIds.has(publisherKeyId)) fail(`${label}.publisherKeyId does not name a catalog publisher`);
  const result = { id, name, version, summary, language, license, sourceUrl, sourceRevision, downloadUrl, size, sha256: packageDigest, hostApi: { minInclusive, maxExclusive }, publisherKeyId };
  if (Object.hasOwn(candidate, 'legacyMigration')) result.legacyMigration = assertLegacyMigration(candidate.legacyMigration, `${label}.legacyMigration`);
  return result;
};

/** Validates a root-authenticated catalog body before it can influence publication. */
export const validateAuthenticatedCatalog = (bytes, { rootKeyId, rootPublicKey, expectedRepositoryId = repositoryId } = {}) => {
  if (!Buffer.isBuffer(bytes)) bytes = Buffer.from(bytes);
  if (bytes.length > maximumCatalogBytes) fail(`catalog exceeds ${maximumCatalogBytes} bytes`);
  const configuredRootKeyId = assertKeyId(rootKeyId, 'rootKeyId');
  const rootPublicKeyBytes = decodeBase64(rootPublicKey, 'rootPublicKey', 32);
  const envelope = parseJsonWithUniqueKeys(bytes.toString('utf8'), 'catalog');
  exactly(envelope, ['format', 'version', 'keyId', 'signed', 'signature'], 'catalog');
  if (envelope.format !== 'tsuyomi-repository' || envelope.version !== 1) fail('catalog is not tsuyomi-repository v1');
  if (assertKeyId(envelope.keyId, 'catalog keyId') !== configuredRootKeyId) fail('catalog root keyId does not match configured root key');
  const signature = decodeBase64(envelope.signature, 'catalog signature', 64);
  const publicKey = createPublicKey({ key: Buffer.concat([ed25519SpkiPrefix, rootPublicKeyBytes]), format: 'der', type: 'spki' });
  if (!verify(null, Buffer.concat([Buffer.from('tsuyomi-repository-v1\0', 'ascii'), Buffer.from(canonicalize(envelope.signed), 'utf8')]), publicKey, signature)) {
    fail('catalog signature does not match configured root public key');
  }
  exactly(envelope.signed, ['repositoryId', 'sequence', 'issuedAt', 'expiresAt', 'publishers', 'packages', 'revocations'], 'catalog signed');
  if (assertCodePointString(envelope.signed.repositoryId, 'catalog repositoryId', { min: 3, max: 128, pattern: sourceIdPattern }) !== expectedRepositoryId) fail('catalog repositoryId does not match this publisher');
  const sequence = assertSafePositiveInteger(envelope.signed.sequence, 'catalog sequence');
  const issuedAt = assertString(envelope.signed.issuedAt, 'catalog issuedAt', { min: 20, max: 24, pattern: instantPattern });
  const expiresAt = assertString(envelope.signed.expiresAt, 'catalog expiresAt', { min: 20, max: 24, pattern: instantPattern });
  const issuedAtMillis = parseInstant(issuedAt, 'catalog issuedAt');
  const expiresAtMillis = parseInstant(expiresAt, 'catalog expiresAt');
  if (expiresAtMillis <= issuedAtMillis || expiresAtMillis - issuedAtMillis > 30 * 24 * 60 * 60 * 1000) fail('catalog lifetime is invalid');
  if (!Array.isArray(envelope.signed.publishers) || envelope.signed.publishers.length > maximumPublisherCount) fail(`catalog publishers must contain at most ${maximumPublisherCount} entries`);
  const publishers = envelope.signed.publishers.map(assertPublisher);
  if (new Set(publishers.map((publisher) => publisher.keyId)).size !== publishers.length || new Set(publishers.map((publisher) => publisher.fingerprint)).size !== publishers.length) fail('catalog publishers must have unique key IDs and fingerprints');
  const publisherKeyIds = new Set(publishers.map((publisher) => publisher.keyId));
  if (!Array.isArray(envelope.signed.packages) || envelope.signed.packages.length > maximumPackageCount) fail(`catalog packages must contain at most ${maximumPackageCount} entries`);
  const packages = envelope.signed.packages.map((candidate, index) => assertCatalogPackage(candidate, index, publisherKeyIds));
  if (new Set(packages.map((candidate) => candidate.id)).size !== packages.length) fail('catalog packages must have unique source IDs');
  exactly(envelope.signed.revocations, ['publisherFingerprints', 'packageDigests'], 'catalog revocations');
  const publisherFingerprints = assertDigestList(envelope.signed.revocations.publisherFingerprints, 'catalog revocations.publisherFingerprints', maximumPublisherCount);
  const packageDigests = assertDigestList(envelope.signed.revocations.packageDigests, 'catalog revocations.packageDigests', maximumPackageCount);
  return {
    signed: { repositoryId: expectedRepositoryId, sequence, issuedAt, expiresAt, publishers, packages, revocations: { publisherFingerprints, packageDigests } },
    expiresAtMillis,
  };
};

const assertDigestList = (value, label, maximum) => {
  if (!Array.isArray(value) || value.length > maximum) fail(`${label} must contain at most ${maximum} digests`);
  const list = value.map((digest, index) => assertDigest(digest, `${label}[${index}]`));
  if (new Set(list).size !== list.length) fail(`${label} must not contain duplicate values`);
  return list;
};

const validateBundlePackage = (candidate, index) => {
  const label = `bundle packages[${index}]`;
  assertObject(candidate, label);
  const keys = ['manifest', 'language', 'license', 'files', ...(Object.hasOwn(candidate, 'legacyMigration') ? ['legacyMigration'] : [])];
  exactly(candidate, keys, label);
  const templateKeys = ['format', 'manifestVersion', 'id', 'version', 'display', 'hostApi', 'entry', 'signing', 'capabilities', 'resourceLimits', 'update'];
  exactly(candidate.manifest, templateKeys, `${label}.manifest`);
  const manifest = candidate.manifest;
  if (manifest.format !== 'tsuyomi-hxp' || manifest.manifestVersion !== 1) fail(`${label}.manifest is not an HXP v1 template`);
  const id = assertCodePointString(manifest.id, `${label}.manifest.id`, { min: 3, max: 128, pattern: sourceIdPattern });
  const version = assertSemVer(manifest.version, `${label}.manifest.version`);
  assertArchivePath(manifest.entry, `${label}.manifest.entry`);
  if (!manifest.entry.endsWith('.mjs')) fail(`${label}.manifest.entry must be an HXP entry path`);
  exactly(manifest.signing, ['algorithm', 'keyId', 'signatureFile'], `${label}.manifest.signing`);
  if (manifest.signing.algorithm !== 'Ed25519' || manifest.signing.signatureFile !== 'signature.ed25519') fail(`${label}.manifest.signing is invalid`);
  assertKeyId(manifest.signing.keyId, `${label}.manifest.signing.keyId`);
  assertCodePointString(candidate.language, `${label}.language`, { min: 1, max: 64 });
  if (assertString(candidate.license, `${label}.license`, { min: 1, max: 128 }) !== 'AGPL-3.0-only') fail(`${label}.license must be AGPL-3.0-only`);
  assertObject(candidate.files, `${label}.files`);
  const files = [];
  let uncompressedBytes = 0;
  for (const [archivePath, encoded] of Object.entries(candidate.files)) {
    assertArchivePath(archivePath, `${label}.files key`);
    if (archivePath === 'manifest.json' || archivePath === 'signature.ed25519') fail(`${label}.files includes a reserved HXP path`);
    const bytes = assertCanonicalBase64(encoded, `${label}.files.${archivePath}`, maximumFileBytes);
    uncompressedBytes += bytes.length;
    if (uncompressedBytes > maximumUncompressedBytes) fail(`${label}.files exceeds ${maximumUncompressedBytes} bytes`);
    files.push({ archivePath, bytes });
  }
  if (files.length === 0 || files.length + 2 > 256) fail(`${label}.files must contain 1..254 HXP files`);
  if (!files.some((file) => file.archivePath === manifest.entry)) fail(`${label}.files must contain the manifest entry`);
  const result = {
    manifest: { ...manifest, signing: { ...manifest.signing } },
    language: candidate.language,
    license: candidate.license,
    files,
  };
  if (Object.hasOwn(candidate, 'legacyMigration')) result.legacyMigration = assertLegacyMigration(candidate.legacyMigration, `${label}.legacyMigration`);
  return { id, version, ...result };
};

/** Parses only the data-only, canonical release-input bundle; it never imports or executes extension code. */
export const parseReleaseBundle = (bytes) => {
  if (!Buffer.isBuffer(bytes)) bytes = Buffer.from(bytes);
  if (bytes.length > maximumBundleBytes) fail(`release bundle exceeds ${maximumBundleBytes} bytes`);
  const bundle = parseJsonWithUniqueKeys(bytes.toString('utf8'), 'release bundle');
  exactly(bundle, ['format', 'version', 'sourceRevision', 'packages'], 'release bundle');
  if (bundle.format !== 'tsuyomi-release-input' || bundle.version !== 1) fail('release bundle is not tsuyomi-release-input v1');
  const sourceRevision = assertCommit(bundle.sourceRevision, 'release bundle sourceRevision');
  if (!Array.isArray(bundle.packages) || bundle.packages.length === 0 || bundle.packages.length > maximumPackageCount) fail(`release bundle packages must contain 1..${maximumPackageCount} entries`);
  const packages = bundle.packages.map(validateBundlePackage);
  let decodedFileBytes = 0;
  for (const candidate of packages) {
    for (const file of candidate.files) {
      decodedFileBytes += file.bytes.length;
      if (decodedFileBytes > maximumBundleBytes) fail(`release bundle decoded files exceed ${maximumBundleBytes} bytes`);
    }
  }
  if (new Set(packages.map((candidate) => candidate.id)).size !== packages.length) fail('release bundle packages must have unique source IDs');
  return { sourceRevision, packages };
};

const privateEnvironment = () => {
  const environment = Object.create(null);
  for (const name of ['PATH', 'SystemRoot', 'SYSTEMROOT', 'TEMP', 'TMP']) {
    if (process.env[name] !== undefined) environment[name] = process.env[name];
  }
  return environment;
};

const defaultToolRunner = async (script, argumentsList, { cwd }) => execFile(process.execPath, [script, ...argumentsList], {
  cwd,
  env: privateEnvironment(),
  windowsHide: true,
  maxBuffer: 1024 * 1024,
});

const temporaryDirectory = async (callback) => {
  const directory = await mkdtemp(resolve(tmpdir(), 'tsuyomi-publish-'));
  try {
    return await callback(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
};

const validatePrivateAnchor = (name, pem, expectedPublicKey) => {
  if (typeof pem !== 'string' || pem.length === 0) fail(`${name} private key is required at signing time`);
  const privateKey = readEd25519PrivateKey(Buffer.from(pem, 'utf8'), `${name} private key`);
  const actualPublicKey = ed25519PublicKeyBytes(privateKey).toString('base64');
  if (actualPublicKey !== expectedPublicKey) fail(`${name} private key does not match its configured public anchor`);
};

const withPrivateKey = async (directory, name, pem, expectedPublicKey, callback) => {
  validatePrivateAnchor(name, pem, expectedPublicKey);
  const path = resolve(directory, `${name}.pkcs8.pem`);
  await writeFile(path, pem, { mode: 0o600, flag: 'wx' });
  try {
    return await callback(path);
  } finally {
    await rm(path, { force: true });
  }
};

const buildReleaseUrl = (repository, tag, assetName) => `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(assetName)}`;
const tagFor = (candidate) => `${candidate.id}-v${candidate.version}`;
const assetFor = (candidate) => `${candidate.id}-${candidate.version}.hxp`;
const sourceAssetFor = (candidate) => `${candidate.id}-${candidate.version}-source.tar.gz`;

const packageCandidate = async ({ candidate, publisherKeyId, publisherPublicKey, publisherPrivateKey, directory, runner, scripts }) => {
  const manifest = { ...candidate.manifest, signing: { ...candidate.manifest.signing, keyId: publisherKeyId } };
  const manifestPath = resolve(directory, `${candidate.id}-manifest.json`);
  const outputPath = resolve(directory, `${candidate.id}-${candidate.version}.hxp`);
  await writeFile(manifestPath, canonicalize(manifest), { mode: 0o600, flag: 'wx' });
  const argumentsList = ['--manifest', manifestPath];
  for (let index = 0; index < candidate.files.length; index += 1) {
    const file = candidate.files[index];
    const filePath = resolve(directory, `${candidate.id}-file-${index}`);
    await writeFile(filePath, file.bytes, { mode: 0o600, flag: 'wx' });
    argumentsList.push('--file', `${file.archivePath}=${filePath}`);
  }
  return withPrivateKey(directory, 'publisher', publisherPrivateKey, publisherPublicKey, async (privateKeyPath) => {
    await runner(scripts.packageHxp, [...argumentsList, '--private-key', privateKeyPath, '--output', outputPath], { cwd: directory });
    const archive = await readFile(outputPath);
    if (archive.length === 0 || archive.length > maximumHxpBytes) fail(`HXP package for ${candidate.id} is outside the HXP byte limit`);
    return archive;
  });
};

const generateCatalog = async ({ catalog, rootKeyId, rootPublicKey, rootPrivateKey, now, directory, runner, scripts }) => {
  const inputPath = resolve(directory, 'catalog-input.json');
  const outputPath = resolve(directory, 'index-v1.json');
  await writeFile(inputPath, canonicalize(catalog), { mode: 0o600, flag: 'wx' });
  return withPrivateKey(directory, 'root', rootPrivateKey, rootPublicKey, async (privateKeyPath) => {
    await runner(scripts.generateCatalog, ['--input', inputPath, '--private-key', privateKeyPath, '--key-id', rootKeyId, '--now', now, '--output', outputPath], { cwd: directory });
    const bytes = await readFile(outputPath);
    validateAuthenticatedCatalog(bytes, { rootKeyId, rootPublicKey });
    return bytes;
  });
};

const readCatalog = async (api, rootKeyId, rootPublicKey) => {
  const ref = await api.getRef(`heads/${catalogBranch}`);
  if (ref === null) return null;
  assertCommit(ref.sha, 'catalog branch ref SHA');
  const commit = await api.getCommit(ref.sha);
  if (commit?.sha !== ref.sha || typeof commit.treeSha !== 'string') fail('catalog branch commit is malformed');
  const tree = await api.getTree(commit.treeSha);
  if (!Array.isArray(tree)) fail('catalog branch tree is malformed');
  const entry = tree.find((candidate) => candidate?.path === catalogPath);
  if (entry === undefined || entry.type !== 'blob' || typeof entry.sha !== 'string') fail('catalog branch does not contain index-v1.json');
  const bytes = await api.getBlob(entry.sha);
  const catalog = validateAuthenticatedCatalog(bytes, { rootKeyId, rootPublicKey });
  return { refSha: ref.sha, treeSha: commit.treeSha, catalog };
};

const assertRelease = (release, tag, sourceRevision) => {
  if (release === null || typeof release !== 'object' || !Number.isSafeInteger(release.id) || release.id < 1) fail(`release ${tag} is malformed`);
  if (release.tagName !== tag || release.targetCommitish !== sourceRevision) fail(`release ${tag} does not target the exact source revision`);
  return release;
};

const assertTag = async (api, tag, sourceRevision) => {
  const tagRef = await api.getRef(`tags/${tag}`);
  if (tagRef === null) return false;
  if (tagRef.objectType !== 'commit' || tagRef.sha !== sourceRevision) fail(`existing tag ${tag} is not the exact immutable source commit`);
  return true;
};

const ensureRelease = async (api, { tag, sourceRevision }) => {
  const tagExists = await assertTag(api, tag, sourceRevision);
  let release = await api.getReleaseByTag(tag);
  if (release === null) {
    try {
      release = await api.createRelease({ tag, targetCommitish: sourceRevision, name: tag });
    } catch (error) {
      release = await api.getReleaseByTag(tag);
      if (release === null) throw error;
    }
  }
  assertRelease(release, tag, sourceRevision);
  if (!tagExists && !await assertTag(api, tag, sourceRevision)) fail(`release ${tag} has no immutable source tag`);
  return release;
};

const exactBytes = (actual, expected, label) => {
  if (!Buffer.isBuffer(actual)) actual = Buffer.from(actual);
  if (!actual.equals(expected)) fail(`${label} bytes do not exactly match the expected immutable asset`);
};

const ensureAsset = async (api, release, name, expectedBytes) => {
  const assets = await api.listReleaseAssets(release.id);
  if (!Array.isArray(assets)) fail(`release ${release.tagName} assets are malformed`);
  const matches = assets.filter((asset) => asset?.name === name);
  if (matches.length > 1) fail(`release ${release.tagName} has duplicate asset ${name}`);
  let asset = matches[0];
  if (asset !== undefined) {
    if (!Number.isSafeInteger(asset.size) || asset.size !== expectedBytes.length) fail(`existing asset ${name} has an unexpected size`);
    exactBytes(await api.downloadReleaseAsset(asset.id), expectedBytes, `existing asset ${name}`);
    exactBytes(await api.downloadPublicReleaseAsset(release.tagName, name), expectedBytes, `public asset ${name}`);
    return asset;
  }
  try {
    asset = await api.uploadReleaseAsset(release.id, name, expectedBytes);
  } catch (error) {
    const retryAssets = await api.listReleaseAssets(release.id);
    const retryMatches = retryAssets.filter((candidate) => candidate?.name === name);
    if (retryMatches.length !== 1) throw error;
    asset = retryMatches[0];
  }
  if (asset?.name !== name || asset.size !== expectedBytes.length) fail(`uploaded asset ${name} metadata is malformed`);
  exactBytes(await api.downloadReleaseAsset(asset.id), expectedBytes, `uploaded asset ${name}`);
  exactBytes(await api.downloadPublicReleaseAsset(release.tagName, name), expectedBytes, `public asset ${name}`);
  return asset;
};

const assertPublicationAnchors = ({ rootKeyId, rootPublicKey, publisherKeyId, publisherPublicKey }) => {
  const configuredRootKeyId = assertKeyId(rootKeyId, 'rootKeyId');
  const configuredPublisherKeyId = assertKeyId(publisherKeyId, 'publisherKeyId');
  const configuredRootPublicKey = decodeBase64(rootPublicKey, 'rootPublicKey', 32).toString('base64');
  const configuredPublisherPublicKey = decodeBase64(publisherPublicKey, 'publisherPublicKey', 32).toString('base64');
  if (configuredRootKeyId === configuredPublisherKeyId || configuredRootPublicKey === configuredPublisherPublicKey) fail('repository root and extension publisher signing anchors must be distinct');
  const fixturePublicKey = 'ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=';
  if ([configuredRootPublicKey, configuredPublisherPublicKey].includes(fixturePublicKey)) fail('public fixture keys cannot authorize production distribution');
  return { rootKeyId: configuredRootKeyId, rootPublicKey: configuredRootPublicKey, publisherKeyId: configuredPublisherKeyId, publisherPublicKey: configuredPublisherPublicKey };
};

const candidateCatalog = ({ current, now, additions }) => {
  const signed = current?.catalog.signed;
  const publishers = signed === undefined ? [] : signed.publishers.map(({ keyId, publicKey }) => ({ keyId, publicKey }));
  const packages = signed === undefined ? [] : signed.packages.map((candidate) => ({ ...candidate, hostApi: { ...candidate.hostApi }, ...(candidate.legacyMigration === undefined ? {} : { legacyMigration: { ...candidate.legacyMigration } }) }));
  const revocations = signed === undefined ? { publisherFingerprints: [], packageDigests: [] } : { publisherFingerprints: [...signed.revocations.publisherFingerprints], packageDigests: [...signed.revocations.packageDigests] };
  for (const addition of additions) {
    const index = packages.findIndex((candidate) => candidate.id === addition.id);
    if (index === -1) packages.push(addition);
    else packages[index] = addition;
  }
  return {
    repositoryId,
    sequence: signed === undefined ? 1 : signed.sequence + 1,
    issuedAt: new Date(now).toISOString(),
    expiresAt: new Date(now + catalogLifetimeMillis).toISOString(),
    publishers,
    packages,
    revocations,
  };
};

const addPublisher = (catalog, publisherKeyId, publisherPublicKey) => {
  const fingerprint = sha256(Buffer.from(publisherPublicKey, 'base64'));
  const existing = catalog.publishers.find((publisher) => publisher.keyId === publisherKeyId);
  if (existing !== undefined) {
    const existingFingerprint = existing.fingerprint ?? sha256(Buffer.from(existing.publicKey, 'base64'));
    if (existing.publicKey !== publisherPublicKey || existingFingerprint !== fingerprint) fail('configured publisher keyId conflicts with authenticated catalog identity');
  } else {
    if (catalog.publishers.some((publisher) => (publisher.fingerprint ?? sha256(Buffer.from(publisher.publicKey, 'base64'))) === fingerprint)) fail('configured publisher public key conflicts with an authenticated catalog publisher');
    if (catalog.publishers.length >= maximumPublisherCount) fail('catalog publisher limit prevents adding the configured publisher');
    catalog.publishers.push({ keyId: publisherKeyId, publicKey: publisherPublicKey });
  }
  return fingerprint;
};

const assertNoRevocation = (catalog, publisherFingerprint, packageDigest) => {
  if (catalog.revocations.publisherFingerprints.includes(publisherFingerprint)) fail('configured publisher is revoked by the authenticated catalog');
  if (catalog.revocations.packageDigests.includes(packageDigest)) fail('candidate package digest is revoked by the authenticated catalog');
};

const createCatalogCommit = async (api, current, bytes, sourceRevision) => {
  const message = `Publish signed repository catalog for ${sourceRevision}`;
  if (current === null) {
    const blobSha = await api.createBlob(bytes);
    const treeSha = await api.createTree(null, [{ path: catalogPath, mode: '100644', type: 'blob', sha: blobSha }]);
    const commitSha = await api.createCommit({ message, treeSha, parents: [] });
    await api.createRef(`heads/${catalogBranch}`, commitSha);
    return commitSha;
  }
  return api.createCatalogCommit({
    branch: catalogBranch,
    expectedHeadSha: current.refSha,
    message,
    path: catalogPath,
    contents: bytes,
  });
};

/**
 * Publishes a data-only release bundle or renews the authenticated repository catalog.
 * `api` is an intentionally injectable GitHub boundary; production CLI uses
 * createGitHubRestApi(), while local HTTP smoke tests can supply a narrow fake.
 */
export const publishRepository = async ({
  mode,
  bundleBytes = undefined,
  now,
  repository,
  expectedSourceRevision = undefined,
  rootKeyId,
  rootPublicKey,
  rootPrivateKey = undefined,
  publisherKeyId,
  publisherPublicKey,
  publisherPrivateKey = undefined,
  allowInitialPublication = false,
  api,
  toolsDirectory: suppliedToolsDirectory = toolsDirectory,
  toolRunner = defaultToolRunner,
} = {}) => {
  if (mode !== 'release' && mode !== 'renew') fail('mode must be release or renew');
  if (api === null || typeof api !== 'object') fail('api is required');
  const publicationRepository = assertRepository(repository);
  const nowMillis = parseInstant(now, 'now');
  const anchors = assertPublicationAnchors({ rootKeyId, rootPublicKey, publisherKeyId, publisherPublicKey });
  const scripts = {
    packageHxp: resolve(suppliedToolsDirectory, 'package-hxp.mjs'),
    generateCatalog: resolve(suppliedToolsDirectory, 'generate-catalog.mjs'),
  };
  const current = await readCatalog(api, anchors.rootKeyId, anchors.rootPublicKey);
  if (current !== null && current.catalog.signed.sequence === Number.MAX_SAFE_INTEGER) fail('catalog sequence is exhausted');
  if (current === null && allowInitialPublication !== true) fail('catalog branch is absent; ALLOW_INITIAL_PUBLICATION=true is required for first publication');
  if (mode === 'renew') {
    if (bundleBytes !== undefined) fail('renew mode must not accept a release bundle');
    if (current === null) fail('renew mode cannot initialize an absent catalog');
    if (current.catalog.expiresAtMillis - nowMillis > renewalWindowMillis) {
      return { status: 'noop', mode, reason: 'catalog-valid-more-than-seven-days', sequence: current.catalog.signed.sequence };
    }
    return temporaryDirectory(async (directory) => {
      const next = candidateCatalog({ current, now: nowMillis, additions: [] });
      const catalogBytes = await generateCatalog({ ...anchors, rootPrivateKey, catalog: next, now, directory, runner: toolRunner, scripts });
      const commitSha = await createCatalogCommit(api, current, catalogBytes, 'renewal');
      return { status: 'published', mode, sequence: next.sequence, catalogCommit: commitSha, packages: [] };
    });
  }

  if (bundleBytes === undefined) fail('release mode requires a release bundle');
  validatePrivateAnchor('root', rootPrivateKey, anchors.rootPublicKey);
  validatePrivateAnchor('publisher', publisherPrivateKey, anchors.publisherPublicKey);
  const bundle = parseReleaseBundle(bundleBytes);
  const existingPackageIds = new Set(current?.catalog.signed.packages.map((candidate) => candidate.id) ?? []);
  if (existingPackageIds.size + bundle.packages.filter((candidate) => !existingPackageIds.has(candidate.id)).length > maximumPackageCount) fail('catalog package limit prevents adding this release bundle');
  const expectedRevision = assertCommit(expectedSourceRevision, 'expectedSourceRevision');
  if (bundle.sourceRevision !== expectedRevision) fail('release bundle sourceRevision does not match EXPECTED_SOURCE_REVISION');
  const mainRef = await api.getRef('heads/main');
  if (mainRef === null || mainRef.sha !== expectedRevision) fail('EXPECTED_SOURCE_REVISION is not the current main commit at signing start');
  const sourceArchive = await api.getSourceArchive(expectedRevision);
  if (!Buffer.isBuffer(sourceArchive) || sourceArchive.length === 0 || sourceArchive.length > maximumSourceArchiveBytes) fail('exact source archive is unavailable or outside its size limit');

  return temporaryDirectory(async (directory) => {
    const publisherFingerprint = sha256(Buffer.from(anchors.publisherPublicKey, 'base64'));
    const baseCatalog = current === null
      ? { repositoryId, sequence: 0, issuedAt: new Date(nowMillis).toISOString(), expiresAt: new Date(nowMillis).toISOString(), publishers: [], packages: [], revocations: { publisherFingerprints: [], packageDigests: [] } }
      : candidateCatalog({ current, now: nowMillis, additions: [] });
    addPublisher(baseCatalog, anchors.publisherKeyId, anchors.publisherPublicKey);
    assertNoRevocation(baseCatalog, publisherFingerprint);
    const additions = [];
    const releaseAssets = [];
    for (const candidate of bundle.packages) {
      const archive = await packageCandidate({ ...anchors, candidate, publisherPrivateKey, directory, runner: toolRunner, scripts });
      const packageDigest = sha256(archive);
      assertNoRevocation(baseCatalog, publisherFingerprint, packageDigest);
      const existing = current?.catalog.signed.packages.find((item) => item.id === candidate.id);
      if (existing !== undefined) {
        if (existing.publisherKeyId !== anchors.publisherKeyId) fail(`package ${candidate.id} has no authenticated publisher-key rotation path`);
        const versionComparison = compareSemVer(candidate.version, existing.version);
        if (versionComparison < 0) fail(`package ${candidate.id} version must be strictly higher than authenticated catalog version`);
        if (versionComparison === 0) {
          if (packageDigest !== existing.sha256) fail(`package ${candidate.id} replaces immutable same-version bytes`);
          if (candidate.language !== existing.language || candidate.license !== existing.license || !sameLegacyMigration(candidate.legacyMigration, existing.legacyMigration)) {
            fail(`package ${candidate.id} changes immutable same-version metadata`);
          }
          const stableRelease = await ensureRelease(api, { tag: tagFor(candidate), sourceRevision: existing.sourceRevision });
          await ensureAsset(api, stableRelease, assetFor(candidate), archive);
          const stableSourceArchive = existing.sourceRevision === expectedRevision ? sourceArchive : await api.getSourceArchive(existing.sourceRevision);
          if (!Buffer.isBuffer(stableSourceArchive) || stableSourceArchive.length === 0 || stableSourceArchive.length > maximumSourceArchiveBytes) fail(`exact source archive for ${candidate.id} is unavailable or outside its size limit`);
          await ensureAsset(api, stableRelease, sourceAssetFor(candidate), stableSourceArchive);
          continue;
        }
      }
      const tag = tagFor(candidate);
      const assetName = assetFor(candidate);
      const release = await ensureRelease(api, { tag, sourceRevision: expectedRevision });
      await ensureAsset(api, release, assetName, archive);
      await ensureAsset(api, release, sourceAssetFor(candidate), sourceArchive);
      additions.push({
        id: candidate.id,
        name: candidate.manifest.display.name,
        version: candidate.version,
        summary: candidate.manifest.display.summary,
        language: candidate.language,
        license: candidate.license,
        sourceUrl: `https://github.com/${publicationRepository}/tree/${expectedRevision}`,
        sourceRevision: expectedRevision,
        downloadUrl: buildReleaseUrl(publicationRepository, tag, assetName),
        size: archive.length,
        sha256: packageDigest,
        hostApi: { ...candidate.manifest.hostApi },
        publisherKeyId: anchors.publisherKeyId,
        ...(candidate.legacyMigration === undefined ? {} : { legacyMigration: candidate.legacyMigration }),
      });
      releaseAssets.push({ id: candidate.id, version: candidate.version, tag, asset: assetName, sha256: packageDigest });
    }
    if (additions.length === 0) {
      return { status: 'noop', mode, reason: 'all-package-bytes-already-published', sequence: current?.catalog.signed.sequence ?? 0, packages: [] };
    }
    const next = candidateCatalog({ current, now: nowMillis, additions });
    addPublisher(next, anchors.publisherKeyId, anchors.publisherPublicKey);
    assertNoRevocation(next, publisherFingerprint, additions[0].sha256);
    for (const addition of additions.slice(1)) assertNoRevocation(next, publisherFingerprint, addition.sha256);
    const catalogBytes = await generateCatalog({ ...anchors, rootPrivateKey, catalog: next, now, directory, runner: toolRunner, scripts });
    const commitSha = await createCatalogCommit(api, current, catalogBytes, expectedRevision);
    return { status: 'published', mode, sequence: next.sequence, catalogCommit: commitSha, packages: releaseAssets };
  });
};

export class GitHubApiError extends Error {
  constructor(method, path, status, message) {
    super(`GitHub ${method} ${path} failed with ${status}: ${message}`);
    this.name = 'GitHubApiError';
    this.status = status;
  }
}

const pathSegment = (value) => encodeURIComponent(value);
const refPath = (ref) => ref.split('/').map(pathSegment).join('/');

const readTransportBody = async (response, maximumBytes) => {
  const declaredLength = response.headers.get('content-length');
  if (declaredLength !== null && (!/^\d+$/.test(declaredLength) || Number(declaredLength) > maximumBytes)) {
    await response.body?.cancel();
    fail('GitHub response exceeds its transport byte limit');
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body ?? []) {
    size += chunk.length;
    if (size > maximumBytes) fail('GitHub response exceeds its transport byte limit');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
};

/**
 * Creates the production GitHub transport. The CLI fixes both bases to GitHub;
 * exported callers may inject localhost bases for an authenticated-free HTTP smoke.
 */
export const createGitHubRestApi = ({ token, repository, fetchImpl = globalThis.fetch, apiBase = 'https://api.github.com/', uploadBase = 'https://uploads.github.com/' } = {}) => {
  if (typeof fetchImpl !== 'function') fail('fetch implementation is required');
  const checkedRepository = assertRepository(repository);
  assertString(token, 'GitHub token', { min: 1, max: 4096 });
  const restBase = new URL(apiBase);
  const uploadsBase = new URL(uploadBase);
  const request = async (method, path, { body = undefined, headers = undefined, upload = false, binary = false } = {}) => {
    const base = upload ? uploadsBase : restBase;
    const url = new URL(path.replace(/^\//, ''), base);
    const response = await fetchImpl(url, {
      method,
      headers: {
        Accept: binary ? 'application/octet-stream' : 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        ...headers,
      },
      body,
      redirect: 'follow',
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new GitHubApiError(method, url.pathname, response.status, 'request rejected');
    }
    if (response.status === 204) return null;
    const bytes = await readTransportBody(response, binary ? maximumSourceArchiveBytes : 8 * 1024 * 1024);
    return binary ? bytes : parseJsonWithUniqueKeys(bytes.toString('utf8'), 'GitHub response');
  };
  const rest = (path) => `repos/${checkedRepository}/${path}`;
  return {
    async getRef(ref) {
      try {
        const response = await request('GET', rest(`git/ref/${refPath(ref)}`));
        if (typeof response?.object?.sha !== 'string') fail(`GitHub ref ${ref} response is malformed`);
        return { sha: response.object.sha, objectType: response.object.type };
      } catch (error) {
        if (error instanceof GitHubApiError && error.status === 404) return null;
        throw error;
      }
    },
    async getCommit(sha) {
      const response = await request('GET', rest(`git/commits/${pathSegment(sha)}`));
      return { sha: response?.sha, treeSha: response?.tree?.sha };
    },
    async getTree(sha) {
      const response = await request('GET', rest(`git/trees/${pathSegment(sha)}`));
      return response?.tree;
    },
    async getBlob(sha) {
      const response = await request('GET', rest(`git/blobs/${pathSegment(sha)}`));
      if (response?.encoding !== 'base64' || typeof response.content !== 'string') fail('GitHub blob response is malformed');
      return Buffer.from(response.content.replace(/\n/g, ''), 'base64');
    },
    async createBlob(bytes) {
      const response = await request('POST', rest('git/blobs'), { body: JSON.stringify({ content: Buffer.from(bytes).toString('base64'), encoding: 'base64' }), headers: { 'Content-Type': 'application/json' } });
      if (typeof response?.sha !== 'string') fail('GitHub create blob response is malformed');
      return response.sha;
    },
    async createTree(baseTree, entries) {
      const response = await request('POST', rest('git/trees'), { body: JSON.stringify({ ...(baseTree === null ? {} : { base_tree: baseTree }), tree: entries }), headers: { 'Content-Type': 'application/json' } });
      if (typeof response?.sha !== 'string') fail('GitHub create tree response is malformed');
      return response.sha;
    },
    async createCommit({ message, treeSha, parents }) {
      const response = await request('POST', rest('git/commits'), { body: JSON.stringify({ message, tree: treeSha, parents }), headers: { 'Content-Type': 'application/json' } });
      if (typeof response?.sha !== 'string') fail('GitHub create commit response is malformed');
      return response.sha;
    },
    async createRef(ref, sha) {
      await request('POST', rest('git/refs'), { body: JSON.stringify({ ref: `refs/${ref}`, sha }), headers: { 'Content-Type': 'application/json' } });
    },
    async createCatalogCommit({ branch, expectedHeadSha, message, path, contents }) {
      const query = 'mutation CreateCatalogCommit($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }';
      const response = await request('POST', 'graphql', {
        body: JSON.stringify({ query, variables: { input: {
          branch: { repositoryNameWithOwner: checkedRepository, branchName: branch },
          expectedHeadOid: expectedHeadSha,
          message: { headline: message },
          fileChanges: { additions: [{ path, contents: Buffer.from(contents).toString('base64') }] },
        } } }),
        headers: { 'Content-Type': 'application/json' },
      });
      if (Array.isArray(response?.errors) && response.errors.length > 0) fail(`GitHub catalog compare-and-swap failed: ${response.errors.map((error) => error.message).join('; ')}`);
      const commitSha = response?.data?.createCommitOnBranch?.commit?.oid;
      if (typeof commitSha !== 'string') fail('GitHub catalog compare-and-swap response is malformed');
      return commitSha;
    },
    async getReleaseByTag(tag) {
      try {
        const response = await request('GET', rest(`releases/tags/${pathSegment(tag)}`));
        return { id: response?.id, tagName: response?.tag_name, targetCommitish: response?.target_commitish };
      } catch (error) {
        if (error instanceof GitHubApiError && error.status === 404) return null;
        throw error;
      }
    },
    async createRelease({ tag, targetCommitish, name }) {
      const response = await request('POST', rest('releases'), { body: JSON.stringify({ tag_name: tag, target_commitish: targetCommitish, name }), headers: { 'Content-Type': 'application/json' } });
      return { id: response?.id, tagName: response?.tag_name, targetCommitish: response?.target_commitish };
    },
    async listReleaseAssets(releaseId) {
      const response = await request('GET', rest(`releases/${pathSegment(String(releaseId))}/assets?per_page=100`));
      if (!Array.isArray(response)) fail('GitHub release asset list response is malformed');
      return response.map((asset) => ({ id: asset?.id, name: asset?.name, size: asset?.size }));
    },
    async downloadReleaseAsset(assetId) {
      return request('GET', rest(`releases/assets/${pathSegment(String(assetId))}`), { binary: true, headers: { Accept: 'application/octet-stream' } });
    },
    async downloadPublicReleaseAsset(tag, name) {
      const url = buildReleaseUrl(checkedRepository, tag, name);
      const response = await fetchImpl(new URL(url), {
        headers: { Accept: 'application/octet-stream' },
        redirect: 'follow',
        signal: AbortSignal.timeout(60_000),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new GitHubApiError('GET', new URL(url).pathname, response.status, 'public asset unavailable');
      }
      return readTransportBody(response, maximumSourceArchiveBytes);
    },
    async uploadReleaseAsset(releaseId, name, bytes) {
      const path = rest(`releases/${pathSegment(String(releaseId))}/assets?name=${encodeURIComponent(name)}`);
      const response = await request('POST', path, { upload: true, body: bytes, headers: { 'Content-Type': 'application/octet-stream' } });
      return { id: response?.id, name: response?.name, size: response?.size };
    },
    async getSourceArchive(sourceRevision) {
      return request('GET', rest(`tarball/${pathSegment(sourceRevision)}`), { binary: true, headers: { Accept: 'application/vnd.github+json' } });
    },
  };
};
/** Production-safe local-smoke seam: inject fetch routing, never an API URL into the CLI. */
export const createGitHubApi = ({ repository, token, fetchImpl = globalThis.fetch } = {}) => createGitHubRestApi({ repository, token, fetchImpl });


const usage = `Usage:\n  node tools/publish-repository.mjs --mode release --bundle <release-input.json> --now <UTC-instant>\n  node tools/publish-repository.mjs --mode renew --now <UTC-instant>`;

const parseArguments = (argumentsList) => {
  const options = Object.create(null);
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === '--help') {
      process.stdout.write(`${usage}\n`);
      process.exit(0);
    }
    if (!['--mode', '--bundle', '--now'].includes(argument)) fail(`unknown option ${argument}`);
    const value = argumentsList[index + 1];
    if (value === undefined || value.startsWith('--') || Object.hasOwn(options, argument)) fail(`${argument} requires exactly one value`);
    options[argument] = value;
    index += 1;
  }
  if (options['--mode'] === undefined || options['--now'] === undefined) fail('--mode and --now are required');
  if (options['--mode'] === 'release' && options['--bundle'] === undefined) fail('--bundle is required for release mode');
  if (options['--mode'] === 'renew' && options['--bundle'] !== undefined) fail('--bundle is not accepted for renew mode');
  return options;
};

const requiredEnvironment = (name) => {
  const value = process.env[name];
  if (value === undefined || value === '') fail(`${name} is required`);
  return value;
};

const readReleaseBundle = async (path) => {
  const resolved = resolve(path);
  const metadata = await stat(resolved);
  if (!metadata.isFile() || metadata.size > maximumBundleBytes) fail(`release bundle exceeds ${maximumBundleBytes} bytes`);
  return readFile(resolved);
};

const runCli = async () => {
  const options = parseArguments(process.argv.slice(2));
  const mode = options['--mode'];
  const bundleBytes = mode === 'release' ? await readReleaseBundle(options['--bundle']) : undefined;
  const repository = requiredEnvironment('GITHUB_REPOSITORY');
  const result = await publishRepository({
    mode,
    bundleBytes,
    now: options['--now'],
    repository,
    expectedSourceRevision: mode === 'release' ? requiredEnvironment('EXPECTED_SOURCE_REVISION') : undefined,
    rootKeyId: requiredEnvironment('REPOSITORY_ROOT_KEY_ID'),
    rootPublicKey: requiredEnvironment('REPOSITORY_ROOT_PUBLIC_KEY'),
    rootPrivateKey: requiredEnvironment('REPOSITORY_ROOT_PRIVATE_KEY'),
    publisherKeyId: requiredEnvironment('EXTENSION_PUBLISHER_KEY_ID'),
    publisherPublicKey: requiredEnvironment('EXTENSION_PUBLISHER_PUBLIC_KEY'),
    publisherPrivateKey: mode === 'release' ? requiredEnvironment('EXTENSION_PUBLISHER_PRIVATE_KEY') : undefined,
    allowInitialPublication: process.env.ALLOW_INITIAL_PUBLICATION === 'true',
    api: createGitHubRestApi({ token: requiredEnvironment('GH_TOKEN'), repository }),
  });
  process.stdout.write(`${canonicalize(result)}\n`);
};

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
