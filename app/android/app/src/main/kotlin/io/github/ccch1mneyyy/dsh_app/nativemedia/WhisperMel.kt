package io.github.ccch1mneyyy.dsh_app.nativemedia

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Smart-turn's Whisper frontend. One worker owns this instance and its reused output. */
internal class WhisperMel {
    private val normalized = FloatArray(SAMPLES)
    private val window = DoubleArray(FFT) { 0.5 - 0.5 * cos(2 * PI * it / FFT) }
    private val frame = DoubleArray(FFT)
    private val transform = Fft400()
    private val power = DoubleArray(FFT / 2 + 1)
    private val filters = Array(MELS) { band ->
        val maxMel = 15.0 + ln(8.0) / (ln(6.4) / 27.0)
        fun hz(index: Int): Double {
            val mel = index * maxMel / (MELS + 1)
            return if (mel < 15.0) mel * (200.0 / 3.0) else 1000.0 * exp((mel - 15) * ln(6.4) / 27)
        }
        val left = hz(band)
        val center = hz(band + 1)
        val right = hz(band + 2)
        DoubleArray(power.size) { bin ->
            val frequency = bin * SAMPLE_RATE.toDouble() / FFT
            max(0.0, min((frequency - left) / (center - left), (right - frequency) / (right - center))) *
                2.0 / (right - left)
        }
    }
    private val firstBin = IntArray(MELS) { band -> filters[band].indexOfFirst { it > 0.0 } }
    private val lastBin = IntArray(MELS) { band -> filters[band].indexOfLast { it > 0.0 } }
    private val features = FloatArray(MELS * FRAMES)

    /** [audio] is 8 seconds, left-padded with zeros; output is mel-major [1, 80, 800]. */
    fun compute(audio: FloatArray): FloatArray {
        var mean = 0.0
        for (sample in audio) mean += sample
        mean /= SAMPLES
        var variance = 0.0
        for (sample in audio) {
            val centered = sample - mean
            variance += centered * centered
        }
        val scale = 1.0 / sqrt(variance / SAMPLES + 1e-7)
        for (i in 0 until SAMPLES) normalized[i] = ((audio[i] - mean) * scale).toFloat()

        // A short utterance is left-padded. Identical normalized samples give identical windowed FFT input.
        val firstBits = normalized[0].toRawBits()
        var prefix = 1
        while (prefix < SAMPLES && normalized[prefix].toRawBits() == firstBits) prefix++

        var peak = Float.NEGATIVE_INFINITY
        for (time in 0 until FRAMES) {
            val start = time * HOP - FFT / 2
            if (time > 0 && minOf(SAMPLES, start + FFT) <= prefix) {
                for (band in 0 until MELS) features[band * FRAMES + time] = features[band * FRAMES]
                continue
            }
            for (i in 0 until FFT) {
                val position = start + i
                val reflected = when {
                    position < 0 -> -position
                    position >= SAMPLES -> 2 * SAMPLES - 2 - position
                    else -> position
                }
                frame[i] = normalized[reflected] * window[i]
            }
            transform.power(frame, power)
            for (band in 0 until MELS) {
                var energy = 0.0
                val filter = filters[band]
                for (bin in firstBin[band]..lastBin[band]) energy += power[bin] * filter[bin]
                val value = log10(max(energy, 1e-10)).toFloat()
                features[band * FRAMES + time] = value
                if (value > peak) peak = value
            }
        }
        val floor = peak - 8.0f
        for (i in features.indices) features[i] = (max(features[i], floor) + 4.0f) / 4.0f
        return features
    }

    companion object {
        const val SAMPLE_RATE = 16000
        const val SAMPLES = 8 * SAMPLE_RATE
        const val MELS = 80
        const val FRAMES = 800
        private const val FFT = 400
        private const val HOP = 160
    }

    /** Mixed radix 4 x 4 x 5 x 5, with no per-frame allocations. */
    private class Fft400 {
        private val real = DoubleArray(FFT)
        private val imaginary = DoubleArray(FFT)
        private val cosines = DoubleArray(FFT) { cos(-2 * PI * it / FFT) }
        private val sines = DoubleArray(FFT) { sin(-2 * PI * it / FFT) }
        private val scratchReal = DoubleArray(5)
        private val scratchImaginary = DoubleArray(5)

        fun power(input: DoubleArray, output: DoubleArray) {
            fft(input, 0, 1, 0, FFT)
            for (i in output.indices) output[i] = real[i] * real[i] + imaginary[i] * imaginary[i]
        }

        private fun fft(input: DoubleArray, start: Int, stride: Int, target: Int, size: Int) {
            if (size == 1) {
                real[target] = input[start]
                imaginary[target] = 0.0
                return
            }
            val radix = if (size % 4 == 0) 4 else 5
            val subSize = size / radix
            for (part in 0 until radix) {
                fft(input, start + part * stride, stride * radix, target + part * subSize, subSize)
            }
            val rootStride = FFT / size
            for (bin in 0 until subSize) {
                for (part in 0 until radix) {
                    scratchReal[part] = real[target + part * subSize + bin]
                    scratchImaginary[part] = imaginary[target + part * subSize + bin]
                }
                for (part in 0 until radix) {
                    val frequency = bin + part * subSize
                    var re = 0.0
                    var im = 0.0
                    for (source in 0 until radix) {
                        val root = source * frequency * rootStride % FFT
                        re += scratchReal[source] * cosines[root] - scratchImaginary[source] * sines[root]
                        im += scratchReal[source] * sines[root] + scratchImaginary[source] * cosines[root]
                    }
                    real[target + frequency] = re
                    imaginary[target + frequency] = im
                }
            }
        }
    }
}
