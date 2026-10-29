"""不弹任何 UI 地把证书装进 / 移出「当前用户-受信任的根证书颁发机构」。

为什么不用 certutil / Import-Certificate：向 Root 存储添加证书时 Windows 会弹
一个安全确认框，非交互环境下会被直接拒绝（"此操作中不允许使用 UI"）。
这里走 crypt32 的 CertAddEncodedCertificateToStore，属于 API 层，没有 UI 环节。

用法：
    python scripts/hongguo_capture/win_cert.py install <证书路径>
    python scripts/hongguo_capture/win_cert.py remove  <证书路径|SHA1指纹>
    python scripts/hongguo_capture/win_cert.py check   <SHA1指纹>
"""

import ctypes
import hashlib
import sys
from ctypes import POINTER, byref, c_char_p, c_void_p, c_wchar_p, create_string_buffer

CERT_STORE_PROV_SYSTEM_W = 10
CERT_SYSTEM_STORE_CURRENT_USER = 0x00010000
ENCODING = 0x00000001 | 0x00010000  # X509_ASN_ENCODING | PKCS_7_ASN_ENCODING
CERT_STORE_ADD_REPLACE_EXISTING = 3
CERT_FIND_SHA1_HASH = 0x00010000

crypt32 = ctypes.WinDLL('crypt32', use_last_error=True)
crypt32.CertOpenStore.argtypes = [c_void_p, ctypes.c_ulong, c_void_p, ctypes.c_ulong, c_void_p]
crypt32.CertOpenStore.restype = c_void_p
crypt32.CertCloseStore.argtypes = [c_void_p, ctypes.c_ulong]
crypt32.CertCloseStore.restype = ctypes.c_bool
crypt32.CertAddEncodedCertificateToStore.argtypes = [
    c_void_p, ctypes.c_ulong, c_char_p, ctypes.c_ulong, ctypes.c_ulong, POINTER(c_void_p)]
crypt32.CertAddEncodedCertificateToStore.restype = ctypes.c_bool
crypt32.CertFindCertificateInStore.argtypes = [
    c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, c_void_p, c_void_p]
crypt32.CertFindCertificateInStore.restype = c_void_p
crypt32.CertDeleteCertificateFromStore.argtypes = [c_void_p]
crypt32.CertDeleteCertificateFromStore.restype = ctypes.c_bool
crypt32.CertFreeCertificateContext.argtypes = [c_void_p]


class CryptHashBlob(ctypes.Structure):
    _fields_ = [('cbData', ctypes.c_ulong), ('pbData', POINTER(ctypes.c_ubyte))]


def open_store(write=True):
    flags = CERT_SYSTEM_STORE_CURRENT_USER | (0 if write else 0)
    handle = crypt32.CertOpenStore(
        c_void_p(CERT_STORE_PROV_SYSTEM_W), ENCODING, None, flags, c_wchar_p('Root'))
    if not handle:
        raise OSError(ctypes.get_last_error(), 'CertOpenStore 失败')
    return handle


def read_der(path):
    raw = open(path, 'rb').read()
    if b'-----BEGIN' in raw:
        import base64
        body = raw.split(b'-----BEGIN CERTIFICATE-----', 1)[1]
        body = body.split(b'-----END CERTIFICATE-----', 1)[0]
        raw = base64.b64decode(b''.join(body.split()))
    return raw


def thumbprint(der):
    return hashlib.sha1(der).hexdigest().upper()


def find(store, der):
    digest = hashlib.sha1(der).digest()
    buffer = (ctypes.c_ubyte * len(digest)).from_buffer_copy(digest)
    blob = CryptHashBlob(len(digest), buffer)
    return crypt32.CertFindCertificateInStore(
        store, ENCODING, 0, CERT_FIND_SHA1_HASH, byref(blob), None)


def install(path):
    der = read_der(path)
    store = open_store()
    try:
        if find(store, der):
            print('already-installed ' + thumbprint(der))
            return 0
        buf = create_string_buffer(der, len(der))
        ok = crypt32.CertAddEncodedCertificateToStore(
            store, ENCODING, buf, len(der), CERT_STORE_ADD_REPLACE_EXISTING, None)
        if not ok:
            code = ctypes.get_last_error()
            print(f'failed error={code}')
            return 1
        print('installed ' + thumbprint(der))
        return 0
    finally:
        crypt32.CertCloseStore(store, 0)


def remove(der):
    store = open_store()
    try:
        context = find(store, der)
        if not context:
            print('not-found')
            return 0
        if not crypt32.CertDeleteCertificateFromStore(context):
            print(f'failed error={ctypes.get_last_error()}')
            return 1
        crypt32.CertFreeCertificateContext(context)
        print('removed')
        return 0
    finally:
        crypt32.CertCloseStore(store, 0)


def check(der):
    store = open_store()
    try:
        found = bool(find(store, der))
        print(('installed ' if found else 'absent ') + thumbprint(der))
        return 0
    finally:
        crypt32.CertCloseStore(store, 0)


if __name__ == '__main__':
    action = sys.argv[1] if len(sys.argv) > 1 else 'check'
    target = sys.argv[2] if len(sys.argv) > 2 else r'C:\Users\13964\.mitmproxy\mitmproxy-ca-cert.cer'
    der = read_der(target)
    sys.exit({'install': install, 'remove': remove, 'check': check}[action](target if action != 'check' else der))
