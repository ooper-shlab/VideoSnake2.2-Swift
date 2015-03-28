//
//  VideoSnakeSessionManager.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/16.
//
//
/*
     File: VideoSnakeSessionManager.h
     File: VideoSnakeSessionManager.m
 Abstract: The class that creates and manages the AVCaptureSession
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

import UIKit
import AVFoundation
import CoreMotion

@objc(VideoSnakeSessionManagerDelegate)
protocol VideoSnakeSessionManagerDelegate: NSObjectProtocol {
    
    func sessionManager(sessionManager: VideoSnakeSessionManager, didStopRunningWithError error: NSError)
    
    // Preview
    func sessionManager(sessionManager: VideoSnakeSessionManager, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer)
    func sessionManagerDidRunOutOfPreviewBuffers(sessionManager: VideoSnakeSessionManager)
    
    // Recording
    func sessionManagerRecordingDidStart(manager: VideoSnakeSessionManager)
    func sessionManager(manager:VideoSnakeSessionManager, recordingDidFailWithError error:NSError) // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
    func sessionManagerRecordingWillStop(manager: VideoSnakeSessionManager)
    func sessionManagerRecordingDidStop(manager: VideoSnakeSessionManager)
    
}


import CoreMedia
import AssetsLibrary
import ImageIO

/*
RETAINED_BUFFER_COUNT is the number of pixel buffers we expect to hold on to from the renderer. This value informs the renderer how to size its buffer pool and how many pixel buffers to preallocate (done in the prepareWithOutputDimensions: method). Preallocation helps to lessen the chance of frame drops in our recording, in particular during recording startup. If we try to hold on to more buffers than RETAINED_BUFFER_COUNT then the renderer will fail to allocate new buffers from its pool and we will drop frames.

A back of the envelope calculation to arrive at a RETAINED_BUFFER_COUNT of '5':
- The preview path only has the most recent frame, so this makes the movie recording path the long pole.
- The movie recorder internally does a dispatch_async to avoid blocking the caller when enqueuing to its internal asset writer.
- Allow 2 frames of latency to cover the dispatch_async and the -[AVAssetWriterInput appendSampleBuffer:] call.
- Then we allow for the encoder to retain up to 3 frames. One frame is retained while being encoded/format converted, while the other two are to handle encoder format conversion pipelining and encoder startup latency.

Really you need to test and measure the latency in your own application pipeline to come up with an appropriate number. 1080p BGRA buffers are quite large, so it's a good idea to keep this number as low as possible.
*/

private let RETAINED_BUFFER_COUNT = 5

//#define RECORD_AUDIO 0

//#define LOG_STATUS_TRANSITIONS 0

private enum VideoSnakeRecordingStatus: Int {
    case Idle = 0
    case StartingRecording
    case Recording
    case StoppingRecording
} // internal state machine
#if LOG_STATUS_TRANSITIONS
    extension VideoSnakeRecordingStatus {
    var toString: String {
    switch self {
    case .Idle:
    return "Idle"
    case .StartingRecording:
    return "StartingRecording"
    case .Recording:
    return "Recording"
    case .StoppingRecording:
    return "StoppingRecording"
    }
    }
    }
#endif // LOG_STATUS_TRANSITIONS

private func angleOffsetFromPortraitOrientationToOrientation(orientation: AVCaptureVideoOrientation) -> CGFloat {
    var angle: CGFloat = 0.0
    
    switch orientation {
    case .Portrait:
        angle = 0.0
    case .PortraitUpsideDown:
        angle = M_PI.g
    case .LandscapeRight:
        angle = -M_PI_2.g
    case .LandscapeLeft:
        angle = M_PI_2.g
    default:
        break
    }
    
    return angle
}

@objc(VideoSnakeSessionManager)
class VideoSnakeSessionManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate, MotionSynchronizationDelegate {
    var recordingOrientation: AVCaptureVideoOrientation // client can set the orientation for the recorded movie
    private weak var _delegate: VideoSnakeSessionManagerDelegate?
    private var _delegateCallbackQueue: dispatch_queue_t!
    
    private var _previousSecondTimestamps: [CMTime] = []
    
    private var _captureSession: AVCaptureSession?
    private var _videoDevice: AVCaptureDevice!
    private var _audioConnection: AVCaptureConnection?
    private var _videoConnection: AVCaptureConnection?
    private var _running: Bool = false
    private var _startCaptureSessionOnEnteringForeground: Bool = false
    private var _applicationWillEnterForegroundNotificationObserver: AnyObject?
    
    private var _sessionQueue: dispatch_queue_t
    private var _videoDataOutputQueue: dispatch_queue_t
    private var _motionSyncedVideoQueue: dispatch_queue_t
    
    private var _renderer: VideoSnakeOpenGLRenderer!
    private var _renderingEnabled: Bool = false
    
    private var _recordingURL: NSURL
    private var _recordingStatus: VideoSnakeRecordingStatus = .Idle
    
    private var _pipelineRunningTask: UIBackgroundTaskIdentifier = 0
    
    private var currentPreviewPixelBuffer: CVPixelBuffer?
    
    // Stats
    private(set) var videoFrameRate: Float = 0.0
    private(set) var videoDimensions: CMVideoDimensions = CMVideoDimensions()
    
    private var videoOrientation: AVCaptureVideoOrientation = AVCaptureVideoOrientation.Portrait
    private var motionSynchronizer: MotionSynchronizer
    
    private var outputVideoFormatDescription: CMFormatDescription?
    private var outputAudioFormatDescription: CMFormatDescription?
    private var recorder: MovieRecorder?
    
    override init() {
        recordingOrientation = AVCaptureVideoOrientation(rawValue: UIDeviceOrientation.Portrait.rawValue)!
        
        _recordingURL = NSURL(fileURLWithPath: String.pathWithComponents([NSTemporaryDirectory(), "Movie.MOV"]))!
        
        _sessionQueue = dispatch_queue_create("com.apple.sample.sessionmanager.capture", DISPATCH_QUEUE_SERIAL)
        
        // In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
        // In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
        // Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
        // AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
        _videoDataOutputQueue = dispatch_queue_create( "com.apple.sample.sessionmanager.video", DISPATCH_QUEUE_SERIAL )
        dispatch_set_target_queue(_videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0))
        
        motionSynchronizer = MotionSynchronizer()
        _motionSyncedVideoQueue = dispatch_queue_create("com.apple.sample.sessionmanager.motion", DISPATCH_QUEUE_SERIAL)
        super.init()
        motionSynchronizer.setSynchronizedSampleBufferDelegate(self, queue: _motionSyncedVideoQueue)
        
        _renderer = VideoSnakeOpenGLRenderer()
        
        _pipelineRunningTask = UIBackgroundTaskInvalid
    }
    
    deinit {
        _delegate = nil // unregister _delegate as a weak reference
        
        self.teardownCaptureSession()
        
    }
    
    //MARK: Delegate
    
    func setDelegate(delegate: VideoSnakeSessionManagerDelegate?, callbackQueue delegateCallbackQueue:dispatch_queue_t?) {
        if delegate != nil && delegateCallbackQueue == nil {
            fatalError("Caller must provide a delegateCallbackQueue")
        }
        
        synchronized(self) {
            self._delegate = delegate
            self._delegateCallbackQueue = delegateCallbackQueue
        }
    }
    
    var delegate: VideoSnakeSessionManagerDelegate? {
        var theDelegate: VideoSnakeSessionManagerDelegate? = nil
        synchronized(self) {
            theDelegate = self._delegate
        }
        return theDelegate
    }
    
    //MARK: Capture Session
    
    // Consider renaming this class VideoSnakeCapturePipeline
    // These methods are synchronous
    func startRunning() {
        dispatch_sync(_sessionQueue) {
            
            self.setupCaptureSession()
            
            self._captureSession?.startRunning()
            self._running = true
        }
    }
    
    func stopRunning() {
        dispatch_sync(_sessionQueue) {
            self._running = false
            
            // the captureSessionDidStopRunning method will stop recording if necessary as well, but we do it here so that the last video and audio samples are better aligned
            self.stopRecording() // does nothing if we aren't currently recording
            
            self._captureSession?.stopRunning()
            
            self.captureSessionDidStopRunning()
            
            self.teardownCaptureSession()
        }
    }
    
    private func setupCaptureSession() {
        if _captureSession != nil {
            return
        }
        
        _captureSession = AVCaptureSession()
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "captureSessionNotification:", name: nil, object: _captureSession)
        _applicationWillEnterForegroundNotificationObserver = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationWillEnterForegroundNotification, object: UIApplication.sharedApplication(), queue: nil) {note in
            // Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
            // Client must stop us running before we can be deallocated
            self.applicationWillEnterForeground()
        }
        
        #if RECORD_AUDIO
            /* Audio */
            let audioDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeAudio)
            let audioIn = AVCaptureDeviceInput(device: audioDevice, error: nil)
            if _captureSession!.canAddInput(audioIn) {
            _captureSession!.addInput(audioIn)
            }
            
            let audioOut = AVCaptureAudioDataOutput()
            // Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
            let audioCaptureQueue = dispatch_queue_create("com.apple.sample.sessionmanager.audio", DISPATCH_QUEUE_SERIAL)
            audioOut.setSampleBufferDelegate(self, queue: audioCaptureQueue)
            
            if _captureSession!.canAddOutput(audioOut) {
            _captureSession!.addOutput(audioOut)
            }
            _audioConnection = audioOut.connectionWithMediaType(AVMediaTypeAudio)
        #endif // RECORD_AUDIO
        
        /* Video */
        let videoDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
        if videoDevice == nil {
            fatalError("Video capturing is not available for this device")
        }
        _videoDevice = videoDevice
        let videoIn = AVCaptureDeviceInput(device: videoDevice, error: nil)
        if _captureSession!.canAddInput(videoIn) {
            _captureSession!.addInput(videoIn)
        }
        
        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        videoOut.setSampleBufferDelegate(self, queue: _videoDataOutputQueue)
        
        // VideoSnake records videos and we prefer not to have any dropped frames in the video recording.
        // By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
        // We do however need to ensure that on average we can process frames in realtime.
        // If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
        videoOut.alwaysDiscardsLateVideoFrames = false
        
        if _captureSession!.canAddOutput(videoOut) {
            _captureSession!.addOutput(videoOut)
        }
        _videoConnection = videoOut.connectionWithMediaType(AVMediaTypeVideo)
        
        var frameRate: Int
        var frameDuration = kCMTimeInvalid
        // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
        if NSProcessInfo.processInfo().processorCount == 1 {
            if _captureSession!.canSetSessionPreset(AVCaptureSessionPreset640x480) {
                _captureSession!.sessionPreset = AVCaptureSessionPreset640x480
            }
            frameRate = 15
        } else {
            _captureSession!.sessionPreset = AVCaptureSessionPresetHigh
            frameRate = 30
        }
        frameDuration = CMTimeMake(1, frameRate.i)
        
        var error: NSError? = nil
        if videoDevice!.lockForConfiguration(&error) {
            videoDevice!.activeVideoMaxFrameDuration = frameDuration
            videoDevice!.activeVideoMinFrameDuration = frameDuration
            videoDevice!.unlockForConfiguration()
        } else {
            NSLog("videoDevice lockForConfiguration returned error %@", error!)
        }
        
        self.videoOrientation = _videoConnection!.videoOrientation
        
        /* Motion */
        self.motionSynchronizer.motionRate = Int32(frameRate * 2)
        
    }
    
    private func teardownCaptureSession() {
        if _captureSession != nil {
            NSNotificationCenter.defaultCenter().removeObserver(self, name: nil, object: _captureSession)
            
            NSNotificationCenter.defaultCenter().removeObserver(_applicationWillEnterForegroundNotificationObserver!)
            _applicationWillEnterForegroundNotificationObserver = nil
            
            _captureSession = nil
        }
    }
    
    func captureSessionNotification(notification: NSNotification) {
        dispatch_async(_sessionQueue) {
            if notification.name == AVCaptureSessionWasInterruptedNotification {
                NSLog("session interrupted")
                
                self.captureSessionDidStopRunning()
            } else if notification.name == AVCaptureSessionInterruptionEndedNotification {
                NSLog("session interruption ended")
            } else if notification.name == AVCaptureSessionRuntimeErrorNotification {
                self.captureSessionDidStopRunning()
                
                let error = notification.userInfo![AVCaptureSessionErrorKey] as! NSError
                if error.code == AVError.DeviceIsNotAvailableInBackground.rawValue {
                    NSLog("device not available in background")
                    
                    // Since we can't resume running while in the background we need to remember this for next time we come to the foreground
                    if self._running {
                        self._startCaptureSessionOnEnteringForeground = true
                    }
                } else if error.code == AVError.MediaServicesWereReset.rawValue {
                    NSLog("media services were reset")
                    self.handleRecoverableCaptureSessionRuntimeError(error)
                } else {
                    self.handleNonRecoverableCaptureSessionRuntimeError(error)
                }
            } else if notification.name == AVCaptureSessionDidStartRunningNotification {
                NSLog("session started running")
            } else if notification.name == AVCaptureSessionDidStopRunningNotification {
                NSLog("session stopped running")
            }
        }
    }
    
    private func handleRecoverableCaptureSessionRuntimeError(error: NSError) {
        if _running {
            _captureSession?.startRunning()
        }
    }
    
    private func handleNonRecoverableCaptureSessionRuntimeError(error: NSError) {
        NSLog("fatal runtime error %@, code \(error.code)", error)
        
        _running = false
        self.teardownCaptureSession()
        
        synchronized(self) {
            if self.delegate != nil {
                dispatch_async(self._delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate!.sessionManager(self, didStopRunningWithError: error)
                    }
                }
            }
        }
    }
    
    private func captureSessionDidStopRunning() {
        self.stopRecording() // does nothing if we aren't currently recording
        self.teardownVideoPipeline()
    }
    
    private func applicationWillEnterForeground() {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), __FUNCTION__)
        
        dispatch_sync( _sessionQueue) {
            if self._startCaptureSessionOnEnteringForeground {
                NSLog("-[%@ %@] manually restarting session", NSStringFromClass(self.dynamicType), __FUNCTION__)
                
                self._startCaptureSessionOnEnteringForeground = false
                if self._running {
                    self._captureSession?.startRunning()
                }
            }
        }
    }
    
    //MARK: Capture Pipeline
    
    private func setupVideoPipelineWithInputFormatDescription(inputFormatDescription: CMFormatDescription) {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), __FUNCTION__)
        
        self.videoPipelineWillStartRunning()
        
        self.motionSynchronizer.sampleBufferClock = _captureSession?.masterClock
        
        self.motionSynchronizer.start()
        
        self.videoDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        _renderer.prepareWithOutputDimensions(self.videoDimensions, retainedBufferCountHint: RETAINED_BUFFER_COUNT)
        _renderer.shouldMirrorMotion = (_videoDevice!.position == .Front); // Account for the fact that front camera preview is mirrored
        self.outputVideoFormatDescription = _renderer.outputFormatDescription
    }
    
    // synchronous, blocks until the pipeline is drained, don't call from within the pipeline
    private func teardownVideoPipeline() {
        // The session is stopped so we are guaranteed that no new buffers are coming through the video data output.
        // There may be inflight buffers on _videoDataOutputQueue or _motionSyncedVideoQueue however.
        // Synchronize with those queues to guarantee no more buffers are in flight.
        // Once the pipeline is drained we can tear it down safely.
        
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), __FUNCTION__)
        
        dispatch_sync(_videoDataOutputQueue){
            
            if self.outputVideoFormatDescription == nil {
                return
            }
            
            self.motionSynchronizer.stop() // no new sbufs will be enqueued to _motionSyncedVideoQueue, but some may already be queued
            dispatch_sync(self._motionSyncedVideoQueue) {
                self.outputVideoFormatDescription = nil
                self._renderer.reset()
                self.currentPreviewPixelBuffer = nil
                
                NSLog("-[%@ %@] finished teardown", NSStringFromClass(self.dynamicType), __FUNCTION__)
                
                self.videoPipelineDidFinishRunning()
            }
        }
    }
    
    private func videoPipelineWillStartRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), __FUNCTION__)
        
        assert(_pipelineRunningTask == UIBackgroundTaskInvalid, "should not have a background task active before the video pipeline starts running")
        
        _pipelineRunningTask = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler {
            NSLog("video capture pipeline background task expired")
        }
    }
    
    private func videoPipelineDidFinishRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), __FUNCTION__)
        
        assert(_pipelineRunningTask != UIBackgroundTaskInvalid, "should have a background task active when the video pipeline finishes running")
        
        UIApplication.sharedApplication().endBackgroundTask(_pipelineRunningTask)
        _pipelineRunningTask = UIBackgroundTaskInvalid
    }
    
    // call under @synchronized( self )
    private func videoPipelineDidRunOutOfBuffers() {
        // We have run out of buffers.
        // Tell the delegate so that it can flush any cached buffers.
        if self.delegate != nil {
            dispatch_async(_delegateCallbackQueue) {
                autoreleasepool {
                    self.delegate!.sessionManagerDidRunOutOfPreviewBuffers(self)
                }
            }
        }
    }
    
    // When set to false the GPU will not be used after the setRenderingEnabled: call returns.
    var renderingEnabled: Bool {
        set {
            synchronized(_renderer) {
                self._renderingEnabled = newValue
            }
        }
        
        get {
            return synchronized(_renderer) {
                return self._renderingEnabled
            }
        }
    }
    
    // call under @synchronized( self )
    private func outputPreviewPixelBuffer(previewPixelBuffer: CVPixelBuffer) {
        if self.delegate != nil {
            // Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
            self.currentPreviewPixelBuffer = previewPixelBuffer
            
            dispatch_async(_delegateCallbackQueue) {
                autoreleasepool {
                    var currentPreviewPixelBuffer: CVPixelBuffer? = nil
                    synchronized(self) {
                        currentPreviewPixelBuffer = self.currentPreviewPixelBuffer
                        if currentPreviewPixelBuffer != nil {
                            self.currentPreviewPixelBuffer = nil
                        }
                    }
                    if currentPreviewPixelBuffer != nil {
                        self.delegate?.sessionManager(self, previewPixelBufferReadyForDisplay: currentPreviewPixelBuffer!)
                    }
                }
            }
        }
    }
    
    //MARK: Pipeline Stage Output Callbacks
    
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        // For video the basic sample flow is:
        //	1) Frame received from video data output on _videoDataOutputQueue via captureOutput:didOutputSampleBuffer:fromConnection: (this method)
        //	2) Frame sent to motion synchronizer to be asynchronously correlated with motion data
        //	3) Frame and correlated motion data received on _motionSyncedVideoQueue via motionSynchronizer:didOutputSampleBuffer:withMotion:
        //	4) Frame and motion data rendered via VideoSnakeOpenGLRenderer while running on _motionSyncedVideoQueue
        //	5) Rendered frame sent to the delegate for previewing
        //	6) Rendered frame sent to the movie recorder if recording is enabled
        
        // For audio the basic sample flow is:
        //	1) Audio sample buffer received from audio data output on an audio specific serial queue via captureOutput:didOutputSampleBuffer:fromConnection: (this method)
        //	2) Audio sample buffer sent to the movie recorder if recording is enabled
        
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        
        if connection === _videoConnection {
            if self.outputVideoFormatDescription == nil {
                self.setupVideoPipelineWithInputFormatDescription(formatDescription)
            }
            
            self.motionSynchronizer.appendSampleBufferForSynchronization(sampleBuffer)
        } else if connection === _audioConnection {
            self.outputAudioFormatDescription = formatDescription
            
            synchronized(self) {
                if _recordingStatus == .Recording {
                    self.recorder?.appendAudioSampleBuffer(sampleBuffer)
                }
            }
        }
    }
    
    func motionSynchronizer(synchronizer: MotionSynchronizer, didOutputSampleBuffer sampleBuffer: CMSampleBufferRef, withMotion motion: CMDeviceMotion?) {
        var renderedPixelBuffer: CVPixelBuffer? = nil
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        self.calculateFramerateAtTimestamp(timestamp)
        
        // We must not use the GPU while running in the background.
        // setRenderingEnabled: takes the same lock so the caller can guarantee no GPU usage once the setter returns.
        synchronized(_renderer) {
            if _renderingEnabled {
                let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                renderedPixelBuffer = _renderer.copyRenderedPixelBuffer(sourcePixelBuffer, motion: motion)
            } else {
                return
            }
        }
        
        synchronized(self) {
            if renderedPixelBuffer != nil {
                self.outputPreviewPixelBuffer(renderedPixelBuffer!)
                
                if _recordingStatus == .Recording {
                    self.recorder?.appendVideoPixelBuffer(renderedPixelBuffer!, withPresentationTime: timestamp)
                }
                
            } else {
                self.videoPipelineDidRunOutOfBuffers()
            }
        }
    }
    
    //MARK: Recording
    
    // Must be running before starting recording
    // These methods are asynchronous, see the recording delegate callbacks
    func startRecording() {
        synchronized(self) {
            if _recordingStatus != .Idle {
                fatalError("Already recording")
            }
            
            self.transitionToRecordingStatus(.StartingRecording, error: nil)
        }
        
        let recorder = MovieRecorder(URL: _recordingURL)
        
        #if RECORD_AUDIO
            recorder.addAudioTrackWithSourceFormatDescription(self.outputAudioFormatDescription!)
        #endif // RECORD_AUDIO
        
        let videoTransform = self.transformFromVideoBufferOrientationToOrientation(self.recordingOrientation, withAutoMirroring: false) // Front camera recording shouldn't be mirrored
        
        recorder.addVideoTrackWithSourceFormatDescription(self.outputVideoFormatDescription!, transform:videoTransform)
        
        let callbackQueue = dispatch_queue_create("com.apple.sample.sessionmanager.recordercallback", DISPATCH_QUEUE_SERIAL); // guarantee ordering of callbacks with a serial queue
        recorder.setDelegate(self, callbackQueue: callbackQueue)
        self.recorder = recorder
        
        recorder.prepareToRecord() // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
    }
    
    func stopRecording() {
        synchronized(self) {
            if _recordingStatus != .Recording {
                return
            }
            
            self.transitionToRecordingStatus(.StoppingRecording, error: nil)
        }
        
        self.recorder?.finishRecording() // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
    }
    
    //MARK: MovieRecorder Delegate
    
    func movieRecorderDidFinishPreparing(recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .StartingRecording {
                fatalError("Expected to be in StartingRecording state")
            }
            
            self.transitionToRecordingStatus(.Recording, error: nil)
        }
    }
    
    func movieRecorder(recorder: MovieRecorder, didFailWithError error: NSError) {
        synchronized(self) {
            self.recorder = nil
            self.transitionToRecordingStatus(.Idle, error: error)
        }
    }
    
    func movieRecorderDidFinishRecording(recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .StoppingRecording {
                fatalError("Expected to be in StoppingRecording state")
            }
            
            // No state transition, we are still in the process of stopping.
            // We will be stopped once we save to the assets library.
        }
        
        self.recorder = nil
        
        let library = ALAssetsLibrary()
        library.writeVideoAtPathToSavedPhotosAlbum(_recordingURL) {assetURL, error in
            
            NSFileManager.defaultManager().removeItemAtURL(self._recordingURL, error: nil)
            
            synchronized(self) {
                if self._recordingStatus != .StoppingRecording {
                    fatalError("Expected to be in StoppingRecording state")
                }
                self.transitionToRecordingStatus(.Idle, error: error)
            }
        }
    }
    
    //MARK: Recording State Machine
    
    // call under @synchonized( self )
    private func transitionToRecordingStatus(newStatus: VideoSnakeRecordingStatus, error: NSError?) {
        var delegateClosure: (VideoSnakeSessionManager -> Void)? = nil
        let oldStatus = _recordingStatus
        _recordingStatus = newStatus
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("VideoSnakeSessionManager recording state transition: %@->%@", oldStatus.toString, newStatus.toString )
        #endif
        
        if newStatus != oldStatus && delegate != nil {
            if error != nil && newStatus == .Idle {
                delegateClosure = {manager in self.delegate!.sessionManager(manager, recordingDidFailWithError: error!)}
            } else {
                // only the above delegate method takes an error
                if oldStatus == .StartingRecording && newStatus == .Recording {
                    delegateClosure = {manager in self.delegate!.sessionManagerRecordingDidStart(manager)}
                } else if oldStatus == .Recording && newStatus == .StoppingRecording {
                    delegateClosure = {manager in self.delegate!.sessionManagerRecordingWillStop(manager)}
                } else if oldStatus == .StoppingRecording && newStatus == .Idle {
                    delegateClosure = {manager in self.delegate!.sessionManagerRecordingDidStop(manager)}
                }
            }
        }
        
        if delegateClosure != nil {
            dispatch_async(_delegateCallbackQueue) {
                autoreleasepool {
                    delegateClosure!(self)
                }
            }
        }
    }
    
    
    // Auto mirroring: Front camera is mirrored; back camera isn't
    // only valid after startRunning has been called
    func transformFromVideoBufferOrientationToOrientation(orientation: AVCaptureVideoOrientation, withAutoMirroring mirror: Bool) -> CGAffineTransform {
        var transform = CGAffineTransformIdentity
        
        // Calculate offsets from an arbitrary reference orientation (portrait)
        let orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(orientation)
        let videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(self.videoOrientation)
        
        // Find the difference in angle between the desired orientation and the video orientation
        let angleOffset = orientationAngleOffset - videoOrientationAngleOffset
        transform = CGAffineTransformMakeRotation(angleOffset)
        
        if _videoDevice!.position == .Front {
            if mirror {
                transform = CGAffineTransformScale(transform, -1, 1)
            } else {
                let uiOrientation = UIInterfaceOrientation(rawValue: Int(orientation.rawValue))!
                if UIInterfaceOrientationIsPortrait(uiOrientation) {
                    transform = CGAffineTransformRotate(transform, M_PI.g)
                }
            }
        }
        
        return transform
    }
    
    private func calculateFramerateAtTimestamp(timestamp: CMTime) {
        _previousSecondTimestamps.append(timestamp)
        
        let oneSecond = CMTimeMake(1, 1)
        let oneSecondAgo = CMTimeSubtract(timestamp, oneSecond)
        
        while _previousSecondTimestamps[0] < oneSecondAgo {
            _previousSecondTimestamps.removeAtIndex(0)
        }
        
        if _previousSecondTimestamps.count > 1 {
            let duration = CMTimeGetSeconds(CMTimeSubtract(_previousSecondTimestamps.last!, _previousSecondTimestamps[0]))
            let newRate = Float(_previousSecondTimestamps.count - 1) / duration.f
            self.videoFrameRate = newRate
        }
    }
    
}