// src/ 를 번들링해 인터넷 없이 열리는 HTML 파일 하나(dist/MD-Studio.html)로 만든다.
import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';

const pkg = JSON.parse(await readFile('package.json', 'utf8'));
const started = Date.now();

const result = await build({
  entryPoints: ['src/main.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['chrome110', 'safari16', 'firefox115'],
  write: false,
  legalComments: 'none',
  charset: 'utf8',
  define: { __APP_VERSION__: JSON.stringify(pkg.version) },
  logLevel: 'warning',
});

const js = result.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
const css = await readFile('src/styles.css', 'utf8');
const template = await readFile('src/index.html', 'utf8');

if (!template.includes('/*__CSS__*/') || !template.includes('/*__JS__*/')) {
  throw new Error('index.html 에 /*__CSS__*/ 또는 /*__JS__*/ 자리표시자가 없습니다');
}
// 함수형 치환: 번들 안의 "$&" 같은 문자열이 치환 패턴으로 해석되지 않도록 한다.
const html = template.replace('/*__CSS__*/', () => css).replace('/*__JS__*/', () => js);

await mkdir('dist', { recursive: true });
await writeFile('dist/MD-Studio.html', html);
console.log(`dist/MD-Studio.html 생성 (${(html.length / 1024).toFixed(0)} KB, ${Date.now() - started}ms, v${pkg.version})`);
