/// 小说阅读的数据模型（0.7.61 新增）。
///
/// 字段与 Go 核心 `app_novels.go` 的 JSON 一一对应：
/// Novel / NovelChapterItem / NovelBook / NovelText。
library;

/// 书籍基本信息（搜索结果 / 详情 / 书架共用）。
class Novel {
  const Novel({
    required this.id,
    required this.source,
    required this.title,
    this.author = '',
    this.category = '',
    this.status = '',
    this.description = '',
    this.cover = '',
    this.latest = '',
    this.chapters = 0,
  });

  final String id;
  final String source;
  final String title;
  final String author;
  final String category;
  final String status;
  final String description;
  final String cover;
  final String latest;
  final int chapters;

  /// 唯一键：站源 + 书号（不同站源可能有同号书）。
  String get key => '$source:$id';

  /// 是否是本地导入的书（正文在本地磁盘，不走网络）。
  bool get isLocal => source == 'local';

  Novel copyWith({
    String? title,
    String? author,
    String? category,
    String? status,
    String? description,
    String? cover,
    String? latest,
    int? chapters,
  }) => Novel(
    id: id,
    source: source,
    title: title ?? this.title,
    author: author ?? this.author,
    category: category ?? this.category,
    status: status ?? this.status,
    description: description ?? this.description,
    cover: cover ?? this.cover,
    latest: latest ?? this.latest,
    chapters: chapters ?? this.chapters,
  );

  factory Novel.fromJson(Map<String, dynamic> json) => Novel(
    id: '${json['id'] ?? ''}',
    source: '${json['source'] ?? ''}',
    title: '${json['title'] ?? ''}',
    author: '${json['author'] ?? ''}',
    category: '${json['category'] ?? ''}',
    status: '${json['status'] ?? ''}',
    description: '${json['description'] ?? ''}',
    cover: '${json['cover'] ?? ''}',
    latest: '${json['latest'] ?? ''}',
    chapters: (json['chapters'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'author': author,
    'category': category,
    'status': status,
    'description': description,
    'cover': cover,
    'latest': latest,
    'chapters': chapters,
  };
}

/// 目录里的一章。
class NovelChapterItem {
  const NovelChapterItem({
    required this.index,
    required this.id,
    required this.title,
  });

  final int index;
  final String id;
  final String title;

  factory NovelChapterItem.fromJson(Map<String, dynamic> json) =>
      NovelChapterItem(
        index: (json['index'] as num?)?.toInt() ?? 0,
        id: '${json['id'] ?? ''}',
        title: '${json['title'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'index': index, 'id': id, 'title': title};
}

/// 详情页结果：书籍信息 + 完整目录。
class NovelBook {
  const NovelBook({required this.novel, required this.chapters});

  final Novel novel;
  final List<NovelChapterItem> chapters;

  factory NovelBook.fromJson(Map<String, dynamic> json) => NovelBook(
    novel: Novel.fromJson(json),
    chapters: [
      for (final row in json['chapterList'] as List? ?? const [])
        NovelChapterItem.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
}

/// 一章正文（按段落返回）。
class NovelText {
  const NovelText({
    required this.bookId,
    required this.chapterId,
    required this.title,
    required this.paragraphs,
  });

  final String bookId;
  final String chapterId;
  final String title;
  final List<String> paragraphs;

  factory NovelText.fromJson(Map<String, dynamic> json) => NovelText(
    bookId: '${json['bookId'] ?? ''}',
    chapterId: '${json['chapterId'] ?? ''}',
    title: '${json['title'] ?? ''}',
    paragraphs: [
      for (final row in json['paragraphs'] as List? ?? const []) '$row',
    ],
  );
}
