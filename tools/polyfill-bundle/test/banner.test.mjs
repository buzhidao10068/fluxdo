import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import { generatedHeader as header, replaceBanner } from '../banner.mjs';

const banner = readFileSync(new URL('../src/_banner.js', import.meta.url), 'utf8');
const artifact = readFileSync(
  new URL('../../../assets/polyfill/compat-polyfill.js', import.meta.url),
  'utf8',
);
const normalizedArtifact = artifact.replace(/\r\n/g, '\n');
const generatedBanner = normalizedArtifact
  .slice(header.length, header.length + banner.replace(/\r\n/g, '\n').length);

test('入仓产物的 banner 与源码同步', () => {
  assert.ok(normalizedArtifact.startsWith(header));
  assert.equal(generatedBanner, banner.replace(/\r\n/g, '\n'));
});

test('banner 增量生成保持依赖 bundle 字节不变，可重复执行且兼容 CRLF', () => {
  const bundle = '(()=>{const sample = "保留\\r\\n";})();\r\n';
  const old = header.replace(/\n/g, '\r\n') + '// 旧 banner\r\n\r\n' + bundle;
  const updated = replaceBanner(old, '// 新 banner\n');
  assert.equal(updated.artifact, header + '// 新 banner\n\n' + bundle);
  assert.deepEqual(replaceBanner(updated.artifact, '// 新 banner\n'), updated);
});

test('banner 增量生成遇到未知产物格式时拒绝写入', () => {
  assert.throws(() => replaceBanner('unknown', banner));
  assert.throws(() => replaceBanner(header + 'unknown bundle', banner));
});

for (const [name, code] of [['源码', banner], ['入仓产物', generatedBanner]]) {
  test(`${name}：缺失 head 时插入一次，保留已有首节点`, () => {
    const firstChild = {};
    let calls = 0;
    const document = {
      head: null,
      createElement: (tag) => ({ tag }),
      documentElement: {
        firstChild,
        insertBefore(node, before) {
          calls++;
          assert.equal(node.tag, 'head');
          assert.equal(before, firstChild);
          document.head = node;
        },
      },
    };
    const context = vm.createContext({ document });
    vm.runInContext(code, context);
    vm.runInContext(code, context);
    assert.equal(calls, 1);
  });

  test(`${name}：保留既有 head，无 DOM 或 DOM 异常时容错`, () => {
    const head = {};
    const document = {
      head,
      documentElement: {},
      createElement() { throw new Error('不应调用'); },
    };
    vm.runInNewContext(code, { document });
    assert.equal(document.head, head);
    assert.doesNotThrow(() => vm.runInNewContext(code));
    assert.doesNotThrow(() => vm.runInNewContext(code, {
      document: { documentElement: {}, createElement() { throw new Error('DOM 未就绪'); } },
    }));
  });

  test(`${name}：保留原生 setAttribute，脚本资源不被添加 crossorigin`, () => {
    class Element {
      tagName = 'SCRIPT';
      attributes = {};
      setAttribute(name, value) { this.attributes[name] = value; }
      hasAttribute(name) { return name in this.attributes; }
    }
    const original = Element.prototype.setAttribute;
    vm.runInNewContext(code, { Element });
    assert.equal(Element.prototype.setAttribute, original);
    for (const src of [
      'https://www.nodeloc.com/assets/app.js',
      'https://cdn.ldstatic.com/assets/app.js',
      'https://third-party.example.com/app.js',
    ]) {
      const script = new Element();
      script.setAttribute('src', src);
      assert.deepEqual(script.attributes, { src });
    }
  });
}
