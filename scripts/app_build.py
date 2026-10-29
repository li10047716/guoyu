import base64
from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False

    @property
    def name(self):
        # 0.7.34：品牌统一为「果屿」，两个变体共用同一个显示名。
        return '果屿'

    @property
    def slug(self):
        return 'guoyu' if self.all_sources else 'guoyu-hongguo'

    @property
    def executable(self):
        """Windows 构建产物名，与 windows/CMakeLists.txt 的 BINARY_NAME 一致。"""
        return 'guoyu.exe'

    @property
    def arguments(self):
        return ['--all-sources'] if self.all_sources else []

    @property
    def flutter_arguments(self):
        return ['--dart-define=ALL_SOURCES=' + str(self.all_sources).lower()]

    @property
    def linker_flags(self):
        return '-s -w -X duanjuapp/native/core.buildAllSources=' + str(self.all_sources).lower()

    @classmethod
    def from_dart_defines(cls, encoded):
        values = {}
        for item in encoded.split(','):
            if not item:
                continue
            key, separator, value = base64.b64decode(item, validate=True).decode('utf-8').partition('=')
            if separator:
                values[key] = value
        return cls(values.get('ALL_SOURCES') == 'true')


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的果屿；默认构建仅红果的果屿')
