"""红果 App 抓包的公共逻辑：过滤、归类、归一化、差异比对。

不依赖 mitmproxy，可单独测试；mitm_addon.py 只是把它接到真实流量上。
"""

import base64
import json
import re
from urllib.parse import parse_qsl, urlsplit

CAPTURE_HOST_SUFFIXES = (
    'fqnovel.com',
    'snssdk.com',
    'snssdk.net',
    'bytedance.com',
    'byteimg.com',
    'ibytedtos.com',
    'bytegoofy.com',
    'amemv.com',
    'douyinpic.com',
    'douyinvod.com',
    'volccdn.com',
    'zjcdn.com',
    'pstatp.com',
    'ixigua.com',
)

PLAYER_PATH_HINTS = (
    'video_model',
    'multi_video',
    'player',
    '/play',
    'get_video',
    'media',
    'video/url',
    'playinfo',
)

MEDIA_KEYS = (
    'main_url',
    'backup_url',
    'backup_url_1',
    'backup_url_2',
    'backup_urls',
    'url_list',
    'play_url',
    'video_list',
    'video_model',
    'fallback_api',
    'encrypt_info',
    'spade_a',
    'video_id',
    'vid',
)

MEDIA_URL_RE = re.compile(r'https?://[^\s"\'\\<>]{10,}?\.(?:mp4|m3u8)[^\s"\'\\<>]*')

IGNORED_REQUEST_HEADERS = {
    'host',
    'connection',
    'content-length',
    'accept-encoding',
    'te',
    'transfer-encoding',
    'expect',
    'upgrade-insecure-requests',
    'if-none-match',
    'if-modified-since',
    'range',
    'proxy-connection',
    'proxy-authorization',
}

# 网关/CDN 回写的响应头，比对时不看。
IGNORED_RESPONSE_HEADERS = {
    'date',
    'server',
    'via',
    'vary',
    'content-length',
    'content-type',
    'cache-control',
    'expires',
    'etag',
    'age',
    'last-modified',
    'server-timing',
    'connection',
    'transfer-encoding',
    'keep-alive',
}

BODY_LIMIT = 1 << 20


def host_matches(host):
    host = (host or '').lower()
    return any(host == suffix or host.endswith('.' + suffix) for suffix in CAPTURE_HOST_SUFFIXES)


def looks_like_player(method, url, response_text=''):
    lowered = (url or '').lower()
    if any(hint in lowered for hint in PLAYER_PATH_HINTS):
        return True
    text = response_text or ''
    return any(f'"{key}"' in text for key in MEDIA_KEYS)


def extract_media_urls(text, limit=40):
    found = []
    seen = set()
    for match in MEDIA_URL_RE.findall(text or ''):
        if match not in seen:
            seen.add(match)
            found.append(match)
        if len(found) >= limit:
            break
    return found


def find_base64_media(text, limit=20):
    """红果部分字段把地址整个 base64 过，这里顺手解一层。"""
    found = []
    for chunk in re.findall(r'"([A-Za-z0-9+/=]{40,8192})"', text or ''):
        try:
            decoded = base64.b64decode(chunk, validate=True).decode('utf-8', 'ignore')
        except Exception:
            continue
        if MEDIA_URL_RE.search(decoded):
            found.append(decoded.strip())
        if len(found) >= limit:
            break
    return found


def normalize_har_entry(entry):
    request = entry.get('request') or {}
    response = entry.get('response') or {}
    headers = {}
    for item in request.get('headers') or []:
        headers[str(item.get('name', '')).lower()] = str(item.get('value', ''))
    post = request.get('postData') or {}
    return {
        'source': 'har',
        'started': ((entry.get('startedDateTime') or '')[:23]),
        'method': request.get('method', ''),
        'url': request.get('url', ''),
        'status': int(response.get('status') or 0),
        'req_headers': headers,
        'req_body': post.get('text') or '',
        'resp_headers': {
            str(item.get('name', '')).lower(): str(item.get('value', ''))
            for item in (response.get('headers') or [])
        },
        'resp_body': ((response.get('content') or {}).get('text') or '')[:BODY_LIMIT],
    }


def load_flows(path):
    """读 .har 或本工具写出的 .jsonl，统一成 flow 字典列表。"""
    with open(path, encoding='utf-8', errors='ignore') as handle:
        text = handle.read()
    stripped = text.lstrip()
    if stripped.startswith('{') and '"log"' in stripped[:4096]:
        document = json.loads(stripped)
        entries = ((document.get('log') or {}).get('entries') or [])
        return [normalize_har_entry(entry) for entry in entries]
    flows = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        record.setdefault('source', 'mitm')
        record.setdefault('method', '')
        record.setdefault('url', '')
        record.setdefault('status', 0)
        record.setdefault('req_headers', {})
        record.setdefault('req_body', '')
        record.setdefault('resp_headers', {})
        record.setdefault('resp_body', '')
        flows.append(record)
    return flows


def query_pairs(url):
    pairs = {}
    for key, value in parse_qsl(urlsplit(url or '').query, keep_blank_values=True):
        pairs[key] = value
    return pairs


def signature_score(flow):
    url = (flow.get('url') or '').lower()
    body = flow.get('resp_body') or ''
    score = 0
    if 'video_model' in url:
        score += 10
    if 'multi_video' in url:
        score += 6
    if '/player' in url:
        score += 5
    if flow.get('status') == 200 and body:
        score += 2
    if body:
        for key in ('main_url', 'backup_url', 'video_list', 'play_url'):
            if f'"{key}"' in body:
                score += 8
                break
        if MEDIA_URL_RE.search(body):
            score += 8
        if '"video_model"' in body:
            score += 4
    return score


def rank_player_candidates(flows, limit=8):
    scored = []
    for flow in flows:
        if not looks_like_player(flow.get('method'), flow.get('url'), flow.get('resp_body')):
            continue
        scored.append((signature_score(flow), flow))
    scored.sort(key=lambda item: item[0], reverse=True)
    return scored[:limit]


def endpoint_inventory(flows):
    inventory = {}
    for flow in flows:
        split = urlsplit(flow.get('url') or '')
        key = (split.netloc, split.path)
        entry = inventory.setdefault(key, {'count': 0, 'statuses': set(), 'empty': 0, 'max_body': 0})
        entry['count'] += 1
        entry['statuses'].add(flow.get('status'))
        if not flow.get('resp_body'):
            entry['empty'] += 1
        entry['max_body'] = max(entry['max_body'], len(flow.get('resp_body') or ''))
    return inventory


def _body_shape(text):
    if not text:
        return {}
    try:
        document = json.loads(text)
    except Exception:
        return {}
    shape = {}

    def walk(node, prefix, depth):
        if depth > 2:
            return
        if isinstance(node, dict):
            for key, value in node.items():
                shape[prefix + key] = type(value).__name__
                if isinstance(value, (dict, list)):
                    walk(value, prefix + key + '.', depth + 1)
        elif isinstance(node, list) and node:
            shape[prefix + '[]'] = type(node[0]).__name__
            walk(node[0], prefix + '[].', depth + 1)

    walk(document, '', 0)
    return shape


def diff_request(baseline, flow):
    """baseline 是我们今天发的请求，flow 是 App 实际发的请求。"""
    captured_query = query_pairs(flow.get('url'))
    baseline_query = dict(baseline.get('query') or {})
    dynamic = set(baseline.get('dynamic_query') or [])

    captured_headers = {
        key.lower(): value
        for key, value in (flow.get('req_headers') or {}).items()
        if key.lower() not in IGNORED_REQUEST_HEADERS
    }
    baseline_headers = {key.lower() for key in (baseline.get('headers') or {})}

    missing_headers = []
    for name in sorted(captured_headers):
        if name in baseline_headers:
            continue
        value = captured_headers[name]
        missing_headers.append({
            'name': name,
            'value': value if len(value) <= 120 else value[:117] + '...',
            'length': len(value),
        })

    extra_headers = sorted(name for name in baseline_headers if name not in captured_headers)

    missing_query = []
    for key in sorted(captured_query):
        if key in dynamic or key in baseline_query:
            continue
        missing_query.append({'name': key, 'value': captured_query[key][:120]})

    extra_query = sorted(
        key for key in baseline_query
        if key not in captured_query and key not in dynamic
    )

    changed_query = []
    for key in sorted(baseline_query):
        if key in dynamic or key not in captured_query or key not in baseline_query:
            continue
        if str(baseline_query[key]) != captured_query[key]:
            changed_query.append({'name': key, 'ours': str(baseline_query[key])[:120], 'app': captured_query[key][:120]})

    return {
        'url': flow.get('url'),
        'status': flow.get('status'),
        'method': flow.get('method'),
        'missing_headers': missing_headers,
        'extra_headers': extra_headers,
        'missing_query': missing_query,
        'extra_query': extra_query,
        'changed_query': changed_query,
        'response_body_shape': _body_shape(flow.get('resp_body')),
        'response_media': extract_media_urls(flow.get('resp_body')),
        'response_base64_media': find_base64_media(flow.get('resp_body')),
        'request_body': (flow.get('req_body') or '')[:4000],
    }


def build_report(flows, baseline):
    inventory = endpoint_inventory(flows)
    candidates = rank_player_candidates(flows)

    lines = ['# 红果抓包分析', '']
    lines.append(f'共 {len(flows)} 条请求，命中相关域名 {len(inventory)} 个端点。')
    lines.append('')

    lines.append('## 端点清单（含「200 空体」，用于定位风控差异）')
    lines.append('')
    lines.append('| 主机 | 路径 | 次数 | 状态 | 空体 | 最大响应 |')
    lines.append('| --- | --- | --- | --- | --- | --- |')
    for (host, path), entry in sorted(inventory.items(), key=lambda item: -item[1]['count'])[:60]:
        statuses = ','.join(str(code) for code in sorted(entry['statuses']))
        lines.append(f"| {host} | {path} | {entry['count']} | {statuses} | {entry['empty']} | {entry['max_body']} |")
    lines.append('')

    if not candidates:
        lines.append('## 没有找到取流请求')
        lines.append('')
        lines.append('请确认抓包期间真的在红果 App 里点开了一集并让它播放了几秒。')
        return '\n'.join(lines)

    lines.append('## 取流候选（按命中程度排序）')
    lines.append('')
    for score, flow in candidates:
        lines.append(f'- score={score} {flow.get("method")} {flow.get("url")[:160]} → {flow.get("status")} / {len(flow.get("resp_body") or "")} 字节')
    lines.append('')

    best = candidates[0][1]
    difference = diff_request(baseline, best)
    lines.append('## 与当前实现的最大差异')
    lines.append('')
    lines.append(f"报文：`{difference['method']} {difference['url']}`")
    lines.append(f"响应：{difference['status']}，{len(best.get('resp_body') or '')} 字节")
    lines.append('')

    lines.append('### App 有、我们没有的请求头')
    if difference['missing_headers']:
        lines.append('')
        lines.append('| 头 | 长度 | 片段 |')
        lines.append('| --- | --- | --- |')
        for item in difference['missing_headers']:
            lines.append(f"| {item['name']} | {item['length']} | `{item['value']}` |")
    else:
        lines.append('')
        lines.append('无。说明请求头层面我们已对齐，问题在参数或会话。')
    lines.append('')

    lines.append('### 我们有、App 没有的请求头')
    lines.append('')
    lines.append(', '.join(f'`{name}`' for name in difference['extra_headers']) or '无')
    lines.append('')

    lines.append('### App 有、我们没有的查询参数')
    lines.append('')
    if difference['missing_query']:
        for item in difference['missing_query']:
            lines.append(f"- `{item['name']}` = `{item['value']}`")
    else:
        lines.append('无')
    lines.append('')

    lines.append('### 我们有、App 没有的查询参数')
    lines.append('')
    lines.append(', '.join(f'`{name}`' for name in difference['extra_query']) or '无')
    lines.append('')

    lines.append('### 同名参数取值不同')
    lines.append('')
    if difference['changed_query']:
        for item in difference['changed_query']:
            lines.append(f"- `{item['name']}`：我们 `{item['ours']}`，App `{item['app']}`")
    else:
        lines.append('无')
    lines.append('')

    lines.append('### App 的请求体')
    lines.append('')
    lines.append('```json')
    lines.append(difference['request_body'] or '(空)')
    lines.append('```')
    lines.append('')

    lines.append('### App 响应里的媒体地址')
    lines.append('')
    if difference['response_media']:
        for item in difference['response_media'][:10]:
            lines.append(f'- `{item[:160]}`')
    else:
        lines.append('响应体里没有直接的 mp4/m3u8 链接（红果多数情况下是 base64 或需要再取一层）。')
    lines.append('')

    if difference['response_base64_media']:
        lines.append('### base64 解出的媒体地址')
        lines.append('')
        for item in difference['response_base64_media'][:10]:
            lines.append(f'- `{item[:160]}`')
        lines.append('')

    lines.append('### 响应体字段结构')
    lines.append('')
    if difference['response_body_shape']:
        lines.append('```')
        for key, kind in sorted(difference['response_body_shape'].items())[:60]:
            lines.append(f'{key}: {kind}')
        lines.append('```')
    else:
        lines.append('响应不是 JSON，或为空。')
    lines.append('')

    return '\n'.join(lines)
