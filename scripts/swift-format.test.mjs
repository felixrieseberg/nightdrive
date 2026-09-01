import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  chunk,
  partitionByMarker,
  swiftFilesIn,
  swiftFormatArguments,
} from './swift-format.mjs';

const SCHEMA = 1;

function marker(files, key = 'k') {
  return { schema: SCHEMA, key, files };
}

test('lints strictly and formats in place', () => {
  const lint = swiftFormatArguments('lint', ['a.swift'], { configuration: '.swift-format' });
  assert.deepEqual(lint, [
    'format',
    'lint',
    '--configuration',
    '.swift-format',
    '--strict',
    '--parallel',
    'a.swift',
  ]);

  const format = swiftFormatArguments('format', ['a.swift'], {
    configuration: '.swift-format',
  });
  assert.deepEqual(format, [
    'format',
    'format',
    '--configuration',
    '.swift-format',
    '--in-place',
    'a.swift',
  ]);
});

test('finds every Swift file below the given roots, sorted', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightdrive-format-'));
  try {
    fs.mkdirSync(path.join(root, 'Sources/Deep/Deeper'), { recursive: true });
    fs.mkdirSync(path.join(root, 'Tests'), { recursive: true });
    fs.writeFileSync(path.join(root, 'Sources/b.swift'), '');
    fs.writeFileSync(path.join(root, 'Sources/a.swift'), '');
    fs.writeFileSync(path.join(root, 'Sources/Deep/Deeper/c.swift'), '');
    fs.writeFileSync(path.join(root, 'Sources/notes.md'), '');
    fs.writeFileSync(path.join(root, 'Tests/t.swift'), '');

    assert.deepEqual(swiftFilesIn(['Sources', 'Tests'], { root }), [
      'Sources/Deep/Deeper/c.swift',
      'Sources/a.swift',
      'Sources/b.swift',
      'Tests/t.swift',
    ]);
    // A root that does not exist is not an error; the tree simply has none.
    assert.deepEqual(swiftFilesIn(['Missing'], { root }), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('checks only the files whose contents changed', () => {
  const digests = new Map([
    ['a.swift', 'aaa'],
    ['b.swift', 'bbb'],
    ['c.swift', 'ccc'],
  ]);
  const { stale, clean } = partitionByMarker(
    digests,
    marker({ 'a.swift': 'aaa', 'b.swift': 'OLD' }),
    { key: 'k' },
  );
  // b changed, c was never recorded.
  assert.deepEqual(stale, ['b.swift', 'c.swift']);
  assert.deepEqual([...clean], [['a.swift', 'aaa']]);
});

test('checks everything when the marker cannot be trusted', () => {
  const digests = new Map([['a.swift', 'aaa']]);
  const files = { 'a.swift': 'aaa' };
  const everything = ['a.swift'];

  assert.deepEqual(partitionByMarker(digests, null, { key: 'k' }).stale, everything);
  // A different swift-format build or configuration invalidates every
  // judgement it previously made.
  assert.deepEqual(
    partitionByMarker(digests, marker(files, 'other'), { key: 'k' }).stale,
    everything,
  );
  assert.deepEqual(
    partitionByMarker(digests, { ...marker(files), schema: SCHEMA + 1 }, { key: 'k' }).stale,
    everything,
  );
  assert.deepEqual(
    partitionByMarker(digests, marker(files), { key: 'k', force: true }).stale,
    everything,
  );
});

test('a file dropped from the tree leaves the rest clean', () => {
  const digests = new Map([['a.swift', 'aaa']]);
  const { stale, clean } = partitionByMarker(
    digests,
    marker({ 'a.swift': 'aaa', 'gone.swift': 'ggg' }),
    { key: 'k' },
  );
  assert.deepEqual(stale, []);
  assert.deepEqual([...clean.keys()], ['a.swift']);
});

test('batches files without losing or duplicating any', () => {
  const items = Array.from({ length: 10 }, (_, index) => index);
  assert.deepEqual(chunk(items, 4), [
    [0, 1, 2, 3],
    [4, 5, 6, 7],
    [8, 9],
  ]);
  assert.deepEqual(chunk([], 4), []);
  assert.deepEqual(chunk(items, 100).flat(), items);
});

test('follows symlinked sources rather than skipping them', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'swift-format-links-'));
  try {
    fs.mkdirSync(path.join(root, 'Sources/Real'), { recursive: true });
    fs.writeFileSync(path.join(root, 'Sources/Real/A.swift'), '');
    fs.symlinkSync(
      path.join(root, 'Sources/Real'),
      path.join(root, 'Sources/Linked'),
    );
    fs.symlinkSync(
      path.join(root, 'Sources/Real/A.swift'),
      path.join(root, 'Sources/B.swift'),
    );
    assert.deepEqual(swiftFilesIn(['Sources'], { root }), [
      'Sources/B.swift',
      'Sources/Linked/A.swift',
      'Sources/Real/A.swift',
    ]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
