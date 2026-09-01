#!/usr/bin/env node
// Lint (or format) Swift sources, skipping files that already passed.
//
// swift-format judges each file on its own — no rule reads across files — so a
// file whose bytes have not changed since it last passed cannot have started
// failing. The record of what passed is keyed by the configuration and the
// swift-format build, and is only written after swift-format accepts a file.
//
//   node scripts/swift-format.mjs lint     # check, skipping unchanged files
//   node scripts/swift-format.mjs format   # rewrite in place
//   node scripts/swift-format.mjs lint --all
//
// NIGHTDRIVE_LINT_CACHE=0 also forces a full run.
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const MARKER_SCHEMA = 1;
const CONFIG_FILE = '.swift-format';
const LINT_PATHS = ['Sources', 'Tests'];
// Chunked so a large tree cannot overrun the platform's argument limit.
const MAX_FILES_PER_INVOCATION = 400;

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

export function swiftFormatArguments(mode, files, { configuration }) {
  const shared = ['format', mode === 'format' ? 'format' : 'lint'];
  const options =
    mode === 'format' ? ['--in-place'] : ['--strict', '--parallel'];
  return [...shared, '--configuration', configuration, ...options, ...files];
}

/// Every Swift file under the linted paths, repo-relative and sorted.
export function swiftFilesIn(roots, { root = REPO_ROOT, fileSystem = fs } = {}) {
  const found = [];
  const walk = (relative) => {
    const absolute = path.join(root, relative);
    let entries;
    try {
      entries = fileSystem.readdirSync(absolute, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const child = path.join(relative, entry.name);
      let kind = entry;
      if (entry.isSymbolicLink()) {
        try {
          kind = fileSystem.statSync(path.join(root, child));
        } catch {
          continue;
        }
      }
      if (kind.isDirectory()) {
        walk(child);
      } else if (kind.isFile() && entry.name.endsWith('.swift')) {
        found.push(child);
      }
    }
  };
  for (const relative of roots) walk(relative);
  return found.sort();
}

/// The files that still have to be checked, and the digests of the ones that
/// don't. A file counts as clean only if the marker recorded that exact
/// content.
export function partitionByMarker(digests, marker, { key, force = false } = {}) {
  const clean = new Map();
  if (force || marker?.schema !== MARKER_SCHEMA || marker?.key !== key) {
    return { stale: [...digests.keys()], clean };
  }
  const passed = marker.files ?? {};
  const stale = [];
  for (const [file, digest] of digests) {
    if (passed[file] === digest) {
      clean.set(file, digest);
    } else {
      stale.push(file);
    }
  }
  return { stale, clean };
}

export function chunk(items, size) {
  const chunks = [];
  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }
  return chunks;
}

/// swift-format's own build, so a toolchain upgrade that changes its rules
/// invalidates everything it previously accepted.
function swiftFormatIdentity() {
  const result = spawnSync('swift', ['format', '--version'], {
    encoding: 'utf8',
    cwd: REPO_ROOT,
  });
  return result.status === 0 ? result.stdout.trim() : 'unknown';
}

function markerPath(mode) {
  return path.join(REPO_ROOT, '.build', 'nightdrive-verification', `${mode}.json`);
}

function digestFiles(files) {
  const digests = new Map();
  for (const file of files) {
    digests.set(file, sha256(fs.readFileSync(path.join(REPO_ROOT, file))));
  }
  return digests;
}

function run(args) {
  return new Promise((resolve) => {
    const child = spawn('swift', args, { cwd: REPO_ROOT, stdio: 'inherit' });
    child.on('error', () => resolve(1));
    child.on('close', (code) => resolve(code ?? 1));
  });
}

async function main(argv = process.argv.slice(2)) {
  const [mode = 'lint', ...rest] = argv;
  if (!['lint', 'format'].includes(mode)) {
    console.error(`Usage: swift-format.mjs [lint|format] [--all]`);
    return 2;
  }

  const force = rest.includes('--all') || process.env.NIGHTDRIVE_LINT_CACHE === '0';
  const configuration = path.join(REPO_ROOT, CONFIG_FILE);
  const files = swiftFilesIn(LINT_PATHS);
  if (files.length === 0) {
    console.error('[swift-format] No Swift files to check.');
    return 0;
  }

  const digests = digestFiles(files);
  const key = sha256(
    [swiftFormatIdentity(), fs.readFileSync(configuration, 'utf8'), mode].join('\0'),
  );
  const { stale } = partitionByMarker(digests, readJson(markerPath(mode)), {
    key,
    force,
  });

  if (stale.length === 0) {
    console.error(`[swift-format] ${files.length} files already ${mode}ed; nothing to do.`);
    return 0;
  }

  const scope =
    stale.length === files.length
      ? `all ${files.length} files`
      : `${stale.length} of ${files.length} files`;
  console.error(`[swift-format] ${mode} ${scope}`);

  for (const batch of chunk(stale, MAX_FILES_PER_INVOCATION)) {
    const code = await run(swiftFormatArguments(mode, batch, { configuration }));
    // Record nothing on failure: swift-format reports per file, and we cannot
    // tell from the exit code which of the batch were clean.
    if (code !== 0) return code;
  }

  // Record only files whose bytes are still what swift-format judged: a file
  // edited while it ran was either not the content that passed (lint) or not
  // swift-format's own output (format).
  const passed = new Map();
  for (const [file, digest] of digestFiles(files)) {
    if (mode === 'format' || digests.get(file) === digest) passed.set(file, digest);
  }
  const file = markerPath(mode);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(
    file,
    `${JSON.stringify(
      {
        schema: MARKER_SCHEMA,
        key,
        files: Object.fromEntries([...passed].sort(([a], [b]) => a.localeCompare(b))),
        completedAt: new Date().toISOString(),
      },
      null,
      2,
    )}\n`,
  );
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main();
}
