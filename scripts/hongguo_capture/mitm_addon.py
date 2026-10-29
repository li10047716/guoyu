"""mitmproxy 插件：只留红果相关流量，整条请求/响应落盘成 jsonl。

用法（由 run.py 自动带参数启动，也可手动）：
    mitmdump -s scripts/hongguo_capture/mitm_addon.py --set hgc_out=capture-out
"""

import json
import os
import sys
import time
from urllib.parse import urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import capture_core as core  # noqa: E402
from mitmproxy import ctx  # noqa: E402

BODY_LIMIT = 1 << 20
TEXT_TYPES = ('json', 'text', 'javascript', 'xml', 'x-www-form-urlencoded')


class HongguoCapture:
    def __init__(self):
        self.out_dir = 'capture-out'
        self.handle = None
        self.path = ''
        self.kept = 0

    def load(self, loader):
        loader.add_option('hgc_out', str, 'capture-out', '红果抓包输出目录')

    def running(self):
        self.out_dir = ctx.options.hgc_out
        os.makedirs(self.out_dir, exist_ok=True)
        self.path = os.path.join(self.out_dir, time.strftime('traffic-%Y%m%d-%H%M%S.jsonl'))
        self.handle = open(self.path, 'a', encoding='utf-8')
        ctx.log.warn(f'红果抓包已就绪：{self.path}')
        ctx.log.warn('现在在设备上打开红果 App，点开任意一部剧的某一集，让它播 5 秒。')

    def done(self):
        if self.handle:
            self.handle.close()
            self.handle = None
        if self.kept:
            ctx.log.warn(f'本轮记录 {self.kept} 条，文件：{self.path}')
            ctx.log.warn('抓包结束后运行：python scripts/hongguo_capture/analyze.py ' + self.out_dir)

    def request(self, flow):
        host = flow.request.pretty_host
        if not core.host_matches(host):
            return
        try:
            flow.metadata['hgc_request_body'] = self._text(flow.request)
        except Exception:
            flow.metadata['hgc_request_body'] = ''

    def response(self, flow):
        host = flow.request.pretty_host
        if not core.host_matches(host):
            return
        try:
            response_body = self._text(flow.response)
        except Exception:
            response_body = ''
        record = {
            'started': time.strftime('%Y-%m-%dT%H:%M:%S'),
            'method': flow.request.method,
            'url': flow.request.pretty_url,
            'status': flow.response.status_code,
            'req_headers': {key: value for key, value in flow.request.headers.items()},
            'req_body': flow.metadata.get('hgc_request_body') or '',
            'resp_headers': {key: value for key, value in flow.response.headers.items()},
            'resp_body': response_body[:BODY_LIMIT],
        }
        self.handle.write(json.dumps(record, ensure_ascii=False) + '\n')
        self.handle.flush()
        self.kept += 1
        if core.looks_like_player(flow.request.method, flow.request.pretty_url, response_body):
            split = urlsplit(flow.request.pretty_url)
            ctx.log.info(f'[取流候选] {flow.response.status_code} {len(response_body)}B {split.path}')

    @staticmethod
    def _text(message):
        if message is None:
            return ''
        content_type = (message.headers.get('content-type') or '').lower()
        if content_type and not any(kind in content_type for kind in TEXT_TYPES):
            return ''
        return message.get_text(strict=False) or ''


addons = [HongguoCapture()]
