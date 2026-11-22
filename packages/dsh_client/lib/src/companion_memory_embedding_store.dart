part of 'companion_memory_store.dart';

/// Derived, disposable vectors. They never grant model references or advance
/// the memory/control revision. The caller filters eligible candidates first;
/// these methods repeat the captured domain, exact row and dependency checks.
extension CompanionMemoryEmbeddingStore on CompanionMemoryStore {
  Map<String, List<double>> memoryEmbeddings({
    required String? characterId,
    required List<MemoryRow> candidates,
    required String modelKey,
    required int dimensions,
  }) {
    _embeddingShape(modelKey, dimensions);
    _checkMemoryCharacter(characterId);
    final found = <String, List<double>>{};
    for (final candidate in candidates) {
      final id = candidate['id'];
      final revision = candidate['row_rev'];
      if (id is! String || revision is! int || !_embeddingCardCurrent(id, revision, characterId)) continue;
      final rows = _db.select(
        '''
        SELECT vector FROM memory_embeddings
        WHERE card_id=? AND card_row_rev=? AND model_key=? AND dimensions=?
      ''',
        [id, revision, modelKey, dimensions],
      );
      if (rows.isEmpty) continue;
      final raw = rows.single['vector'];
      if (raw is! List<int> || raw.length != dimensions * 4) continue;
      final bytes = ByteData.sublistView(Uint8List.fromList(raw));
      final vector = List<double>.generate(dimensions, (i) => bytes.getFloat32(i * 4, Endian.little));
      var norm = 0.0;
      for (final value in vector) {
        norm += value * value;
      }
      // A damaged cache is a miss, never a NaN that can reorder the candidate
      // list or a reason to bypass the original memory eligibility rules.
      if (!norm.isFinite || (norm - 1).abs() > 0.001) continue;
      found[id] = List<double>.unmodifiable(vector);
    }
    return Map<String, List<double>>.unmodifiable(found);
  }

  /// An inference completed outside SQLite. A revision/domain change while it
  /// ran loses this compare-and-store; it cannot resurrect a forgotten card.
  bool saveMemoryEmbedding({
    required String? characterId,
    required String cardId,
    required int rowRevision,
    required String modelKey,
    required List<double> vector,
  }) {
    _embeddingShape(modelKey, vector.length);
    _checkMemoryCharacter(characterId);
    var squared = 0.0;
    for (final value in vector) {
      if (!value.isFinite) throw ArgumentError.value(vector, 'vector', 'Non-finite embedding');
      squared += value * value;
    }
    if (!squared.isFinite || squared <= 0) {
      throw ArgumentError.value(vector, 'vector', 'Empty or non-finite norm');
    }
    final length = math.sqrt(squared);
    final bytes = ByteData(vector.length * 4);
    for (var i = 0; i < vector.length; i++) {
      bytes.setFloat32(i * 4, vector[i] / length, Endian.little);
    }
    return _transaction(() {
      if (!_embeddingCardCurrent(cardId, rowRevision, characterId)) return false;
      _db.execute(
        '''
        INSERT INTO memory_embeddings(card_id,card_row_rev,model_key,dimensions,vector,created_at_ms)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(card_id,model_key) DO UPDATE SET
          card_row_rev=excluded.card_row_rev,dimensions=excluded.dimensions,
          vector=excluded.vector,created_at_ms=excluded.created_at_ms
      ''',
        [cardId, rowRevision, modelKey, vector.length, bytes.buffer.asUint8List(), _checkedNow()],
      );
      return true;
    });
  }

  /// Removing the optional on-device model may also remove its derived cache.
  /// Neither operation deletes or changes the user's memory text.
  void clearMemoryEmbeddings({required String modelKey}) {
    _db.execute('DELETE FROM memory_embeddings WHERE model_key=?', [modelKey]);
  }

  bool _embeddingCardCurrent(String id, int revision, String? characterId) {
    final rows = _db.select(
      '''
      SELECT collection FROM memory_cards
      WHERE id=? AND row_rev=? AND status!='withdrawn'
        AND (character_id IS NULL OR character_id=?)
    ''',
      [id, revision, characterId],
    );
    return rows.isNotEmpty &&
        _memoryLayer(rows.single['collection'] as String) == 'card' &&
        _memoryReferencesCurrent(id);
  }
}

void _embeddingShape(String modelKey, int dimensions) {
  if (modelKey.isEmpty || modelKey.length > 512 || modelKey.contains('\u0000') || dimensions < 1 || dimensions > 4096) {
    throw ArgumentError('Invalid embedding model identity or dimensions');
  }
}

const _memoryEmbeddingSchema16 = '''
CREATE TABLE memory_embeddings (
  card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
  card_row_rev INTEGER NOT NULL CHECK(card_row_rev>=1),
  model_key TEXT NOT NULL,
  dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096),
  vector BLOB NOT NULL CHECK(length(vector)=dimensions*4),
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(card_id,model_key)
);
CREATE TRIGGER memory_embeddings_revision AFTER UPDATE OF row_rev ON memory_cards
WHEN OLD.row_rev!=NEW.row_rev BEGIN
  DELETE FROM memory_embeddings WHERE card_id=NEW.id;
END;
''';
