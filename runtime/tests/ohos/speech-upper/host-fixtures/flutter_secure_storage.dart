// Explicit unused keystore boundary, not production storage.
class FlutterSecureStorage {
  const FlutterSecureStorage();
  Future<String?> read({required String key}) => throw UnimplementedError();
  Future<void> write({required String key, required String? value}) => throw UnimplementedError();
  Future<void> delete({required String key}) => throw UnimplementedError();
}
