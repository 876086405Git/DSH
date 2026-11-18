// Explicit unused persistence boundary. Preview tests never read preferences.
class SharedPreferences {
  static Future<SharedPreferences> getInstance() async => throw UnimplementedError('preferences boundary');
  String? getString(String key) => throw UnimplementedError();
  bool? getBool(String key) => throw UnimplementedError();
  Future<bool> setString(String key, String value) => throw UnimplementedError();
  Future<bool> setBool(String key, bool value) => throw UnimplementedError();
  Future<bool> remove(String key) => throw UnimplementedError();
}
