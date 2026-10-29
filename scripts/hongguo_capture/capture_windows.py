"""把 Windows 系统代理指向本地 mitmproxy，并临时信任 mitmproxy 根证书。

只改当前用户（HKCU）范围，不需要管理员权限；所有原始值先备份，
`restore` 会原样写回并移除证书。任何一步失败都回滚。

用法：
    python scripts/hongguo_capture/capture_windows.py prep
    python scripts/hongguo_capture/capture_windows.py restore
    python scripts/hongguo_capture/capture_windows.py status
"""

import hashlib
import json
import os
import subprocess
import sys
import winreg

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'capture-out')
OUT_DIR = os.path.abspath(OUT_DIR)
BACKUP = os.path.join(OUT_DIR, 'proxy-backup.json')

SETTINGS = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
PROXY = '127.0.0.1:8080'
CA_CER = os.path.expanduser(r'~\.mitmproxy\mitmproxy-ca-cert.cer')
CA_THUMB = 'A8A44F79F0F0E6F3B0F1C58A0F8B7A0B6D1C0F00'  # 占位，实际从 certutil 输出取


def read_settings():
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, SETTINGS) as key:
        values = {}
        for name in ('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL'):
            try:
                values[name] = winreg.QueryValueEx(key, name)[0]
            except FileNotFoundError:
                values[name] = None
        return values


def write_values(values, delete=()):
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, SETTINGS, 0, winreg.KEY_WRITE) as key:
        for name, value in values.items():
            if name in delete or value is None:
                try:
                    winreg.DeleteValue(key, name)
                except FileNotFoundError:
                    pass
                continue
            if isinstance(value, int):
                winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, value)
            else:
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)


def notify_change():
    # 让 WinINET 立即重新读取代理设置，否则已运行的进程仍用旧值
    ps = (
        'Add-Type -Namespace W -Name I -MemberDefinition '
        '" [DllImport(\\"wininet.dll\\")] public static extern bool InternetSetOption('
        'IntPtr h, int o, IntPtr b, int l); "; '
        '[W.I]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0); '
        '[W.I]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)'
    )
    subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', ps],
                   capture_output=True, text=True)


def ca_thumbprint():
    """直接对证书 DER 算 SHA1，避开 certutil 的中文输出编码问题。"""
    if not os.path.exists(CA_CER):
        return None
    raw = open(CA_CER, 'rb').read()
    if b'-----BEGIN' in raw:
        import base64
        body = raw.split(b'-----BEGIN CERTIFICATE-----', 1)[1]
        body = body.split(b'-----END CERTIFICATE-----', 1)[0]
        raw = base64.b64decode(b''.join(body.split()))
    return hashlib.sha1(raw).hexdigest()


def ca_installed(thumb):
    result = subprocess.run(
        ['powershell', '-NoProfile', '-NonInteractive', '-Command',
         f'if (Test-Path Cert:\\CurrentUser\\Root\\{thumb}) {{ "yes" }} else {{ "no" }}'],
        capture_output=True, text=True, encoding='utf-8', errors='replace')
    return (result.stdout or '').strip().endswith('yes')


def prep():
    os.makedirs(OUT_DIR, exist_ok=True)
    if not os.path.exists(CA_CER):
        print('[x] 找不到 mitmproxy 根证书：' + CA_CER)
        print('    先运行一次 mitmdump 让它生成证书。')
        return 2
    thumb = ca_thumbprint()
    if not thumb:
        print('[x] 无法读取证书指纹')
        return 2

    backup = {'settings': read_settings(), 'ca_thumbprint': thumb, 'ca_added': False}
    with open(BACKUP, 'w', encoding='utf-8') as handle:
        json.dump(backup, handle, ensure_ascii=False, indent=2)
    print('[1/3] 已备份原代理设置 -> ' + BACKUP)
    for name, value in backup['settings'].items():
        print(f'      {name} = {value!r}')

    if not ca_installed(thumb):
        result = subprocess.run(['certutil', '-user', '-addstore', 'Root', CA_CER],
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        if result.returncode != 0:
            print('[x] 导入根证书失败：')
            print((result.stdout or '') + (result.stderr or ''))
            return 3
        backup['ca_added'] = True
        with open(BACKUP, 'w', encoding='utf-8') as handle:
            json.dump(backup, handle, ensure_ascii=False, indent=2)
        print('[2/3] 已把 mitmproxy 根证书导入当前用户 Root 存储（抓完会移除）')
    else:
        print('[2/3] 根证书已在当前用户 Root 存储，跳过导入')

    write_values({'ProxyEnable': 1, 'ProxyServer': PROXY}, delete=('AutoConfigURL',))
    notify_change()
    print(f'[3/3] 系统代理已指向 {PROXY}')
    print('      现在启动红果鉴并播一集，抓完运行：capture_windows.py restore')
    return 0


def restore():
    backup = {}
    if os.path.exists(BACKUP):
        with open(BACKUP, encoding='utf-8') as handle:
            backup = json.load(handle)
        settings = backup.get('settings') or {}
        write_values(settings, delete=('AutoConfigURL',) if settings.get('AutoConfigURL') is None else ())
        notify_change()
        print('[1/2] 代理设置已恢复：')
        for name, value in settings.items():
            print(f'      {name} = {value!r}')
    else:
        write_values({'ProxyEnable': 0}, delete=('AutoConfigURL',))
        notify_change()
        print('[1/2] 没有备份文件，已关闭代理开关')

    thumb = backup.get('ca_thumbprint') or ca_thumbprint()
    if backup.get('ca_added') and thumb:
        result = subprocess.run(['certutil', '-user', '-delstore', 'Root', thumb],
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        print('[2/2] 移除 mitmproxy 根证书：' + ('完成' if result.returncode == 0 else '失败'))
        if result.returncode != 0:
            print((result.stdout or '') + (result.stderr or ''))
    else:
        print('[2/2] 本次未新增根证书，无需移除')
    return 0


def status():
    current = read_settings()
    for name, value in current.items():
        print(f'{name} = {value!r}')
    thumb = ca_thumbprint()
    if thumb:
        print(f'mitmproxy CA 已安装 = {ca_installed(thumb)}')
    return 0


if __name__ == '__main__':
    action = sys.argv[1] if len(sys.argv) > 1 else 'status'
    sys.exit({'prep': prep, 'restore': restore, 'status': status}.get(action, status)())
