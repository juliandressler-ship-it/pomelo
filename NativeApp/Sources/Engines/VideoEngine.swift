import AVFoundation
import Foundation

struct VideoEngine: ConversionEngine {
    static let nativeTargets: Set<FileFormat> = [.mp4, .mov]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from.category == .video else { return false }
        return to.category == .video || Self.audioTargets.contains(to)
    }

    /// Audiospur aus einem Video (Phase 5, L11).
    static let audioTargets: Set<FileFormat> = [.mp3, .m4a, .wav]

    func convert(_ request: ConversionRequest) async throws {
        if Self.nativeTargets.contains(request.target), request.sourceFormat != .gif, await MediaInfo.isNativelyReadable(request.source) {
            do {
                let asset = AVURLAsset(url: request.source)
                try await AVExporter.export(asset: asset, to: request.destination, format: request.target, preset: AVAssetExportPresetHighestQuality, progress: request.progress)
                return
            } catch {
                try Task.checkCancellation()
                guard FFmpeg.isAvailable else { throw error }
            }
        }
        if Self.audioTargets.contains(request.target) {
            try await Self.extractAudio(request)
            return
        }
        try await Self.ffmpegConvert(source: request.source, destination: request.destination, target: request.target, progress: request.progress)
    }

    /// Audiospur speichern. M4A aus AAC wird nur umverpackt (keine Qualitätsverluste),
    /// sonst nativ (AVFoundation) und erst danach über ffmpeg.
    static func extractAudio(_ request: ConversionRequest) async throws {
        if request.sourceFormat != .gif, await MediaInfo.isNativelyReadable(request.source) {
            let asset = AVURLAsset(url: request.source)
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard !tracks.isEmpty else { throw OpenTangerineError.invalidInput("This video has no sound track.") }
            if request.target != .mp3 {
                do {
                    if request.target == .m4a {
                        try await AVExporter.export(asset: asset, to: request.destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, progress: request.progress)
                    } else {
                        try await AVExporter.exportAudioPCM(asset: asset, to: request.destination, format: request.target, progress: request.progress)
                    }
                    return
                } catch {
                    try Task.checkCancellation()
                    guard FFmpeg.isAvailable else { throw error }
                }
            }
        }
        if request.target == .m4a, await FFmpeg.audioCodec(of: request.source) == "aac" {
            let duration = await FFmpeg.probeDuration(request.source)
            try await FFmpeg.run(["-i", request.source.path, "-vn", "-map", "0:a:0", "-c:a", "copy", "-map_metadata", "0", "-f", "ipod", request.destination.path],
                                 purpose: "Extracting audio", duration: duration, progress: request.progress)
            return
        }
        try await AudioEngine.ffmpegConvert(source: request.source, destination: request.destination, target: request.target, progress: request.progress)
    }

    static func codecArguments(for target: FileFormat, videoBitrate: Int? = nil, audioBitrate: Int? = nil) -> [String] {
        var args: [String] = []
        switch target {
        case .mp4:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", "-f", "mp4"]
        case .mov:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "mov"]
        case .mkv:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "matroska"]
        case .webm:
            args += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-row-mt", "1", "-c:a", "libopus", "-f", "webm"]
        case .avi:
            args += ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "4", "-c:a", "libmp3lame", "-f", "avi"]
        case .wmv:
            args += ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2", "-f", "asf"]
        default:
            break
        }
        if let videoBitrate, target != .webm, target != .avi, target != .wmv {
            args += ["-b:v", "\(videoBitrate)", "-maxrate", "\(Int(Double(videoBitrate) * 1.4))", "-bufsize", "\(videoBitrate * 2)"]
        } else if target == .mp4 || target == .mov || target == .mkv {
            args += ["-crf", "20"]
        }
        if let audioBitrate, target != .avi, target != .wmv { args += ["-b:a", "\(audioBitrate)"] }
        return args
    }

    static func ffmpegConvert(source: URL, destination: URL, target: FileFormat, videoFilters: [String] = [], videoBitrate: Int? = nil, audioBitrate: Int? = nil, progress: @escaping (Double) -> Void) async throws {
        let duration = await FFmpeg.probeDuration(source)
        if target == .gif {
            let filters = videoFilters + ["fps=12", "scale='min(640,iw)':-2:flags=lanczos", "split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"]
            let args = ["-i", source.path, "-vf", filters.joined(separator: ","), "-loop", "0", "-f", "gif", destination.path]
            try await FFmpeg.run(args, purpose: "Creating GIF", duration: duration, progress: progress)
            return
        }
        var args = ["-i", source.path, "-map_metadata", "0"]
        var filters = videoFilters
        if target == .mp4 || target == .mov || target == .mkv || target == .webm {
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        args += codecArguments(for: target, videoBitrate: videoBitrate, audioBitrate: audioBitrate)
        args.append(destination.path)
        try await FFmpeg.run(args, purpose: "Converting to \(target.displayName)", duration: duration, progress: progress)
    }
}

