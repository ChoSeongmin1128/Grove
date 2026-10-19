import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
export default defineConfig({
  root: `${here}src`,
  publicDir: `${here}.generated`,
  clearScreen: false,
  build: {
    outDir: `${here}dist`,
    emptyOutDir: true,
    target: ['es2022', 'chrome110', 'safari15'],
    rollupOptions: {
      input: {
        main: `${here}src/index.html`,
        recorder: `${here}src/recorder.html`,
      },
    },
  },
});
