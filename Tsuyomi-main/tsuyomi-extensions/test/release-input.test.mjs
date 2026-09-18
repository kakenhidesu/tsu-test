// SPDX-FileCopyrightText: 2026 Tsuyomi Contributors
// SPDX-License-Identifier: AGPL-3.0-only

import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';
import { prepareRelease } from '../tools/prepare-release.mjs';

const execFile = promisify(execFileCallback);
const projectRoot = fileURLToPath(new URL('..', import.meta.url));
const prepareReleaseCli = new URL('../tools/prepare-release.mjs', import.meta.url);
const sourceConfigUrl = new URL('../release/sources.json', import.meta.url);
const revision = '0123456789abcdef0123456789abcdef01234567';

const command = (argumentsList, cwd = projectRoot) => execFile(
  process.execPath,
  [fileURLToPath(prepareReleaseCli), ...argumentsList],
  { cwd },
);

const fixtureRoot = async () => {
  const root = await mkdtemp(join(tmpdir(), 'tsuyomi-release-input-'));
  const sources = JSON.parse(await readFile(sourceConfigUrl, 'utf8'));
  const compiledPath = join(root, 'dist/modules/wenku8/index.mjs');
  await mkdir(dirname(compiledPath), { recursive: true });
  await writeFile(compiledPath, 'export default { source: "test" };\n');
  await mkdir(join(root, 'release'), { recursive: true });
  return { root, sources, compiledPath };
};

const writeSources = (root, sources) => writeFile(join(root, 'release/sources.json'), JSON.stringify(sources));

const clone = (value) => JSON.parse(JSON.stringify(value));

test('prepare-release rejects an unbound revision and refuses to overwrite an existing bundle', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'tsuyomi-release-production-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const output = join(directory, 'release-input.json');
  await writeFile(output, 'previous reviewed release input');
  await assert.rejects(command(['--revision', revision, '--output', output]), /Refusing to overwrite/);
  assert.equal(await readFile(output, 'utf8'), 'previous reviewed release input');
  await assert.rejects(
    command(['--revision', 'not-a-commit', '--output', join(directory, 'invalid.json')]),
    /--revision/,
  );
});

test('prepare-release rejects unsafe source data, duplicate source IDs, and HXP limits', async (t) => {
  const { root, sources } = await fixtureRoot();
  t.after(() => rm(root, { recursive: true, force: true }));
  const output = join(root, 'release-input.json');
  const run = () => prepareRelease({ root, revision, output });

  const unsafeArchivePath = clone(sources);
  unsafeArchivePath.packages[0].files = { '../index.mjs': 'dist/modules/wenku8/index.mjs' };
  await writeSources(root, unsafeArchivePath);
  await assert.rejects(run(), /normalized relative slash path/);

  const unsafeCompiledPath = clone(sources);
  unsafeCompiledPath.packages[0].files = { 'index.mjs': '../outside.mjs' };
  await writeSources(root, unsafeCompiledPath);
  await assert.rejects(run(), /files\.index\.mjs is invalid/);

  const duplicateSource = clone(sources);
  duplicateSource.packages.push(clone(duplicateSource.packages[0]));
  await writeSources(root, duplicateSource);
  await assert.rejects(run(), /duplicate source id org\.tsuyomi\.wenku8/);

  const excessiveFiles = clone(sources);
  excessiveFiles.packages[0].files = { 'index.mjs': 'dist/modules/wenku8/index.mjs' };
  for (let index = 0; index < 254; index += 1) {
    excessiveFiles.packages[0].files[`assets/${index}.mjs`] = 'dist/modules/wenku8/index.mjs';
  }
  await writeSources(root, excessiveFiles);
  await assert.rejects(run(), /must contain 1\.\.254 archive files/);
});

test('prepare-release rejects a symbolic linked compiled input', async (t) => {
  const { root, sources, compiledPath } = await fixtureRoot();
  t.after(() => rm(root, { recursive: true, force: true }));
  const linkedPath = join(dirname(compiledPath), 'linked.mjs');
  try {
    await symlink('index.mjs', linkedPath);
  } catch (error) {
    if (error.code === 'EPERM') {
      t.skip('symbolic links are unavailable to this Windows test process');
      return;
    }
    throw error;
  }
  const symlinkedInput = clone(sources);
  symlinkedInput.packages[0].files = { 'index.mjs': 'dist/modules/wenku8/linked.mjs' };
  await writeSources(root, symlinkedInput);
  await assert.rejects(
    prepareRelease({ root, revision, output: join(root, 'release-input.json') }),
    /must not traverse symbolic links/,
  );
});
