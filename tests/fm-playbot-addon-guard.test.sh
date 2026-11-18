#!/usr/bin/env bash
# Real Git regression for addon-guard lane-rebase preservation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_test_require_node "fm-playbot-addon-guard"

FM_TEST_GUARD_MODULE="$ROOT/bin/fm-playbot-addon-guard.mjs" \
FM_TEST_REPO_ROOT="$(fm_test_tmproot fm-playbot-addon-guard)" \
  "$FM_TEST_NODE_BIN" --no-warnings --input-type=module <<'NODE' || fail "lane-rebase did not preserve both addon trees"
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const { guardAddon } = await import(pathToFileURL(process.env.FM_TEST_GUARD_MODULE));
const base = process.env.FM_TEST_REPO_ROOT;
const git = (root, args) => {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', env: {
    ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.test',
    GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.test',
  } });
  if (result.status !== 0) throw new Error(`${args.join(' ')}: ${result.stderr.trim()}`);
  return result.stdout;
};
const put = (root, name, bytes) => {
  const file = path.join(root, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
};
const snapshot = (directory) => Object.fromEntries(fs.readdirSync(directory, { recursive: true, withFileTypes: true })
  .filter((entry) => entry.isFile())
  .map((entry) => [path.relative(directory, path.join(entry.parentPath, entry.name)), fs.readFileSync(path.join(entry.parentPath, entry.name)).toString('hex')]));

for (const rootMirror of [false, true]) {
  const root = path.join(base, rootMirror ? 'with-root-mirror' : 'without-root-mirror');
  fs.mkdirSync(root, { recursive: true });
  git(root, ['init', '-q', '-b', 'main']);
  put(root, 'prototype-game/project.godot', 'project\n');
  put(root, 'prototype-game/addons/playbot/plugin.cfg', 'tracked addon original\n');
  put(root, 'base.txt', 'base\n');
  put(root, 'stash-only.txt', 'original\n');
  git(root, ['add', '.']);
  git(root, ['commit', '-qm', 'base']);
  git(root, ['checkout', '-qb', 'target']);
  put(root, 'target.txt', 'target\n');
  git(root, ['add', 'target.txt']);
  git(root, ['commit', '-qm', 'target']);
  git(root, ['checkout', '-q', 'main']);
  put(root, 'lane.txt', 'lane\n');
  git(root, ['add', 'lane.txt']);
  git(root, ['commit', '-qm', 'lane']);
  put(root, 'stash-only.txt', 'retained stash\n');
  git(root, ['stash', 'push', '-qm', 'preexisting stash', '--', 'stash-only.txt']);
  const stashBefore = git(root, ['rev-parse', 'refs/stash']).trim();
  const nested = path.join(root, 'prototype-game/addons/playbot');
  put(root, 'prototype-game/addons/playbot/plugin.cfg', 'injected addon bytes\n');
  put(root, 'prototype-game/addons/playbot/extra.bin', Buffer.from([0, 1, 255]));
  const projects = [{ addon: { path: nested, byteIdentical: true, version: 'test' } }];
  if (rootMirror) {
    put(root, 'project.godot', 'root project\n');
    const mirror = path.join(root, 'addons/playbot');
    put(root, 'addons/playbot/plugin.cfg', 'root mirror bytes\n');
    put(root, 'addons/playbot/extra.bin', Buffer.from([255, 1, 0]));
    projects.push({ addon: { path: mirror, byteIdentical: true, version: 'test' } });
  }
  const before = projects.map((project) => snapshot(project.addon.path));
  const trackedAtHead = git(root, ['ls-tree', '-r', '--name-only', 'HEAD', '--', 'prototype-game/addons/playbot']).trim().split('\n').filter(Boolean);
  assert.equal(trackedAtHead.length, 1);
  const untrackedRoot = git(root, ['ls-files', '--others', '--exclude-standard', '--', 'addons/playbot']).trim().split('\n').filter(Boolean);
  assert.equal(untrackedRoot.length, rootMirror ? 2 : 0);
  const report = { projects, bundle: { confirmed: true, version: 'test' }, errors: [] };
  const result = await guardAddon({ root, report, operation: 'lane-rebase', args: ['target'], git,
    indexFlags: [], operations: [], trackedChurn: () => false, verify: async () => report });
  assert.equal(result.rebasedOnto, 'target');
  assert.equal(git(root, ['merge-base', 'HEAD', 'target']).trim(), git(root, ['rev-parse', 'target']).trim());
  assert.equal(fs.readFileSync(path.join(root, 'lane.txt'), 'utf8'), 'lane\n');
  assert.deepEqual(projects.map((project) => snapshot(project.addon.path)), before);
  assert.equal(git(root, ['rev-parse', 'refs/stash']).trim(), stashBefore);
  assert.equal(git(root, ['status', '--porcelain', '--', 'addons/playbot']).trim() !== '', rootMirror);
  console.log(`fixture ${rootMirror ? 'root-mirror' : 'nested-only'}: tracked addon files=${trackedAtHead.length}, untracked root addon files=${untrackedRoot.length}, preserved trees=${projects.length}`);
}
NODE
pass "fm-playbot-addon-guard: lane-rebase preserves tracked addon and untracked root mirror without dropping stash"
