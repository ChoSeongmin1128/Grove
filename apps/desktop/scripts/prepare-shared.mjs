import { copyFile, cp, mkdir, lstat, readFile, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const app = fileURLToPath(new URL('..', import.meta.url));
const source = resolve(app, '../../design-system');
const target = resolve(app, '.generated/shared');
await mkdir(target, { recursive: true });
if ((await lstat(target)).isSymbolicLink()) throw new Error('Shared asset output must not be a symlink.');
for (const name of ['appearance.css', 'appearance.js', 'typography.css', 'components.css', 'controls.css', 'desktop-preview.css', 'components.js', 'controls.js', 'icons.js']) {
  await copyFile(resolve(source, name), resolve(target, name));
}
await cp(resolve(source, 'vendor/lucide'), resolve(target, 'vendor/lucide'), { recursive: true });

await mkdir(resolve(app, '.generated/native'), { recursive: true });

await mkdir(resolve(app, '.generated/brand'), { recursive: true });
await copyFile(resolve(app, 'brand/mark.svg'), resolve(app, '.generated/brand/mark.svg'));

const git = (...args) => execFileSync('git', args, { cwd: resolve(app, '../..'), encoding: 'utf8' }).trim();
const config = JSON.parse(await readFile(resolve(app, 'src-tauri/tauri.conf.json'), 'utf8'));
const release = resolve(app, '.generated/release');
await mkdir(release, { recursive: true });
await writeFile(resolve(release, 'build-info.json'), JSON.stringify({
  formatVersion: 1,
  version: config.version,
  build: config.bundle.macOS.bundleVersion,
  bundleIdentifier: config.identifier,
  sourceCommit: git('rev-parse', 'HEAD'),
  sourceTree: git('rev-parse', 'HEAD^{tree}'),
  sourceDirty: Boolean(git('status', '--porcelain', '--untracked-files=normal')),
  hostPlatform: process.platform,
  hostArchitecture: process.arch,
}, null, 2) + '\n');
