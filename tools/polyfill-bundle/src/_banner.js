// 这个文件不是 ES Module entry,build.mjs 读它的内容塞到 esbuild banner,
// 让它在 bundle 最顶部、所有 import 副作用之前执行。
//
// ensureHead 必须最早：es-module-shims 启动前 document.head 必须存在。
// NodeLoc 当前资源同源，移除旧站 CDN 的 SCRIPT.src / crossorigin 特例。
// 将来只有确认新 CDN 返回 ACAO 后，才能单独评估跨域错误诊断。

(function () {
  // ===== 1) ensureHead =====
  try {
    if (
      typeof document !== 'undefined' &&
      document.documentElement &&
      !document.head
    ) {
      document.documentElement.insertBefore(
        document.createElement('head'),
        document.documentElement.firstChild,
      );
    }
  } catch (e) {}

})();
