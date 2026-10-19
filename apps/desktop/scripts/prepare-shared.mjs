import { copyFile, cp, mkdir, lstat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const app = fileURLToPath(new URL('..', import.meta.url));
const source = resolve(app, '../../design-system');
const target = resolve(app, '.generated/shared');
await mkdir(target, { recursive: true });
if ((await lstat(target)).isSymbolicLink()) throw new Error('Shared asset output must not be a symlink.');
for (const name of ['appearance.css', 'typography.css', 'components.css', 'controls.css', 'desktop-preview.css', 'components.js', 'controls.js', 'icons.js']) {
  await copyFile(resolve(source, name), resolve(target, name));
}
await cp(resolve(source, 'vendor/lucide'), resolve(target, 'vendor/lucide'), { recursive: true });
