class StreamingAsrModel {
  const StreamingAsrModel({required this.encoder, required this.decoder, required this.joiner, required this.tokens})
    : isSystem = false;

  /// Explicit system backend selection, never an assertion that model files exist.
  const StreamingAsrModel.system() : encoder = '', decoder = '', joiner = '', tokens = '', isSystem = true;

  final bool isSystem;

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}
