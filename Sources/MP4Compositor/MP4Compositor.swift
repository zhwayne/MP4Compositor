//
// Created by iya on 2022/12/20.
//

import Foundation
import AVFoundation
import Combine
import UIKit
import CoreImage

public final class MP4Compositor {
    
    private var assetWriter: AVAssetWriter?
    
    private let videoAssetWriterInput: AVAssetWriterInput
    
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    
    private let audioAppAssetWriterInput: AVAssetWriterInput
    
    private let audioMicAssetWriterInput: AVAssetWriterInput
    
    /// 上一帧的媒体时间戳。
    private lazy var lastVideoFrameTime: CFTimeInterval = CACurrentMediaTime()
    
    /// 视频的总时长，以纳秒为单位。
    private var videoDuration: Int64 = 0
    
    private(set) var thumbnail: CIImage?
    
    private var backgroundTask: UIBackgroundTaskIdentifier?
    
    private var backgroundTaskCancellable: AnyCancellable?
        
    private var error: Error?
    
    private var url: URL?
        
    private var sourceTime: CMTime = .zero
    
    private var lastTimeIntervalBetweenTowFrams: TimeInterval = 0
    
    deinit {
        print("\(#function)[\(#line)] \(#fileID)")
    }
    
    public init(videoConfiguration: VideoConfiguration = .default,
         audioConfiguration: AudioConfiguration = .default,
         url: URL? = nil) throws {

        // 初始化 assetWriter。
        self.url = url ?? Self.getDefaultVideoURL()
        assetWriter = try AVAssetWriter(url: self.url!, fileType: .mp4)
        assetWriter!.shouldOptimizeForNetworkUse = true
        
        // 初始化 videoAssetWriterInput。
        let videoOutputSettings = videoConfiguration.outputSettings
        videoAssetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoAssetWriterInput.expectsMediaDataInRealTime = true

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoAssetWriterInput)
        
        // 初始化 audioAssetWriterInput。
        let audioOutputSettings = audioConfiguration.outputSettings
        audioAppAssetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        audioAppAssetWriterInput.expectsMediaDataInRealTime = true
        audioMicAssetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        audioMicAssetWriterInput.expectsMediaDataInRealTime = true
        
        // 添加 Inputs
        if assetWriter!.canAdd(videoAssetWriterInput) {
            assetWriter!.add(videoAssetWriterInput)
        }
        if assetWriter!.canAdd(audioAppAssetWriterInput) {
            assetWriter!.add(audioAppAssetWriterInput)
        }
        if assetWriter!.canAdd(audioMicAssetWriterInput) {
            assetWriter!.add(audioMicAssetWriterInput)
        }
        
        // 后台任务处理
        backgroundTaskCancellable = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] note in
                self?.beginBackgroundTask()
            }
    }
}

extension MP4Compositor {
    
    private static func getDefaultVideoURL() -> URL {
        let tmp = NSTemporaryDirectory()
        let fileName = "\(UUID().uuidString).mp4"
        let path = (tmp as NSString).appendingPathComponent(fileName)
        return URL(fileURLWithPath: path)
    }
}

extension MP4Compositor {
    
    public func requestThumbnail() -> UIImage? {
        guard let thumbnail = thumbnail else { return nil }
        return UIImage(ciImage: thumbnail)
    }
}

extension MP4Compositor {
    
    public struct VideoConfiguration {
        /// 视频宽度（像素）
        public var width: Int
        /// 视频高度（像素）
        public var height: Int
        /// 每像素比特
        public var bitsPerPixel: Int
        /// 最大关键帧间隔
        public var maxKeyFrameInterval: Int
        
        public static let `default` = VideoConfiguration(
            width: 720,
            height: 1280,
            bitsPerPixel: 6,
            maxKeyFrameInterval: 15
        )
        
        public init(width: Int, height: Int, bitsPerPixel: Int, maxKeyFrameInterval: Int) {
            self.width = width
            self.height = height
            self.bitsPerPixel = bitsPerPixel
            self.maxKeyFrameInterval = maxKeyFrameInterval
        }
    }
    
    public struct AudioConfiguration {
        /// 采样率
        public var sampleRate: Int
        /// 声道数
        public var numberOfChannels: Int
        /// 每声道的比特率
        public var bitRatePerChannel: Int
        
        public static let `default` = AudioConfiguration(
            sampleRate: 22050,
            numberOfChannels: 2,
            bitRatePerChannel: 28000
        )
        
        public init(sampleRate: Int, numberOfChannels: Int, bitRatePerChannel: Int) {
            self.sampleRate = sampleRate
            self.numberOfChannels = numberOfChannels
            self.bitRatePerChannel = bitRatePerChannel
        }
    }
}

extension MP4Compositor.VideoConfiguration {
    
    fileprivate var outputSettings: [String: Any] {
        let numPixels = width * height
        let averageBitRate = numPixels * bitsPerPixel
        
        let compressionProperties = [
            AVVideoAverageBitRateKey: averageBitRate,
            AVVideoMaxKeyFrameIntervalKey: maxKeyFrameInterval,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
        ] as [String: Any]
        
        let videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ] as [String: Any]
        
        return videoSettings
    }
}

extension MP4Compositor.AudioConfiguration {
    
    fileprivate var outputSettings: [String: Any] {
        
        let audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: numberOfChannels,
            AVEncoderBitRatePerChannelKey: bitRatePerChannel
        ] as [String: Any]
        
        return audioSettings
    }
}

extension MP4Compositor: VideoRecordable {
    
    private func beginBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "VideoCompositorBackgroundTask",
            expirationHandler: { [weak self] in
                guard let self else { return }
                Task { try? await self.finishWriting() }
            }
        )
    }
    
    private func endBackgroundTask() {
        if let backgroundTask, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            self.backgroundTask = .invalid
        }
    }
    
    private func makeSourceTime() -> CMTime {
        // 获取当前帧和上一帧之间的时间差
        var timeInterval = max(CACurrentMediaTime() - lastVideoFrameTime, 0.001)
        if timeInterval > 0.1 {
            timeInterval = lastTimeIntervalBetweenTowFrams
        }
        defer {
            lastVideoFrameTime = CACurrentMediaTime()
            lastTimeIntervalBetweenTowFrams = timeInterval
        }
        videoDuration += Int64(timeInterval * 1_000_000_000)
        return CMTime(value: videoDuration, timescale: 1_000_000_000)
    }
    
    public func write(buffer: VideoBuffer) {
        guard let assetWriter else {
            return
        }
        // 处理错误
        if assetWriter.status == .failed, let error = assetWriter.error {
            self.error = error
            self.url = nil
            print("write buffer error: \(error)")
            endBackgroundTask()
        }
        guard self.url != nil else {
            return
        }
        sourceTime = makeSourceTime()
        
        if assetWriter.status == .unknown {
            guard assetWriter.startWriting() else { return }
            assetWriter.startSession(atSourceTime: sourceTime)
        }
        
        if assetWriter.status == .writing || assetWriter.status == .unknown {
            switch buffer {
            case .audioApp(let buffer):
                if let buffer = try? buffer.adjustTime(sourceTime),
                   audioAppAssetWriterInput.isReadyForMoreMediaData {
                    audioAppAssetWriterInput.append(buffer)
                }
            case .audioMic(let buffer):
                if let buffer = try? buffer.adjustTime(sourceTime),
                   audioMicAssetWriterInput.isReadyForMoreMediaData {
                    audioMicAssetWriterInput.append(buffer)
                }
            case .video(let buffer):
                if let buffer = try? buffer.adjustTime(sourceTime),
                   videoAssetWriterInput.isReadyForMoreMediaData {
                    videoAssetWriterInput.append(buffer)
                }
                if thumbnail == nil, let imageBuffer = buffer.imageBuffer {
                    thumbnail = CIImage(cvImageBuffer: imageBuffer)
                }
            case .pixel(let buffer):
                if videoAssetWriterInput.isReadyForMoreMediaData {
                    pixelBufferAdaptor.append(buffer, withPresentationTime: sourceTime)
                }
                if thumbnail == nil {
                    thumbnail = CIImage(cvImageBuffer: buffer)
                }
            }
        }
    }
    
    @discardableResult
    public func finishWriting() async throws -> URL? {
        defer { self.endBackgroundTask() }
        // 如果有错误则直接抛出
        if let error = self.error {
            throw error
        }
        // 如果不存在 assetWriter 则直接返回 url，因为 assetWriter 在结束录制完成后会被置空。
        guard let assetWriter = self.assetWriter else {
            return url
        }
        
        switch assetWriter.status {
        case .unknown, .cancelled:
            return nil
        case .completed:
            if let error = self.error { throw error } else { return url }
        case .failed:
            if let error = self.error { throw error } else { return nil }
        case .writing: break;
        @unknown default:
            fatalError()
        }
        
        videoAssetWriterInput.markAsFinished()
        audioMicAssetWriterInput.markAsFinished()
        audioAppAssetWriterInput.markAsFinished()
        
        await assetWriter.finishWriting()
        self.assetWriter = nil
        if let error = assetWriter.error {
            throw error
        } else {
            return url
        }
    }
}


extension CVPixelBuffer {
    
    /// `CVPixelBuffer` to `CMSampleBuffer`.
    func asSampleBuffer(timingInfo: inout CMSampleTimingInfo) -> CMSampleBuffer? {
        guard let formatDescription = CMFormatDescription.make(from: self) else {
            return nil
        }
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: self,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        if let sampleBuffer = sampleBuffer {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                           to: CFMutableDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
            let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(dictionary, key, value)
        }
        return sampleBuffer
    }
}


extension CMFormatDescription {
    
    static func make(from pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        return formatDescription
    }
}


extension CMSampleBuffer {
    
    func adjustTime(_ newTime: CMTime) throws -> CMSampleBuffer {
        var timingInfos = try self.sampleTimingInfos()
        (0..<timingInfos.count).forEach { idx in
            timingInfos[idx].decodeTimeStamp = newTime
            timingInfos[idx].presentationTimeStamp = newTime
        }
        return try CMSampleBuffer(copying: self, withNewTiming: timingInfos)
    }
}
