// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { lstat, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertArchivePath,
  assertCodePointString,
  assertExactKeys,
  assertObject,
  assertString,
  canonicalize,
  parseJsonWithUniqueKeys,
  sha256,
} from './repository-format.mjs';

const MAX_PACKAGES = 512;
const MAX_REGULAR_FILES = 254;
const MAX_FILE_BYTES = 8 * 1024 * 1024;
const MAX_PACKAGE_BYTES = 16 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 128 * 1024;
const MAX_BUNDLE_BYTES = 64 * 1024 * 1024;
const SHA_256_HEX = /^[0-9a-f]{64}$/;
const ZERO_SHA_256 = '0'.repeat(64);
const COMMIT_SHA = /^[0-9a-f]{40}$/;
const COMPILED_SOURCE_PATH = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;

const usage = `Usage:
  node tools/prepare-release.mjs --revision <40-lowercase-hex-commit> --output <release-input.json>

Reads reviewed release/sources.json and compiled files from this checkout, then
writes a canonical unsigned tsuyomi-release-input v1 bundle. It never reads
keys, signs packages, executes extension code, or publishes anything.`;

const fail = (message) => {
  throw new Error(message);
};

const manifestSchema = parseJsonWithUniqueKeys(
  await readFile(new URL('../schemas/hxp-manifest-v1.schema.json', import.meta.url), 'utf8'),
  'HXP manifest schema',
);
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validateManifest = ajv.compile(manifestSchema);

const parseArguments = (argumentsList) => {
  const options = Object.create(null);
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === '--help') {
      process.stdout.write(`${usage}\n`);
      return null;
    }
    if (!['--revision', '--output'].includes(argument)) fail(`Unknown option ${argument}`);
    const value = argumentsList[index + 1];
    if (value === undefined || value.startsWith('--')) fail(`${argument} requires a value`);
    if (options[argument] !== undefined) fail(`${argument} may only be supplied once`);
    options[argument] = value;
    index += 1;
  }
  for (const required of ['--revision', '--output']) {
    if (options[required] === undefined) fail(`${required} is required`);
  }
  return options;
};

const assertCompiledSourcePath = (value, label) => {
  assertString(value, label, { min: 1, max: 1024, pattern: COMPILED_SOURCE_PATH });
  if (value.normalize('NFC') !== value || value.split('/').some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} must be a normalized relative compiled file path`);
  }
  return value;
};

const readRegularFile = async (root, relativePath, label, maximumBytes = MAX_FILE_BYTES) => {
  const path = assertCompiledSourcePath(relativePath, label);
  const components = path.split('/');
  let current = root;
  for (const [index, component] of components.entries()) {
    current = join(current, component);
    let status;
    try {
      status = await lstat(current);
    } catch (error) {
      fail(`Cannot read ${label} ${relativePath}: ${error.code ?? error.message}`);
    }
    if (status.isSymbolicLink()) fail(`${label} must not traverse symbolic links`);
    if (index < components.length - 1 && !status.isDirectory()) fail(`${label} has a non-directory path component`);
    if (index === components.length - 1 && !status.isFile()) fail(`${label} must name a regular file`);
    if (index === components.length - 1 && status.size > maximumBytes) fail(`${label} exceeds ${maximumBytes} bytes`);
  }
  return readFile(current);
};

const readSources = async (root) => {
  const bytes = await readRegularFile(root, 'release/sources.json', 'release sources', MAX_BUNDLE_BYTES);
  return parseJsonWithUniqueKeys(bytes.toString('utf8'), 'release/sources.json');
};

const validateManifestTemplate = (manifest, label, archivePaths) => {
  assertObject(manifest, `${label}.manifest`);
  if (Object.hasOwn(manifest, 'integrity')) fail(`${label}.manifest must not provide integrity`);
  const entry = assertArchivePath(manifest.entry, `${label}.manifest.entry`);
  if (!entry.endsWith('.mjs')) fail(`${label}.manifest.entry must be an HXP entry path`);
  if (!archivePaths.has(entry)) fail(`${label}.files must supply manifest entry ${entry}`);
  const completedManifest = {
    ...manifest,
    integrity: {
      algorithm: 'sha256',
      contentDigest: ZERO_SHA_256,
      files: Object.fromEntries([...archivePaths].map((archivePath) => [archivePath, ZERO_SHA_256])),
    },
  };
  const manifestBytes = Buffer.from(canonicalize(completedManifest), 'utf8');
  if (manifestBytes.length > MAX_MANIFEST_BYTES) fail(`${label}.manifest exceeds ${MAX_MANIFEST_BYTES} bytes after integrity is derived`);
  if (!validateManifest(completedManifest)) {
    fail(`${label}.manifest violates pinned hxp-manifest-v1.schema.json: ${ajv.errorsText(validateManifest.errors)}`);
  }
  return { manifest, manifestBytes };
};

const validateLegacyMigration = (value, label) => {
  assertExactKeys(value, ['fromPublisherFingerprint', 'fromPackageSha256'], label);
  return {
    fromPublisherFingerprint: assertString(value.fromPublisherFingerprint, `${label}.fromPublisherFingerprint`, { min: 64, max: 64, pattern: SHA_256_HEX }),
    fromPackageSha256: assertString(value.fromPackageSha256, `${label}.fromPackageSha256`, { min: 64, max: 64, pattern: SHA_256_HEX }),
  };
};

const preparePackage = async (source, index, root) => {
  const label = `release/sources.json.packages[${index}]`;
  assertObject(source, label);
  const expectedKeys = ['manifest', 'language', 'license', 'files'];
  if (Object.hasOwn(source, 'legacyMigration')) expectedKeys.push('legacyMigration');
  assertExactKeys(source, expectedKeys, label);

  assertObject(source.files, `${label}.files`);
  const mappings = Object.entries(source.files);
  if (mappings.length === 0 || mappings.length > MAX_REGULAR_FILES) {
    fail(`${label}.files must contain 1..${MAX_REGULAR_FILES} archive files`);
  }

  const archivePaths = new Set();
  for (const [archivePath] of mappings) {
    assertArchivePath(archivePath, `${label}.files archive path`);
    if (archivePath === 'manifest.json' || archivePath === 'signature.ed25519') fail(`${label}.files cannot supply reserved HXP path ${archivePath}`);
    archivePaths.add(archivePath);
  }
  const { manifest, manifestBytes } = validateManifestTemplate(source.manifest, label, archivePaths);
  const language = assertCodePointString(source.language, `${label}.language`, { min: 1, max: 64 });
  const license = assertCodePointString(source.license, `${label}.license`, { min: 1, max: 128 });

  const files = Object.create(null);
  let contentBytes = 0;
  let archiveBytes = 22 + 76 + 2 * Buffer.byteLength('manifest.json', 'utf8') + manifestBytes.length + 76 + 2 * Buffer.byteLength('signature.ed25519', 'utf8') + 64;
  for (const [archivePath, sourcePath] of mappings) {
    const bytes = await readRegularFile(root, sourcePath, `${label}.files.${archivePath}`);
    if (bytes.length > MAX_FILE_BYTES) fail(`${label}.files.${archivePath} exceeds ${MAX_FILE_BYTES} bytes`);
    contentBytes += bytes.length;
    if (contentBytes >= MAX_PACKAGE_BYTES) fail(`${label}.files cannot fit within the ${MAX_PACKAGE_BYTES}-byte HXP package limit`);
    archiveBytes += 76 + 2 * Buffer.byteLength(archivePath, 'utf8') + bytes.length;
    if (archiveBytes > MAX_PACKAGE_BYTES) fail(`${label}.files cannot fit within the ${MAX_PACKAGE_BYTES}-byte HXP package limit`);
    files[archivePath] = bytes.toString('base64');
  }

  const result = { manifest, language, license, files };
  if (Object.hasOwn(source, 'legacyMigration')) result.legacyMigration = validateLegacyMigration(source.legacyMigration, `${label}.legacyMigration`);
  return result;
};

export const prepareRelease = async ({ root, revision, output }) => {
  const projectRoot = resolve(root);
  const sourceRevision = assertString(revision, '--revision', { min: 40, max: 40, pattern: COMMIT_SHA });
  const outputPath = assertString(output, '--output', { min: 1, max: 4096 });
  const sources = await readSources(projectRoot);
  assertExactKeys(sources, ['format', 'version', 'packages'], 'release/sources.json');
  if (sources.format !== 'tsuyomi-release-sources') fail('release/sources.json.format must be tsuyomi-release-sources');
  if (sources.version !== 1) fail('release/sources.json.version must be 1');
  if (!Array.isArray(sources.packages) || sources.packages.length === 0 || sources.packages.length > MAX_PACKAGES) {
    fail(`release/sources.json.packages must contain 1..${MAX_PACKAGES} packages`);
  }

  const packages = [];
  const sourceIds = new Set();
  let packageBytes = 0;
  for (const [index, source] of sources.packages.entries()) {
    const prepared = await preparePackage(source, index, projectRoot);
    packageBytes += Buffer.byteLength(canonicalize(prepared), 'utf8');
    if (packageBytes > MAX_BUNDLE_BYTES) fail(`release input exceeds ${MAX_BUNDLE_BYTES} bytes`);
    const sourceId = assertCodePointString(prepared.manifest.id, `release/sources.json.packages[${index}].manifest.id`, {
      min: 3,
      max: 128,
      pattern: /^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$/,
    });
    if (sourceIds.has(sourceId)) fail(`release/sources.json.packages has duplicate source id ${sourceId}`);
    sourceIds.add(sourceId);
    packages.push(prepared);
  }

  const bundle = {
    format: 'tsuyomi-release-input',
    version: 1,
    sourceRevision,
    packages,
  };
  const bundleBytes = Buffer.from(canonicalize(bundle), 'utf8');
  if (bundleBytes.length > MAX_BUNDLE_BYTES) fail(`release input exceeds ${MAX_BUNDLE_BYTES} bytes`);
  const absoluteOutput = resolve(outputPath);
  await mkdir(dirname(absoluteOutput), { recursive: true });
  try {
    await writeFile(absoluteOutput, bundleBytes, { flag: 'wx' });
  } catch (error) {
    if (error.code === 'EEXIST') fail(`Refusing to overwrite existing output ${absoluteOutput}`);
    throw error;
  }
  return { bundle, bytes: bundleBytes, output: absoluteOutput };
};

const commandPath = process.argv[1] === undefined ? null : resolve(process.argv[1]);
if (commandPath === fileURLToPath(import.meta.url)) {
  const options = parseArguments(process.argv.slice(2));
  if (options !== null) {
    const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
    const prepared = await prepareRelease({
      root,
      revision: options['--revision'],
      output: options['--output'],
    });
    process.stdout.write(`${sha256(prepared.bytes)}  ${prepared.output}\n`);
  }
}
