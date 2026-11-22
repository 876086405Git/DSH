// The parts of Discourse's JSON the forum pages use. Field names follow
// Discourse's serializers (TopicListItemSerializer, PostSerializer,
// NotificationSerializer, CurrentUserSerializer…); every reader is lenient — a
// missing or odd field becomes a default, never a crash — because plugins and
// versions add, drop and reshape fields.

import 'emoji.dart';

// ── JSON helpers ─────────────────────────────────────────────────────────────

Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
List<Object?> _list(Object? v) => v is List ? v : const [];
int _int(Object? v, [int fallback = 0]) => switch (v) {
  int n => n,
  num n => n.toInt(),
  String s => int.tryParse(s) ?? fallback,
  _ => fallback,
};
int? _intOrNull(Object? v) => switch (v) {
  int n => n,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};
String _str(Object? v, [String fallback = '']) => v is String ? v : (v == null ? fallback : '$v');
String? _strOrNull(Object? v) => v is String && v.isNotEmpty ? v : null;
bool _bool(Object? v) => v == true;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// Tags are `{id, name, slug}` objects on current Discourse and plain
/// strings on older ones.
List<String> _tags(Object? v) => [
  for (final t in _list(v))
    if (t is String && t.isNotEmpty) t else if (t is Map && t['name'] is String) t['name'] as String,
];

/// Decodes the few HTML entities Discourse leaves in titles and blurbs.
String decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
    final code = m[1]!;
    if (code.startsWith('#x') || code.startsWith('#X')) {
      final n = int.tryParse(code.substring(2), radix: 16);
      return n == null ? m[0]! : String.fromCharCode(n);
    }
    if (code.startsWith('#')) {
      final n = int.tryParse(code.substring(1));
      return n == null ? m[0]! : String.fromCharCode(n);
    }
    return switch (code) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'nbsp' => ' ',
      'hellip' => '…',
      'mdash' => '—',
      'ndash' => '–',
      'lsquo' => '‘',
      'rsquo' => '’',
      'ldquo' => '“',
      'rdquo' => '”',
      _ => m[0]!,
    };
  });
}

/// A title or blurb as shown: entities decoded, `:emoji:` as the character.
String forumPlainText(String text) => replaceEmojiShortcodes(decodeEntities(text));

// ── Users ────────────────────────────────────────────────────────────────────

/// Anyone shown with an avatar: a poster, a participant, the signed-in user.
class ForumUser {
  const ForumUser({required this.id, required this.username, this.name, this.avatarTemplate});

  factory ForumUser.fromJson(Object? json) {
    final m = _map(json);
    return ForumUser(
      id: _int(m['id']),
      username: _str(m['username']),
      name: _strOrNull(m['name']),
      avatarTemplate: _strOrNull(m['avatar_template']),
    );
  }

  final int id;
  final String username;
  final String? name;

  /// `/user_avatar/<host>/<name>/{size}/<id>.png` (or an absolute letter
  /// avatar URL); `{size}` is filled in by the client.
  final String? avatarTemplate;

  /// The name to show: the full name when set, else the username.
  String get displayName => (name?.trim().isNotEmpty ?? false) ? name!.trim() : username;
}

/// `/session/current.json`: who the key belongs to.
class ForumCurrentUser extends ForumUser {
  const ForumCurrentUser({
    required super.id,
    required super.username,
    super.name,
    super.avatarTemplate,
    this.unreadNotifications = 0,
    this.unreadHighPriority = 0,
    this.allUnread = 0,
    this.trustLevel = 0,
    this.canCreateTopic = true,
    this.admin = false,
    this.moderator = false,
  });

  factory ForumCurrentUser.fromJson(Object? json) {
    final root = _map(json);
    final m = root.containsKey('current_user') ? _map(root['current_user']) : root;
    final user = ForumUser.fromJson(m);
    final unread = _int(m['unread_notifications']);
    final high = _int(m['unread_high_priority_notifications']);
    return ForumCurrentUser(
      id: user.id,
      username: user.username,
      name: user.name,
      avatarTemplate: user.avatarTemplate,
      unreadNotifications: unread,
      unreadHighPriority: high,
      allUnread: m.containsKey('all_unread_notifications_count')
          ? _int(m['all_unread_notifications_count'])
          : unread + high,
      trustLevel: _int(m['trust_level']),
      canCreateTopic: m['can_create_topic'] != false,
      admin: _bool(m['admin']),
      moderator: _bool(m['moderator']),
    );
  }

  final int unreadNotifications;
  final int unreadHighPriority;

  /// The badge number: everything unread, private messages included.
  final int allUnread;
  final int trustLevel;
  final bool canCreateTopic;
  final bool admin;
  final bool moderator;

  ForumCurrentUser copyWith({int? allUnread}) => ForumCurrentUser(
    id: id,
    username: username,
    name: name,
    avatarTemplate: avatarTemplate,
    unreadNotifications: unreadNotifications,
    unreadHighPriority: unreadHighPriority,
    allUnread: allUnread ?? this.allUnread,
    trustLevel: trustLevel,
    canCreateTopic: canCreateTopic,
    admin: admin,
    moderator: moderator,
  );
}

/// `/u/<username>/summary.json` plus the card fields of `/u/<username>.json`.
class ForumUserSummary {
  const ForumUserSummary({
    this.topicCount = 0,
    this.postCount = 0,
    this.likesReceived = 0,
    this.likesGiven = 0,
    this.daysVisited = 0,
    this.solvedCount = 0,
  });

  factory ForumUserSummary.fromJson(Object? json) {
    final m = _map(_map(json)['user_summary']);
    return ForumUserSummary(
      topicCount: _int(m['topic_count']),
      postCount: _int(m['post_count']),
      likesReceived: _int(m['likes_received']),
      likesGiven: _int(m['likes_given']),
      daysVisited: _int(m['days_visited']),
      solvedCount: _int(m['solved_count']),
    );
  }

  final int topicCount;
  final int postCount;
  final int likesReceived;
  final int likesGiven;
  final int daysVisited;
  final int solvedCount;
}

// ── Categories ───────────────────────────────────────────────────────────────

class ForumCategory {
  const ForumCategory({
    required this.id,
    required this.name,
    required this.slug,
    this.color = '0088CC',
    this.textColor = 'FFFFFF',
    this.parentId,
    this.description,
    this.topicCount = 0,
    this.position = 0,
    this.permission,
    this.readRestricted = false,
  });

  factory ForumCategory.fromJson(Object? json) {
    final m = _map(json);
    return ForumCategory(
      id: _int(m['id']),
      name: forumPlainText(_str(m['name'])),
      slug: _str(m['slug']),
      color: _str(m['color'], '0088CC'),
      textColor: _str(m['text_color'], 'FFFFFF'),
      parentId: m['parent_category_id'] is int ? m['parent_category_id'] as int : null,
      description: _strOrNull(m['description_text']) ?? _strOrNull(m['description_excerpt']),
      topicCount: _int(m['topic_count']),
      position: _int(m['position']),
      permission: m['permission'] is int ? m['permission'] as int : null,
      readRestricted: _bool(m['read_restricted']),
    );
  }

  final int id;
  final String name;
  final String slug;

  /// Hex without `#`, as Discourse stores it.
  final String color;
  final String textColor;
  final int? parentId;
  final String? description;
  final int topicCount;
  final int position;

  /// For the signed-in user: 1 create topics, 2 reply only, 3 read only.
  /// Null when signed out (or not sent).
  final int? permission;
  final bool readRestricted;

  /// `0xFFRRGGBB` for [color] (grey when malformed).
  int get colorValue {
    var hex = color.replaceFirst('#', '');
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    final n = int.tryParse(hex, radix: 16);
    return n == null || hex.length != 6 ? 0xFF8A8F98 : 0xFF000000 | n;
  }

  /// Whether a new topic can go here (unknown permission counts as yes; the
  /// server has the last word).
  bool get canCreateTopic => permission == null || permission == 1;
}

/// `/site.json`: the categories and the notification type names.
class ForumSite {
  const ForumSite({
    this.categories = const [],
    this.notificationTypes = const {},
    this.canTagTopics = false,
    this.uncategorizedId,
  });

  factory ForumSite.fromJson(Object? json) {
    final m = _map(json);
    final categories = [for (final c in _list(m['categories'])) ForumCategory.fromJson(c)]
      ..sort((a, b) => a.position.compareTo(b.position));
    final types = <int, String>{
      for (final e in _map(m['notification_types']).entries)
        if (e.value is int) e.value as int: e.key,
    };
    return ForumSite(
      categories: categories,
      notificationTypes: types,
      canTagTopics: _bool(m['can_tag_topics']),
      uncategorizedId: m['uncategorized_category_id'] is int ? m['uncategorized_category_id'] as int : null,
    );
  }

  final List<ForumCategory> categories;

  /// Notification type id → name (`replied`, `liked`…).
  final Map<int, String> notificationTypes;
  final bool canTagTopics;

  /// 「未分类」: kept by Discourse even when posting there is off; not shown
  /// as a capsule or offered in the composer.
  final int? uncategorizedId;

  ForumCategory? category(int? id) {
    if (id == null) return null;
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Top-level categories, in the forum's order (the capsule row), without
  /// 「未分类」.
  List<ForumCategory> get topLevel => [
    for (final c in categories)
      if (c.parentId == null && c.id != uncategorizedId && c.slug.isNotEmpty) c,
  ];
}

// ── Topic lists ──────────────────────────────────────────────────────────────

/// One poster of a topic in a list (`posters[]`), resolved against the
/// list's `users[]`.
class ForumPoster {
  const ForumPoster({required this.user, this.description = '', this.latest = false});

  final ForumUser user;

  /// `Original Poster, Most Recent Poster` and the like.
  final String description;

  /// The most recent poster (Discourse's `extras: latest`).
  final bool latest;

  bool get original => description.contains('Original Poster');
}

class ForumTopic {
  const ForumTopic({
    required this.id,
    required this.title,
    this.slug = '',
    this.postsCount = 1,
    this.replyCount = 0,
    this.highestPostNumber = 1,
    this.views = 0,
    this.likeCount = 0,
    this.categoryId,
    this.createdAt,
    this.bumpedAt,
    this.lastPostedAt,
    this.pinned = false,
    this.closed = false,
    this.archived = false,
    this.excerpt,
    this.tags = const [],
    this.posters = const [],
    this.unseen = false,
    this.unreadPosts = 0,
    this.lastReadPostNumber,
    this.imageUrl,
    this.lastPosterUsername,
  });

  factory ForumTopic.fromJson(Object? json, [Map<int, ForumUser> users = const {}]) {
    final m = _map(json);
    final posters = <ForumPoster>[];
    for (final p in _list(m['posters'])) {
      final pm = _map(p);
      final user = users[_int(pm['user_id'], -1)];
      if (user == null) continue;
      posters.add(
        ForumPoster(
          user: user,
          description: _str(pm['description']),
          latest: _str(pm['extras']).split(' ').contains('latest'),
        ),
      );
    }
    final excerpt = _strOrNull(m['excerpt']);
    return ForumTopic(
      id: _int(m['id']),
      title: forumPlainText(_str(m['title'], _str(m['fancy_title']))),
      slug: _str(m['slug']),
      postsCount: _int(m['posts_count'], 1),
      replyCount: _int(m['reply_count'], _int(m['posts_count'], 1) - 1),
      highestPostNumber: _int(m['highest_post_number'], 1),
      views: _int(m['views']),
      likeCount: _int(m['like_count']),
      categoryId: m['category_id'] is int ? m['category_id'] as int : null,
      createdAt: _date(m['created_at']),
      bumpedAt: _date(m['bumped_at']),
      lastPostedAt: _date(m['last_posted_at']),
      pinned: _bool(m['pinned']),
      closed: _bool(m['closed']),
      archived: _bool(m['archived']),
      excerpt: excerpt == null ? null : forumPlainText(excerpt.replaceAll(RegExp(r'<[^>]*>'), '')),
      tags: _tags(m['tags']),
      posters: posters,
      unseen: _bool(m['unseen']),
      unreadPosts: _int(m['unread_posts'], _int(m['unread'])) + _int(m['new_posts']),
      lastReadPostNumber: m['last_read_post_number'] is int ? m['last_read_post_number'] as int : null,
      imageUrl: _strOrNull(m['image_url']),
      lastPosterUsername: _strOrNull(m['last_poster_username']),
    );
  }

  final int id;
  final String title;
  final String slug;
  final int postsCount;

  /// Posts after the first one (Discourse's own `reply_count` counts direct
  /// replies only; lists show `posts_count - 1`, see [replies]).
  final int replyCount;
  final int highestPostNumber;
  final int views;
  final int likeCount;
  final int? categoryId;
  final DateTime? createdAt;
  final DateTime? bumpedAt;
  final DateTime? lastPostedAt;
  final bool pinned;
  final bool closed;
  final bool archived;
  final String? excerpt;
  final List<String> tags;
  final List<ForumPoster> posters;

  /// Signed in: never opened.
  final bool unseen;

  /// Signed in: new posts since the last visit.
  final int unreadPosts;
  final int? lastReadPostNumber;
  final String? imageUrl;
  final String? lastPosterUsername;

  /// What a list shows as 「N 回复」.
  int get replies => postsCount > 0 ? postsCount - 1 : 0;

  /// The time a list shows: the last post, else the bump, else creation.
  DateTime? get activityAt => lastPostedAt ?? bumpedAt ?? createdAt;

  /// The original poster first, then the latest, then the rest; at most [max].
  List<ForumUser> avatars([int max = 3]) {
    final ordered = [...posters]
      ..sort((a, b) {
        int rank(ForumPoster p) => p.original ? 0 : (p.latest ? 1 : 2);
        return rank(a).compareTo(rank(b));
      });
    final seen = <int>{};
    return [
      for (final p in ordered)
        if (seen.add(p.user.id)) p.user,
    ].take(max).toList();
  }
}

/// One page of `/latest.json`, `/top.json`, `/c/…/l/latest.json`.
class ForumTopicListPage {
  const ForumTopicListPage({required this.topics, this.moreTopicsUrl, this.canCreateTopic = false});

  factory ForumTopicListPage.fromJson(Object? json) {
    final m = _map(json);
    final users = <int, ForumUser>{
      for (final u in _list(m['users']))
        if (_map(u)['id'] is int) _map(u)['id'] as int: ForumUser.fromJson(u),
    };
    final list = _map(m['topic_list']);
    return ForumTopicListPage(
      topics: [for (final t in _list(list['topics'])) ForumTopic.fromJson(t, users)],
      moreTopicsUrl: _strOrNull(list['more_topics_url']),
      canCreateTopic: _bool(list['can_create_topic']),
    );
  }

  final List<ForumTopic> topics;

  /// Present while there are more pages.
  final String? moreTopicsUrl;
  final bool canCreateTopic;

  bool get hasMore => moreTopicsUrl != null && topics.isNotEmpty;
}

// ── Topics and posts ─────────────────────────────────────────────────────────

class ForumPost {
  const ForumPost({
    required this.id,
    required this.postNumber,
    required this.topicId,
    required this.user,
    this.cooked = '',
    this.createdAt,
    this.updatedAt,
    this.replyToPostNumber,
    this.replyCount = 0,
    this.likeCount = 0,
    this.liked = false,
    this.canLike = false,
    this.canUnlike = false,
    this.bookmarked = false,
    this.bookmarkId,
    this.yours = false,
    this.hidden = false,
    this.deleted = false,
    this.postType = 1,
    this.userTitle,
    this.staff = false,
    this.acceptedAnswer = false,
    this.actionCode,
    this.replyToUsername,
  });

  factory ForumPost.fromJson(Object? json) {
    final m = _map(json);
    var likes = 0;
    var liked = false;
    var canLike = false;
    var canUnlike = false;
    for (final a in _list(m['actions_summary'])) {
      final am = _map(a);
      if (_int(am['id']) != _likeActionType) continue;
      likes = _int(am['count']);
      liked = _bool(am['acted']);
      canLike = _bool(am['can_act']);
      canUnlike = _bool(am['can_undo']);
    }
    // discourse-reactions: the main reaction is the like.
    if (m['current_user_used_main_reaction'] == true) liked = true;
    if (likes == 0 && m['like_count'] is int) likes = m['like_count'] as int;
    return ForumPost(
      id: _int(m['id']),
      postNumber: _int(m['post_number'], 1),
      topicId: _int(m['topic_id']),
      user: ForumUser(
        id: _int(m['user_id']),
        username: _str(m['username']),
        name: _strOrNull(m['name']),
        avatarTemplate: _strOrNull(m['avatar_template']),
      ),
      cooked: _str(m['cooked']),
      createdAt: _date(m['created_at']),
      updatedAt: _date(m['updated_at']),
      replyToPostNumber: m['reply_to_post_number'] is int ? m['reply_to_post_number'] as int : null,
      replyCount: _int(m['reply_count']),
      likeCount: likes,
      liked: liked,
      canLike: canLike,
      canUnlike: canUnlike,
      bookmarked: _bool(m['bookmarked']),
      bookmarkId: _intOrNull(m['bookmark_id']),
      yours: _bool(m['yours']),
      hidden: _bool(m['hidden']),
      deleted: m['deleted_at'] != null || _bool(m['user_deleted']),
      postType: _int(m['post_type'], 1),
      userTitle: _strOrNull(m['user_title']),
      staff: _bool(m['staff']) || _bool(m['admin']) || _bool(m['moderator']),
      acceptedAnswer: _bool(m['accepted_answer']),
      actionCode: _strOrNull(m['action_code']),
      replyToUsername: _strOrNull(_map(m['reply_to_user'])['username']),
    );
  }

  final int id;
  final int postNumber;
  final int topicId;
  final ForumUser user;

  /// Server-rendered HTML (render/cooked.dart reads it).
  final String cooked;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int? replyToPostNumber;
  final int replyCount;
  final int likeCount;
  final bool liked;
  final bool canLike;
  final bool canUnlike;
  final bool bookmarked;
  final int? bookmarkId;
  final bool yours;
  final bool hidden;
  final bool deleted;

  /// 1 regular, 2 moderator action, 3 small action (「置顶了话题」), 4 whisper.
  final int postType;
  final String? userTitle;
  final bool staff;
  final bool acceptedAnswer;

  /// For small actions: what happened (`pinned.enabled`, `closed.enabled`…).
  final String? actionCode;

  /// Whom this post answers (when it is a reply to a post other than the
  /// one right above or the first).
  final String? replyToUsername;

  /// A small action row (pinned, closed, moved…), not a real post.
  bool get isSmallAction => postType == 3;

  ForumPost copyWith({int? likeCount, bool? liked, bool? bookmarked, int? bookmarkId, bool clearBookmark = false}) =>
      ForumPost(
        id: id,
        postNumber: postNumber,
        topicId: topicId,
        user: user,
        cooked: cooked,
        createdAt: createdAt,
        updatedAt: updatedAt,
        replyToPostNumber: replyToPostNumber,
        replyCount: replyCount,
        likeCount: likeCount ?? this.likeCount,
        liked: liked ?? this.liked,
        canLike: canLike,
        canUnlike: canUnlike,
        bookmarked: bookmarked ?? this.bookmarked,
        bookmarkId: clearBookmark ? null : (bookmarkId ?? this.bookmarkId),
        yours: yours,
        hidden: hidden,
        deleted: deleted,
        postType: postType,
        userTitle: userTitle,
        staff: staff,
        acceptedAnswer: acceptedAnswer,
        actionCode: actionCode,
        replyToUsername: replyToUsername,
      );
}

/// Discourse's post action type id for a like.
const _likeActionType = 2;

/// `/t/<id>.json`: the topic, its first chunk of posts and the ids of all
/// the others (fetched in chunks through `/t/<id>/posts.json`).
class ForumTopicDetail {
  const ForumTopicDetail({
    required this.id,
    required this.title,
    this.slug = '',
    this.categoryId,
    this.postsCount = 1,
    this.views = 0,
    this.likeCount = 0,
    this.createdAt,
    this.lastPostedAt,
    this.closed = false,
    this.archived = false,
    this.pinned = false,
    this.tags = const [],
    this.stream = const [],
    this.posts = const [],
    this.canCreatePost = false,
    this.participants = const [],
    this.bookmarks = const {},
    this.chunkSize = 20,
  });

  factory ForumTopicDetail.fromJson(Object? json) {
    final m = _map(json);
    final stream = _map(m['post_stream']);
    final details = _map(m['details']);
    final bookmarks = <int, int>{
      for (final b in _list(m['bookmarks']))
        if (_map(b)['bookmarkable_type'] == 'Post' && _map(b)['bookmarkable_id'] is int && _map(b)['id'] is int)
          _map(b)['bookmarkable_id'] as int: _map(b)['id'] as int,
    };
    final posts = [
      for (final p in _list(stream['posts']))
        () {
          final post = ForumPost.fromJson(p);
          final bookmark = bookmarks[post.id];
          return bookmark == null ? post : post.copyWith(bookmarked: true, bookmarkId: bookmark);
        }(),
    ];
    return ForumTopicDetail(
      id: _int(m['id']),
      title: forumPlainText(_str(m['title'], _str(m['fancy_title']))),
      slug: _str(m['slug']),
      categoryId: m['category_id'] is int ? m['category_id'] as int : null,
      postsCount: _int(m['posts_count'], 1),
      views: _int(m['views']),
      likeCount: _int(m['like_count']),
      createdAt: _date(m['created_at']),
      lastPostedAt: _date(m['last_posted_at']),
      closed: _bool(m['closed']),
      archived: _bool(m['archived']),
      pinned: _bool(m['pinned']),
      tags: _tags(m['tags']),
      stream: [for (final id in _list(stream['stream'])) _int(id)],
      posts: posts,
      canCreatePost: _bool(details['can_create_post']),
      participants: [for (final u in _list(details['participants'])) ForumUser.fromJson(u)],
      bookmarks: bookmarks,
      chunkSize: _int(m['chunk_size'], 20),
    );
  }

  final int id;
  final String title;
  final String slug;
  final int? categoryId;
  final int postsCount;
  final int views;
  final int likeCount;
  final DateTime? createdAt;
  final DateTime? lastPostedAt;
  final bool closed;
  final bool archived;
  final bool pinned;
  final List<String> tags;

  /// Every post id in order.
  final List<int> stream;

  /// The posts loaded so far, in [stream] order.
  final List<ForumPost> posts;
  final bool canCreatePost;
  final List<ForumUser> participants;

  /// Post id → bookmark id, for the signed-in user.
  final Map<int, int> bookmarks;
  final int chunkSize;

  int get replies => postsCount > 0 ? postsCount - 1 : 0;

  /// Ids in [stream] not loaded yet, in order.
  List<int> get missing => _missing.toList();

  Iterable<int> get _missing {
    final loaded = {for (final p in posts) p.id};
    return stream.where((id) => !loaded.contains(id));
  }

  bool get hasMore => _missing.isNotEmpty;

  ForumTopicDetail copyWith({List<ForumPost>? posts, List<int>? stream, int? postsCount}) => ForumTopicDetail(
    id: id,
    title: title,
    slug: slug,
    categoryId: categoryId,
    postsCount: postsCount ?? this.postsCount,
    views: views,
    likeCount: likeCount,
    createdAt: createdAt,
    lastPostedAt: lastPostedAt,
    closed: closed,
    archived: archived,
    pinned: pinned,
    tags: tags,
    stream: stream ?? this.stream,
    posts: posts ?? this.posts,
    canCreatePost: canCreatePost,
    participants: participants,
    bookmarks: bookmarks,
    chunkSize: chunkSize,
  );
}

/// `/t/<id>/posts.json?post_ids[]=…`.
List<ForumPost> forumPostsFromJson(Object? json) => [
  for (final p in _list(_map(_map(json)['post_stream'])['posts'])) ForumPost.fromJson(p),
];

// ── Search ───────────────────────────────────────────────────────────────────

class ForumSearchHit {
  const ForumSearchHit({required this.topic, this.postNumber = 1, this.blurb = '', this.user, this.createdAt});

  final ForumTopic topic;
  final int postNumber;

  /// The matching text around the term (plain text).
  final String blurb;
  final ForumUser? user;
  final DateTime? createdAt;
}

class ForumSearchResult {
  const ForumSearchResult({this.hits = const [], this.more = false});

  factory ForumSearchResult.fromJson(Object? json) {
    final m = _map(json);
    final topics = <int, ForumTopic>{
      for (final t in _list(m['topics']))
        if (_map(t)['id'] is int) _map(t)['id'] as int: ForumTopic.fromJson(t),
    };
    final hits = <ForumSearchHit>[];
    for (final p in _list(m['posts'])) {
      final pm = _map(p);
      final topic = topics[_int(pm['topic_id'], -1)];
      if (topic == null) continue;
      hits.add(
        ForumSearchHit(
          topic: topic,
          postNumber: _int(pm['post_number'], 1),
          blurb: forumPlainText(_str(pm['blurb']).replaceAll(RegExp(r'<[^>]*>'), '')),
          user: ForumUser.fromJson(pm),
          createdAt: _date(pm['created_at']),
        ),
      );
    }
    final grouped = _map(m['grouped_search_result']);
    return ForumSearchResult(
      hits: hits,
      more: _bool(grouped['more_full_page_results']) || _bool(grouped['more_posts']),
    );
  }

  final List<ForumSearchHit> hits;
  final bool more;
}

// ── Notifications ────────────────────────────────────────────────────────────

class ForumNotification {
  const ForumNotification({
    required this.id,
    required this.type,
    this.read = false,
    this.highPriority = false,
    this.createdAt,
    this.topicId,
    this.postNumber,
    this.title,
    this.slug,
    this.data = const {},
    this.actorAvatarTemplate,
  });

  factory ForumNotification.fromJson(Object? json) {
    final m = _map(json);
    final data = _map(m['data']);
    final title = _strOrNull(m['fancy_title']) ?? _strOrNull(data['topic_title']);
    return ForumNotification(
      id: _int(m['id']),
      type: _int(m['notification_type']),
      read: _bool(m['read']),
      highPriority: _bool(m['high_priority']),
      createdAt: _date(m['created_at']),
      topicId: m['topic_id'] is int ? m['topic_id'] as int : null,
      postNumber: m['post_number'] is int ? m['post_number'] as int : null,
      title: title == null ? null : forumPlainText(title),
      slug: _strOrNull(m['slug']),
      data: data,
      actorAvatarTemplate: _strOrNull(m['acting_user_avatar_template']),
    );
  }

  final int id;

  /// Discourse notification type id (see [ForumSite.notificationTypes];
  /// the core ids are stable: 1 mentioned, 2 replied, 3 quoted, 5 liked…).
  final int type;
  final bool read;
  final bool highPriority;
  final DateTime? createdAt;
  final int? topicId;
  final int? postNumber;
  final String? title;
  final String? slug;
  final Map<String, Object?> data;
  final String? actorAvatarTemplate;

  /// Who did it (`display_username`, else `original_username`, else
  /// `username`).
  String? get actor =>
      _strOrNull(data['display_username']) ?? _strOrNull(data['original_username']) ?? _strOrNull(data['username']);

  /// For badge notifications.
  String? get badgeName => _strOrNull(data['badge_name']);

  /// For consolidated likes: how many.
  int get count => _int(data['count'], 1);

  ForumNotification asRead() => ForumNotification(
    id: id,
    type: type,
    read: true,
    highPriority: highPriority,
    createdAt: createdAt,
    topicId: topicId,
    postNumber: postNumber,
    title: title,
    slug: slug,
    data: data,
    actorAvatarTemplate: actorAvatarTemplate,
  );
}

class ForumNotificationPage {
  const ForumNotificationPage({this.notifications = const [], this.total = 0, this.hasMore = false});

  factory ForumNotificationPage.fromJson(Object? json) {
    final m = _map(json);
    final list = [for (final n in _list(m['notifications'])) ForumNotification.fromJson(n)];
    return ForumNotificationPage(
      notifications: list,
      total: _int(m['total_rows_notifications'], list.length),
      hasMore: _strOrNull(m['load_more_notifications']) != null && list.isNotEmpty,
    );
  }

  final List<ForumNotification> notifications;
  final int total;
  final bool hasMore;
}

// ── Writing ──────────────────────────────────────────────────────────────────

/// `/uploads.json`: what goes into the post (`upload://` short URL).
class ForumUpload {
  const ForumUpload({required this.shortUrl, required this.url, this.filename = 'image', this.width, this.height});

  factory ForumUpload.fromJson(Object? json) {
    final m = _map(json);
    return ForumUpload(
      shortUrl: _str(m['short_url']),
      url: _str(m['url']),
      filename: _str(m['original_filename'], 'image'),
      width: m['thumbnail_width'] is int ? m['thumbnail_width'] as int : _intOrNull(m['width']),
      height: m['thumbnail_height'] is int ? m['thumbnail_height'] as int : _intOrNull(m['height']),
    );
  }

  final String shortUrl;
  final String url;
  final String filename;
  final int? width;
  final int? height;

  /// The Markdown Discourse's own composer writes for an image.
  String get markdown {
    final alt = filename.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '').replaceAll(RegExp(r'[\[\]|]'), '');
    final size = width != null && height != null ? '|${width}x$height' : '';
    return '![${alt.isEmpty ? 'image' : alt}$size](${shortUrl.isEmpty ? url : shortUrl})';
  }
}
