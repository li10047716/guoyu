"""抓包结果分析：把「App 发了什么」和我们当前实现逐项对齐。

用法：
    python scripts/hongguo_capture/analyze.py capture-out
    python scripts/hongguo_capture/analyze.py capture.har
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import capture_core as core  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def load_baseline():
    with open(os.path.join(HERE, 'baseline_request.json'), encoding='utf-8') as handle:
        return json.load(handle)


def collect_files(target):
    if os.path.isdir(target):
        files = []
        for name in sorted(os.listdir(target)):
            if name.endswith(('.jsonl', '.har')):
                files.append(os.path.join(target, name))
        return files
    return [target]


def main(argv=None):
    parser = argparse.ArgumentParser(description='分析红果抓包结果')
    parser.add_argument('target', nargs='?', default=os.path.join(os.path.dirname(os.path.dirname(HERE)), 'capture-out'),
                        help='抓包目录或 .har / .jsonl 文件，默认 capture-out')
    parser.add_argument('--report', default='', help='报告输出路径，默认写到抓包目录')
    args = parser.parse_args(argv)

    files = collect_files(args.target)
    if not files:
        print(f'没找到抓包文件：{args.target}')
        return 1

    flows = []
    for path in files:
        loaded = core.load_flows(path)
        print(f'{os.path.basename(path)}: {len(loaded)} 条')
        flows.extend(loaded)

    # 本工具的 jsonl 已按域名过滤；HAR 可能混着别的站的流量，这里再筛一遍。
    filtered = [flow for flow in flows if core.host_matches(core.urlsplit(flow.get('url') or '').netloc)]
    if filtered:
        flows = filtered
    else:
        print('提示：没有命中红果相关域名，按原始内容继续分析。')

    if not flows:
        print('抓包文件里没有可用请求。')
        return 1

    report = core.build_report(flows, load_baseline())
    if args.report:
        output = args.report
    elif os.path.isdir(args.target):
        output = os.path.join(args.target, 'capture_report.md')
    else:
        output = os.path.splitext(args.target)[0] + '-report.md'

    with open(output, 'w', encoding='utf-8') as handle:
        handle.write(report + '\n')
    print()
    print(report)
    print()
    print(f'报告已写入：{output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
