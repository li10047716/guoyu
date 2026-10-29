"""一键启动红果抓包：打印步骤 → 起 mitmproxy → 退出后自动分析。

    python scripts/hongguo_capture/run.py
    python scripts/hongguo_capture/run.py --dry-run     只检查环境、打印步骤
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analyze  # noqa: E402

PROXY_PORT = 8080
MITM_DIR = os.path.join(os.path.expanduser('~'), '.mitmproxy')
CA_CERT = os.path.join(MITM_DIR, 'mitmproxy-ca-cert.pem')
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(HERE)), 'capture-out')


def lan_ip():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(('223.5.5.5', 80))
        return probe.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        probe.close()


def find_mitmdump():
    found = shutil.which('mitmdump')
    if found:
        return [found]
    base = os.path.dirname(sys.executable)
    for directory in (base, os.path.join(base, 'Scripts')):
        for name in ('mitmdump.exe', 'mitmdump'):
            candidate = os.path.join(directory, name)
            if os.path.isfile(candidate):
                return [candidate]
    return []


def cert_fingerprint():
    if not os.path.isfile(CA_CERT) or not shutil.which('openssl'):
        return ''
    result = subprocess.run(
        ['openssl', 'x509', '-inform', 'PEM', '-subject_hash_old', '-in', CA_CERT],
        capture_output=True, text=True,
    )
    line = (result.stdout or '').strip().splitlines()
    return line[0].strip() if line else ''


def print_steps(ip, mitmdump, hashed):
    print('=' * 68)
    print('红果 App 抓包 · 操作步骤')
    print('=' * 68)
    print(f'''
0) 本机代理地址：{ip}:{PROXY_PORT}
   证书文件：{CA_CERT}

1) 设备（模拟器或手机）和这台电脑连同一个 WiFi。

2) 设代理：WiFi 详情 → 手动代理 → 主机 {ip}，端口 {PROXY_PORT}

3) 装证书（关键，不装就只能看到 TLS 握手失败）：
   安卓 7 以后，用户证书不被 App 信任，必须进系统证书目录。
   推荐在「已 root 的模拟器」里做（雷电 / MuMu 都自带 root）：

     adb root
     adb remount
     adb push "{CA_CERT}" /sdcard/mitm.pem
     adb shell "cat /sdcard/mitm.pem > /system/etc/security/cacerts/{hashed or "c8750f0d"}.0"
     adb shell "chmod 644 /system/etc/security/cacerts/{hashed or "c8750f0d"}.0"
     adb reboot

   真机没有 root 时，用户证书装不进系统目录，红果会直接拒绝握手——
   这种情况换模拟器最省事。

4) 保持这个窗口开着，然后在红果 App 里点开任意一部剧的某一集，
   让它真的播起来 5 秒以上（这一步必须有真实播放，否则抓不到取流请求）。

5) 回到这个窗口按 Ctrl-C 结束，工具会自动分析并给出差异清单。
''')
    if not mitmdump:
        print('-' * 68)
        print('未检测到 mitmproxy，先装：')
        print('  python -m pip install -U mitmproxy')
        print('（国内源镜像里没有这个包，直接用官方源即可）')
        print('-' * 68)


def main(argv=None):
    parser = argparse.ArgumentParser(description='启动红果抓包')
    parser.add_argument('--dry-run', action='store_true', help='只检查环境并打印步骤')
    parser.add_argument('--port', type=int, default=PROXY_PORT)
    args = parser.parse_args(argv)

    ip = lan_ip()
    mitmdump = find_mitmdump()
    hashed = cert_fingerprint()
    print_steps(ip, mitmdump, hashed)
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f'抓包输出目录：{OUT_DIR}')

    if args.dry_run:
        return 0
    if not mitmdump:
        return 1

    command = mitmdump + [
        '-s', os.path.join(HERE, 'mitm_addon.py'),
        '--set', f'hgc_out={OUT_DIR}',
        '--listen-host', '0.0.0.0',
        '--listen-port', str(args.port),
        '--set', 'block_global=false',
    ]
    print('启动：' + ' '.join(command))
    print('-' * 68)
    try:
        subprocess.run(command, check=False)
    except KeyboardInterrupt:
        pass

    print('-' * 68)
    if os.path.isdir(OUT_DIR) and any(name.endswith('.jsonl') for name in os.listdir(OUT_DIR)):
        print('开始分析抓包结果……')
        return analyze.main([OUT_DIR])
    print('没有产生抓包文件，请确认代理和证书是否生效。')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
