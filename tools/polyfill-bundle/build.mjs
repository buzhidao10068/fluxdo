// 两步打包：
// 1) @babel/preset-env (useBuiltIns: 'entry') 把 `import 'core-js/stable'` 按 browserslist
//    展开成精确的 `import 'core-js/modules/<feature>'` 列表 (只挑 iOS 15+ 缺的)
// 2) esbuild bundle 成 IIFE，作为 Flutter asset 注入 InAppWebView.initialUserScripts
import { generatedHeader, replaceBanner } from './banner.mjs';
import { readFile, writeFile, mkdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '../..');
const outFile = path.join(projectRoot, 'assets/polyfill/compat-polyfill.js');
const bannerSource = await readFile(path.join(__dirname, 'src/_banner.js'), 'utf8');
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--banner-only') {
  const result = replaceBanner(await readFile(outFile, 'utf8'), bannerSource);
  await writeFile(outFile, result.artifact);
  console.log(`✓ 已同步 banner；依赖 bundle SHA-256: ${result.bundleHash}`);
  process.exit(0);
}
if (args.length) throw new Error('仅支持 --banner-only 或不传参数的完整构建');

// 仅修改 banner 时无需加载 Babel / esbuild 或安装依赖。
const { transformAsync } = await import('@babel/core');
const esbuild = await import('esbuild');
const entryFile = path.join(__dirname, 'src/index.js');
// 必须放在 src/ 下，否则相对 import './error-reporter.js' 解析不到
const tmpEntry = path.join(__dirname, 'src/.tmp-entry.js');

// 跟 package.json 的 core-js devDep 对齐，preset-env 用它判断 polyfill 元数据版本
const corejsVersion = JSON.parse(
  await readFile(path.join(__dirname, 'package.json'), 'utf8'),
).devDependencies['core-js'].replace(/^[\^~]/, '');

await mkdir(path.dirname(outFile), { recursive: true });

try {
  // Step 1: Babel 展开 entry
  const entrySource = await readFile(entryFile, 'utf8');
  const { code } = await transformAsync(entrySource, {
    filename: entryFile,
    babelrc: false,
    configFile: false,
    presets: [
      [
        '@babel/preset-env',
        {
          useBuiltIns: 'entry',
          corejs: { version: corejsVersion, proposals: false },
          modules: false, // 保留 ES Modules 让 esbuild 处理
        },
      ],
    ],
  });
  await writeFile(tmpEntry, code);

  // Step 2: esbuild bundle IIFE
  await esbuild.build({
    entryPoints: [tmpEntry],
    bundle: true,
    format: 'iife',
    minify: true,
    target: ['safari15'],
    outfile: outFile,
    nodePaths: [path.join(__dirname, 'node_modules')],
    legalComments: 'none',
    // banner 是 bundle 最顶部、所有 import 副作用之前执行。
    // ensureHead 必须在 es-module-shims 启动前执行，见 src/_banner.js。
    banner: {
      js: generatedHeader + bannerSource,
    },
    logLevel: 'warning',
  });

  const { size } = await stat(outFile);
  const rel = path.relative(projectRoot, outFile);
  console.log(`✓ ${rel}  ${(size / 1024).toFixed(1)} KB minified`);
} finally {
  await rm(tmpEntry, { force: true });
}
