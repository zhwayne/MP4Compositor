//
//  VideoRecordable.swift
//
//  Created by iya on 2022/12/21.
//

import Foundation
import AVFoundation

public protocol VideoRecordable {
    
    /**
     写入视频数据。
     - Parameter buffer: 包含视频数据的 videoBuffer。
     */
    func write(buffer: VideoBuffer)
    
    /**
     结束写入视频数据。
     - Returns: 视频本地地址。若 url 为空，说明本次没有录制视频或者录制取消。
     - Throws: 写入失败的异常。
     */
    func finishWriting() async throws -> URL?
}

public extension VideoRecordable {
    
    /// 写入图片数据。
    /// - Parameter buffer: 包含者图片数据的 pixelBuffer。
    func write(pixel buffer: CVPixelBuffer) {
        write(buffer: .pixel(buffer))
    }
    
    /**
     写入视频数据。
     - Parameter buffer: 包含者视频数据的 sampleBuffer。
     */
    func write(video buffer: CMSampleBuffer) {
        write(buffer: .video(buffer))
    }
    
    /**
     写入 App 音频数据（可选）。
     - Parameter buffer: 包含音频数据的 sampleBuffer。
     */
    func write(audioApp buffer: CMSampleBuffer) {
        write(buffer: .audioApp(buffer))
    }
    
    /**
     写入麦克风音频数据。
     - Parameter buffer:  包含音频数据的 sampleBuffer。
     */
    func write(audioMic buffer: CMSampleBuffer) {
        write(buffer: .audioMic(buffer))
    }
}
