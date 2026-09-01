import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const POLICY = path.join(SCRIPT_DIR, 'verify-localized-errors.sh');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightdrive-localized-errors-'));
  fs.mkdirSync(path.join(root, 'Sources/Nightdrive/Demo'), { recursive: true });
  fs.mkdirSync(path.join(root, 'Sources/Nightdrive/Development'), { recursive: true });
  fs.mkdirSync(path.join(root, 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(root, 'scripts/localized-error-allowlist.json'), '[]\n');
  return root;
}

function writeSource(root, relative, source) {
  const destination = path.join(root, 'Sources/Nightdrive', relative);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, source);
}

function run(root, ...arguments_) {
  return spawnSync(POLICY, ['--root', root, ...arguments_], {
    cwd: root,
    encoding: 'utf8',
  });
}

test('rejects raw LocalizedError copy without matching unrelated strings', () => {
  const root = fixture();
  try {
    writeSource(
      root,
      'Errors.swift',
      `
let unrelated = "This is not an error description."

enum RawFailure: LocalizedError {
  case failed(Int)
  var errorDescription: String? {
    switch self {
    case .failed(let code): "The operation failed (\\(code))."
    }
  }
}

struct PassThroughFailure: LocalizedError {
  let errorDescription: String?
}
`,
    );
    writeSource(
      root,
      'Demo/Ignored.swift',
      'enum DemoFailure: LocalizedError { var errorDescription: String? { "Demo failed." } }\n',
    );
    writeSource(
      root,
      'Development/Ignored.swift',
      'enum DevFailure: LocalizedError { var errorDescription: String? { "Dev failed." } }\n',
    );

    const result = run(root);
    assert.equal(result.status, 1);
    assert.match(result.stdout, /Sources\/Nightdrive\/Errors\.swift:\d+: error: raw string literal/);
    assert.match(result.stdout, /RawFailure\.errorDescription/);
    assert.doesNotMatch(result.stdout, /unrelated|DemoFailure|DevFailure|PassThroughFailure/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('accepts String(localized:) in declarations and conforming extensions', () => {
  const root = fixture();
  try {
    writeSource(
      root,
      'Localized.swift',
      `
enum LocalizedFailure: LocalizedError {
  case failed(Int)
  var errorDescription: String? {
    switch self {
    case .failed(let code): String(localized: "The operation failed (\\(code)).")
    }
  }
}

struct ExtendedFailure {}
extension ExtendedFailure: LocalizedError {
  var errorDescription: String? { String(localized: "The extension failed.") }
}
`,
    );

    const result = run(root);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /use the String Catalog/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('rejects split and qualified LocalizedError conformances', () => {
  const root = fixture();
  try {
    writeSource(
      root,
      'Definitions.swift',
      `
struct SplitFailure: LocalizedError {}

enum QualifiedFailure: Foundation.LocalizedError {
  var errorDescription: String? { "Qualified failure." }
}
`,
    );
    writeSource(
      root,
      'Descriptions.swift',
      `
extension SplitFailure {
  var errorDescription: String? { "Split failure." }
}
`,
    );

    const result = run(root);
    assert.equal(result.status, 1);
    assert.match(result.stdout, /SplitFailure\.errorDescription/);
    assert.match(result.stdout, /QualifiedFailure\.errorDescription/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('fingerprinted debt cannot grow or change silently', () => {
  const root = fixture();
  try {
    const source =
      'enum LegacyFailure: LocalizedError { var errorDescription: String? { "Legacy copy." } }\n';
    writeSource(root, 'Legacy.swift', source);

    const printed = run(root, '--print-allowlist');
    assert.equal(printed.status, 0, printed.stderr);
    fs.writeFileSync(
      path.join(root, 'scripts/localized-error-allowlist.json'),
      printed.stdout,
    );
    assert.equal(run(root).status, 0);

    writeSource(root, 'Legacy.swift', source.replace('Legacy copy.', 'Changed legacy copy.'));
    const changed = run(root);
    assert.equal(changed.status, 1);
    assert.match(changed.stdout, /raw string literal in LegacyFailure\.errorDescription/);
    assert.match(changed.stdout, /stale localized-error allowlist entry/);
    assert.match(changed.stdout, /--print-allowlist/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
