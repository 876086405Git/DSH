/// Local timing policy for optional screen companionship. It never sends a
/// request, displays a line, or writes a memory. Hourly physical-attempt caps
/// are reserved by the native observer before a model call.
class CompanionScreenPace {
  String frequency = 'normal';
  int? _cheapAt;
  int? _seriousAt;
  int? _userAt;
  int _unanswered = 0;
  String _scene = 'other';
  final List<String> _recentQuips = [];

  int get unanswered => _unanswered;

  void userSpoke(int? at) {
    if (at == null || (_userAt != null && at <= _userAt!)) return;
    _userAt = at;
    _unanswered = 0;
  }

  double _factor(int now) {
    final backoff = _unanswered < 2
        ? 1.0
        : _unanswered == 2
        ? 1.5
        : (2.0 + (_unanswered - 3) * .5).clamp(2.0, 3.0).toDouble();
    final chosen = switch (frequency) {
      'quiet' => 2.0,
      'chatty' => .8,
      _ => 1.0,
    };
    final replied = _userAt != null && now >= _userAt! && now - _userAt! <= 120000 ? .8 : 1.0;
    return backoff * chosen * replied * (_scene == 'idle' ? 2 : 1);
  }

  bool cheapDue(int now) => _cheapAt == null || now >= _cheapAt! && now - _cheapAt! >= (30000 * _factor(now)).ceil();

  void cheapStarted(int now) {
    _cheapAt = now;
  }

  bool seriousDue(int now, CompanionScreenReading reading, {required bool userBusy}) {
    if (reading.salience <= .85) return false;
    if (_userAt != null && (now < _userAt! || now - _userAt! < 10000)) return false;
    if ((userBusy || reading.busy) && reading.salience < .95) return false;
    return _seriousAt == null || now >= _seriousAt! && now - _seriousAt! >= (180000 * _factor(now)).ceil();
  }

  void seriousStarted(int now) {
    _seriousAt = now;
  }

  bool quipIsNew(String text) {
    final value = _normalize(text);
    if (value.isEmpty) return false;
    return !_recentQuips.any((old) => _similar(old, value));
  }

  /// Only an actual visible presentation creates an unanswered opportunity.
  void shown(int now, CompanionScreenReading reading, {required bool quip}) {
    _unanswered++;
    _scene = reading.scene;
    if (quip) {
      _recentQuips.add(_normalize(reading.quip));
      if (_recentQuips.length > 12) _recentQuips.removeAt(0);
    }
  }

  void observed(CompanionScreenReading reading) {
    _scene = reading.scene;
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s，。！？、；：,.!?;:“”「」『』（）()【】\[\]—…]+'), '');

  static bool _similar(String left, String right) {
    if (left == right) return true;
    Set<String> pairs(String text) {
      final chars = text.runes.toList();
      return {
        for (var i = 0; i + 1 < chars.length; i++) String.fromCharCodes([chars[i], chars[i + 1]]),
      };
    }

    final a = pairs(left), b = pairs(right);
    return a.isNotEmpty && b.isNotEmpty && 2 * a.intersection(b).length / (a.length + b.length) >= .8;
  }
}

class CompanionScreenReading {
  const CompanionScreenReading({
    required this.scene,
    required this.mood,
    required this.salience,
    required this.busy,
    required this.quip,
    required this.emotion,
  });
  final String scene;
  final String mood;
  final double salience;
  final bool busy;
  final String quip;
  final String emotion;

  static CompanionScreenReading? parse(Map<String, Object?>? value) {
    if (value == null ||
        value['scene'] is! String ||
        value['mood'] is! String ||
        value['salience'] is! num ||
        value['busy'] is! bool ||
        value['quip'] is! String ||
        value['emotion'] is! String) {
      return null;
    }
    final salience = (value['salience']! as num).toDouble();
    final quip = (value['quip']! as String).trim();
    final mood = (value['mood']! as String).trim();
    final emotion = (value['emotion']! as String).trim();
    if (!salience.isFinite ||
        salience < 0 ||
        salience > 1 ||
        quip.runes.length > 20 ||
        mood.runes.length > 40 ||
        emotion.runes.length > 24) {
      return null;
    }
    const scenes = {'gaming', 'coding', 'video', 'reading', 'chatting', 'idle', 'other'};
    return CompanionScreenReading(
      scene: scenes.contains(value['scene']) ? value['scene']! as String : 'other',
      mood: mood,
      salience: salience,
      busy: value['busy']! as bool,
      quip: quip,
      emotion: emotion.isEmpty ? 'neutral' : emotion,
    );
  }
}
