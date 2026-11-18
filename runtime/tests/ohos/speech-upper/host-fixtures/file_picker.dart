enum FileType { audio }
class HostPickedFile {
  Stream<List<int>> readAsByteStream() => throw UnimplementedError();
  int lengthSync() => throw UnimplementedError();
}
class FilePicker {
  static Future<HostPickedFile?> pickFile({required FileType type}) => throw UnimplementedError('file picker boundary');
}
