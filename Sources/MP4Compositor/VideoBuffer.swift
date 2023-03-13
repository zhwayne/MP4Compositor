//
//  VideoBuffer.swift
//
//  Created by iya on 2023/1/7.
//

import Foundation
import CoreMedia
import CoreVideo

public enum VideoBuffer {
    case pixel(CVPixelBuffer)
    case video(CMSampleBuffer)
    case audioApp(CMSampleBuffer)
    case audioMic(CMSampleBuffer)
}
