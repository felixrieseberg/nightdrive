import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  buildArtifactsExist,
  buildInputFingerprint,
  buildMarkerCanBeReused,
  cacheRoot,
  createSwiftArguments,
  debugInfoFormatFor,
  dependencyState,
  discoverBuildArtifacts,
  jobsForActiveSlots,
  makeCacheKey,
  recommendedJobCount,
  repairRelocatedSwiftPMArtifacts,
  runWithWatchdogRetry,
  shouldDisableSandbox,
  swiftToolchainIdentity,
  swiftToolchainMetadataIdentity,
} from './run-swiftpm.mjs';

test('adds bounded jobs to build and test commands', () => {
  assert.deepEqual(
    createSwiftArguments('build', ['-c', 'debug'], { jobs: 4 }),
    ['build', '--jobs', '4', '-c', 'debug'],
  );
  assert.deepEqual(
    createSwiftArguments('test', ['--filter', 'NightdriveTests'], { jobs: 3 }),
    ['test', '--jobs', '3', '--filter', 'NightdriveTests'],
  );
});

test('pins dependency versions only when Package.resolved exists', () => {
  assert.deepEqual(
    createSwiftArguments('build', [], { jobs: 4, useResolvedVersions: false }),
    ['build', '--jobs', '4'],
  );
  assert.deepEqual(
    createSwiftArguments('build', [], { jobs: 4, useResolvedVersions: true }),
    ['build', '--jobs', '4', '--only-use-versions-from-resolved-file'],
  );
});

test('preserves explicit SwiftPM options', () => {
  const args = createSwiftArguments(
    'test',
    [
      '--jobs=7',
      '--only-use-versions-from-resolved-file',
      '--disable-sandbox',
      '--filter',
      'NightdriveTests',
    ],
    { jobs: 4, useResolvedVersions: true, disableSandbox: true },
  );
  assert.equal(args.filter((arg) => arg === '--only-use-versions-from-resolved-file').length, 1);
  assert.equal(args.filter((arg) => arg === '--disable-sandbox').length, 1);
  assert.equal(args.includes('--jobs'), false);
  assert.equal(args.includes('--jobs=7'), true);
});

test('places runner defaults before executable arguments', () => {
  assert.deepEqual(
    createSwiftArguments('run', ['Nightdrive', '--', '--example', 'value'], {
      jobs: 2,
      disableSandbox: true,
    }),
    [
      'run',
      '--jobs',
      '2',
      '--disable-sandbox',
      'Nightdrive',
      '--',
      '--example',
      'value',
    ],
  );
  assert.deepEqual(
    createSwiftArguments('run', ['--skip-build', 'Nightdrive'], { jobs: 2 }),
    ['run', '--jobs', '2', '--skip-build', 'Nightdrive'],
  );
});

test('does not add build flags to unrelated commands', () => {
  assert.deepEqual(createSwiftArguments('package', ['clean'], { jobs: 4 }), [
    'package',
    'clean',
  ]);
  assert.deepEqual(
    createSwiftArguments('package', ['clean'], { jobs: 4, disableSandbox: true }),
    ['package', '--disable-sandbox', 'clean'],
  );
});

test('cache keys change with dependencies, manifest, or toolchain', () => {
  const base = { swiftVersion: 'Swift 6.3', dependencyContents: 'package state 1' };
  assert.notEqual(
    makeCacheKey(base),
    makeCacheKey({ ...base, dependencyContents: 'package state 2' }),
  );
  assert.notEqual(
    makeCacheKey(base),
    makeCacheKey({ ...base, swiftVersion: 'Swift 6.4' }),
  );
});

test('toolchain identity includes host platform and architecture', () => {
  assert.equal(
    swiftToolchainIdentity({
      swiftVersion: 'Swift 6.3\n',
      platform: 'darwin',
      arch: 'arm64',
    }),
    'darwin\narm64\nSwift 6.3',
  );
});

test('selected toolchain identity changes with compiler metadata or Xcode selection', () => {
  const base = {
    executablePath: '/toolchain/usr/bin/swift',
    size: 100,
    modifiedNanoseconds: 200,
    changedNanoseconds: 300,
    platform: 'darwin',
    arch: 'arm64',
  };
  assert.equal(swiftToolchainMetadataIdentity(base), swiftToolchainMetadataIdentity(base));
  assert.notEqual(
    swiftToolchainMetadataIdentity(base),
    swiftToolchainMetadataIdentity({ ...base, modifiedNanoseconds: 201 }),
  );
  assert.notEqual(
    swiftToolchainMetadataIdentity(base),
    swiftToolchainMetadataIdentity({ ...base, developerDirectory: '/other/Xcode' }),
  );
});

test('dependency-free packages do not require Package.resolved', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightdrive-runner-test-'));
  try {
    fs.writeFileSync(path.join(root, 'Package.swift'), '// dependency-free package\n');
    const first = dependencyState(root);
    assert.equal(first.hasResolvedFile, false);

    fs.writeFileSync(path.join(root, 'Package.swift'), '// changed manifest\n');
    const second = dependencyState(root);
    assert.notDeepEqual(first.contents, second.contents);

    fs.writeFileSync(path.join(root, 'Package.resolved'), '{"pins":[]}');
    const third = dependencyState(root);
    assert.equal(third.hasResolvedFile, true);
    assert.notDeepEqual(second.contents, third.contents);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('repairs downloaded artifact paths after a checkout is moved', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightdrive-relocation-test-'));
  try {
    const relocatedArtifact = path.join(
      root,
      '.build',
      'artifacts',
      'sparkle',
      'Sparkle',
      'Sparkle.xcframework',
    );
    fs.mkdirSync(relocatedArtifact, { recursive: true });
    const stateFile = path.join(root, '.build', 'workspace-state.json');
    fs.writeFileSync(stateFile, JSON.stringify({
      object: {
        artifacts: [{
          path: '/old/checkout/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework',
        }],
      },
      version: 7,
    }));

    assert.equal(repairRelocatedSwiftPMArtifacts({ root }), 1);
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    assert.equal(state.object.artifacts[0].path, relocatedArtifact);
    assert.equal(repairRelocatedSwiftPMArtifacts({ root }), 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('build fingerprints include sources, resources, and tests only when requested', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightdrive-fingerprint-test-'));
  try {
    fs.mkdirSync(path.join(root, 'Sources', 'App'), { recursive: true });
    fs.mkdirSync(path.join(root, 'Resources'), { recursive: true });
    fs.mkdirSync(path.join(root, 'Tests', 'AppTests'), { recursive: true });
    fs.writeFileSync(path.join(root, 'Package.swift'), '// package\n');
    fs.writeFileSync(path.join(root, 'Sources', 'App', 'App.swift'), 'let value = 1\n');
    fs.writeFileSync(path.join(root, 'Resources', 'fixture.txt'), 'resource 1\n');
    fs.writeFileSync(path.join(root, 'Tests', 'AppTests', 'AppTests.swift'), 'test 1\n');

    const build = buildInputFingerprint({ root });
    const testBuild = buildInputFingerprint({ root, buildsTests: true });
    assert.notEqual(build, testBuild);

    fs.writeFileSync(path.join(root, 'Tests', 'AppTests', 'AppTests.swift'), 'test 2\n');
    assert.equal(buildInputFingerprint({ root }), build);
    assert.notEqual(buildInputFingerprint({ root, buildsTests: true }), testBuild);

    fs.writeFileSync(path.join(root, 'Resources', 'fixture.txt'), 'resource 2\n');
    assert.notEqual(buildInputFingerprint({ root }), build);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('discovers and verifies generic executable and XCTest artifacts', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightdrive-artifact-test-'));
  try {
    const executable = path.join(root, 'Example');
    fs.writeFileSync(executable, '#!/bin/sh\n');
    fs.chmodSync(executable, 0o755);
    const testExecutableDirectory = path.join(
      root,
      'ExamplePackageTests.xctest',
      'Contents',
      'MacOS',
    );
    fs.mkdirSync(testExecutableDirectory, { recursive: true });
    const testExecutable = path.join(testExecutableDirectory, 'ExamplePackageTests');
    fs.writeFileSync(testExecutable, '#!/bin/sh\n');
    fs.chmodSync(testExecutable, 0o755);

    const buildArtifacts = discoverBuildArtifacts(root);
    const testArtifacts = discoverBuildArtifacts(root, true);
    assert.deepEqual(buildArtifacts, [{ kind: 'executable', relative: 'Example' }]);
    assert.deepEqual(testArtifacts, [
      { kind: 'xctest', relative: 'ExamplePackageTests.xctest' },
    ]);
    assert.equal(buildArtifactsExist(root, buildArtifacts), true);
    assert.equal(buildArtifactsExist(root, testArtifacts, true), true);

    fs.rmSync(executable);
    assert.equal(buildArtifactsExist(root, buildArtifacts), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('reuses only an exact default build marker', () => {
  const args = ['-c', 'debug'];
  const marker = {
    schema: 2,
    cacheSchema: 'v1',
    buildsTests: false,
    inputFingerprint: 'all-build-inputs',
    cacheKey: 'toolchain-and-dependencies',
    toolchainIdentity: 'selected-toolchain',
    debugInfoFormat: 'none',
    arguments: args,
  };
  const candidate = {
    args,
    marker,
    inputFingerprint: 'all-build-inputs',
    cacheKey: 'toolchain-and-dependencies',
    toolchainIdentity: 'selected-toolchain',
    debugInfoFormat: 'none',
    artifactsExist: true,
  };
  assert.equal(buildMarkerCanBeReused(candidate), true);
  assert.equal(
    buildMarkerCanBeReused({ ...candidate, inputFingerprint: 'changed-source' }),
    false,
  );
  assert.equal(
    buildMarkerCanBeReused({ ...candidate, cacheKey: 'changed-dependency' }),
    false,
  );
  assert.equal(
    buildMarkerCanBeReused({ ...candidate, toolchainIdentity: 'other-toolchain' }),
    false,
  );
  assert.equal(buildMarkerCanBeReused({ ...candidate, artifactsExist: false }), false);
  assert.equal(
    buildMarkerCanBeReused({ ...candidate, debugInfoFormat: 'dwarf' }),
    false,
  );
  assert.equal(
    buildMarkerCanBeReused({ ...candidate, args: ['-c', 'release'] }),
    false,
  );
  assert.equal(
    buildMarkerCanBeReused({ ...candidate, args: ['--product', 'Example'] }),
    false,
  );
});

test('test build markers require exact build-tests state', () => {
  const args = ['--build-tests', '-c', 'debug'];
  const marker = {
    schema: 2,
    cacheSchema: 'v1',
    buildsTests: true,
    inputFingerprint: 'all-test-inputs',
    cacheKey: 'toolchain-and-dependencies',
    toolchainIdentity: 'selected-toolchain',
    debugInfoFormat: 'none',
    arguments: args,
  };
  const candidate = {
    args,
    marker,
    inputFingerprint: 'all-test-inputs',
    cacheKey: 'toolchain-and-dependencies',
    toolchainIdentity: 'selected-toolchain',
    debugInfoFormat: 'none',
    artifactsExist: true,
  };
  assert.equal(buildMarkerCanBeReused(candidate), true);
  assert.equal(
    buildMarkerCanBeReused({
      ...candidate,
      args: ['-c', 'debug'],
    }),
    false,
  );
});

test('sizes compiler parallelism to the host and shared slot count', () => {
  assert.equal(recommendedJobCount({ logicalCores: 14, slotCount: 2 }), 7);
  assert.equal(recommendedJobCount({ logicalCores: 8, slotCount: 2 }), 4);
  assert.equal(recommendedJobCount({ logicalCores: 64, slotCount: 2 }), 8);
  assert.equal(recommendedJobCount({ logicalCores: 1, slotCount: 2 }), 1);
});

test('gives a lone verification run the whole machine', () => {
  assert.equal(jobsForActiveSlots(1, { logicalCores: 14, override: undefined }), 14);
  assert.equal(jobsForActiveSlots(2, { logicalCores: 14, override: undefined }), 7);
  assert.equal(jobsForActiveSlots(3, { logicalCores: 14, override: undefined }), 4);
  assert.equal(jobsForActiveSlots(1, { logicalCores: 14, override: '5' }), 5);
  assert.equal(jobsForActiveSlots(1, { logicalCores: 1, override: undefined }), 1);
});

test('omits debug information from debug builds unless asked for it', () => {
  assert.equal(debugInfoFormatFor({ configuration: 'debug' }), 'none');
  assert.equal(debugInfoFormatFor({ configuration: 'release' }), null);
  assert.equal(debugInfoFormatFor({ configuration: 'debug', override: '' }), 'none');
  assert.equal(debugInfoFormatFor({ configuration: 'debug', override: 'dwarf' }), 'dwarf');
  assert.equal(debugInfoFormatFor({ configuration: 'release', override: 'none' }), 'none');
  assert.throws(
    () => debugInfoFormatFor({ configuration: 'debug', override: 'yes-please' }),
    /NIGHTDRIVE_DEBUG_INFO_FORMAT/,
  );
});

test('asks every debug entry point for the same debug information', () => {
  // The executable, test, e2e and snapshot builds all land on one command
  // line, so alternating between them cannot invalidate llbuild's work.
  assert.deepEqual(
    createSwiftArguments('build', ['-c', 'debug'], { jobs: 4, debugInfoFormat: 'none' }),
    ['build', '--jobs', '4', '-debug-info-format', 'none', '-c', 'debug'],
  );
  assert.deepEqual(
    createSwiftArguments('build', ['--build-tests', '-c', 'debug'], {
      jobs: 4,
      debugInfoFormat: 'none',
    }),
    ['build', '--jobs', '4', '-debug-info-format', 'none', '--build-tests', '-c', 'debug'],
  );
  assert.deepEqual(
    createSwiftArguments('build', ['-c', 'debug', '-debug-info-format', 'dwarf'], {
      jobs: 4,
      debugInfoFormat: 'none',
    }),
    ['build', '--jobs', '4', '-c', 'debug', '-debug-info-format', 'dwarf'],
  );
  assert.deepEqual(
    createSwiftArguments('build', ['-c', 'release'], { jobs: 4, debugInfoFormat: null }),
    ['build', '--jobs', '4', '-c', 'release'],
  );
});

test('uses a Nightdrive-specific cache override', () => {
  assert.equal(
    cacheRoot({ NIGHTDRIVE_SWIFT_CACHE_DIR: '/tmp/custom-swift-cache' }),
    '/tmp/custom-swift-cache',
  );
});

test('sandbox behavior supports explicit overrides and automatic probing', () => {
  assert.equal(shouldDisableSandbox({ platform: 'linux', probe: () => ({ status: 1 }) }), false);
  assert.equal(
    shouldDisableSandbox({ platform: 'darwin', probe: () => ({ status: 0 }) }),
    false,
  );
  assert.equal(
    shouldDisableSandbox({ platform: 'darwin', probe: () => ({ status: 1 }) }),
    true,
  );
  assert.equal(
    shouldDisableSandbox({
      platform: 'darwin',
      override: 'false',
      probe: () => ({ status: 1 }),
    }),
    false,
  );
  assert.equal(
    shouldDisableSandbox({
      platform: 'darwin',
      override: 'true',
      probe: () => ({ status: 0 }),
    }),
    true,
  );
});

test('watchdog failures retry exactly once', async () => {
  let attempts = 0;
  let retryNotices = 0;
  const result = await runWithWatchdogRetry(
    async () => {
      attempts += 1;
      return attempts === 1
        ? { code: 1, watchdogFired: true }
        : { code: 0, watchdogFired: false };
    },
    () => {
      retryNotices += 1;
    },
  );
  assert.equal(attempts, 2);
  assert.equal(retryNotices, 1);
  assert.equal(result.code, 0);
});

test('ordinary failures are not retried', async () => {
  let attempts = 0;
  const result = await runWithWatchdogRetry(async () => {
    attempts += 1;
    return { code: 1, watchdogFired: false };
  });
  assert.equal(attempts, 1);
  assert.equal(result.code, 1);
});
