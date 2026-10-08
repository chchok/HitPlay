import XCTest
@testable import HitPlayCatSource

/// TVBox 单文件 JS 源识别：cat.js、drpy ESM 与 __JS_SPIDER__。
final class TVBoxJSSourceDetectionTests: XCTestCase {
    private var enginePackageSample: String {
        """
        const fastify = require('fastify');
        function start(config) { return fastify().listen(0); }
        function stop() {}
        module.exports = { start, stop };
        """
    }

    func testFongMiEvalReturnFormatIsDetected() {
        let sample = """
        import { cheerio, Crypto } from 'lib/cat.js';
        function __jsEvalReturn() {
          return { init: function(cfg) {}, home: function(f) { return {}; } };
        }
        export { __jsEvalReturn };
        """
        XCTAssertTrue(CatSourceStore.isTVBoxJSSource(sample))
    }

    func testJSSpiderGlobalFormatIsDetected() {
        let sample = """
        var spider = { init: function() {}, category: function(tid, pg) { return {}; } };
        __JS_SPIDER__ = spider;
        """
        XCTAssertTrue(CatSourceStore.isTVBoxJSSource(sample))
    }

    func testDrpyESMDefaultExportIsDetected() {
        let sample = """
        export default {
          init(cfg) {},
          home(filter) { return {}; },
          category(tid, pg, filter, ext) { return {}; },
          detail(id) { return {}; },
          play(flag, id, flags) { return {}; },
          search(wd, quick) { return {}; },
        };
        """
        XCTAssertTrue(CatSourceStore.isTVBoxJSSource(sample))
    }

    func testEnginePackageIsNotTVBoxSource() {
        XCTAssertFalse(CatSourceStore.isTVBoxJSSource(enginePackageSample))
    }

    /// 回归：引擎包 esbuild 产物（大文件及尾部 export 互操作块）
    /// 曾被宽松正则误判为 TVBox 源，导致用户真实订阅被改写成 source.js 失效。
    /// 引擎信号（require(/module.exports/catServerFactory）必须一票否决。
    func testBundledEnginePackageIsNotTVBoxSource() {
        let bundled = """
        globalThis.websiteBundle = function() { return `(function() {
          const exports = {}; const module = { exports };
          var Si=Object.create;var Ot=Object.defineProperty;
          const fastify = require('fastify');
          module.exports = { start };
          function start(config) { const server = catServerFactory((req,res)=>{}); server.listen(0); }
          export { run as default };
        })()` };
        """
        XCTAssertFalse(CatSourceStore.isTVBoxJSSource(bundled))
        // 即使不含显式 export default，只要出现引擎信号同样否决。
        XCTAssertFalse(CatSourceStore.isTVBoxJSSource("var app = require('express')(); app.get('/home', h);"))
    }

    func testPlainScriptWithoutSourceMarkersIsNotTVBoxSource() {
        XCTAssertFalse(CatSourceStore.isTVBoxJSSource("console.log('hello');\nfunction helper() { return 1; }\n"))
    }
}
