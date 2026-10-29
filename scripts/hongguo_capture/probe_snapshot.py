"""二分定位红果鉴本地配置快照中导致 FormatException 的字段。

用法: python probe_snapshot.py <keys 逗号分隔|empty>
  写一个只含指定字段的 shared_preferences.json，供启动测试。
"""
import json
import os
import sys

OLD = r"D:\Downloads\红果鉴1026\hgplayer-backup-182019\zhenguojian-cfg\shared_preferences.json.moved"
NEW = os.path.expandvars(r"%APPDATA%\真果鉴\真果鉴\shared_preferences.json")


def load_old_values():
    top = json.load(open(OLD, encoding='utf-8'))
    snap = json.loads(top['flutter.localSnapshot.v1'])
    return snap['values']


def main(selector):
    vals = load_old_values()
    if selector == 'empty':
        chosen = {}
    else:
        keys = [k.strip() for k in selector.split(',') if k.strip()]
        missing = [k for k in keys if k not in vals]
        if missing:
            raise SystemExit('未知字段: %s' % missing)
        chosen = {k: vals[k] for k in keys}

    snap = json.dumps({'version': 1, 'values': chosen}, ensure_ascii=False)
    payload = json.dumps({'flutter.localSnapshot.v1': snap}, ensure_ascii=False)
    with open(NEW, 'w', encoding='utf-8') as f:
        f.write(payload)
    print('写入 %d 字节, 字段: %s' % (len(payload), list(chosen.keys()) or '空'))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'empty')
