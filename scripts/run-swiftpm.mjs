#!/usr/bin/env node
/**
 * Run SwiftPM with repository-wide defaults that are safe across worktrees:
 *
 * - each checkout keeps its own mutable .build database;
 * - compiler module caches are shared by toolchain and dependency state;
 * - a small number of process slots bounds aggregate compiler concurrency;
 * - a no-output watchdog retries the occasional wedged SwiftPM invocation once.
 */

import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const CACHE_SCHEMA = 'v1';
const MARKER_SCHEMA = 2;
const DEFAULT_SLOTS = 2;
const DEFAULT_MAX_JOBS = 8;
const DEFAULT_WATCHDOG_SECONDS = 90;
const DEFAULT_MAX_AGE_DAYS = 14;
const DEBUG_INFO_FORMATS = ['dwarf', 'codeview', 'none'];
const BUILDING_COMMANDS = new Set(['build', 'test', 'run']);
const SUPPORTED_COMMANDS = new Set([...BUILDING_COMMANDS, 'package']);

function positiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export function recommendedJobCount({
  logicalCores,
  slotCount = DEFAULT_SLOTS,
  maxJobs = DEFAULT_MAX_JOBS,
}) {
  const cores = positiveInteger(logicalCores, 1);
  const slots = positiveInteger(slotCount, DEFAULT_SLOTS);
  const cap = positiveInteger(maxJobs, DEFAULT_MAX_JOBS);
  return Math.max(1, Math.min(cap, Math.floor(cores / slots)));
}

function hostLogicalCoreCount() {
  return typeof os.availableParallelism === 'function'
    ? os.availableParallelism()
    : os.cpus().length;
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

export function swiftToolchainIdentity({
  swiftVersion,
  platform = process.platform,
  arch = process.arch,
}) {
  return `${platform}\n${arch}\n${swiftVersion.trim()}`;
}

export function makeCacheKey({
  swiftVersion,
  dependencyContents = '',
  selectedToolchainIdentity = '',
  platform,
  arch,
}) {
  const identity = swiftToolchainIdentity({ swiftVersion, platform, arch });
  return sha256(Buffer.concat([
    Buffer.from(`${CACHE_SCHEMA}\n${identity}\n${selectedToolchainIdentity}\n`),
    Buffer.isBuffer(dependencyContents)
      ? dependencyContents
      : Buffer.from(String(dependencyContents)),
  ])).slice(0, 20);
}

function swiftVersion() {
  const result = spawnSync('swift', ['--version'], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || 'Could not determine the Swift toolchain version.');
  }
  return result.stdout;
}

export function swiftToolchainMetadataIdentity({
  executablePath,
  size,
  modifiedNanoseconds,
  changedNanoseconds,
  developerDirectory = '',
  toolchains = '',
  sdkRoot = '',
  platform = process.platform,
  arch = process.arch,
}) {
  return sha256(JSON.stringify({
    executablePath,
    size: String(size),
    modifiedNanoseconds: String(modifiedNanoseconds),
    changedNanoseconds: String(changedNanoseconds),
    developerDirectory,
    toolchains,
    sdkRoot,
    platform,
    arch,
  }));
}

function selectedSwiftToolchainIdentity(env, version) {
  const result = spawnSync('xcrun', ['--find', 'swift'], { encoding: 'utf8', env });
  if (result.status !== 0) {
    return sha256(JSON.stringify({
      swiftVersion: version.trim(),
      developerDirectory: env.DEVELOPER_DIR || '',
      toolchains: env.TOOLCHAINS || '',
      sdkRoot: env.SDKROOT || '',
      platform: process.platform,
      arch: process.arch,
    }));
  }
  const executablePath = result.stdout.trim();
  const stat = fs.statSync(executablePath, { bigint: true });
  return swiftToolchainMetadataIdentity({
    executablePath,
    size: stat.size,
    modifiedNanoseconds: stat.mtimeNs,
    changedNanoseconds: stat.ctimeNs,
    developerDirectory: env.DEVELOPER_DIR,
    toolchains: env.TOOLCHAINS,
    sdkRoot: env.SDKROOT,
  });
}

export function dependencyState(root = REPO_ROOT) {
  const manifest = fs.readFileSync(path.join(root, 'Package.swift'));
  const resolvedPath = path.join(root, 'Package.resolved');
  let resolved;
  let hasResolvedFile;
  try {
    resolved = fs.readFileSync(resolvedPath);
    hasResolvedFile = true;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    resolved = Buffer.from('(no Package.resolved)');
    hasResolvedFile = false;
  }
  return {
    hasResolvedFile,
    contents: Buffer.concat([
      Buffer.from('Package.swift\0'),
      manifest,
      Buffer.from('\0Package.resolved\0'),
      resolved,
    ]),
  };
}

export function cacheRoot(env = process.env) {
  if (env.NIGHTDRIVE_SWIFT_CACHE_DIR) return path.resolve(env.NIGHTDRIVE_SWIFT_CACHE_DIR);
  return path.join(os.tmpdir(), 'nightdrive-swift-cache', CACHE_SCHEMA);
}

function cacheContext(env = process.env, root = REPO_ROOT) {
  const version = swiftVersion();
  const toolchainIdentity = selectedSwiftToolchainIdentity(env, version);
  const dependencies = dependencyState(root);
  const key = makeCacheKey({
    swiftVersion: version,
    dependencyContents: dependencies.contents,
    selectedToolchainIdentity: toolchainIdentity,
  });
  const rootPath = cacheRoot(env);
  const keyPath = path.join(rootPath, 'keys', key);
  return {
    dependencies,
    key,
    rootPath,
    keyPath,
    moduleCachePath: path.join(keyPath, 'module-cache'),
    slotsPath: path.join(rootPath, 'slots'),
    swiftVersion: version.trim(),
    toolchainIdentity,
  };
}

function hasOption(args, names) {
  return args.some((arg) => names.includes(arg) || names.some((name) => arg.startsWith(`${name}=`)));
}

function splitExecutableArguments(args) {
  const separator = args.indexOf('--');
  return separator < 0
    ? { swiftArguments: args, executableArguments: [] }
    : {
        swiftArguments: args.slice(0, separator),
        executableArguments: args.slice(separator),
      };
}

export function createSwiftArguments(command, args, {
  jobs = recommendedJobCount({ logicalCores: hostLogicalCoreCount() }),
  useResolvedVersions = false,
  disableSandbox = false,
  debugInfoFormat = null,
} = {}) {
  if (!SUPPORTED_COMMANDS.has(command)) return [command, ...args];

  const { swiftArguments, executableArguments } = splitExecutableArguments(args);
  const defaults = [];
  if (BUILDING_COMMANDS.has(command)) {
    if (!hasOption(swiftArguments, ['--jobs', '-j'])) defaults.push('--jobs', String(jobs));
    if (useResolvedVersions &&
        !hasOption(swiftArguments, [
          '--only-use-versions-from-resolved-file',
          '--force-resolved-versions',
        ])) {
      defaults.push('--only-use-versions-from-resolved-file');
    }
    // llbuild keys every compile on its exact command line, so a checkout that
    // alternates between flag sets recompiles the whole target each way. Every
    // entry point therefore asks for the same debug information, and the fast
    // answer — none — is the default because verification never debugs.
    if (debugInfoFormat && !hasOption(swiftArguments, ['-debug-info-format'])) {
      defaults.push('-debug-info-format', debugInfoFormat);
    }
  }
  if (disableSandbox && !hasOption(swiftArguments, ['--disable-sandbox'])) {
    defaults.push('--disable-sandbox');
  }
  return [command, ...defaults, ...swiftArguments, ...executableArguments];
}

function booleanOverride(value) {
  if (value === undefined || value === '') return null;
  if (['1', 'true', 'yes', 'on'].includes(value.toLowerCase())) return true;
  if (['0', 'false', 'no', 'off'].includes(value.toLowerCase())) return false;
  throw new Error(
    'NIGHTDRIVE_SWIFTPM_DISABLE_SANDBOX must be true/false, yes/no, on/off, or 1/0.',
  );
}

/// Debug information is the one build setting a verification run never needs
/// and pays for twice: emitting it costs about a third of a cold debug build,
/// and disagreeing about it between entry points costs a full recompile. Debug
/// builds therefore omit it unless someone is about to attach a debugger.
export function debugInfoFormatFor({ configuration, override } = {}) {
  if (override !== undefined && override !== '') {
    if (!DEBUG_INFO_FORMATS.includes(override)) {
      throw new Error(
        `NIGHTDRIVE_DEBUG_INFO_FORMAT must be one of ${DEBUG_INFO_FORMATS.join(', ')}.`,
      );
    }
    return override;
  }
  return configuration === 'debug' ? 'none' : null;
}

export function shouldDisableSandbox({
  platform = process.platform,
  override,
  probe = () => spawnSync(
    '/usr/bin/sandbox-exec',
    ['-p', '(version 1) (allow default)', '/usr/bin/true'],
    { stdio: 'ignore' },
  ),
} = {}) {
  const explicit = booleanOverride(override);
  if (explicit !== null) return explicit;
  if (platform !== 'darwin') return false;
  const result = probe();
  return result.status !== 0;
}

function processState(pid) {
  try {
    process.kill(pid, 0);
    return 'alive';
  } catch (error) {
    return error?.code === 'EPERM' ? 'unknown' : 'dead';
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

export function repairRelocatedSwiftPMArtifacts({ root = REPO_ROOT } = {}) {
  const stateFile = path.join(root, '.build', 'workspace-state.json');
  const state = readJson(stateFile);
  const artifacts = state?.object?.artifacts;
  if (!Array.isArray(artifacts)) return 0;

  const artifactRoot = path.join(root, '.build', 'artifacts');
  const artifactSegment = `${path.sep}.build${path.sep}artifacts${path.sep}`;
  let repaired = 0;
  for (const artifact of artifacts) {
    const previousPath = artifact?.path;
    if (typeof previousPath !== 'string' ||
        !path.isAbsolute(previousPath) ||
        fs.existsSync(previousPath)) {
      continue;
    }

    const segmentIndex = previousPath.lastIndexOf(artifactSegment);
    if (segmentIndex < 0) continue;
    const relative = previousPath.slice(segmentIndex + artifactSegment.length);
    const relocatedPath = path.resolve(artifactRoot, relative);
    const relativeToArtifactRoot = path.relative(artifactRoot, relocatedPath);
    if (relativeToArtifactRoot.startsWith(`..${path.sep}`) ||
        relativeToArtifactRoot === '..' ||
        path.isAbsolute(relativeToArtifactRoot) ||
        !fs.existsSync(relocatedPath)) {
      continue;
    }

    artifact.path = relocatedPath;
    repaired += 1;
  }

  if (repaired > 0) {
    fs.writeFileSync(stateFile, `${JSON.stringify(state, null, 2)}\n`);
  }
  return repaired;
}

function activeSlotFiles(context) {
  if (!fs.existsSync(context.slotsPath)) return [];
  const active = [];
  for (const entry of fs.readdirSync(context.slotsPath)) {
    if (!/^slot-[0-9]+\.lock$/.test(entry)) continue;
    const file = path.join(context.slotsPath, entry);
    const info = readJson(file);
    const state = info?.pid ? processState(info.pid) : 'dead';
    if (state === 'dead') {
      try {
        fs.rmSync(file);
      } catch {
      }
    } else {
      active.push(file);
    }
  }
  return active;
}

function maintenanceLockPath(context) {
  return path.join(context.slotsPath, 'maintenance.lock');
}

function maintenanceIsActive(context) {
  const file = maintenanceLockPath(context);
  const info = readJson(file);
  if (!info) {
    fs.rmSync(file, { force: true });
    return false;
  }
  if (processState(info.pid) !== 'dead') return true;
  fs.rmSync(file, { force: true });
  return false;
}

function acquireMaintenanceLock(context) {
  fs.mkdirSync(context.slotsPath, { recursive: true });
  const file = maintenanceLockPath(context);
  const token = crypto.randomUUID();
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const fd = fs.openSync(file, 'wx', 0o600);
      fs.writeFileSync(
        fd,
        `${JSON.stringify({
          pid: process.pid,
          token,
          startedAt: new Date().toISOString(),
        })}\n`,
      );
      fs.closeSync(fd);
      return {
        release() {
          const current = readJson(file);
          if (current?.token === token) fs.rmSync(file, { force: true });
        },
      };
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      if (maintenanceIsActive(context)) {
        throw new Error('Shared Swift cache maintenance is already running.');
      }
    }
  }
  throw new Error('Could not acquire the shared Swift cache maintenance lock.');
}

async function acquireSlot(context, slotCount) {
  fs.mkdirSync(context.slotsPath, { recursive: true });
  const token = crypto.randomUUID();
  let lastNotice = 0;
  while (true) {
    if (maintenanceIsActive(context)) {
      if (Date.now() - lastNotice > 15_000) {
        console.error('[swiftpm] Waiting for shared Swift cache maintenance…');
        lastNotice = Date.now();
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
      continue;
    }
    activeSlotFiles(context);
    for (let index = 0; index < slotCount; index += 1) {
      const file = path.join(context.slotsPath, `slot-${index}.lock`);
      try {
        const fd = fs.openSync(file, 'wx', 0o600);
        fs.writeFileSync(
          fd,
          `${JSON.stringify({
            pid: process.pid,
            token,
            startedAt: new Date().toISOString(),
          })}\n`,
        );
        fs.closeSync(fd);
        const slot = {
          release() {
            const current = readJson(file);
            if (current?.token === token) fs.rmSync(file, { force: true });
          },
          // How many slots — this one included — were held once it was taken.
          // Sizing compiler jobs from the real contention rather than from the
          // slot ceiling lets a lone verification run use the whole machine.
          activeCount: Math.max(1, activeSlotFiles(context).length),
        };
        if (maintenanceIsActive(context)) {
          slot.release();
          break;
        }
        return slot;
      } catch (error) {
        if (error?.code !== 'EEXIST') throw error;
      }
    }
    if (Date.now() - lastNotice > 15_000) {
      console.error(`[swiftpm] Waiting for one of ${slotCount} shared verification slots…`);
      lastNotice = Date.now();
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}

function terminateProcessGroup(child, signal) {
  if (!child.pid) return;
  try {
    process.kill(-child.pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
    }
  }
}

function runOnce(args, env, watchdogMs) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    let lastOutputAt = startedAt;
    let watchdogFired = false;
    let settled = false;
    const child = spawn('swift', args, {
      cwd: REPO_ROOT,
      env,
      detached: true,
      stdio: ['inherit', 'pipe', 'pipe'],
    });
    child.stdout.on('data', (chunk) => {
      lastOutputAt = Date.now();
      process.stdout.write(chunk);
    });
    child.stderr.on('data', (chunk) => {
      lastOutputAt = Date.now();
      process.stderr.write(chunk);
    });

    const interval = setInterval(() => {
      if (watchdogFired || Date.now() - lastOutputAt < watchdogMs) return;
      watchdogFired = true;
      console.error(
        `[swiftpm] No output for ${Math.round(watchdogMs / 1000)}s; terminating the wedged process.`,
      );
      terminateProcessGroup(child, 'SIGTERM');
      setTimeout(() => terminateProcessGroup(child, 'SIGKILL'), 5_000).unref();
    }, Math.min(1_000, watchdogMs));

    const forwardInterrupt = () => terminateProcessGroup(child, 'SIGINT');
    const forwardTermination = () => terminateProcessGroup(child, 'SIGTERM');
    const cleanup = () => {
      clearInterval(interval);
      process.off('SIGINT', forwardInterrupt);
      process.off('SIGTERM', forwardTermination);
    };
    process.once('SIGINT', forwardInterrupt);
    process.once('SIGTERM', forwardTermination);
    child.on('error', (error) => {
      cleanup();
      if (settled) return;
      settled = true;
      reject(error);
    });
    child.on('close', (code, signal) => {
      cleanup();
      if (settled) return;
      settled = true;
      resolve({
        code: code ?? 1,
        signal,
        watchdogFired,
        elapsedMs: Date.now() - startedAt,
      });
    });
  });
}

export async function runWithWatchdogRetry(run, onRetry = () => {}) {
  let result = await run();
  if (result.watchdogFired) {
    onRetry(result);
    result = await run();
  }
  return result;
}

function configurationFromArgs(args) {
  const index = args.findIndex((arg) => arg === '-c' || arg === '--configuration');
  if (index >= 0 && args[index + 1]) return args[index + 1];
  const inline = args.find(
    (arg) => arg.startsWith('--configuration=') || arg.startsWith('-c='),
  );
  return inline ? inline.split('=', 2)[1] : 'debug';
}

function markerPath(args, root = REPO_ROOT) {
  const kind = args.includes('--build-tests') ? 'tests' : 'build';
  return path.join(
    root,
    '.build',
    'nightdrive-verification',
    `${configurationFromArgs(args)}-${kind}.json`,
  );
}

function recordsDefaultBuild(args) {
  return !hasOption(args, [
    '--product',
    '--target',
    '--package-path',
    '--scratch-path',
    '--build-path',
    '--build-system',
    '--multiroot-data-file',
    '--destination',
    '--triple',
    '--sdk',
    '--toolchain',
    '--arch',
  ]) && !args.includes('--show-bin-path');
}

function buildInputEntries(root, buildsTests) {
  const entries = [];

  function visit(relative, ancestorDirectories = new Set()) {
    const absolute = path.join(root, relative);
    let stat;
    try {
      stat = fs.lstatSync(absolute);
    } catch (error) {
      if (error?.code === 'ENOENT') return;
      throw error;
    }

    if (stat.isSymbolicLink()) {
      entries.push({
        kind: 'symlink',
        relative,
        contents: Buffer.from(fs.readlinkSync(absolute)),
      });
      let targetStat;
      try {
        targetStat = fs.statSync(absolute);
      } catch {
        return;
      }
      if (targetStat.isFile()) {
        entries.push({
          kind: 'file',
          relative: `${relative}\0symlink-target`,
          contents: fs.readFileSync(absolute),
        });
        return;
      }
      if (!targetStat.isDirectory()) return;
    } else if (stat.isFile()) {
      entries.push({ kind: 'file', relative, contents: fs.readFileSync(absolute) });
      return;
    } else if (!stat.isDirectory()) {
      return;
    }

    const realDirectory = fs.realpathSync(absolute);
    if (ancestorDirectories.has(realDirectory)) {
      entries.push({
        kind: 'directory-cycle',
        relative,
        contents: Buffer.from(realDirectory),
      });
      return;
    }
    const descendants = new Set(ancestorDirectories);
    descendants.add(realDirectory);
    for (const child of fs.readdirSync(absolute).sort()) {
      visit(path.join(relative, child), descendants);
    }
  }

  const manifests = fs.readdirSync(root)
    .filter((name) => name.startsWith('Package') && name.endsWith('.swift'))
    .sort();
  for (const manifest of manifests) visit(manifest);
  visit('Package.resolved');
  visit('Sources');
  visit('Resources');
  visit('Plugins');
  if (buildsTests) visit('Tests');
  return entries.sort((left, right) => {
    const byPath = left.relative.localeCompare(right.relative);
    return byPath === 0 ? left.kind.localeCompare(right.kind) : byPath;
  });
}

export function buildInputFingerprint({
  root = REPO_ROOT,
  buildsTests = false,
} = {}) {
  const hash = crypto.createHash('sha256');
  for (const entry of buildInputEntries(root, buildsTests)) {
    hash.update(entry.kind);
    hash.update('\0');
    hash.update(entry.relative);
    hash.update('\0');
    hash.update(entry.contents);
    hash.update('\0');
  }
  return hash.digest('hex');
}

function isExecutableFile(file) {
  try {
    const stat = fs.statSync(file);
    return stat.isFile() && (stat.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

function isExecutableTestBundle(file) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    return false;
  }
  if (stat.isFile()) return (stat.mode & 0o111) !== 0;
  if (!stat.isDirectory()) return false;
  const executableDirectory = path.join(file, 'Contents', 'MacOS');
  try {
    return fs.readdirSync(executableDirectory)
      .some((name) => isExecutableFile(path.join(executableDirectory, name)));
  } catch {
    return false;
  }
}

export function discoverBuildArtifacts(binPath, buildsTests = false) {
  let names;
  try {
    names = fs.readdirSync(binPath).sort();
  } catch {
    return [];
  }
  if (buildsTests) {
    return names
      .filter((name) => name.endsWith('.xctest'))
      .filter((name) => isExecutableTestBundle(path.join(binPath, name)))
      .map((relative) => ({ kind: 'xctest', relative }));
  }
  return names
    .filter((name) => !name.endsWith('.xctest'))
    .filter((name) => isExecutableFile(path.join(binPath, name)))
    .map((relative) => ({ kind: 'executable', relative }));
}

export function buildArtifactsExist(binPath, artifacts, buildsTests = false) {
  if (!binPath || !Array.isArray(artifacts) || artifacts.length === 0) return false;
  const expectedKind = buildsTests ? 'xctest' : 'executable';
  return artifacts.every((artifact) => {
    if (artifact?.kind !== expectedKind ||
        !artifact.relative ||
        path.basename(artifact.relative) !== artifact.relative) {
      return false;
    }
    const file = path.join(binPath, artifact.relative);
    return buildsTests ? isExecutableTestBundle(file) : isExecutableFile(file);
  });
}

export function buildMarkerCanBeReused({
  args,
  marker,
  inputFingerprint,
  cacheKey,
  toolchainIdentity,
  debugInfoFormat = null,
  artifactsExist,
}) {
  const buildsTests = args.includes('--build-tests');
  return recordsDefaultBuild(args) &&
    marker?.schema === MARKER_SCHEMA &&
    marker.cacheSchema === CACHE_SCHEMA &&
    marker.buildsTests === buildsTests &&
    marker.inputFingerprint === inputFingerprint &&
    marker.cacheKey === cacheKey &&
    marker.toolchainIdentity === toolchainIdentity &&
    (marker.debugInfoFormat ?? null) === debugInfoFormat &&
    JSON.stringify(marker.arguments) === JSON.stringify(args) &&
    artifactsExist;
}

function markerIsReusable(args, context, swiftDefaults, root = REPO_ROOT) {
  if (!recordsDefaultBuild(args)) return null;
  const marker = readJson(markerPath(args, root));
  const buildsTests = args.includes('--build-tests');
  const reusable = buildMarkerCanBeReused({
    args,
    marker,
    inputFingerprint: buildInputFingerprint({ root, buildsTests }),
    cacheKey: context.key,
    toolchainIdentity: context.toolchainIdentity,
    debugInfoFormat: swiftDefaults.debugInfoFormat ?? null,
    artifactsExist: buildArtifactsExist(marker?.binPath, marker?.artifacts, buildsTests),
  });
  return reusable ? marker : null;
}

function showBinPath(configuration, env, swiftDefaults) {
  const args = createSwiftArguments(
    'build',
    ['-c', configuration, '--show-bin-path'],
    swiftDefaults,
  );
  const result = spawnSync(
    'swift',
    args,
    { cwd: REPO_ROOT, env, encoding: 'utf8' },
  );
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || 'Could not locate SwiftPM build products.');
  }
  return result.stdout.trim();
}

function writeBuildMarker(args, env, context, swiftDefaults, fingerprintBefore) {
  if (!recordsDefaultBuild(args)) return;
  const buildsTests = args.includes('--build-tests');
  // A source edited while the build ran was not what the artifacts were
  // compiled from, so record nothing and let the next run rebuild.
  const inputFingerprint = buildInputFingerprint({ buildsTests });
  if (fingerprintBefore !== undefined && inputFingerprint !== fingerprintBefore) {
    fs.rmSync(markerPath(args), { force: true });
    return;
  }
  const binPath = showBinPath(configurationFromArgs(args), env, swiftDefaults);
  const artifacts = discoverBuildArtifacts(binPath, buildsTests);
  const file = markerPath(args);
  if (artifacts.length === 0) {
    fs.rmSync(file, { force: true });
    return;
  }
  const marker = {
    schema: MARKER_SCHEMA,
    cacheSchema: CACHE_SCHEMA,
    buildsTests,
    configuration: configurationFromArgs(args),
    inputFingerprint,
    cacheKey: context.key,
    toolchainIdentity: context.toolchainIdentity,
    debugInfoFormat: swiftDefaults.debugInfoFormat ?? null,
    binPath,
    artifacts,
    arguments: args,
    completedAt: new Date().toISOString(),
  };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(marker, null, 2)}\n`);
}

function directorySize(root) {
  let total = 0;
  if (!fs.existsSync(root)) return total;
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const file = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(file);
      else {
        try {
          total += fs.statSync(file).size;
        } catch {
        }
      }
    }
  }
  return total;
}

function humanBytes(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function cacheStatus(context) {
  const keysPath = path.join(context.rootPath, 'keys');
  const keys = fs.existsSync(keysPath) ? fs.readdirSync(keysPath) : [];
  console.log(`Shared Swift cache: ${context.rootPath}`);
  console.log(`Current key: ${context.key}`);
  console.log(`Swift toolchain: ${context.swiftVersion}`);
  console.log(`Package.resolved: ${context.dependencies.hasResolvedFile ? 'present' : 'absent'}`);
  console.log(`Cache keys: ${keys.length}; size: ${humanBytes(directorySize(keysPath))}`);
  console.log(`Active verification slots: ${activeSlotFiles(context).length}`);
}

function cachePrune(context, maxAgeDays) {
  const maintenance = acquireMaintenanceLock(context);
  try {
    if (activeSlotFiles(context).length > 0) {
      throw new Error('Cannot prune while shared verification slots are active.');
    }
    const keysPath = path.join(context.rootPath, 'keys');
    if (!fs.existsSync(keysPath)) {
      console.log('No shared Swift cache to prune.');
      return;
    }
    const cutoff = Date.now() - maxAgeDays * 24 * 60 * 60 * 1000;
    let removed = 0;
    for (const key of fs.readdirSync(keysPath)) {
      if (key === context.key) continue;
      const keyPath = path.join(keysPath, key);
      const lastUsed = path.join(keyPath, 'last-used');
      let modified = 0;
      try {
        modified = fs.statSync(lastUsed).mtimeMs;
      } catch {
        try {
          modified = fs.statSync(keyPath).mtimeMs;
        } catch {
          continue;
        }
      }
      if (modified < cutoff) {
        fs.rmSync(keyPath, { recursive: true, force: true });
        removed += 1;
      }
    }
    console.log(`Pruned ${removed} shared Swift cache key(s) older than ${maxAgeDays} day(s).`);
  } finally {
    maintenance.release();
  }
}

function formatDuration(milliseconds) {
  return `${(milliseconds / 1000).toFixed(1)}s`;
}

function makeSwiftDefaults({ context, configuration, jobs }) {
  return {
    jobs,
    useResolvedVersions: context.dependencies.hasResolvedFile,
    disableSandbox: shouldDisableSandbox({
      override: process.env.NIGHTDRIVE_SWIFTPM_DISABLE_SANDBOX,
    }),
    debugInfoFormat: debugInfoFormatFor({
      configuration,
      override: process.env.NIGHTDRIVE_DEBUG_INFO_FORMAT,
    }),
  };
}

/// Compiler jobs for a run that holds `activeSlots` of the shared slots. The
/// environment override wins so a machine under other load can be pinned.
export function jobsForActiveSlots(activeSlots, {
  logicalCores = hostLogicalCoreCount(),
  override = process.env.NIGHTDRIVE_SWIFT_JOBS,
} = {}) {
  return positiveInteger(
    override,
    recommendedJobCount({
      logicalCores,
      slotCount: activeSlots,
      maxJobs: logicalCores,
    }),
  );
}

async function main(argv = process.argv.slice(2)) {
  const [command, ...inputArgs] = argv;
  if (!command) {
    console.error(
      'Usage: run-swiftpm.mjs <build|test|run|marker-bin-path|cache-status|cache-prune|cache-key-path> [arguments…]',
    );
    return 2;
  }

  const context = cacheContext();
  if (command === 'marker-bin-path') {
    const configuration = inputArgs[0] || 'debug';
    const file = markerPath(['-c', configuration]);
    const marker = readJson(file);
    if (!marker?.arguments) {
      throw new Error(`No verified ${configuration} build marker exists.`);
    }
    const defaults = makeSwiftDefaults({
      context,
      configuration,
      jobs: jobsForActiveSlots(DEFAULT_SLOTS),
    });
    if (markerIsReusable(marker.arguments, context, defaults) !== null) {
      console.log(marker.binPath);
      return 0;
    }
    throw new Error(
      `The verified ${configuration} build is stale; run the default build again.`,
    );
  }
  if (command === 'cache-status') {
    cacheStatus(context);
    return 0;
  }
  if (command === 'cache-prune') {
    cachePrune(
      context,
      positiveInteger(
        process.env.NIGHTDRIVE_CACHE_MAX_AGE_DAYS,
        DEFAULT_MAX_AGE_DAYS,
      ),
    );
    return 0;
  }
  if (command === 'cache-key-path') {
    console.log(context.keyPath);
    return 0;
  }
  if (!SUPPORTED_COMMANDS.has(command)) {
    console.error(`Unsupported SwiftPM command: ${command}`);
    return 2;
  }

  const repairedArtifacts = repairRelocatedSwiftPMArtifacts();
  if (repairedArtifacts > 0) {
    console.error(
      `[swiftpm] Repaired ${repairedArtifacts} dependency artifact path(s) after checkout relocation.`,
    );
  }

  fs.mkdirSync(context.moduleCachePath, { recursive: true });
  fs.writeFileSync(path.join(context.keyPath, 'last-used'), `${new Date().toISOString()}\n`);

  const slotCount = positiveInteger(
    process.env.NIGHTDRIVE_SWIFTPM_SLOTS,
    DEFAULT_SLOTS,
  );
  const watchdogSeconds = positiveInteger(
    process.env.NIGHTDRIVE_SWIFTPM_WATCHDOG_SECONDS,
    DEFAULT_WATCHDOG_SECONDS,
  );
  const configuration = configurationFromArgs(inputArgs);
  const env = {
    ...process.env,
    CLANG_MODULE_CACHE_PATH: context.moduleCachePath,
    SWIFTPM_MODULECACHE_OVERRIDE: context.moduleCachePath,
  };

  // A query, not work: answer it from the verified build rather than paying
  // for another SwiftPM manifest load, and never take a slot for it.
  const skipsWork = inputArgs.includes('--show-bin-path');
  if (command === 'build' && skipsWork) {
    const buildArgs = inputArgs.filter((argument) => argument !== '--show-bin-path');
    const defaults = makeSwiftDefaults({
      context,
      configuration,
      jobs: jobsForActiveSlots(slotCount),
    });
    const marker = markerIsReusable(buildArgs, context, defaults);
    if (marker) {
      console.log(marker.binPath);
      return 0;
    }
    console.log(showBinPath(configuration, env, defaults));
    return 0;
  }

  if (command === 'build') {
    const defaults = makeSwiftDefaults({
      context,
      configuration,
      jobs: jobsForActiveSlots(slotCount),
    });
    const marker = markerIsReusable(inputArgs, context, defaults);
    if (marker) {
      console.error(
        inputArgs.includes('--build-tests')
          ? '[swiftpm] Inputs unchanged; reusing the verified test build.'
          : '[swiftpm] Inputs unchanged; reusing the verified executable build.',
      );
      return 0;
    }
  }

  const slot = await acquireSlot(context, slotCount);
  try {
    const swiftDefaults = makeSwiftDefaults({
      context,
      configuration,
      jobs: jobsForActiveSlots(slot.activeCount),
    });
    if (repairedArtifacts > 0 && BUILDING_COMMANDS.has(command)) {
      console.error(
        '[swiftpm] Cleaning non-relocatable compiler outputs from the previous checkout path.',
      );
      const clean = spawnSync('swift', ['package', 'clean'], {
        cwd: REPO_ROOT,
        env,
        stdio: 'inherit',
      });
      if (clean.error) throw clean.error;
      if (clean.status !== 0) return clean.status ?? 1;
    }
    const args = createSwiftArguments(command, inputArgs, swiftDefaults);
    const fingerprintBefore =
      command === 'build' && recordsDefaultBuild(inputArgs)
        ? buildInputFingerprint({ buildsTests: inputArgs.includes('--build-tests') })
        : undefined;
    console.error(
      `[swiftpm] swift ${args.join(' ')} (shared cache ${context.key}, jobs ${swiftDefaults.jobs})`,
    );
    const result = await runWithWatchdogRetry(
      () => runOnce(args, env, watchdogSeconds * 1000),
      (firstResult) => {
        console.error(
          `[swiftpm] Retrying once after watchdog termination (${formatDuration(firstResult.elapsedMs)}).`,
        );
      },
    );
    console.error(`[swiftpm] Finished in ${formatDuration(result.elapsedMs)}.`);
    if (result.code === 0 && command === 'build') {
      writeBuildMarker(inputArgs, env, context, swiftDefaults, fingerprintBefore);
    }
    return result.code;
  } finally {
    slot.release();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = await main();
  } catch (error) {
    console.error(`[swiftpm] ${error.message}`);
    process.exitCode = 1;
  }
}
