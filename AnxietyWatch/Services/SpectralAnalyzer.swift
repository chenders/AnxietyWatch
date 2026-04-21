// AnxietyWatch/Services/SpectralAnalyzer.swift
import Accelerate

/// FFT-based spectral analysis using Apple's Accelerate framework.
/// Pure computation — no hardware dependencies.
enum SpectralAnalyzer {

    struct PowerSpectrum {
        let frequencies: [Float]    // Hz per bin
        let magnitudes: [Float]     // Power spectral density per bin
        let sampleRate: Float
    }

    /// Compute one-sided power spectral density via real FFT with Hann window.
    /// Returns nil if signal has fewer than 4 samples.
    static func computePSD(signal: [Float], sampleRate: Float) -> PowerSpectrum? {
        let count = signal.count
        guard count >= 4 else { return nil }

        let log2n = vDSP_Length(ceil(log2(Float(count))))
        let n = Int(1 << log2n)
        let halfN = n / 2

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Zero-pad to next power of 2
        var padded = [Float](repeating: 0, count: n)
        padded.replaceSubrange(0..<min(count, n), with: signal.prefix(n))

        // Apply Hann window to reduce spectral leakage
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(padded, 1, window, 1, &padded, 1, vDSP_Length(n))

        // Pack real signal into split complex for vDSP_fft_zrip:
        // even-indexed samples → realp, odd-indexed → imagp
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        padded.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        // Forward real-to-complex FFT in place
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // vDSP_fft_zrip packs DC into realp[0] and Nyquist into imagp[0].
        // Unpack them before computing magnitudes so bin 0 is pure DC power.
        let dcComponent = split.realp[0]
        let nyquistComponent = split.imagp[0]
        split.realp[0] = dcComponent
        split.imagp[0] = 0

        // Magnitude squared of each frequency bin
        var magnitudes = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))

        // DC and Nyquist are real-only — they appear once in the one-sided spectrum
        // so they get 1/N² normalization (not 2/N²).
        let dcNyquistScale = 1.0 / Float(n * n)
        magnitudes[0] = dcComponent * dcComponent * dcNyquistScale

        // Normalize remaining bins: 2/N² gives one-sided PSD
        var scale = 2.0 / Float(n * n)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))
        // Restore DC bin (was overwritten by vDSP_vsmul)
        magnitudes[0] = dcComponent * dcComponent * dcNyquistScale

        // Frequency axis: bin k corresponds to k * (sampleRate / N) Hz
        let freqResolution = sampleRate / Float(n)
        let frequencies = (0..<halfN).map { Float($0) * freqResolution }

        return PowerSpectrum(frequencies: frequencies, magnitudes: magnitudes, sampleRate: sampleRate)
    }

    /// Sum power spectral density within a frequency band [lowHz, highHz].
    static func bandPower(_ spectrum: PowerSpectrum, lowHz: Float, highHz: Float) -> Float {
        zip(spectrum.frequencies, spectrum.magnitudes)
            .filter { $0.0 >= lowHz && $0.0 <= highHz }
            .reduce(0) { $0 + $1.1 }
    }

    /// Root mean square of a signal.
    static func rms(_ signal: [Float]) -> Float {
        guard !signal.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(signal, 1, &result, vDSP_Length(signal.count))
        return result
    }
}
