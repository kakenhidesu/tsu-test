// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

// Builds a `tsuyomi-repository` v0 index and its detached signature from a directory of `.hxp`
// packages. Node standard library only.
//
// Usage:
//   node tools/repository/build-index.mjs \
//     --packages <dir> --out <dir> --repository-id org.example.repo \
//     --name "…" --summary "…" --key-id "…" --seed-hex <64 hex> [--days 30]
//
// The seed is an Ed25519 private key seed. Test fixtures use the public, deterministic
// `Phase2TestPublisher` seed; never sign a published repository with it.

import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { basename, resolve } from 'node:path';
import { unzipSync } from 'node:zlib';

// Copied from tsuyomi-extensions/tools/build-fixture.mjs so both hosts canonicalize identically.
const canonicalize = (value) => {
  if (value === null || typeof value === 'boolean' || typeof value === 'number') return JSON.stringify(value);
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  if (typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(',')}}`;
  }
  throw new TypeError('Unsupported canonical JSON value');
};

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const options = (() => {
  const parsed = new Map();
  for (let index = 2; index < process.argv.length; index += 2) {
    const key = process.argv[index];
    if (!key.startsWith('--')) throw new Error(`Unexpected argument ${key}`);
    parsed.set(key.slice(2), process.argv[index + 1]);
  }
  return parsed;
})();

const required = (name) => {
  const value = options.get(name);
  if (!value) throw new Error(`Missing --${name}`);
  return value;
};

// The manifest lives in the archive; reading it here keeps the index and the package from drifting,
// because the host refuses an install whose manifest disagrees with the index preview.
const readManifest = (archive) => {
  const end = archive.lastIndexOf(Buffer.from('PK', 'binary'));
  if (end < 0) throw new Error('Not a zip archive');
  const count = archive.readUInt16LE(end + 10);
  let cursor = archive.readUInt32LE(end + 16);
  for (let index = 0; index < count; index += 1) {
    const nameLength = archive.readUInt16LE(cursor + 28);
    const extraLength = archive.readUInt16LE(cursor + 30);
    const commentLength = archive.readUInt16LE(cursor + 32);
    const method = archive.readUInt16LE(cursor + 10);
    const compressedSize = archive.readUInt32LE(cursor + 20);
    const localOffset = archive.readUInt32LE(cursor + 42);
    const name = archive.subarray(cursor + 46, cursor + 46 + nameLength).toString('utf8');
    if (name === 'manifest.json') {
      const localNameLength = archive.readUInt16LE(localOffset + 26);
      const localExtraLength = archive.readUInt16LE(localOffset + 28);
      const start = localOffset + 30 + localNameLength + localExtraLength;
      const stored = archive.subarray(start, start + compressedSize);
      return JSON.parse(method === 0 ? stored.toString('utf8') : unzipSync(stored, { finishFlush: 2 }).toString('utf8'));
    }
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  throw new Error('Archive has no manifest.json');
};

const packagesDirectory = resolve(required('packages'));
const outputDirectory = resolve(required('out'));
const days = Number(options.get('days') ?? '30');
const issuedAt = new Date();
const expiresAt = new Date(issuedAt.getTime() + days * 24 * 60 * 60 * 1000);
const stamp = (date) => `${date.toISOString().slice(0, 19)}Z`;

const packages = [];
for (const name of (await readdir(packagesDirectory)).sort()) {
  if (!name.endsWith('.hxp')) continue;
  const archive = await readFile(resolve(packagesDirectory, name));
  const manifest = readManifest(archive);
  packages.push({
    id: manifest.id,
    version: manifest.version,
    hostApi: { minInclusive: manifest.hostApi.minInclusive, maxExclusive: manifest.hostApi.maxExclusive },
    display: { name: manifest.display.name, summary: manifest.display.summary },
    capabilities: manifest.capabilities,
    file: `packages/${basename(name)}`,
    sha256: sha256(archive),
    sizeBytes: archive.length,
  });
}
if (packages.length === 0) throw new Error(`No .hxp packages in ${packagesDirectory}`);

const seed = Buffer.from(required('seed-hex'), 'hex');
if (seed.length !== 32) throw new Error('--seed-hex must be 32 bytes');
const privateKey = createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]),
  format: 'der',
  type: 'pkcs8',
});
const publicKeyDer = createPublicKey(privateKey).export({ format: 'der', type: 'spki' });
const publicKey = publicKeyDer.subarray(publicKeyDer.length - 32);

const index = {
  format: 'tsuyomi-repository',
  version: 0,
  repositoryId: required('repository-id'),
  display: { name: required('name'), summary: required('summary') },
  publisher: { keyId: required('key-id'), publicKey: publicKey.toString('hex') },
  issuedAt: stamp(issuedAt),
  expiresAt: stamp(expiresAt),
  packages,
  revocations: [],
};

const canonicalIndex = Buffer.from(canonicalize(index), 'utf8');
const signature = sign(
  null,
  Buffer.concat([Buffer.from('tsuyomi-repository-v0\0', 'ascii'), canonicalIndex]),
  privateKey,
);

await mkdir(outputDirectory, { recursive: true });
await writeFile(resolve(outputDirectory, 'index.json'), canonicalIndex);
await writeFile(resolve(outputDirectory, 'index.sig'), signature);
process.stdout.write(`wrote ${packages.length} package(s) to ${outputDirectory}\n`);
