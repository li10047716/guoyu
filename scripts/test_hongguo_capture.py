import base64
import json
import os
import tempfile
import unittest

from hongguo_capture import capture_core

HERE = os.path.dirname(os.path.abspath(__file__))
CAPTURE_DIR = os.path.join(HERE, 'hongguo_capture')


def build_flow(**overrides):
    flow = {
        'method': 'POST',
        'url': 'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=8662',
        'status': 200,
        'req_headers': {'User-Agent': 'com.phoenix.read/73532'},
        'req_body': '{}',
        'resp_headers': {'content-type': 'application/json'},
        'resp_body': '{"data":{}}',
    }
    flow.update(overrides)
    return flow


class HostFilterTests(unittest.TestCase):
    def test_keeps_hongguo_hosts(self):
        self.assertTrue(capture_core.host_matches('api5-normal-sinfonlineb.fqnovel.com'))
        self.assertTrue(capture_core.host_matches('api-normal.snssdk.com'))
        self.assertTrue(capture_core.host_matches('p3-sign.douyinpic.com'))

    def test_rejects_lookalikes(self):
        self.assertFalse(capture_core.host_matches('fqnovel.com.evil.test'))
        self.assertFalse(capture_core.host_matches('notfqnovel.com'))
        self.assertFalse(capture_core.host_matches('example.com'))
        self.assertFalse(capture_core.host_matches(''))


class ClassifyTests(unittest.TestCase):
    def test_player_path(self):
        self.assertTrue(capture_core.looks_like_player('POST', 'https://x/novel/player/video_model/v1/', ''))

    def test_media_keys_in_response(self):
        self.assertTrue(capture_core.looks_like_player('POST', 'https://x/a/b/', '{"video_list":[]}'))
        self.assertFalse(capture_core.looks_like_player('POST', 'https://x/a/b/', '{"ok":1}'))


class MediaTests(unittest.TestCase):
    def test_extracts_direct_urls(self):
        text = '{"main_url":"https://v3.example.com/a/b.mp4?x=1","backup":"https://v3.example.com/c.m3u8"}'
        found = capture_core.extract_media_urls(text)
        self.assertEqual(len(found), 2)
        self.assertIn('b.mp4?x=1', found[0])

    def test_decodes_base64_wrapped_url(self):
        raw = 'https://v26-web.douyinvod.com/abc/video.mp4?br=1000'
        wrapped = base64.b64encode(raw.encode()).decode()
        text = '{"main_url":"%s"}' % wrapped
        self.assertEqual(capture_core.find_base64_media(text), [raw])

    def test_ignores_noise(self):
        self.assertEqual(capture_core.find_base64_media('{"a":"short"}'), [])


class LoadTests(unittest.TestCase):
    def test_loads_jsonl(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'traffic.jsonl')
            with open(path, 'w', encoding='utf-8') as handle:
                handle.write(json.dumps(build_flow()) + '\n')
                handle.write('not json\n')
            flows = capture_core.load_flows(path)
        self.assertEqual(len(flows), 1)
        self.assertEqual(flows[0]['source'], 'mitm')

    def test_loads_har(self):
        document = {'log': {'entries': [{
            'startedDateTime': '2026-10-27T08:00:00.000Z',
            'request': {
                'method': 'POST',
                'url': 'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=8662',
                'headers': [{'name': 'X-Tt-Token', 'value': 'abc'}],
                'postData': {'text': '{"mixed_video_id_map":{}}'},
            },
            'response': {
                'status': 200,
                'headers': [{'name': 'Content-Type', 'value': 'application/json'}],
                'content': {'text': '{"data":{}}'},
            },
        }]}}
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'capture.har')
            with open(path, 'w', encoding='utf-8') as handle:
                json.dump(document, handle)
            flows = capture_core.load_flows(path)
        self.assertEqual(len(flows), 1)
        self.assertEqual(flows[0]['req_headers']['x-tt-token'], 'abc')
        self.assertEqual(flows[0]['status'], 200)


class DiffTests(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(CAPTURE_DIR, 'baseline_request.json'), encoding='utf-8') as handle:
            self.baseline = json.load(handle)

    def test_flags_missing_header_and_query(self):
        flow = build_flow(
            url='https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=8662&series_id=123',
            req_headers={'User-Agent': 'x', 'X-Tt-Token': 'session', 'Cookie': 'sessionid=1'},
            resp_body=json.dumps({'data': {'v': {'video_model': '{}'}}}),
        )
        difference = capture_core.diff_request(self.baseline, flow)
        names = {item['name'] for item in difference['missing_headers']}
        self.assertIn('x-tt-token', names)
        self.assertIn('cookie', names)
        self.assertEqual([item['name'] for item in difference['missing_query']], ['series_id'])
        self.assertIn('data.v.video_model', difference['response_body_shape'])

    def test_reports_headers_only_we_send(self):
        flow = build_flow(req_headers={'User-Agent': 'x'})
        difference = capture_core.diff_request(self.baseline, flow)
        self.assertIn('x-medusa', difference['extra_headers'])
        self.assertEqual(difference['missing_headers'], [])

    def test_ignores_transport_headers(self):
        flow = build_flow(req_headers={'User-Agent': 'x', 'Host': 'h', 'Content-Length': '2', 'Accept-Encoding': 'gzip'})
        difference = capture_core.diff_request(self.baseline, flow)
        self.assertEqual(difference['missing_headers'], [])

    def test_baseline_matches_current_player_endpoint(self):
        self.assertEqual(self.baseline['path'], '/novel/player/multi_video_model/v1/')
        for name in ('x-gorgon', 'x-khronos', 'x-ladon', 'x-argus', 'x-helios', 'x-medusa'):
            self.assertIn(name, {key.lower() for key in self.baseline['headers']})


class ReportTests(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(CAPTURE_DIR, 'baseline_request.json'), encoding='utf-8') as handle:
            self.baseline = json.load(handle)

    def test_report_ranks_player_candidate(self):
        flows = [
            build_flow(url='https://a.fqnovel.com/reading/x/', resp_body='{"ok":1}'),
            build_flow(resp_body='{"data":{"1":{"video_model":"{\\"video_list\\":[]}"}}}'),
        ]
        report = capture_core.build_report(flows, self.baseline)
        self.assertIn('## 取流候选', report)
        self.assertIn('multi_video_model', report)
        self.assertIn('### App 有、我们没有的请求头', report)

    def test_report_without_candidate(self):
        flows = [build_flow(url='https://a.fqnovel.com/reading/x/', resp_body='{"ok":1}')]
        report = capture_core.build_report(flows, self.baseline)
        self.assertIn('没有找到取流请求', report)

    def test_empty_200_is_visible_in_inventory(self):
        flows = [build_flow(resp_body='', status=200)]
        report = capture_core.build_report(flows, self.baseline)
        self.assertIn('| 1 | 200 | 1 |', report)


if __name__ == '__main__':
    unittest.main()
