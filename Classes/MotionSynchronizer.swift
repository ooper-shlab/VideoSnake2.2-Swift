//
//  MotionSynchronizer.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/11.
//
//
/*
     File: MotionSynchronizer.h
     File: MotionSynchronizer.m
 Abstract: Synchronizes motion samples with media samples
  Version: 2.2

 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.

 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.

 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.

 Copyright (C) 2014 Apple Inc. All Rights Reserved.

 */

import Foundation
import CoreMedia
import CoreMotion

@objc(MotionSynchronizationDelegate)
protocol MotionSynchronizationDelegate: NSObjectProtocol {
    
    func motionSynchronizer(synchronizer: MotionSynchronizer, didOutputSampleBuffer sampleBuffer: CMSampleBufferRef, withMotion motion: CMDeviceMotion?)
    
}


private let MOTION_DEFAULT_SAMPLES_PER_SECOND = 60
private let MEDIA_ARRAY_SIZE = 5
private let MOTION_ARRAY_SIZE = 10

private let VIDEOSNAKE_REMAPPED_PTS = "RemappedPTS"

@objc(MotionSynchronizer)
class MotionSynchronizer: NSObject {
    
    var sampleBufferClock: CMClock?
    
    private weak var _delegate: MotionSynchronizationDelegate?
    private var _delegateCallbackQueue: dispatch_queue_t!
    
    private var motionClock: CMClock
    private var motionQueue: NSOperationQueue
    private var motionManager: CMMotionManager
    private var mediaSamples: [CMSampleBuffer] = []
    private var motionSamples: [CMDeviceMotion] = []
    
    override init() {
        
        mediaSamples.reserveCapacity(MEDIA_ARRAY_SIZE)
        motionSamples.reserveCapacity(MOTION_ARRAY_SIZE)
        
        motionQueue = NSOperationQueue()
        
        motionManager = CMMotionManager()
        
        motionClock = CMClockGetHostTimeClock()
        super.init()
        motionQueue.maxConcurrentOperationCount = 1 // Serial queue
        self.motionRate = MOTION_DEFAULT_SAMPLES_PER_SECOND.i
        
    }
    
    func start() {
        if !self.motionManager.deviceMotionActive {
            if self.sampleBufferClock == nil {
                fatalError("No sample buffer clock. Please set one before calling start.")
            }
            
            if self.motionManager.deviceMotionAvailable {
                let motionHandler: CMDeviceMotionHandler = {motion, error in
                    if error == nil {
                        self.appendMotionSampleForSynchronization(motion)
                    } else {
                        NSLog("%@", error!)
                    }
                }
                
                self.motionManager.startDeviceMotionUpdatesToQueue(self.motionQueue, withHandler: motionHandler)
            }
        }
    }
    
    func stop() {
        if self.motionManager.deviceMotionActive {
            self.motionManager.stopDeviceMotionUpdates() // no new blocks will be enqueued to self.motionQueue
            self.motionQueue.addOperationWithBlock {
                synchronized(self) {
                    self.motionSamples.removeAll(keepCapacity: true)
                }
            }
            synchronized(self) {
                self.mediaSamples.removeAll(keepCapacity: true)
            }
        }
    }
    
    var motionRate: Int32 {
        get {
            let motionHz = Int(1.0 / self.motionManager.deviceMotionUpdateInterval)
            return motionHz.i
        }
        
        set {
            let updateIntervalSeconds = 1.0 / NSTimeInterval(newValue)
            self.motionManager.deviceMotionUpdateInterval = updateIntervalSeconds
        }
    }
    
    private func outputSampleBuffer(sampleBuffer: CMSampleBuffer, withSynchronizedMotionSample motion: CMDeviceMotion?) {
        dispatch_async(_delegateCallbackQueue) {
            autoreleasepool {
                _delegate?.motionSynchronizer(self, didOutputSampleBuffer: sampleBuffer, withMotion: motion)
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
            let mediaTimeDict = CMGetAttachment(mediaSample, VIDEOSNAKE_REMAPPED_PTS, nil)?.takeUnretainedValue() as! NSDictionary?
            let mediaTime = (mediaTimeDict != nil) ? CMTimeMakeFromDictionary(mediaTimeDict!) : CMSampleBufferGetPresentationTimeStamp(mediaSample)
            let mediaTimeSeconds = CMTimeGetSeconds(mediaTime)
            var closestDifference = DBL_MAX
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
                self.motionSamples.removeRange(0..<closestMotionIndex)
            }
        }
        
        // Remove synced media samples
        if lastSyncedMediaIndex >= 0 {
            self.mediaSamples.removeRange(0..<lastSyncedMediaIndex + 1)
        }
        
        // If the motion array is too large, remove the oldest motion samples
        if self.motionSamples.count > MOTION_ARRAY_SIZE {
            self.motionSamples.removeRange(0..<self.motionSamples.count - MOTION_ARRAY_SIZE)
        }
    }
    
    private func appendMotionSampleForSynchronization(motion: CMDeviceMotion) {
        synchronized(self) {
            self.motionSamples.append(motion)
            self.sync()
        }
    }
    
    func appendSampleBufferForSynchronization(sampleBuffer: CMSampleBuffer) {
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
    
    func setSynchronizedSampleBufferDelegate(sampleBufferDelegate: MotionSynchronizationDelegate, queue sampleBufferCallbackQueue: dispatch_queue_t?) {
        _delegate = sampleBufferDelegate
        
        _delegateCallbackQueue = sampleBufferCallbackQueue
        
    }
    
    private func convertSampleBufferTimeToMotionClock(sampleBuffer: CMSampleBuffer) {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let remappedPTS = CMSyncConvertTime(originalPTS, self.sampleBufferClock, self.motionClock)
        
        // Attach the remapped timestamp to the buffer for use in -sync
        let remappedPTSDict = CMTimeCopyAsDictionary(remappedPTS, kCFAllocatorDefault)
        CMSetAttachment(sampleBuffer, VIDEOSNAKE_REMAPPED_PTS, remappedPTSDict, kCMAttachmentMode_ShouldPropagate.ui)
        
    }
    
}