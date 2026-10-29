"""从 1024 品牌母版生成各平台图标与启动图。

母版（build/icon-final/）：
- icon-1024-flat.png   满幅直角，用于 iOS 等**不允许透明**的场景；
- icon-1024-round.png  已带圆角，只作参考。

圆角、尺寸、密度全部在本脚本里算，母版更新后重跑一次即可：
    python scripts/generate_brand_assets.py
"""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
BRAND = '果屿'
SLOGAN = '你的娱乐宇宙，自成一岛'

# 圆角比例取自设计稿（1024 母版 / 228px 圆角）
RADIUS_RATIO = 228 / 1024
# 与启动动画、原生启动背景同色，避免从系统启动到 Flutter 首帧跳色
SPLASH_BG = (6, 10, 22)
SLOGAN_COLOR = (139, 149, 170)

ANDROID_LAUNCHER = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

FONT_CANDIDATES = [
    ('C:/Windows/Fonts/msyhbd.ttc', 0),
    ('C:/Windows/Fonts/msyh.ttc', 0),
    ('/System/Library/Fonts/PingFang.ttc', 0),
    ('/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc', 0),
    ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 0),
]


def load_font(size):
    for path, index in FONT_CANDIDATES:
        if Path(path).is_file():
            try:
                return ImageFont.truetype(path, size, index=index)
            except OSError:
                continue
    return ImageFont.load_default()


def resize(image, size):
    """两级缩放：先到 4 倍目标，再落到目标，避免小尺寸锯齿与振铃。"""
    wide = image.resize((size[0] * 4, size[1] * 4), Image.Resampling.LANCZOS)
    return wide.resize(size, Image.Resampling.LANCZOS)


def rounded(image, radius_ratio=RADIUS_RATIO):
    canvas = image.convert('RGBA')
    mask = Image.new('L', canvas.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, canvas.size[0] - 1, canvas.size[1] - 1),
        radius=round(canvas.size[0] * radius_ratio),
        fill=255,
    )
    canvas.putalpha(mask)
    return canvas


def save(image, relative):
    destination = ROOT / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)
    print(f'  {relative}  {image.size[0]}x{image.size[1]}')


def build_icon(flat, destination):
    """Windows .ico：多尺寸圆角图标，任务栏与资源管理器都取到清晰的那一层。"""
    icon = rounded(resize(flat, (256, 256)))
    target = ROOT / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    icon.save(
        target,
        format='ICO',
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f'  {destination}  16~256 多尺寸')


def build_flutter_logo(flat):
    save(rounded(resize(flat, (512, 512))), 'assets/branding/logo.png')


def build_android(flat):
    for folder, size in ANDROID_LAUNCHER.items():
        save(
            rounded(resize(flat, (size, size))),
            f'android/app/src/main/res/{folder}/ic_launcher.png',
        )


def build_ios(flat):
    contents = json.loads(
        (ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text()
    )
    for entry in contents['images']:
        filename = entry.get('filename')
        if not filename:
            continue
        points = float(entry['size'].split('x')[0])
        pixels = round(points * float(entry['scale'].rstrip('x')))
        # iOS 图标不能带 alpha，直接用直角母版
        save(
            resize(flat.convert('RGB'), (pixels, pixels)),
            'ios/Runner/Assets.xcassets/AppIcon.appiconset/' + filename,
        )


def build_tv_banner(flat, resources):
    """Android TV 启动横幅：320x180dp，xhdpi 出 640x360。"""
    banner = Image.new('RGBA', (640, 360), SPLASH_BG + (255,))
    # 左下角一层极淡的主色光晕，避免整块纯色显得死板
    glow = Image.new('RGBA', (640, 360), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((-120, 120, 420, 520), fill=(24, 62, 122, 90))
    banner = Image.alpha_composite(banner, glow).convert('RGB')
    draw = ImageDraw.Draw(banner)
    logo = rounded(resize(flat, (150, 150)))
    banner.paste(logo, (127, 105), logo)
    draw.text((313, 120), BRAND, font=load_font(64), fill=(242, 245, 250))
    draw.text((317, 226), SLOGAN, font=load_font(20), fill=SLOGAN_COLOR)
    for name in resources:
        save(banner, f'android/app/src/main/res/drawable-xhdpi/{name}.png')


def build_android_launch_background():
    """原生启动背景：从系统启动到 Flutter 首帧保持同一个深色底，不闪白。"""
    path = ROOT / 'android/app/src/main/res/drawable/launch_background.xml'
    path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- 由 scripts/generate_brand_assets.py 生成：与 Flutter 开屏页同底色，避免启动白闪 -->\n'
        '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <item android:drawable="@color/splash_background" />\n'
        '</layer-list>\n',
        encoding='utf-8',
    )
    values = ROOT / 'android/app/src/main/res/values/brand_colors.xml'
    values.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <color name="splash_background">#FF060A16</color>\n'
        '</resources>\n',
        encoding='utf-8',
    )
    print('  android/app/src/main/res/drawable/launch_background.xml')


def main():
    parser = argparse.ArgumentParser(description='生成果屿各平台图标与启动图；需要 Pillow。')
    parser.add_argument(
        '--source',
        type=Path,
        default=ROOT / 'build/icon-final/icon-1024-flat.png',
        help='1024x1024 满幅直角母版',
    )
    options = parser.parse_args()
    flat = Image.open(options.source)
    if flat.size != (1024, 1024):
        flat = flat.resize((1024, 1024), Image.Resampling.LANCZOS)
    print('Windows')
    build_icon(flat, 'windows/runner/resources/app_icon.ico')
    print('Flutter')
    build_flutter_logo(flat)
    print('Android')
    build_android(flat)
    build_tv_banner(flat, ['tv_banner', 'tv_banner_all_sources'])
    build_android_launch_background()
    print('iOS')
    build_ios(flat)


if __name__ == '__main__':
    main()
