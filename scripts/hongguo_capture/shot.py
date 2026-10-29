"""最小桌面截屏（Win32 GDI + Pillow），仅用于本地排障时的界面确认。"""
import ctypes
import ctypes.wintypes as wt
import sys

from PIL import Image

user32 = ctypes.WinDLL('user32', use_last_error=True)
gdi32 = ctypes.WinDLL('gdi32', use_last_error=True)

SM_CXSCREEN, SM_CYSCREEN = 0, 1
SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ('biSize', wt.DWORD), ('biWidth', wt.LONG), ('biHeight', wt.LONG),
        ('biPlanes', wt.WORD), ('biBitCount', wt.WORD), ('biCompression', wt.DWORD),
        ('biSizeImage', wt.DWORD), ('biXPelsPerMeter', wt.LONG),
        ('biYPelsPerMeter', wt.LONG), ('biClrUsed', wt.DWORD), ('biClrImportant', wt.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [('bmiHeader', BITMAPINFOHEADER), ('bmiColors', wt.DWORD * 3)]


def grab(path):
    w = user32.GetSystemMetrics(SM_CXSCREEN)
    h = user32.GetSystemMetrics(SM_CYSCREEN)
    screen_dc = user32.GetDC(0)
    mem_dc = gdi32.CreateCompatibleDC(screen_dc)
    bmp = gdi32.CreateCompatibleBitmap(screen_dc, w, h)
    gdi32.SelectObject(mem_dc, bmp)
    gdi32.BitBlt(mem_dc, 0, 0, w, h, screen_dc, 0, 0, SRCCOPY)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h
    bi.bmiHeader.biPlanes = 1
    bi.bmiHeader.biBitCount = 32
    bi.bmiHeader.biCompression = 0
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mem_dc, bmp, 0, h, buf, ctypes.byref(bi), DIB_RGB_COLORS)

    img = Image.frombuffer('RGB', (w, h), buf, 'raw', 'BGRX', 0, 1)
    img.save(path)

    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem_dc)
    user32.ReleaseDC(0, screen_dc)
    return w, h


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'shot.png'
    print(grab(out), out)
