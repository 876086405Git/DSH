package io.github.ccch1mneyyy.dsh_app.companion

import org.json.JSONObject

/** The pinned BGE Chinese tokenizer's cased BERT/WordPiece configuration.
 * No vocabulary is guessed or bundled: it is read from its revision-pinned
 * tokenizer.json, and unsupported normalization configurations fail loading.
 * Algorithm reference: Hugging Face's Apache-2.0 BERT tokenizer documentation;
 * this is an independent Kotlin implementation for the specific model.
 */
internal class CompanionWordPiece(json: String) {
    private val vocabulary = HashMap<String, Int>()
    private val special = linkedMapOf("[PAD]" to 0, "[UNK]" to 100, "[CLS]" to 101, "[SEP]" to 102, "[MASK]" to 103)
    private val maxWord: Int

    init {
        val root = JSONObject(json)
        val normalizer = root.getJSONObject("normalizer")
        require(normalizer.getString("type") == "BertNormalizer")
        require(normalizer.getBoolean("clean_text") && normalizer.getBoolean("handle_chinese_chars"))
        require(!normalizer.getBoolean("lowercase"))
        require(normalizer.isNull("strip_accents") || !normalizer.getBoolean("strip_accents"))
        require(root.getJSONObject("pre_tokenizer").getString("type") == "BertPreTokenizer")
        val model = root.getJSONObject("model")
        require(model.getString("type") == "WordPiece" && model.getString("unk_token") == "[UNK]")
        require(model.getString("continuing_subword_prefix") == "##")
        maxWord = model.getInt("max_input_chars_per_word")
        require(maxWord == 100)
        val raw = model.getJSONObject("vocab")
        require(raw.length() == 21128)
        val ids = BooleanArray(raw.length())
        for (word in raw.keys()) {
            val id = raw.getInt(word)
            require(id in ids.indices && !ids[id])
            ids[id] = true
            vocabulary[word] = id
        }
        for ((word, id) in special) require(vocabulary[word] == id)
    }

    /** One sequence, at most 512 tokens including the two model delimiters. */
    fun encode(text: String): LongArray {
        require(text.length <= 65536)
        val result = ArrayList<Int>(512)
        result.add(101)
        val ordinary = StringBuilder()
        fun flush() {
            if (ordinary.isEmpty()) return
            for (word in basic(ordinary.toString())) {
                for (id in pieces(word)) {
                    if (result.size == 511) break
                    result.add(id)
                }
                if (result.size == 511) break
            }
            ordinary.setLength(0)
        }
        var index = 0
        while (index < text.length && result.size < 511) {
            val matched = special.entries.firstOrNull { text.startsWith(it.key, index) }
            if (matched != null) {
                flush()
                if (result.size < 511) result.add(matched.value)
                index += matched.key.length
            } else {
                val cp = Character.codePointAt(text, index)
                ordinary.appendCodePoint(cp)
                index += Character.charCount(cp)
            }
        }
        flush()
        result.add(102)
        return LongArray(result.size) { result[it].toLong() }
    }

    private fun basic(text: String): List<String> {
        val words = ArrayList<String>()
        val word = StringBuilder()
        fun flush() {
            if (word.isNotEmpty()) words.add(word.toString())
            word.setLength(0)
        }
        var index = 0
        while (index < text.length) {
            val cp = Character.codePointAt(text, index)
            index += Character.charCount(cp)
            if (cp == 0 || cp == 0xfffd || control(cp)) continue
            when {
                Character.isWhitespace(cp) || Character.isSpaceChar(cp) -> flush()
                chinese(cp) || punctuation(cp) -> {
                    flush()
                    words.add(String(Character.toChars(cp)))
                }
                else -> word.appendCodePoint(cp)
            }
        }
        flush()
        return words
    }

    private fun pieces(word: String): List<Int> {
        val cps = word.codePoints().toArray()
        if (cps.size > maxWord) return listOf(100)
        val found = ArrayList<Int>()
        var start = 0
        while (start < cps.size) {
            var end = cps.size
            var id: Int? = null
            while (end > start) {
                val part = (if (start == 0) "" else "##") + String(cps, start, end - start)
                id = vocabulary[part]
                if (id != null) break
                end--
            }
            // WordPiece rejects the whole word if a later suffix is unknown.
            if (id == null) return listOf(100)
            found.add(id)
            start = end
        }
        return found
    }

    private fun control(cp: Int): Boolean {
        if (cp == 9 || cp == 10 || cp == 13) return false
        return when (Character.getType(cp)) {
            Character.CONTROL.toInt(), Character.FORMAT.toInt(), Character.PRIVATE_USE.toInt(),
            Character.SURROGATE.toInt(), Character.UNASSIGNED.toInt() -> true
            else -> false
        }
    }

    private fun punctuation(cp: Int): Boolean {
        if (cp in 33..47 || cp in 58..64 || cp in 91..96 || cp in 123..126) return true
        return when (Character.getType(cp)) {
            Character.CONNECTOR_PUNCTUATION.toInt(), Character.DASH_PUNCTUATION.toInt(),
            Character.START_PUNCTUATION.toInt(), Character.END_PUNCTUATION.toInt(),
            Character.INITIAL_QUOTE_PUNCTUATION.toInt(), Character.FINAL_QUOTE_PUNCTUATION.toInt(),
            Character.OTHER_PUNCTUATION.toInt() -> true
            else -> false
        }
    }

    private fun chinese(cp: Int): Boolean = cp in 0x4e00..0x9fff || cp in 0x3400..0x4dbf ||
        cp in 0x20000..0x2a6df || cp in 0x2a700..0x2b73f || cp in 0x2b740..0x2b81f ||
        cp in 0x2b820..0x2ceaf || cp in 0xf900..0xfaff || cp in 0x2f800..0x2fa1f
}
