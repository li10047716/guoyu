"""截取指定标题的窗口（Win32），用于本地排障时确认界面状态。"""
import ctypes
import ctypes.wintypes as wt
import sys
import time

from PIL import Image

user32 = ctypes.WinDLL('user32', use_last_error=True)
gdi32 = ctypes.WinDLL('gdi32', use_last_error=True)

SRCCOPY = 0x00CC0020
SW_RESTORE = 9
DIB_RGB_COLORS = 0
PW_RENDERFULLCONTENT = 0x00000002


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ('biSize', wt.DWORD), ('biWidth', wt.LONG), ('biHeight', wt.LONG),
        ('biPlanes', wt.WORD), ('biBitCount', wt.WORD), ('biCompression', wt.DWORD),
        ('biSizeImage', wt.DWORD), ('biXPelsPerMeter', wt.LONG),
        ('biYPelsPerMeter', wt.LONG), ('biClrUsed', wt.DWORD), ('biClrImportant', wt.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [('bmiHeader', BITMAPINFOHEADER), ('bmiColors', wt.DWORD * 3)]


user32.FindWindowW.restype = wt.HWND
user32.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
gdi32.GetDIBits.argtypes = [wt.HDC, wt.HBITMAP, wt.UINT, wt.UINT,
                            ctypes.c_void_p, ctypes.POINTER(BITMAPINFO), wt.UINT]


def find(title):
    hwnd = user32.FindWindowW(None, title)
    if not hwnd:
        found = []

        @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
        def cb(h, _):
            n = user32.GetWindowTextLengthW(h)
            if n:
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(h, buf, n + 1)
                if title in buf.value:
                    found.append((h, buf.value))
            return True

        user32.EnumWindows(cb, 0)
        if found:
            return found[0][0]
    return hwnd


def grab_window(hwnd, path):
    user32.ShowWindow(hwnd, SW_RESTORE)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.6)
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.right - r.left, r.bottom - r.top
    if w <= 0 or h <= 0:
        raise RuntimeError('窗口尺寸异常 %dx%d' % (w, h))

    hdc = user32.GetWindowDC(hwnd)
    mem = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mem, bmp)
    ok = user32.PrintWindow(hwnd, mem, PW_RENDERFULLCONTENT)
    if not ok:
        gdi32.BitBlt(mem, 0, 0, w, h, hdc, 0, 0, SRCCOPY)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h
    bi.bmiHeader.biPlanes = 1
    bi.bmiHeader.biBitCount = 32
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bi), DIB_RGB_COLORS)
    Image.frombuffer('RGB', (w, h), buf, 'raw', 'BGRX', 0, 1).save(path)

    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem)
    user32.ReleaseDC(hwnd, hdc)
    return w, h


if __name__ == '__main__':
    title = sys.argv[1]
    out = sys.argv[2]
    hwnd = find(title)
    if not hwnd:
        print('NO_WINDOW')
        sys.exit(2)
    print('hwnd=%s' % hwnd, grab_window(hwnd, out), out)
