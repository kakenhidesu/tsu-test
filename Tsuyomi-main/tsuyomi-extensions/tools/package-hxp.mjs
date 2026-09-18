// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { sign } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import {
  assertArchivePath,
  assertExactKeys,
  assertObject,
  assertString,
  canonicalize,
  ed25519PublicKeyBytes,
  parseJsonWithUniqueKeys,
  readEd25519PrivateKey,
  sha256,
  zipStore,
} from './repository-format.mjs';

const FIXTURE_PUBLIC_KEY_BASE64 = 'ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=';
const MAX_PACKAGE_BYTES = 16 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 128 * 1024;
const MAX_FILE_BYTES = 8 * 1024 * 1024;
const MAX_UNCOMPRESSED_BYTES = 32 * 1024 * 1024;
const MAX_FILE_COUNT = 256;
const KEY_ID = /^[A-Za-z0-9._-]{8,128}$/;

const usage = `Usage:
  node tools/package-hxp.mjs --manifest <template.json> --private-key <pkcs8.pem|der>
    --output <extension.hxp> --file <archive-path=source-path> [--file ...]

The manifest template supplies the normal HXP fields, including \"entry\" and
\"signing\". This command derives integrity.files, contentDigest, and the detached
Ed25519 signature. It refuses the public deterministic test-fixture key and never
creates or selects a signing key.`;
const archivePathCompare = (left, right) => (left < right ? -1 : left > right ? 1 : 0);

const fail = (message) => {
  throw new Error(message);
};
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

const parseHostSemVer = (value, label) => {
  assertString(value, label, { min: 5, max: 128, pattern: SEMVER });
  const match = SEMVER.exec(value);
  const core = match.slice(1, 4).map((component) => {
    if (component.length > 10 || component.length === 10 && component > '2147483647') fail(`${label} exceeds the host SemanticVersion integer range`);
    return Number(component);
  });
  return { core, preRelease: match[4]?.split('.') ?? [] };
};

const compareHostSemVer = (left, right) => {
  for (let index = 0; index < left.core.length; index += 1) {
    if (left.core[index] !== right.core[index]) return left.core[index] < right.core[index] ? -1 : 1;
  }
  if (left.preRelease.length === 0 || right.preRelease.length === 0) return left.preRelease.length === right.preRelease.length ? 0 : left.preRelease.length === 0 ? 1 : -1;
  for (let index = 0; index < Math.max(left.preRelease.length, right.preRelease.length); index += 1) {
    const leftIdentifier = left.preRelease[index];
    const rightIdentifier = right.preRelease[index];
    if (leftIdentifier === undefined || rightIdentifier === undefined) return leftIdentifier === undefined ? -1 : 1;
    if (leftIdentifier === rightIdentifier) continue;
    const leftNumeric = /^\d+$/.test(leftIdentifier);
    const rightNumeric = /^\d+$/.test(rightIdentifier);
    if (leftNumeric && rightNumeric) {
      const normalizedLeft = leftIdentifier.replace(/^0+/, '') || '0';
      const normalizedRight = rightIdentifier.replace(/^0+/, '') || '0';
      if (normalizedLeft.length !== normalizedRight.length) return normalizedLeft.length < normalizedRight.length ? -1 : 1;
      return normalizedLeft < normalizedRight ? -1 : 1;
    }
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftIdentifier < rightIdentifier ? -1 : 1;
  }
  return 0;
};

const manifestSchema = JSON.parse(await readFile(new URL('../schemas/hxp-manifest-v1.schema.json', import.meta.url), 'utf8'));
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validateManifest = ajv.compile(manifestSchema);
const assertCanonicalOrigin = (value, label) => {
  assertString(value, label, { min: 12, max: MAX_MANIFEST_BYTES });
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`${label} must be an HTTPS origin`);
  }
  if (url.protocol !== 'https:' || url.username !== '' || url.password !== '' || url.search !== '' || url.hash !== '' || url.pathname !== '/' && url.pathname !== '') {
    fail(`${label} must be an HTTPS origin without user info, query, fragment, or path`);
  }
  const host = url.hostname;
  const labels = host.endsWith('.') ? host.slice(0, -1).split('.') : host.split('.');
  if (host === '' || labels.length === 0 || labels.some((part) => !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(part))) {
    fail(`${label} must have a Java-compatible DNS host`);
  }
  const port = url.port === '' || url.port === '443' ? '' : `:${url.port}`;
  return `https://${host.toLowerCase()}${port}`;
};
const assertPolicyOrigin = (value, label) => {
  const canonical = assertCanonicalOrigin(value, label);
  if (value !== canonical) fail(`${label} must use its canonical HTTPS origin spelling`);
  return canonical;
};


const assertOriginSet = (values, label, requireNonEmpty = false) => {
  if (!Array.isArray(values) || requireNonEmpty && values.length === 0) fail(`${label} must be a non-empty origin array`);
  const origins = values.map((value, index) => assertCanonicalOrigin(value, `${label}[${index}]`));
  if (new Set(origins).size !== origins.length) fail(`${label} contains duplicate canonical origins`);
  return new Set(origins);
};

const assertRequestPath = (value, label) => {
  if (typeof value !== 'string' || !value.startsWith('/') || value.includes('?') || value.includes('#') || value.length > 1024) {
    fail(`${label} must be a slash-prefixed UTF-16 path of at most 1024 code units without query or fragment`);
  }
  return value;
};

const assertParameterName = (value, label) => {
  if (typeof value !== 'string' || value.trim() === '' || [...value].length > 256) fail(`${label} must be a non-blank name of at most 256 code points`);
  return value;
};

const parseParameters = (value, label, kind, operation = undefined) => {
  assertObject(value, label);
  const entries = Object.entries(value).sort(([left], [right]) => archivePathCompare(left, right));
  if (kind === 'update' && (entries.length < 1 || entries.length > 16)) fail(`${label} must contain 1..16 parameters`);
  const parsed = entries.map(([name, rule]) => {
    assertParameterName(name, `${label} parameter name`);
    assertObject(rule, `${label}.${name}`);
    const parameterKind = rule.kind;
    if (parameterKind === 'fixed') {
      assertExactKeys(rule, ['kind', 'value'], `${label}.${name}`);
      if (typeof rule.value !== 'string' || [...rule.value].length > 8192) fail(`${label}.${name}.value exceeds the host string limit`);
      return { name, kind: parameterKind, value: rule.value };
    }
    assertExactKeys(rule, ['kind'], `${label}.${name}`);
    if (kind === 'redirect' || kind === 'update' && parameterKind !== 'remoteBookId') fail(`${label}.${name} has an unsupported parameter kind`);
    if (parameterKind === 'remoteBookId') {
      if (!['add', 'remove', 'move', 'update'].includes(operation ?? 'update')) fail(`${label}.${name} cannot use remoteBookId`);
    } else if (parameterKind === 'cursor') {
      if (operation !== 'read' || name !== 'cursor') fail(`${label}.${name} can only be the read cursor`);
    } else if (parameterKind === 'targetId') {
      if (operation !== 'move') fail(`${label}.${name} can only target a move`);
    } else {
      fail(`${label}.${name} has an unsupported parameter kind`);
    }
    return { name, kind: parameterKind };
  });
  const count = (parameterKind) => parsed.filter((parameter) => parameter.kind === parameterKind).length;
  if (kind === 'update' && count('remoteBookId') !== 1) fail(`${label} must contain exactly one remoteBookId`);
  if (kind === 'remote') {
    const expectedBookIds = ['add', 'remove', 'move'].includes(operation) ? 1 : 0;
    const expectedTargetIds = operation === 'move' ? 1 : 0;
    if (count('remoteBookId') !== expectedBookIds || count('targetId') !== expectedTargetIds || count('cursor') > 1) fail(`${label} has an invalid parameter mix`);
  }
  return parsed;
};

const assertRemotePolicy = (value, label, networkOrigins, operation) => {
  assertExactKeys(value, ['origin', 'method', 'path', 'parameters', ...(Object.hasOwn(value, 'referrerPath') ? ['referrerPath'] : []), ...(Object.hasOwn(value, 'redirects') ? ['redirects'] : [])], label);
  const origin = assertPolicyOrigin(value.origin, `${label}.origin`);
  if (!networkOrigins.has(origin)) fail(`${label}.origin is outside declared network origins`);
  if (typeof value.method !== 'string') fail(`${label}.method must be a string`);
  if (['read', 'targets'].includes(operation) && value.method !== 'GET' || operation === 'add' && !['GET', 'POST'].includes(value.method) || ['remove', 'move'].includes(operation) && value.method !== 'POST') fail(`${label}.method violates the capability policy`);
  const path = assertRequestPath(value.path, `${label}.path`);
  const referrerPath = Object.hasOwn(value, 'referrerPath') ? assertRequestPath(value.referrerPath, `${label}.referrerPath`) : null;
  const parameters = parseParameters(value.parameters, `${label}.parameters`, 'remote', operation);
  const redirects = Object.hasOwn(value, 'redirects') ? value.redirects.map((redirect, index) => {
    const redirectLabel = `${label}.redirects[${index}]`;
    assertExactKeys(redirect, ['origin', 'method', 'path', 'parameters', ...(Object.hasOwn(redirect, 'referrerPath') ? ['referrerPath'] : [])], redirectLabel);
    const redirectOrigin = assertPolicyOrigin(redirect.origin, `${redirectLabel}.origin`);
    if (!networkOrigins.has(redirectOrigin) || redirect.method !== 'GET') fail(`${redirectLabel} violates the capability policy`);
    return { origin: redirectOrigin, method: 'GET', path: assertRequestPath(redirect.path, `${redirectLabel}.path`), referrerPath: Object.hasOwn(redirect, 'referrerPath') ? assertRequestPath(redirect.referrerPath, `${redirectLabel}.referrerPath`) : null, parameters: parseParameters(redirect.parameters, `${redirectLabel}.parameters`, 'redirect') };
  }) : [];
  if (redirects.length > 5 || new Set(redirects.map(canonicalize)).size !== redirects.length) fail(`${label}.redirects must contain at most five distinct targets`);
  return { origin, method: value.method, path, referrerPath, parameters, redirects };
};

const assertCapabilitySemantics = (capabilities) => {
  const networkOrigins = assertOriginSet(capabilities.network.origins, 'capabilities.network.origins', true);
  const cookieOrigins = assertOriginSet(capabilities.cookies.origins, 'capabilities.cookies.origins');
  if (capabilities.cookies.mode === 'none' && cookieOrigins.size !== 0 || [...cookieOrigins].some((origin) => !networkOrigins.has(origin))) fail('cookies violate the network capability policy');
  const webLoginOrigins = assertOriginSet(capabilities.webLogin.origins, 'capabilities.webLogin.origins');
  if (!capabilities.webLogin.enabled && webLoginOrigins.size !== 0 || [...webLoginOrigins].some((origin) => !networkOrigins.has(origin))) fail('webLogin violates the network capability policy');
  if (Object.hasOwn(capabilities, 'updateCheck')) {
    const update = capabilities.updateCheck;
    assertExactKeys(update, ['version', 'origin', 'method', 'path', 'parameters', ...(Object.hasOwn(update, 'referrerPath') ? ['referrerPath'] : [])], 'capabilities.updateCheck');
    const origin = assertPolicyOrigin(update.origin, 'capabilities.updateCheck.origin');
    if (update.version !== 2 || update.method !== 'GET' || !networkOrigins.has(origin)) fail('updateCheck violates the network capability policy');
    assertRequestPath(update.path, 'capabilities.updateCheck.path');
    if (Object.hasOwn(update, 'referrerPath')) assertRequestPath(update.referrerPath, 'capabilities.updateCheck.referrerPath');
    parseParameters(update.parameters, 'capabilities.updateCheck.parameters', 'update', 'update');
  }
  const remote = capabilities.remoteLibrary;
  const writes = new Set(remote.writeOperations);
  const required = new Set([...(remote.read ? ['read', 'targets'] : []), ...[...writes]]);
  const policies = remote.policies;
  if (policies === undefined) {
    if (required.size !== 0) fail('remoteLibrary policies are required for granted operations');
  } else {
    assertObject(policies, 'capabilities.remoteLibrary.policies');
    if (Object.keys(policies).length !== required.size || Object.keys(policies).some((name) => !required.has(name))) fail('remoteLibrary policies do not exactly cover granted operations');
    for (const operation of required) assertRemotePolicy(policies[operation], `capabilities.remoteLibrary.policies.${operation}`, networkOrigins, operation);
  }
};



const parseArguments = (argumentsList) => {
  const options = { files: [] };
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === '--help') {
      process.stdout.write(`${usage}\n`);
      process.exit(0);
    }
    if (!['--manifest', '--private-key', '--output', '--file'].includes(argument)) fail(`Unknown option ${argument}`);
    const value = argumentsList[index + 1];
    if (value === undefined || value.startsWith('--')) fail(`${argument} requires a value`);
    index += 1;
    if (argument === '--file') options.files.push(value);
    else if (options[argument] !== undefined) fail(`${argument} may only be supplied once`);
    else options[argument] = value;
  }
  for (const required of ['--manifest', '--private-key', '--output']) {
    if (options[required] === undefined) fail(`${required} is required`);
  }
  if (options.files.length === 0) fail('At least one --file is required');
  return options;
};

const readRequired = async (path, label) => {
  try {
    return await readFile(resolve(path));
  } catch (error) {
    fail(`Cannot read ${label} ${path}: ${error.code ?? error.message}`);
  }
};

const parseFileMapping = async (specification) => {
  const separator = specification.indexOf('=');
  if (separator <= 0 || separator === specification.length - 1) fail(`Invalid --file mapping ${JSON.stringify(specification)}; use archive-path=source-path`);
  const archivePath = assertArchivePath(specification.slice(0, separator), '--file archive path');
  const sourcePath = specification.slice(separator + 1);
  return [archivePath, await readRequired(sourcePath, `file for ${archivePath}`)];
};

const options = parseArguments(process.argv.slice(2));
const templateBytes = await readRequired(options['--manifest'], 'manifest template');
const template = parseJsonWithUniqueKeys(templateBytes.toString('utf8'), 'HXP manifest template');
assertObject(template, 'HXP manifest template');
if (Object.hasOwn(template, 'integrity')) fail('HXP manifest template must not provide integrity; packaging derives it from --file inputs');
assertExactKeys(template.signing, ['algorithm', 'keyId', 'signatureFile'], 'HXP manifest template.signing');
if (template.format !== 'tsuyomi-hxp') fail('HXP manifest template format must be tsuyomi-hxp');
if (template.manifestVersion !== 1) fail('HXP manifest template manifestVersion must be 1');
parseHostSemVer(template.version, 'HXP manifest template.version');
const hostMin = parseHostSemVer(template.hostApi?.minInclusive, 'HXP manifest template.hostApi.minInclusive');
const hostMax = parseHostSemVer(template.hostApi?.maxExclusive, 'HXP manifest template.hostApi.maxExclusive');
if (compareHostSemVer(hostMin, hostMax) >= 0) fail('HXP manifest template.hostApi must have minInclusive < maxExclusive');
const entryPath = assertArchivePath(template.entry, 'HXP manifest template.entry');
if (!entryPath.endsWith('.mjs') || entryPath.length > 512) fail('HXP manifest template.entry must be an HXP entry path');
if (template.signing.algorithm !== 'Ed25519') fail('HXP manifest template.signing.algorithm must be Ed25519');
assertString(template.signing.keyId, 'HXP manifest template.signing.keyId', { min: 8, max: 128, pattern: KEY_ID });
if (template.signing.signatureFile !== 'signature.ed25519') fail('HXP manifest template.signing.signatureFile must be signature.ed25519');

const files = await Promise.all(options.files.map(parseFileMapping));
let suppliedContentBytes = 0;
const fileEntries = new Map();
for (const [archivePath, bytes] of files) {
  if (archivePath === 'manifest.json' || archivePath === 'signature.ed25519') fail(`${archivePath} is reserved by the HXP format`);
  if (fileEntries.has(archivePath)) fail(`Duplicate --file archive path ${archivePath}`);
  if (bytes.length > MAX_FILE_BYTES) fail(`${archivePath} exceeds ${MAX_FILE_BYTES} bytes`);
  suppliedContentBytes += bytes.length;
  fileEntries.set(archivePath, bytes);
}
if (fileEntries.size + 2 > MAX_FILE_COUNT) fail(`HXP archive exceeds ${MAX_FILE_COUNT} regular entries`);
if (!fileEntries.has(entryPath)) fail(`HXP entry ${entryPath} is not supplied by --file`);

const privateKey = readEd25519PrivateKey(await readRequired(options['--private-key'], 'private key'));
if (ed25519PublicKeyBytes(privateKey).toString('base64') === FIXTURE_PUBLIC_KEY_BASE64) {
  fail('The deterministic public test-fixture key is forbidden for production HXP packaging');
}

const integrityFiles = Object.fromEntries([...fileEntries.entries()]
  .sort(([left], [right]) => archivePathCompare(left, right))
  .map(([archivePath, bytes]) => [archivePath, sha256(bytes)]));
const contentDigest = sha256(Buffer.from(canonicalize(integrityFiles), 'utf8'));
const manifest = {
  ...template,
  integrity: {
    algorithm: 'sha256',
    contentDigest,
    files: integrityFiles,
  },
};
if (!validateManifest(manifest)) fail(`HXP manifest violates pinned hxp-manifest-v1.schema.json: ${ajv.errorsText(validateManifest.errors)}`);
assertCapabilitySemantics(manifest.capabilities);
const canonicalManifest = Buffer.from(canonicalize(manifest), 'utf8');
if (canonicalManifest.length > MAX_MANIFEST_BYTES) fail(`HXP manifest exceeds ${MAX_MANIFEST_BYTES} bytes`);
const signature = sign(null, Buffer.concat([
  Buffer.from('tsuyomi-hxp-v1\0', 'ascii'),
  canonicalManifest,
  Buffer.from([0]),
  Buffer.from(contentDigest, 'ascii'),
]), privateKey);
if (signature.length !== 64) fail('Ed25519 did not return a 64-byte signature');
const uncompressedBytes = canonicalManifest.length + signature.length + suppliedContentBytes;
if (uncompressedBytes > MAX_UNCOMPRESSED_BYTES) fail(`HXP uncompressed content exceeds ${MAX_UNCOMPRESSED_BYTES} bytes`);

const archive = zipStore([
  ['manifest.json', canonicalManifest],
  ...[...fileEntries.entries()].sort(([left], [right]) => archivePathCompare(left, right)),
  ['signature.ed25519', signature],
]);
if (archive.length > MAX_PACKAGE_BYTES) fail(`HXP archive exceeds ${MAX_PACKAGE_BYTES} bytes`);
const output = resolve(options['--output']);
await mkdir(dirname(output), { recursive: true });
try {
  await writeFile(output, archive, { flag: 'wx' });
} catch (error) {
  if (error.code === 'EEXIST') fail(`Refusing to overwrite existing output ${output}`);
  throw error;
}
process.stdout.write(`${sha256(archive)}  ${output}\n`);
