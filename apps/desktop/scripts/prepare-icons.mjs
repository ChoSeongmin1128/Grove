import { mkdir, readFile, writeFile, copyFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const desktop = fileURLToPath(new URL('../', import.meta.url));
const root = path.resolve(desktop, '../..');
const source = path.join(desktop, 'brand/mark.svg');
const stage = path.join(root, '.work/nero-brand-icons');
const icons = path.join(desktop, 'src-tauri/icons');
const cli = path.join(desktop, 'node_modules/@tauri-apps/cli/tauri.js');
await mkdir(stage, { recursive: true });
await mkdir(icons, { recursive: true });

function generate(input, output, sizes = []) {
  execFileSync(process.execPath, [cli, 'icon', input, '--output', output, ...sizes.flatMap(size => ['--png', String(size)])], { cwd: desktop, stdio: 'inherit' });
}

const svg = await readFile(source, 'utf8');
const background = await readFile(path.join(desktop, 'brand/app-background.svg'), 'utf8');
const artwork = svg.replace(/<svg\b[^>]*>/, '<g transform="translate(46.08 46.08) scale(.82)">').replace('</svg>', '</g>');
const application = path.join(stage, 'app-icon.svg');
await writeFile(application, background.replace('</svg>', `${artwork}</svg>`));
generate(application, path.join(stage, 'app'));
generate(application, path.join(stage, 'png'), [512]);
await copyFile(path.join(stage, 'app/icon.icns'), path.join(icons, 'icon.icns'));
await copyFile(path.join(stage, 'app/icon.ico'), path.join(icons, 'icon.ico'));
await copyFile(path.join(stage, 'png/512x512.png'), path.join(icons, 'icon.png'));

for (const [name, color, sizes] of [['on-light', '#000000', [32, 36]], ['on-dark', '#FFFFFF', [32]]]) {
  const input = path.join(stage, `${name}.svg`);
  await writeFile(input, svg.replace(/fill="#[\da-f]+"/gi, `fill="${color}"`));
  const output = path.join(stage, name);
  generate(input, output, sizes);
  await copyFile(path.join(output, '32x32.png'), path.join(icons, `tray-${name}.png`));
  if (name === 'on-light') await copyFile(path.join(output, '36x36.png'), path.join(icons, 'tray-template.png'));
}
