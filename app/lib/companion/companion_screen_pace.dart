/// What each frequency the person picks means, in one place. [glance]: how
/// often she looks (ms); [aside]: how often she may speak up properly (ms);
/// [salience]: the least that is worth that aside; [mindsBusy]: she waits
/// while the person types; [backsOff]: unanswered lines slow her down.
typedef CompanionScreenTempo = ({int glance, int aside, double salience, bool mindsBusy, bool backsOff});

const companionScreenTempos = <String, CompanionScreenTempo>{
  'quiet': (glance: 60000, aside: 180000, salience: .8, mindsBusy: true, backsOff: true),
  'normal': (glance: 20000, aside: 60000, salience: .7, mindsBusy: true, backsOff: false),
  'chatty': (glance: 10000, aside: 30000, salience: .6, mindsBusy: false, backsOff: false),
  'live': (glance: 5000, aside: 12000, salience: .5, mindsBusy: false, backsOff: false),
};

/// Local timing policy for optional screen companionship. It never sends a
/// request, displays a line, or writes a memory. The person's hourly limit,
/// if they set one, is reserved by the native observer before each line.
class CompanionScreenPace {
  String frequency = 'normal';
  int? _cheapAt;
  int? _seriousAt;
  int? _userAt;
  int _unanswered = 0;
  final List<String> _recentQuips = [];

  /// Salience at which she speaks up even while the person is busy.
  static const busySalience = .85;

  int get unanswered => _unanswered;

  CompanionScreenTempo get _tempo => companionScreenTempos[frequency] ?? companionScreenTempos['normal']!;

  void userSpoke(int? at) {
    if (at == null || (_userAt != null && at <= _userAt!)) return;
    _userAt = at;
    _unanswered = 0;
  }

  double _factor(int now) {
    // Quiet only: lines nobody answered slow her a quarter each, to twice at most.
    final backoff = _tempo.backsOff ? (1 + (_unanswered - 1) * .25).clamp(1.0, 2.0).toDouble() : 1.0;
    final replied = _userAt != null && now >= _userAt! && now - _userAt! <= 120000 ? .8 : 1.0;
    return backoff * replied;
  }

  bool cheapDue(int now) =>
      _cheapAt == null || now >= _cheapAt! && now - _cheapAt! >= (_tempo.glance * _factor(now)).ceil();

  void cheapStarted(int now) {
    _cheapAt = now;
  }

  bool seriousDue(int now, CompanionScreenReading reading, {required bool userBusy}) {
    if (reading.salience < _tempo.salience) return false;
    if (_userAt != null && (now < _userAt! || now - _userAt! < 3000)) return false;
    if (waitsForIdle(reading) && (userBusy || reading.busy)) return false;
    return _seriousAt == null || now >= _seriousAt! && now - _seriousAt! >= (_tempo.aside * _factor(now)).ceil();
  }

  /// Whether the aside must find the person idle: only where busy matters.
  bool waitsForIdle(CompanionScreenReading reading) => _tempo.mindsBusy && reading.salience < busySalience;

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
    if (quip) {
      _recentQuips.add(_normalize(reading.quip));
      if (_recentQuips.length > 12) _recentQuips.removeAt(0);
    }
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
    if (!salience.isFinite || salience < 0 || salience > 1 || mood.runes.length > 40 || emotion.runes.length > 24) {
      return null;
    }
    const scenes = {'gaming', 'coding', 'video', 'reading', 'chatting', 'idle', 'other'};
    return CompanionScreenReading(
      scene: scenes.contains(value['scene']) ? value['scene']! as String : 'other',
      mood: mood,
      salience: salience,
      busy: value['busy']! as bool,
      // Too long for her bubble: only the quip is dropped, the reading stays.
      quip: quip.runes.length > 30 ? '' : quip,
      emotion: emotion.isEmpty ? 'neutral' : emotion,
    );
  }
}
