// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import { createPrivateKey, generateKeyPairSync } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';
import { ed25519PublicKeyBytes, sha256 } from '../tools/repository-format.mjs';
import { createGitHubApi, parseReleaseBundle, publishRepository, validateAuthenticatedCatalog } from '../tools/publish-repository.mjs';

const sourceRevision = '1'.repeat(40);
const initialNow = '2026-09-11T00:00:00.000Z';
const defaultRepository = 'Chachaanteng/tsuyomi-extensions';
const toolDirectory = fileURLToPath(new URL('../tools/', import.meta.url));

const privateKey = () => generateKeyPairSync('ed25519').privateKey.export({ type: 'pkcs8', format: 'pem' });
const publicKey = (pem) => ed25519PublicKeyBytes(createPrivateKey(pem)).toString('base64');
const objectSha = (prefix, value) => sha256(Buffer.concat([Buffer.from(prefix, 'utf8'), Buffer.from(value)])).slice(0, 40);
const execFile = promisify(execFileCallback);
const readStoredZip = (archive) => {
  const entries = new Map();
  let offset = 0;
  while (archive.readUInt32LE(offset) === 0x04034b50) {
    const size = archive.readUInt32LE(offset + 22);
    const nameLength = archive.readUInt16LE(offset + 26);
    const extraLength = archive.readUInt16LE(offset + 28);
    const nameOffset = offset + 30;
    const contentOffset = nameOffset + nameLength + extraLength;
    entries.set(archive.subarray(nameOffset, nameOffset + nameLength).toString('utf8'), archive.subarray(contentOffset, contentOffset + size));
    offset = contentOffset + size;
  }
  return entries;
};



const manifest = (version = '1.0.0') => ({
  format: 'tsuyomi-hxp',
  manifestVersion: 1,
  id: 'org.tsuyomi.publisherfixture',
  version,
  display: { name: 'Publisher fixture', summary: 'Release publisher behavioral fixture', homepage: 'https://example.test/' },
  hostApi: { minInclusive: '1.2.0', maxExclusive: '2.0.0' },
  entry: 'index.mjs',
  signing: { algorithm: 'Ed25519', keyId: 'untrusted-input-key', signatureFile: 'signature.ed25519' },
  capabilities: {
    network: { origins: ['https://example.test'], maxConcurrentRequests: 1, requestTimeoutMs: 1000, maxResponseBytes: 1024 },
    cookies: { mode: 'none', origins: [] },
    webLogin: { enabled: false, origins: [] },
    home: { enabled: false },
    remoteLibrary: { read: false, writeOperations: [] },
    storage: { quotaBytes: 0 },
  },
  resourceLimits: { maxExecutionWallTimeMs: 100, maxMemoryBytes: 1048576 },
  update: { channel: 'stable' },
});

const bundle = ({ version = '1.0.0', contents = 'export const source = "publisher fixture";\n', legacyMigration = undefined, source = sourceRevision } = {}) => Buffer.from(JSON.stringify({
  format: 'tsuyomi-release-input',
  version: 1,
  sourceRevision: source,
  packages: [{
    manifest: manifest(version),
    language: 'zh-CN',
    license: 'AGPL-3.0-only',
    files: { 'index.mjs': Buffer.from(contents, 'utf8').toString('base64') },
    ...(legacyMigration === undefined ? {} : { legacyMigration }),
  }],
}), 'utf8');

class LocalGitHub {
  constructor(mainSha = sourceRevision) {
    this.refs = new Map([['heads/main', { sha: mainSha, objectType: 'commit' }]]);
    this.blobs = new Map();
    this.trees = new Map();
    this.commits = new Map();
    this.releases = new Map();
    this.assets = new Map();
    this.sourceArchives = new Map([[sourceRevision, Buffer.from('source archive at immutable commit\n', 'utf8')]]);
    this.nextAssetId = 1;
    this.catalogCommitCalls = 0;
    this.releaseCreations = 0;
    this.persistThenFailAsset = undefined;
    this.raceCatalogCommit = false;
  }

  async getRef(ref) {
    return this.refs.get(ref) ?? null;
  }

  async getCommit(sha) {
    return this.commits.get(sha) ?? null;
  }

  async getTree(sha) {
    return this.trees.get(sha) ?? null;
  }

  async getBlob(sha) {
    const bytes = this.blobs.get(sha);
    if (bytes === undefined) throw new Error(`missing blob ${sha}`);
    return Buffer.from(bytes);
  }

  async createBlob(bytes) {
    const sha = objectSha('blob\0', bytes);
    this.blobs.set(sha, Buffer.from(bytes));
    return sha;
  }

  async createTree(baseTree, entries) {
    const inherited = baseTree === null ? [] : this.trees.get(baseTree) ?? [];
    const byPath = new Map(inherited.map((entry) => [entry.path, { ...entry }]));
    for (const entry of entries) byPath.set(entry.path, { ...entry });
    const tree = [...byPath.values()].sort((left, right) => left.path.localeCompare(right.path));
    const sha = objectSha('tree\0', JSON.stringify(tree));
    this.trees.set(sha, tree);
    return sha;
  }

  async createCommit({ message, treeSha, parents }) {
    const sha = objectSha('commit\0', JSON.stringify({ message, treeSha, parents }));
    this.commits.set(sha, { sha, treeSha, parents: [...parents] });
    return sha;
  }

  async createRef(ref, sha) {
    if (this.refs.has(ref)) throw new Error(`reference ${ref} already exists`);
    this.refs.set(ref, { sha, objectType: 'commit' });
  }

  async createCatalogCommit({ branch, expectedHeadSha, message, path, contents }) {
    this.catalogCommitCalls += 1;
    const ref = `heads/${branch}`;
    if (this.raceCatalogCommit) {
      this.raceCatalogCommit = false;
      const foreignTree = await this.createTree(null, []);
      const foreignCommit = await this.createCommit({ message: 'foreign update', treeSha: foreignTree, parents: [this.refs.get(ref).sha] });
      this.refs.set(ref, { sha: foreignCommit, objectType: 'commit' });
    }
    const current = this.refs.get(ref);
    if (current?.sha !== expectedHeadSha) throw new Error('expectedHeadOid compare-and-swap rejected stale catalog head');
    const blobSha = await this.createBlob(contents);
    const treeSha = await this.createTree(this.commits.get(current.sha).treeSha, [{ path, mode: '100644', type: 'blob', sha: blobSha }]);
    const commitSha = await this.createCommit({ message, treeSha, parents: [current.sha] });
    this.refs.set(ref, { sha: commitSha, objectType: 'commit' });
    return commitSha;
  }

  async getReleaseByTag(tag) {
    const release = this.releases.get(tag);
    return release === undefined ? null : { id: release.id, tagName: release.tagName, targetCommitish: release.targetCommitish };
  }

  async createRelease({ tag, targetCommitish, name }) {
    if (this.releases.has(tag)) throw new Error('release already exists');
    const tagRef = this.refs.get(`tags/${tag}`);
    if (tagRef !== undefined && (tagRef.sha !== targetCommitish || tagRef.objectType !== 'commit')) throw new Error('tag points elsewhere');
    this.refs.set(`tags/${tag}`, { sha: targetCommitish, objectType: 'commit' });
    const release = { id: this.releases.size + 1, tagName: tag, targetCommitish, name, assetIds: [] };
    this.releases.set(tag, release);
    this.releaseCreations += 1;
    return { id: release.id, tagName: release.tagName, targetCommitish: release.targetCommitish };
  }

  async listReleaseAssets(releaseId) {
    const release = [...this.releases.values()].find((candidate) => candidate.id === releaseId);
    if (release === undefined) throw new Error('release is missing');
    return release.assetIds.map((assetId) => {
      const asset = this.assets.get(assetId);
      return { id: asset.id, name: asset.name, size: asset.bytes.length };
    });
  }

  async downloadReleaseAsset(assetId) {
    const asset = this.assets.get(assetId);
    if (asset === undefined) throw new Error('asset is missing');
    return Buffer.from(asset.bytes);
  }

  async downloadPublicReleaseAsset(tag, name) {
    const release = this.releases.get(tag);
    const asset = release?.assetIds.map((id) => this.assets.get(id)).find((entry) => entry.name === name);
    if (!asset) throw new Error('public asset unavailable');
    return Buffer.from(asset.bytes);
  }

  async uploadReleaseAsset(releaseId, name, bytes) {
    const release = [...this.releases.values()].find((candidate) => candidate.id === releaseId);
    if (release === undefined) throw new Error('release is missing');
    const existing = release.assetIds.map((assetId) => this.assets.get(assetId)).find((asset) => asset.name === name);
    if (existing !== undefined) throw new Error('asset already exists');
    const asset = { id: this.nextAssetId, name, bytes: Buffer.from(bytes) };
    this.nextAssetId += 1;
    this.assets.set(asset.id, asset);
    release.assetIds.push(asset.id);
    if (this.persistThenFailAsset === name) {
      this.persistThenFailAsset = undefined;
      throw new Error('simulated upload response loss after GitHub persisted the asset');
    }
    return { id: asset.id, name: asset.name, size: asset.bytes.length };
  }

  async getSourceArchive(revision) {
    const bytes = this.sourceArchives.get(revision);
    if (bytes === undefined) throw new Error(`source archive ${revision} is missing`);
    return Buffer.from(bytes);
  }

  async catalogBytes() {
    const ref = this.refs.get('heads/repository');
    if (ref === undefined) return null;
    const tree = this.trees.get(this.commits.get(ref.sha).treeSha);
    return this.getBlob(tree.find((entry) => entry.path === 'index-v1.json').sha);
  }
}

const credentials = () => {
  const rootPrivateKey = privateKey();
  const publisherPrivateKey = privateKey();
  return {
    rootKeyId: 'repository-root-test',
    rootPublicKey: publicKey(rootPrivateKey),
    rootPrivateKey,
    publisherKeyId: 'extension-publisher-test',
    publisherPublicKey: publicKey(publisherPrivateKey),
    publisherPrivateKey,
  };
};

const options = (api, keys, overrides = {}) => ({
  mode: 'release',
  bundleBytes: bundle(),
  now: initialNow,
  repository: defaultRepository,
  expectedSourceRevision: sourceRevision,
  allowInitialPublication: true,
  api,
  toolsDirectory: toolDirectory,
  ...keys,
  ...overrides,
});

const catalogInput = (keys, { expiresAt = '2026-09-20T00:00:00.000Z', publishers = [], packages = [], revocations = { publisherFingerprints: [], packageDigests: [] } } = {}) => ({
  repositoryId: 'org.tsuyomi.extensions',
  sequence: 1,
  issuedAt: initialNow,
  expiresAt,
  publishers,
  packages,
  revocations,
});

const installSignedCatalog = async (api, keys, input) => {
  const directory = await mkdtemp(join(tmpdir(), 'tsuyomi-release-catalog-'));
  try {
    const inputPath = join(directory, 'input.json');
    const keyPath = join(directory, 'root.pem');
    const outputPath = join(directory, 'index-v1.json');
    await Promise.all([writeFile(inputPath, JSON.stringify(input)), writeFile(keyPath, keys.rootPrivateKey)]);
    await execFile(process.execPath, [fileURLToPath(new URL('../tools/generate-catalog.mjs', import.meta.url)), '--input', inputPath, '--private-key', keyPath, '--key-id', keys.rootKeyId, '--now', initialNow, '--output', outputPath]);
    const bytes = await readFile(outputPath);
    const blobSha = await api.createBlob(bytes);
    const treeSha = await api.createTree(null, [{ path: 'index-v1.json', mode: '100644', type: 'blob', sha: blobSha }]);
    const commitSha = await api.createCommit({ message: 'authenticated catalog', treeSha, parents: [] });
    await api.createRef('heads/repository', commitSha);
    return bytes;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
};

test('release uses real signer CLIs, verifies persisted retry assets, and renews only in its seven-day window', async () => {
  const api = new LocalGitHub();
  const keys = credentials();
  api.persistThenFailAsset = 'org.tsuyomi.publisherfixture-1.0.0.hxp';
  const released = await publishRepository(options(api, keys));
  assert.equal(released.status, 'published');
  assert.equal(released.sequence, 1);
  assert.equal(api.releaseCreations, 1);
  const catalog = validateAuthenticatedCatalog(await api.catalogBytes(), keys);
  assert.equal(catalog.signed.packages[0].publisherKeyId, keys.publisherKeyId);
  assert.equal(catalog.signed.packages[0].sourceRevision, sourceRevision);
  const tag = 'org.tsuyomi.publisherfixture-v1.0.0';
  assert.equal(api.refs.get(`tags/${tag}`).sha, sourceRevision);
  assert.equal((await api.listReleaseAssets(1)).length, 2, 'HXP and exact-commit source archive are both attached');
  const hxpAsset = (await api.listReleaseAssets(1)).find((asset) => asset.name.endsWith('.hxp'));
  const packagedManifest = JSON.parse(readStoredZip(await api.downloadReleaseAsset(hxpAsset.id)).get('manifest.json').toString('utf8'));
  assert.equal(packagedManifest.signing.keyId, keys.publisherKeyId, 'the protected publisher keyId replaces untrusted bundle metadata');

  const unnecessaryRenewal = await publishRepository(options(api, keys, {
    mode: 'renew',
    bundleBytes: undefined,
    now: '2026-09-12T00:00:00.000Z',
    expectedSourceRevision: undefined,
    publisherPrivateKey: undefined,
    allowInitialPublication: false,
  }));
  assert.deepEqual(unnecessaryRenewal, { status: 'noop', mode: 'renew', reason: 'catalog-valid-more-than-seven-days', sequence: 1 });

  const renewal = await publishRepository(options(api, keys, {
    mode: 'renew',
    bundleBytes: undefined,
    now: '2026-09-19T00:00:00.000Z',
    expectedSourceRevision: undefined,
    publisherPrivateKey: undefined,
    allowInitialPublication: false,
  }));
  assert.equal(renewal.status, 'published');
  assert.equal(renewal.sequence, 2);
  assert.equal(validateAuthenticatedCatalog(await api.catalogBytes(), keys).signed.sequence, 2);
});

test('publisher fails closed for missing bootstrap approval, malformed inputs, wrong roots, and tampered catalogs', async () => {
  const api = new LocalGitHub();
  const keys = credentials();
  await assert.rejects(publishRepository(options(api, keys, { allowInitialPublication: false })), /ALLOW_INITIAL_PUBLICATION/);
  assert.equal(api.releaseCreations, 0);
  assert.throws(() => parseReleaseBundle(Buffer.from('{"format":"tsuyomi-release-input","version":1,"sourceRevision":"bad","packages":[]}', 'utf8')), /sourceRevision/);

  const signedApi = new LocalGitHub();
  await installSignedCatalog(signedApi, keys, catalogInput(keys));
  const otherRoot = credentials();
  await assert.rejects(publishRepository(options(signedApi, { ...keys, rootPublicKey: otherRoot.rootPublicKey }, { allowInitialPublication: false })), /signature|root/i);
  assert.equal(signedApi.releaseCreations, 0);

  const tamperedApi = new LocalGitHub();
  const signedBytes = await installSignedCatalog(tamperedApi, keys, catalogInput(keys));
  const tamperedEnvelope = JSON.parse(signedBytes.toString('utf8'));
  tamperedEnvelope.signed.sequence = 2;
  const ref = tamperedApi.refs.get('heads/repository');
  const tree = tamperedApi.trees.get(tamperedApi.commits.get(ref.sha).treeSha);
  tamperedApi.blobs.set(tree[0].sha, Buffer.from(JSON.stringify(tamperedEnvelope), 'utf8'));
  await assert.rejects(publishRepository(options(tamperedApi, keys, { allowInitialPublication: false })), /signature|catalog/i);
  assert.equal(tamperedApi.releaseCreations, 0);
});

test('revocations, immutable same-version replacement, metadata drift, and implicit publisher rotation are rejected', async () => {
  const keys = credentials();
  const revokedApi = new LocalGitHub();
  await installSignedCatalog(revokedApi, keys, catalogInput(keys, {
    publishers: [{ keyId: keys.publisherKeyId, publicKey: keys.publisherPublicKey }],
    revocations: { publisherFingerprints: [sha256(Buffer.from(keys.publisherPublicKey, 'base64'))], packageDigests: [] },
  }));
  await assert.rejects(publishRepository(options(revokedApi, keys, { allowInitialPublication: false })), /revoked/);
  assert.equal(revokedApi.releaseCreations, 0);

  const api = new LocalGitHub();
  await publishRepository(options(api, keys));
  await assert.rejects(publishRepository(options(api, keys, { allowInitialPublication: false, bundleBytes: bundle({ contents: 'export const source = "changed";\n' }) })), /same-version bytes/);
  await assert.rejects(publishRepository(options(api, keys, { allowInitialPublication: false, bundleBytes: bundle({ legacyMigration: { fromPublisherFingerprint: 'a'.repeat(64), fromPackageSha256: 'b'.repeat(64) } }) })), /same-version metadata/);
  const replacementPublisher = credentials();
  await assert.rejects(publishRepository(options(api, { ...keys, publisherKeyId: replacementPublisher.publisherKeyId, publisherPublicKey: replacementPublisher.publisherPublicKey, publisherPrivateKey: replacementPublisher.publisherPrivateKey }, { allowInitialPublication: false, bundleBytes: bundle({ version: '1.0.1' }) })), /rotation|conflicts/);
});

test('a GraphQL expectedHeadOid race rejects a catalog changed then deleted before publication', async () => {
  const api = new LocalGitHub();
  const keys = credentials();
  await publishRepository(options(api, keys));
  const previousHead = api.refs.get('heads/repository').sha;
  api.raceCatalogCommit = true;
  await assert.rejects(publishRepository(options(api, keys, { allowInitialPublication: false, bundleBytes: bundle({ version: '1.0.1' }) })), /compare-and-swap/);
  assert.notEqual(api.refs.get('heads/repository').sha, previousHead);
  assert.deepEqual(api.trees.get(api.commits.get(api.refs.get('heads/repository').sha).treeSha), []);
  assert.equal(api.catalogCommitCalls, 1);
});

test('one release bundle can publish multiple independently versioned sources', async () => {
  const api = new LocalGitHub();
  const keys = credentials();
  const input = JSON.parse(bundle());
  const second = structuredClone(input.packages[0]);
  second.manifest.id = 'org.tsuyomi.second';
  input.packages.push(second);
  await publishRepository(options(api, keys, { bundleBytes: Buffer.from(JSON.stringify(input)) }));
  const published = validateAuthenticatedCatalog(await api.catalogBytes(), keys);
  assert.deepEqual(published.signed.packages.map((item) => item.id).sort(), ['org.tsuyomi.publisherfixture', 'org.tsuyomi.second']);
  for (const item of published.signed.packages) {
    const release = await api.getReleaseByTag(`${item.id}-v${item.version}`);
    const asset = (await api.listReleaseAssets(release.id)).find((entry) => entry.name.endsWith('.hxp'));
    assert.equal(sha256(await api.downloadReleaseAsset(asset.id)), item.sha256);
  }
});

test('a higher safe version can replace a revoked package without erasing its revocation', async () => {
  const keys = credentials();
  const originalApi = new LocalGitHub();
  await publishRepository(options(originalApi, keys));
  const original = validateAuthenticatedCatalog(await originalApi.catalogBytes(), keys).signed;
  const repairApi = new LocalGitHub();
  await installSignedCatalog(repairApi, keys, catalogInput(keys, {
    publishers: original.publishers.map(({ keyId, publicKey }) => ({ keyId, publicKey })),
    packages: original.packages,
    revocations: { publisherFingerprints: [], packageDigests: [original.packages[0].sha256] },
  }));
  await publishRepository(options(repairApi, keys, { allowInitialPublication: false, bundleBytes: bundle({ version: '1.0.1' }) }));
  const repaired = validateAuthenticatedCatalog(await repairApi.catalogBytes(), keys).signed;
  assert.equal(repaired.packages[0].version, '1.0.1');
  assert.deepEqual(repaired.revocations.packageDigests, [original.packages[0].sha256]);
});

test('a private-API download cannot substitute for a matching public release download', async () => {
  const api = new LocalGitHub();
  const keys = credentials();
  api.downloadPublicReleaseAsset = async () => Buffer.from('different public bytes');
  await assert.rejects(publishRepository(options(api, keys)), /public asset.*bytes/);
  assert.equal(await api.catalogBytes(), null);
});

test('GitHub source archives negotiate API media type and return binary bytes', async (t) => {
  const archive = Buffer.from([0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe]);
  const server = createServer((request, response) => {
    if (request.headers.accept !== 'application/vnd.github+json') {
      response.writeHead(415);
      response.end('Unsupported Media Type');
      return;
    }
    response.writeHead(200, { 'Content-Type': 'application/gzip' });
    response.end(archive);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  const api = createGitHubApi({
    repository: defaultRepository,
    token: 'nonproduction-test-token',
    fetchImpl: (url, init) => fetch(`http://127.0.0.1:${server.address().port}${url.pathname}`, init),
  });
  assert.deepEqual(await api.getSourceArchive(sourceRevision), archive);
});
