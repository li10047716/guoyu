const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');

/// 应用显示名。
///
/// 0.7.34：品牌由「真果鉴 / 红果鉴」统一为「果屿」。
/// 两个构建变体是同一个产品的不同站源授权范围，不再拆成两个名字，
/// 只在内部 slug（备份文件名、发布产物名）上区分。
const appName = '果屿';

/// 品牌标语，启动页使用。
const appSlogan = '你的娱乐宇宙，自成一岛';

/// 发布产物 / 备份文件名用的内部标识。
///
/// 仍按变体区分：全源版与红果版的备份文件混在一起时容易互相覆盖。
const appSlug = allSourcesEnabled ? 'guoyu' : 'guoyu-hongguo';
