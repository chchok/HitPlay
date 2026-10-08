#!/usr/bin/env python3
"""HitPlay py源宿主。

加载 FongMi/TV 契约的 Spider（class Spider: init/homeContent/categoryContent/
detailContent/searchContent/playerContent），把请求映射到猫源开放协议：

    GET  /config                       → 站点列表（video.sites，含 api 基址）
    POST /spider/{key}/3/init          → spider.init(extend)
    POST /spider/{key}/3/home          → homeContent(filter) (+ homeVideoContent)
    POST /spider/{key}/3/category      → categoryContent(id, page, false, filters)
    POST /spider/{key}/3/detail        → detailContent([id])
    POST /spider/{key}/3/search        → searchContent(wd, False, page)
    POST /spider/{key}/3/play          → playerContent(flag, id) / playContent(flag, id)

stdout 输出 HITPLAY_PORT=<port> 供宿主 App 探测。
"""
import importlib.util
import inspect
import json
import os
import re
import sys
import subprocess
import threading
import time
from urllib.parse import urlparse, unquote, urljoin, parse_qsl
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PACKAGE_DIR = sys.argv[1] if len(sys.argv) > 1 else "."

# fongmi/drpy 生态 py 源的标准依赖面（缺少时只安装到应用私有依赖目录）。
# 值为 import 名：pycryptodome 导入为 Crypto。
DEPENDENCY_WHITELIST = {
    "requests": "requests",
    "bs4": "bs4",
    "lxml": "lxml",
    "pyquery": "pyquery",
    "pycryptodome": "Crypto",
    "ujson": "ujson",
    "cachetools": "cachetools",
}

_state = {
    "server": None,
    "spiders": {},   # key(py_<源名>) → Spider 实例（P1 多源并存）
    "sites": [],
}
_DETAIL_COMPAT_LOCK = threading.RLock()
_DETAIL_MODULE_LOCKS = {}

# FongMi 桌面端遗留的本地代理地址（9978/9999 双端口 + localhost/IPv6 变体，
# 生态通用兼容点）：统一改写为本宿主实际端口。
_LEGACY_PROXY_RE = re.compile(
    r"https?://(?:127\.0\.0\.1|localhost|\[::1\]|::1):(9978|9999)/proxy(?=[?/#\s\"'<]|$)",
    re.IGNORECASE,
)


def log(message):
    sys.stderr.write("[hitplay-py] %s\n" % message)
    sys.stderr.flush()


def invoke_method(method, args):
    """旧位置签名自适应：按形参数量截断实参，
    避免 TypeError 掩盖方法体内的真实异常。"""
    try:
        signature = inspect.signature(method)
    except (TypeError, ValueError):
        return method(*args)
    positional = [p for p in signature.parameters.values()
                  if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
    if not any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in signature.parameters.values()):
        args = args[:len(positional)]
    return method(*args)


def split_headers(value):
    """`url|Header=k=v&k2=v2` 尾注拆分（TVBox 生态尾注约定）：
    按最后一个 | 截断，尾段能解析出非空键值对时才拆，否则保持原串。
    `Header=` 引导段（FongMi 生态常见写法）先剥掉，避免残进键值表。"""
    if "|" not in value:
        return value, {}
    url, suffix = value.rsplit("|", 1)
    if suffix.lower().startswith("header="):
        suffix = suffix[len("header="):]
    headers = dict(parse_qsl(suffix))
    return (url, headers) if headers else (value, {})


def probe_dependency_whitelist():
    """探测标准依赖；首次运行时将缺少的兼容包安装到应用私有目录。"""
    import importlib

    def missing_modules():
        missing = []
        for package, module in DEPENDENCY_WHITELIST.items():
            try:
                importlib.import_module(module)
            except Exception:
                missing.append(package)
        return missing

    dependency_dir = os.environ.get("HITPLAY_PY_DEPENDENCY_DIR", "").strip()
    if dependency_dir:
        os.makedirs(dependency_dir, exist_ok=True)
        if dependency_dir not in sys.path:
            sys.path.insert(0, dependency_dir)

    missing = missing_modules()
    if not missing:
        log("依赖白名单齐备（%d 项）" % len(DEPENDENCY_WHITELIST))
        return []
    if not dependency_dir:
        log("依赖白名单缺失: %s（未配置应用私有依赖目录）" % ",".join(missing))
        return missing

    # Multiple source runtimes can start together. An exclusive lock keeps pip
    # from writing the same target directory concurrently; waiters re-probe.
    lock_path = os.path.join(dependency_dir, ".hitplay-pip-install.lock")
    deadline = time.time() + 210
    owns_lock = False
    while time.time() < deadline:
        missing = missing_modules()
        if not missing:
            log("依赖白名单齐备（%d 项）" % len(DEPENDENCY_WHITELIST))
            return []
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            owns_lock = True
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock_path) > 300:
                    os.unlink(lock_path)
                    continue
            except OSError:
                continue
            time.sleep(0.5)

    if not owns_lock:
        missing = missing_modules()
        log("等待 PY 依赖安装超时，缺少: %s" % ",".join(missing))
        return missing

    try:
        missing = missing_modules()
        package_names = {
            "requests": "requests",
            "bs4": "beautifulsoup4",
            "lxml": "lxml",
            "pyquery": "pyquery",
            "pycryptodome": "pycryptodome",
            "ujson": "ujson",
            "cachetools": "cachetools",
        }
        requested = [package_names[name] for name in missing]
        if not requested:
            return []
        log("正在为 PY 源准备应用私有依赖: %s" % ",".join(requested))
        try:
            result = subprocess.run(
                [sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
                 "--no-input", "--upgrade", "--target", dependency_dir, *requested],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=180,
                check=False,
            )
        except Exception as error:
            log("PY 依赖安装失败: %s" % type(error).__name__)
            return missing
        missing = missing_modules()
        if result.returncode == 0 and not missing:
            log("PY 依赖已就绪（%d 项）" % len(DEPENDENCY_WHITELIST))
            return []
        summary = result.stderr[-700:].replace("\n", " | ").strip()
        log("PY 依赖仍有缺失: %s%s" % (",".join(missing), ("；" + summary) if summary else ""))
        return missing
    finally:
        try:
            os.unlink(lock_path)
        except OSError:
            pass


def cookies_directory():
    """P2-3：py 源 cookies 目录。HITPLAY_COOKIES_DIR 可覆盖（多包共享/外部管理）；
    默认包内 cookies/。android 桩的 ExternalStorage 系方法也指向此处。"""
    override = os.environ.get("HITPLAY_COOKIES_DIR", "").strip()
    base = override if override else os.path.join(PACKAGE_DIR, "cookies")
    try:
        os.makedirs(base, exist_ok=True)
    except OSError:
        base = PACKAGE_DIR
    return base


def inject_android_stubs():
    """安卓/Java 桩（fongmi Chaquopy 生态源在桌面端的通用兼容做法）。

    FongMi/Chaquopy 生态的 py 源常直接 import android.*/java.* 操作 UI 或 IO，
    桌面端没有这些运行时，import 即崩。这里用 PEP 562 模块级 __getattr__ 提供
    宽松假体：任何属性/调用都返回新的假对象；已知路径方法（ExternalStorage 等）
    的 toString() 返回包内 cookies 目录，保证 os.path.join 链路可用。
    """
    import types

    cookies_dir = cookies_directory()

    class StubPath:
        """toString()/str() 呈现为真实路径的假对象。"""

        def __init__(self, path):
            self._path = path

        def toString(self, *args, **kwargs):
            return self._path

        def getAbsolutePath(self, *args, **kwargs):
            return self._path

        def __str__(self):
            return self._path

        def __repr__(self):
            return "<stub-path %s>" % self._path

        def __getattr__(self, item):
            if item.startswith("__") and item.endswith("__"):
                raise AttributeError(item)
            return lambda *args, **kwargs: StubPath(self._path)

    class Stub:
        def __init__(self, name="<stub>"):
            object.__setattr__(self, "_name", name)

        def __getattr__(self, item):
            if item.startswith("__") and item.endswith("__"):
                raise AttributeError(item)
            name = "%s.%s" % (object.__getattribute__(self, "_name"), item)
            if name.endswith(("getExternalStorageDirectory", "getExternalFilesDir", "getFilesDir", "getCacheDir", "getDir")):
                return lambda *args, **kwargs: StubPath(cookies_dir)
            return Stub(name)

        def __call__(self, *args, **kwargs):
            name = object.__getattribute__(self, "_name")
            if name.endswith(("getExternalStorageDirectory", "getExternalFilesDir", "getFilesDir", "getCacheDir", "getDir")):
                return StubPath(cookies_dir)
            # Handler.post / View.post 等同步执行即可：桌面端没有消息队列。
            if name.endswith((".post", ".postDelayed", ".runOnUiThread", ".run")):
                for argument in args:
                    runnable = argument
                    run = getattr(runnable, "run", None)
                    if callable(run):
                        try:
                            run()
                        except Exception as error:
                            log("stub runnable 异常: %s" % error)
                return Stub(name + "#done")
            return Stub(name + "()")

        def __str__(self):
            return object.__getattribute__(self, "_name")

        def __repr__(self):
            return "<stub %s>" % object.__getattribute__(self, "_name")

        def __iter__(self):
            return iter(())

        def __len__(self):
            return 0

        def __bool__(self):
            return False

    class StubFinder:
        PREFIXES = ("android", "java", "javax", "kotlin")

        def find_spec(self, fullname, path=None, target=None):
            if fullname.split(".")[0] in self.PREFIXES:
                return importlib.util.spec_from_loader(fullname, self)
            return None

        def create_module(self, spec):
            module = types.ModuleType(spec.name)
            module.__getattr__ = lambda item: Stub("%s.%s" % (spec.name, item))
            return module

        def exec_module(self, module):
            pass

    if not any(isinstance(finder, StubFinder) for finder in sys.meta_path):
        sys.meta_path.insert(0, StubFinder())


def inject_base_module():
    """注入 base.spider 通用基类：源码常 `from base.spider import Spider` 继承。

    方法面对齐 FongMi 生态 base/spider.py 契约（fetch/post/postJson/pq/xpText/
    regStr/removeHtmlTags/cleanText/str2json/json2str/log/getProxyUrl/local 系列、
    getCache/setCache/delCache），保证依赖这些成员的源在 HitPlay 上可用。
    """
    import types
    import requests as requests_lib
    import urllib3

    try:
        urllib3.disable_warnings()
    except Exception:
        pass

    if "base.spider" in sys.modules:
        return

    # 进程内 TTL 缓存（生态 /cache?do=get|set|del 的语义：value 带 expiresAt）。
    _cache_store = {}

    def _cache_now():
        return int(time.time())

    class Spider:
        def __init__(self, *args, **kwargs):
            self.session = requests_lib.Session()
            self.extend = ""

        def getName(self):
            return ""

        def init(self, extend=""):
            pass

        def homeContent(self, flag):
            return {}

        def homeVideoContent(self):
            return {}

        def categoryContent(self, tid, pg, flag, extend):
            return {}

        def detailContent(self, ids):
            return {}

        def searchContent(self, key, quick, pg="1"):
            return {}

        def searchContentPage(self, key, quick, pg):
            return self.searchContent(key, quick, pg)

        def playerContent(self, flag, pid, vipFlags=None):
            return {}

        def playContent(self, flag, pid, vipFlags=None):
            return {}

        def liveContent(self, url):
            return ""

        def isVideoFormat(self, url):
            return False

        def manualVideoCheck(self):
            return False

        def localProxy(self, param):
            return {}

        def action(self, action):
            return {}

        def proxy(self, param):
            return {}

        def destroy(self):
            pass

        def getDependence(self):
            return []

        def setExtendInfo(self, extend):
            self.extend = extend if isinstance(extend, str) else json.dumps(extend, ensure_ascii=False)

        def fetch(self, url, headers=None, timeout=15, verify=True, **kwargs):
            return self.session.get(url, headers=headers or {}, timeout=timeout, verify=verify, **kwargs)

        def post(self, url, data=None, headers=None, timeout=15, verify=True, **kwargs):
            return self.session.post(url, data=data, headers=headers or {}, timeout=timeout, verify=verify, **kwargs)

        def postJson(self, url, json=None, headers=None, cookies=None, timeout=15):
            return self.session.post(url, json=json, headers=headers or {}, cookies=cookies, timeout=timeout)

        def req(self, url, **kwargs):
            return self.fetch(url, **kwargs)

        def pq(self, html):
            from lxml import etree
            return etree.HTML(html)

        def html(self, content):
            from lxml import etree
            return etree.HTML(content)

        def xpText(self, root, expr):
            try:
                elements = root.xpath(expr)
            except Exception:
                return ''
            if len(elements) == 0:
                return ''
            first = elements[0]
            return first if isinstance(first, str) else (first.text or '')

        def regStr(self, src, reg=None, group=1):
            if reg is None:
                return ''
            match = None
            try:
                match = re.search(reg, src)
            except Exception:
                match = None
            if not match:
                try:
                    match = re.search(src, reg)
                except Exception:
                    match = None
            try:
                return match.group(group) if match else ''
            except Exception:
                return ''

        def removeHtmlTags(self, src):
            try:
                return re.sub('<.*?>', '', src)
            except Exception:
                return src

        def cleanText(self, src):
            try:
                return re.sub('[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]', '', src)
            except Exception:
                return src

        def str2json(self, content):
            return json.loads(content)

        def json2str(self, content):
            return json.dumps(content, ensure_ascii=False)

        def log(self, msg):
            if isinstance(msg, (dict, list)):
                log(json.dumps(msg, ensure_ascii=False))
            else:
                log(msg)

        def getProxyUrl(self, local=True):
            """本机 /proxy 回源地址（?do=py 形态）。端口读取宿主注入的
            HITPLAY_PY_PORT（服务绑定后写入），拿不到时回退 FongMi 桌面默认
            9978——该形态地址由宿主的 9978 改写逻辑兜底。"""
            port = os.environ.get("HITPLAY_PY_PORT") or os.environ.get("RZDTV_PORT") or "9978"
            return 'http://127.0.0.1:%s/proxy?do=py' % port

        def getCache(self, key):
            entry = _cache_store.get(str(key))
            if entry is None:
                return None
            if 'expiresAt' in entry and entry['expiresAt'] < _cache_now():
                self.delCache(key)
                return None
            return entry.get('value')

        def setCache(self, key, value, expires_in=3600):
            try:
                if isinstance(value, (int, float)):
                    value = str(value)
                if isinstance(value, (dict, list)):
                    value = json.dumps(value, ensure_ascii=False)
                if value is None or len(str(value)) == 0:
                    return 'failed'
                _cache_store[str(key)] = {
                    'value': value,
                    'expiresAt': _cache_now() + int(expires_in),
                }
                return 'succeed'
            except Exception:
                return 'failed'

        def delCache(self, key):
            _cache_store.pop(str(key), None)
            return 'succeed'

    spider_module = types.ModuleType("base.spider")
    spider_module.Spider = Spider
    base_module = types.ModuleType("base")
    base_module.spider = spider_module
    sys.modules["base"] = base_module
    sys.modules["base.spider"] = spider_module

    # base.localProxy：生态源会 `from base.localProxy import Proxy`，
    # 用 Proxy.getUrl(...) / Proxy.getPort(...) 拼本机回源地址。端口语义同
    # getProxyUrl：宿主注入 HITPLAY_PY_PORT，缺省回退 9978（由改写逻辑兜底）。
    if "base.localProxy" not in sys.modules:
        local_proxy_module = types.ModuleType("base.localProxy")

        class Proxy:
            def __init__(self, *args, **kwargs):
                pass

            def getUrl(self, local=True):
                port = os.environ.get("HITPLAY_PY_PORT") or os.environ.get("RZDTV_PORT") or "9978"
                return 'http://127.0.0.1:%s' % port

            def getPort(self):
                return int(os.environ.get("HITPLAY_PY_PORT") or os.environ.get("RZDTV_PORT") or "9978")

        local_proxy_module.Proxy = Proxy
        sys.modules["base.localProxy"] = local_proxy_module
        base_module.localProxy = local_proxy_module


def load_spider_modules():
    """装载包目录内全部 Spider 源（P1 多源并存）：优先 index.py，其余按文件名排序。

    返回 [(spider_cls, spider_instance, source_name)]；依赖缺失的源跳过并记录。
    """
    inject_base_module()
    inject_android_stubs()
    candidates = []
    index = os.path.join(PACKAGE_DIR, "index.py")
    if os.path.isfile(index):
        candidates.append(index)
    for name in sorted(os.listdir(PACKAGE_DIR)):
        if name.endswith(".py") and name != "index.py":
            candidates.append(os.path.join(PACKAGE_DIR, name))
    loaded = []
    for path in candidates:
        module_name = "hitplay_py_" + re.sub(r"\W", "_", os.path.basename(path))
        spec = importlib.util.spec_from_file_location(module_name, path)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        try:
            spec.loader.exec_module(module)
        except Exception as error:  # 依赖缺失的源直接跳过
            log("跳过 %s: %s（多为依赖缺失，见启动日志白名单自检）" % (os.path.basename(path), error))
            continue
        spider_cls = getattr(module, "Spider", None)
        if spider_cls is None:
            continue
        try:
            instance = spider_cls()
        except Exception as error:
            log("实例化 %s 失败: %s" % (os.path.basename(path), error))
            continue
        log("已加载 Spider: %s" % os.path.basename(path))
        loaded.append((spider_cls, instance, os.path.basename(path)))
    return loaded


def spider_site_key(source_name):
    """站点键：py_<源文件名净化>。多源并存时每源一路由前缀。"""
    return "py_" + re.sub(r"\W", "_", source_name.replace(".py", ""))


def build_sites(loaded_spiders):
    """逐源生成站点表；站点 key 与 /spider/<key>/3 路由一一对应。"""
    sites = []
    for spider_cls, spider, source_name in loaded_spiders:
        try:
            name = spider.getName() or source_name.replace(".py", "")
        except Exception:
            name = source_name.replace(".py", "")
        sites.append({
            "key": spider_site_key(source_name),
            "name": name,
            "type": 3,
            "api": "/spider/%s/3" % spider_site_key(source_name),
            "searchable": 1,
        })
    return sites


def as_int(value, default=1):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def resolve_spider(key):
    """按站点 key 取 Spider；未知 key 回退第一个源（兼容旧「单源 key=py」地址）。"""
    spiders = _state["spiders"]
    if key in spiders:
        return spiders[key]
    if spiders:
        return next(iter(spiders.values()))
    return None


def call_spider(spider, route, body):
    if route == "home":
        # TVBox/FongMi 生态约定 filter=True：源在 flag 为真时才返回筛选组。
        try:
            result = invoke_method(spider.homeContent, (True,)) or {}
        except Exception:
            result = {}
        if not result.get("class"):
            try:
                videos = spider.homeVideoContent() or {}
                result = dict(result)
                result["list"] = videos.get("list", [])
            except Exception:
                pass
        result.setdefault("class", [])
        return rewrite_payload(result, spider)
    if route == "category":
        result = invoke_method(spider.categoryContent,
                               (str(body.get("id", "")), str(as_int(body.get("page"))), True,
                                body.get("filters") or {})) or {}
        return rewrite_payload(result, spider)
    if route == "detail":
        namespace = getattr(getattr(spider, "detailContent", None), "__globals__", {})
        # Different modules can still load in parallel; only requests sharing
        # mutable source globals need to wait for a compatibility retry.
        with _DETAIL_COMPAT_LOCK:
            module_lock = _DETAIL_MODULE_LOCKS.setdefault(id(namespace), threading.RLock())
        with module_lock:
            item_id = body.get("id", "")
            ids = item_id if isinstance(item_id, list) else [item_id]
            result = spider.detailContent(ids) or {}
            entries = result.get("list", []) if isinstance(result, dict) else []
            if not entries:
                # Some FongMi scripts define NEED_PARSE_FROM and intentionally omit
                # those episodes from detailContent. HitPlay can resolve parse=1
                # player URLs, so retry once with those sources enabled only when
                # the script otherwise returned an empty detail.
                excluded = namespace.get("NEED_PARSE_FROM") if isinstance(namespace, dict) else None
                if isinstance(excluded, (set, frozenset, list, tuple)) and excluded:
                    namespace["NEED_PARSE_FROM"] = type(excluded)()
                    try:
                        candidate = spider.detailContent(ids) or {}
                    except Exception:
                        candidate = {}
                    finally:
                        namespace["NEED_PARSE_FROM"] = excluded
                    candidate_entries = candidate.get("list", []) if isinstance(candidate, dict) else []
                    if candidate_entries:
                        log("detail 兼容回退：已保留需解析线路")
                        result = candidate
            return rewrite_payload(result, spider)
    if route == "search":
        keyword = body.get("wd", "")
        page = as_int(body.get("page"))
        # searchContentPage 优先（生态方法面约定）：部分源只实现了分页版。
        page_method = getattr(spider, "searchContentPage", None)
        if callable(page_method):
            try:
                return rewrite_payload(invoke_method(page_method, (keyword, False, str(page))), spider)
            except TypeError:
                pass
        try:
            return rewrite_payload(spider.searchContent(keyword, False, page), spider)
        except TypeError:
            return rewrite_payload(spider.searchContent(keyword, False), spider)
    if route == "play":
        flag = body.get("flag", "")
        play_id = body.get("id", "")
        empty_result = {}
        for method in ("playerContent", "playContent"):
            fn = getattr(spider, method, None)
            if fn is None:
                continue
            # 三参（TVBox flag/id/flags）优先，二参兜底：invoke 自适应截断签名。
            for args in ((flag, play_id, []), (flag, play_id)):
                result = rewrite_payload(invoke_method(fn, args) or {}, spider)
                if isinstance(result, dict):
                    # 播放地址 `|Header=` 尾注并入 header（TVBox 生态约定；
                    # 图集协议 pics:// 等不拆）。列表页图片由 rewrite_item 逐张拆。
                    url_value = result.get("url")
                    if isinstance(url_value, str) and url_value.strip() \
                            and not re.match(r"^\s*(?:pics|manga|mange)://", url_value, re.I):
                        clean_url, inline = split_headers(url_value)
                        if inline:
                            existing = result.get("header", result.get("headers", {}))
                            if isinstance(existing, str):
                                # TVBox 源常用空字符串 header 表示直连。
                                existing = json.loads(existing) if existing.strip() else {}
                            result["header"] = {**inline, **(existing if isinstance(existing, dict) else {})}
                            result["url"] = clean_url
                    url = result.get("url")
                    if url and (not isinstance(url, str) or url.strip()):
                        return result
                    empty_result = result or empty_result
                break
        # Try both resolver contracts before falling back to the episode page;
        # inherited playerContent often returns {} while playContent is real.
        parsed_play_id = urlparse(str(play_id).strip())
        if parsed_play_id.scheme.lower() in ("http", "https") and parsed_play_id.netloc:
            media_extensions = {"m3u8", "mp4", "mkv", "mpd", "flv", "ts", "mov", "webm", "m4v", "m2ts"}
            extension = parsed_play_id.path.rsplit(".", 1)[-1].lower() if "." in parsed_play_id.path else ""
            result = dict(empty_result)
            result["url"] = parsed_play_id.geturl()
            result["parse"] = 0 if extension in media_extensions else 1
            log("播放兼容回退：已返回原始播放地址")
            return result
        return empty_result
    return {}


def rewrite_item(item, spider=None):
    """单条目兼容归一：
    - vod_id `tab:id:` 前缀 → 自动补 vod_tag=folder + cate（文件夹导航约定）；
    - vod_pic 三形态：dict {url, headers} / `url|Header=` 尾注 / clan:// 占位符；
    - 相对路径海报按源 host 补全。
    """
    if not isinstance(item, dict):
        return item
    result = dict(item)
    identifier = result.get("vod_id")
    if isinstance(identifier, str) and identifier.startswith("tab:id:") and identifier[7:]:
        result.setdefault("vod_tag", "folder")
        result.setdefault("cate", {"id": identifier[7:]})
    picture = result.get("vod_pic")
    pic = picture.get("url") if isinstance(picture, dict) else picture
    headers = picture.get("headers", picture.get("header", {})) if isinstance(picture, dict) else {}
    if isinstance(pic, str) and "|" in pic:
        pic, inline_headers = split_headers(pic)
        if inline_headers:
            headers = {**inline_headers, **headers}
    if isinstance(pic, str) and pic.startswith("clan://"):
        # HitPlay 无 clan 内置资产：置空占位符，避免拉取 404 刷屏。
        pic = ""
    if isinstance(pic, str) and pic and not pic.startswith(("http:", "https:", "data:")):
        host = getattr(spider, "host", None) or getattr(spider, "HOST", None) if spider is not None else None
        if host:
            pic = urljoin(host, pic)
    if pic:
        result["vod_pic"] = {"url": pic, "headers": headers} if headers else pic
    elif pic == "":
        # clan:// 占位符已置空：显式覆盖，避免原串残留。
        result["vod_pic"] = ""
    return result


def rewrite_payload(payload, spider=None):
    """返回值深度兼容归一：遗留 9978/9999 代理地址改写 + 条目 rewrite_item。"""
    if isinstance(payload, dict):
        rewritten = {key: rewrite_payload(item, spider) for key, item in payload.items()}
        if "vod_id" in rewritten or "vod_pic" in rewritten:
            rewritten = rewrite_item(rewritten, spider)
        return rewritten
    if isinstance(payload, list):
        return [rewrite_payload(item, spider) for item in payload]
    if isinstance(payload, str):
        if _state.get("server") and ("9978" in payload or "9999" in payload):
            actual = "http://127.0.0.1:%d/proxy" % _state["server"].server_address[1]
            return _LEGACY_PROXY_RE.sub(actual, payload)
        return payload
    return payload


def resolve_local_proxy(param):
    """调用 spider.localProxy(param)，返回 (status, mime, body_bytes, extra_headers)。

    FongMi 契约：返回 [code, content-type, body, headers?, b64flag?]；
    body 为 str 且 b64flag 为真时按 base64 解码（图片/二进制代理）。
    多源并存：param 带 name/spider/source 时按站点 key 或源名分发；
    否则逐源尝试，第一个给出非空结果的源生效（drpy 系不区分来源约定）。
    """
    import base64

    spiders = _state["spiders"]
    candidates = []
    hint = str(param.get("name") or param.get("spider") or param.get("source") or "")
    if hint:
        normalized = "py_" + re.sub(r"\W", "_", hint.replace(".py", ""))
        exact, partial = [], []
        for key, spider in spiders.items():
            try:
                spider_name = spider.getName() or ""
            except Exception:
                spider_name = ""
            if key == normalized or spider_name == hint:
                exact.append(spider)
            elif normalized in key or key in normalized or (hint and hint in spider_name):
                partial.append(spider)
        candidates = exact + partial
    candidates += [spider for spider in spiders.values() if spider not in candidates]

    result = None
    for spider in candidates:
        try:
            result = spider.localProxy(param)
        except Exception:
            result = None
        if result:
            break

    status, mime, body, headers, b64flag = 200, "application/octet-stream", b"", None, False
    if isinstance(result, (list, tuple)) and result:
        if len(result) > 0 and result[0] is not None:
            status = as_int(result[0], 200)
        if len(result) > 1 and result[1]:
            mime = str(result[1])
        if len(result) > 2:
            body = result[2] if result[2] is not None else b""
        if len(result) > 3 and isinstance(result[3], dict):
            headers = result[3]
        if len(result) > 4:
            b64flag = bool(result[4])
    elif isinstance(result, dict) and result.get("body") is not None:
        mime = str(result.get("content-type") or result.get("mime") or mime)
        body = result["body"]
        headers = result.get("headers")
    if isinstance(body, str):
        body = base64.b64decode(body) if b64flag else body.encode("utf-8")
    elif isinstance(body, bytearray):
        body = bytes(body)
    return status, mime, body, headers


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return {}

    def _send_raw(self, status, mime, body, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        for key, value in (extra_headers or {}).items():
            # 源给的响应头不透传逐跳/框架头；CRLF 一律拒绝（头注入防御）。
            if str(key).lower() in ("content-type", "content-length", "connection", "transfer-encoding"):
                continue
            if "\r" in str(key) + str(value) or "\n" in str(key) + str(value):
                continue
            try:
                self.send_header(str(key), str(value))
            except Exception:
                pass
        self.end_headers()
        self.wfile.write(body)

    def _proxy_param(self):
        parsed = urlparse(self.path)
        from urllib.parse import parse_qs
        query = parse_qs(parsed.query)
        # BaseHTTPRequestHandler 按 latin-1 解码请求行：中文参数值需还原为 UTF-8
        # （已是真 Unicode 的值 encode latin-1 会失败，原样保留）。
        def decode_value(value):
            try:
                return value.encode("latin-1").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                return value
        param = {decode_value(key): decode_value(values[0]) for key, values in query.items() if values}
        if self.command == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length > 0 else b""
            if body:
                # 原始 body 一并带出（localProxy 原始 body 契约，≤2MiB 上限在
                # _handle_proxy 侧校验），JSON 形态再合并进查询参数。
                param["__raw_body__"] = body
                try:
                    parsed_body = json.loads(body)
                    if isinstance(parsed_body, dict):
                        param.update({str(key): str(value) for key, value in parsed_body.items()})
                except ValueError:
                    pass
        return param

    def _handle_proxy(self):
        try:
            param = self._proxy_param()
            raw_body = param.pop("__raw_body__", b"")
            if raw_body:
                if len(raw_body) > 2 * 1024 * 1024:
                    self._send_raw(413, "text/plain; charset=utf-8", b"proxy body too large")
                    return
                # 原始 body 契约：源可读取原始请求体（图片上传等）。
                param["body"] = raw_body
            # 请求头与 Range 透传（localProxy 扩展契约）：
            # 需要 Referer/UA/Range 才能回源的视频代理依赖这两项。
            param["headers"] = dict(self.headers)
            range_header = self.headers.get("Range")
            if range_header:
                param["range"] = param["Range"] = range_header
            try:
                status, mime, body, headers = resolve_local_proxy(param)
            except Exception:
                log("localProxy 异常:\n%s" % traceback.format_exc())
                self._send_raw(502, "text/plain; charset=utf-8", b"localProxy error")
                return
            self._send_raw(status, mime, body, headers)
        except Exception:
            log("proxy 路由异常:\n%s" % traceback.format_exc())
            try:
                self._send_raw(502, "text/plain; charset=utf-8", b"proxy error")
            except Exception:
                pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/config":
            self._send(200, {"video": {"sites": _state["sites"]}})
            return
        # P2-2 健康检查：就绪状态 + 已装载源清单。
        if parsed.path == "/check":
            self._send(200, {
                "ok": True,
                "ready": bool(_state["sites"]),
                "spiders": sorted(_state["spiders"].keys()),
                "sites": len(_state["sites"]),
            })
            return
        # FongMi py 源 localProxy 契约（/proxy?do=py&…），drpy 图集/网盘中转依赖此路由。
        if parsed.path == "/proxy":
            self._handle_proxy()
            return
        self._send(404, {"error": "not found", "path": parsed.path})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/proxy":
            self._handle_proxy()
            return
        body = self._read_json()
        # 中文站点 key 会被客户端百分号编码（/spider/py_%e8%8c%84…），先解码再路由。
        path = unquote(parsed.path)
        match = re.match(r"^/spider/([\w-]+)/(\d+)/(home|category|search|detail|play|init)$", path)
        if not match:
            self._send(404, {"error": "not found", "path": path})
            return
        route = match.group(3)
        spider = resolve_spider(match.group(1))
        if spider is None:
            self._send(404, {"error": "no spider", "key": match.group(1)})
            return
        try:
            if route == "init":
                try:
                    spider.init(json.dumps(body) if body else "")
                except Exception as error:
                    log("init 异常（继续）: %s" % error)
                self._send(200, {})
                return
            self._send(200, call_spider(spider, route, body))
        except ModuleNotFoundError as error:
            # 缺依赖与源逻辑错误区分报（PYTHON_DEPENDENCY / PYTHON_SOURCE_ERROR），
            # 客户端可据此给出「缺依赖」而非「源坏了」的提示。
            log("路由 %s 依赖缺失: %s" % (route, error))
            self._send(500, {"error": {
                "code": "PYTHON_DEPENDENCY",
                "message": "缺少 Python 依赖: %s" % (getattr(error, "name", None) or error),
            }})
        except Exception:
            log("路由 %s 异常:\n%s" % (route, traceback.format_exc()))
            self._send(500, {"error": {"code": "PYTHON_SOURCE_ERROR", "message": "engine error"}})


def main():
    probe_dependency_whitelist()
    loaded = load_spider_modules()
    if not loaded:
        log("缺少可用的 Spider（需要 index.py 或目录内 .py 文件）")
        sys.exit(3)
    spiders = {}
    for spider_cls, spider, source_name in loaded:
        try:
            spider.init(os.environ.get("HITPLAY_PY_EXTEND", ""))
        except Exception as error:
            log("Spider.init 异常（继续）: %s" % error)
        spiders[spider_site_key(source_name)] = spider
    _state["spiders"] = spiders
    _state["sites"] = build_sites(loaded)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    _state["server"] = server
    port = server.server_address[1]
    # 源在运行期会经 getProxyUrl()/base.localProxy.Proxy 拼回源地址，注入真实端口。
    os.environ["HITPLAY_PY_PORT"] = str(port)
    sys.stdout.write("HITPLAY_PORT=%d\n" % port)
    sys.stdout.flush()
    log("py源服务已启动 :%d" % port)
    server.serve_forever()


def _shutdown_on_stdin_eof():
    # 父应用退出/被强杀后 stdin 管道关闭或收到 stop：立即退出，防止孤儿引擎常驻。
    for line in sys.stdin:
        if line.strip() == "stop":
            os._exit(0)
    os._exit(0)


def _watch_parent():
    # 兜底守护：stdin 方案对继承终端输入等场景不生效，PPID 变 1 即父进程已亡。
    while True:
        time.sleep(3)
        if os.getppid() == 1:
            os._exit(0)


if __name__ == "__main__":
    threading.Thread(target=_shutdown_on_stdin_eof, daemon=True).start()
    threading.Thread(target=_watch_parent, daemon=True).start()
    main()
