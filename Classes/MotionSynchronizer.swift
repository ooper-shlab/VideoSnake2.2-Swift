//
//  MotionSynchronizer.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/11.
//
//
/*
 <codex>
 <abstract>Synchronizes motion samples with media samples</abstract>
 </codex>
 */

import Foundation
import CoreMedia
import CoreMotion

@objc(MotionSynchronizationDelegate)
protocol MotionSynchronizationDelegate: NSObjectProtocol {
    
    func motionSynchronizer(_ synchronizer: MotionSynchronizer, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, withMotion motion: CMDeviceMotion?)
    
}


private let MOTION_DEFAULT_SAMPLES_PER_SECOND = 60
private let MEDIA_ARRAY_SIZE = 5
private let MOTION_ARRAY_SIZE = 10

private let VIDEOSNAKE_REMAPPED_PTS = "RemappedPTS"

@objc(MotionSynchronizer)
class MotionSynchronizer: NSObject {
    
    var sampleBufferClock: CMClock?
    
    private weak var _delegate: MotionSynchronizationDelegate?
    private var _delegateCallbackQueue: DispatchQueue!
    
    private var motionClock: CMClock
    private var motionQueue: OperationQueue
    private var motionManager: CMMotionManager
    private var mediaSamples: [CMSampleBuffer] = []
    private var motionSamples: [CMDeviceMotion] = []
    
    override init() {
        
        mediaSamples.reserveCapacity(MEDIA_ARRAY_SIZE)
        motionSamples.reserveCapacity(MOTION_ARRAY_SIZE)
        
        motionQueue = OperationQueue()
        
        motionManager = CMMotionManager()
        
        motionClock = CMClockGetHostTimeClock()
        super.init()
        motionQueue.maxConcurrentOperationCount = 1 // Serial queue
        self.motionRate = MOTION_DEFAULT_SAMPLES_PER_SECOND.i
        
    }
    
    func start() {
        if !self.motionManager.isDeviceMotionActive {
            if self.sampleBufferClock == nil {
                fatalError("No sample buffer clock. Please set one before calling start.")
            }
            
            if self.motionManager.isDeviceMotionAvailable {
                let motionHandler: CMDeviceMotionHandler = {motion, error in
                    if error == nil {
                        self.appendMotionSampleForSynchronization(motion!)
                    } else {
                        NSLog("\(error!)")
                    }
                }
                
                self.motionManager.startDeviceMotionUpdates(to: self.motionQueue, withHandler: motionHandler)
            }
        }
    }
    
    func stop() {
        if self.motionManager.isDeviceMotionActive {
            self.motionManager.stopDeviceMotionUpdates() // no new blocks will be enqueued to self.motionQueue
            self.motionQueue.addOperation {
                synchronized(self) {
                    self.motionSamples.removeAll(keepingCapacity: true)
                }
            }
            synchronized(self) {
                self.mediaSamples.removeAll(keepingCapacity: true)
            }
        }
    }
    
    var motionRate: Int32 {
        get {
            let motionHz = Int(1.0 / self.motionManager.deviceMotionUpdateInterval)
            return motionHz.i
        }
        
        set {
            let updateIntervalSeconds = 1.0 / TimeInterval(newValue)
            self.motionManager.deviceMotionUpdateInterval = updateIntervalSeconds
        }
    }
    
    private func outputSampleBuffer(_ sampleBuffer: CMSampleBuffer, withSynchronizedMotionSample motion: CMDeviceMotion?) {
        _delegateCallbackQueue.async {
            autoreleasepool {
                self._delegate?.motionSynchronizer(self, didOutputSampleBuffer: sampleBuffer, withMotion: motion)
            }
        }
    }
    
    /*
    Outputs media samples with synchronized motion samples
    
    The media and motion arrays function like queues, with newer samples toward the end of the array. For each media sample, starting with the oldest, we look for the motion sample with the closest possible timestamp.
    
    We output a media sample in two cases:
    1) The difference between media sample and motion sample timestamps are getting larger, indicating that we've found the closest possible motion sample for a media sample.
    2) The media array has grown too large, in which case we sync with the closest motion sample we've found so far.
    */
    private func sync() {
        var lastSyncedMediaIndex = -1
        
        for mediaIndex in 0..<self.mediaSamples.count {
            let mediaSample = self.mediaSamples[mediaIndex]
            let mediaTimeDict = CMGetAttachment(mediaSample, key: VIDEOSNAKE_REMAPPED_PTS as CFString, attachmentModeOut: nil) as! CFDictionary?
            let mediaTime = (mediaTimeDict != nil) ? CMTimeMakeFromDictionary(mediaTimeDict!) : CMSampleBufferGetPresentationTimeStamp(mediaSample)
            let mediaTimeSeconds = CMTimeGetSeconds(mediaTime)
            var closestDifference = Double.greatestFiniteMagnitude
            var closestMotionIndex = 0
            
            for motionIndex in 0..<self.motionSamples.count {
                let motionSample = self.motionSamples[motionIndex]
                let motionTimeSeconds = motionSample.timestamp
                let difference = fabs(mediaTimeSeconds - motionTimeSeconds)
                if difference > closestDifference {
                    // Sync as soon as the timestamp difference begins to increase
                    self.outputSampleBuffer(mediaSample, withSynchronizedMotionSample: self.motionSamples[closestMotionIndex])
                    lastSyncedMediaIndex = mediaIndex
                    break
                } else {
                    closestDifference = difference
                    closestMotionIndex = motionIndex
                }
            }
            
            // If we haven't yet found the closest motion sample for this media sample, but the media array is too large, just sync with the closest motion sample we've seen so far
            if lastSyncedMediaIndex < mediaIndex && self.mediaSamples.count > MEDIA_ARRAY_SIZE {
                self.outputSampleBuffer(mediaSample, withSynchronizedMotionSample: (closestMotionIndex < self.motionSamples.count) ? self.motionSamples[closestMotionIndex] : nil)
                lastSyncedMediaIndex = mediaIndex
            }
            
            // If we synced this media sample with a motion sample, we won't need the motion samples that are older than the one we used; remove them
            if lastSyncedMediaIndex == mediaIndex && self.motionSamples.count > 0 {
                self.motionSamples.removeSubrange(0..<closestMotionIndex)
            }
        }
        
        // Remove synced media samples
        if lastSyncedMediaIndex >= 0 {
            self.mediaSamples.removeSubrange(0..<lastSyncedMediaIndex + 1)
        }
        
        // If the motion array is too large, remove the oldest motion samples
        if self.motionSamples.count > MOTION_ARRAY_SIZE {
            self.motionSamples.removeSubrange(0..<self.motionSamples.count - MOTION_ARRAY_SIZE)
        }
    }
    
    private func appendMotionSampleForSynchronization(_ motion: CMDeviceMotion) {
        synchronized(self) {
            self.motionSamples.append(motion)
            self.sync()
        }
    }
    
    func appendSampleBufferForSynchronization(_ sampleBuffer: CMSampleBuffer) {
        // Convert media timestamp to motion clock if necessary (i.e. we're recording audio, so media timestamps have been synced to the audio clock)
        if self.sampleBufferClock != nil {
            if !CFEqual(self.sampleBufferClock!, self.motionClock) {
                self.convertSampleBufferTimeToMotionClock(sampleBuffer)
            }
        }
        
        synchronized(self) {
            self.mediaSamples.append(sampleBuffer)
            self.sync()
        }
    }
    
    func setSynchronizedSampleBufferDelegate(_ sampleBufferDelegate: MotionSynchronizationDelegate, queue sampleBufferCallbackQueue: DispatchQueue?) {
        _delegate = sampleBufferDelegate
        
        _delegateCallbackQueue = sampleBufferCallbackQueue
        
    }
    
    private func convertSampleBufferTimeToMotionClock(_ sampleBuffer: CMSampleBuffer) {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let remappedPTS = CMSyncConvertTime(originalPTS, from: self.sampleBufferClock!, to: self.motionClock)
        
        // Attach the remapped timestamp to the buffer for use in -sync
        let remappedPTSDict = CMTimeCopyAsDictionary(remappedPTS, allocator: kCFAllocatorDefault)
        CMSetAttachment(sampleBuffer, key: VIDEOSNAKE_REMAPPED_PTS as CFString, value: remappedPTSDict, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        
    }
    
}
