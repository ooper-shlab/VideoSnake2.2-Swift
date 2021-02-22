//
//  VideoSnakeSessionManager.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/16.
//
//
/*
 <codex>
 <abstract>The class that creates and manages the AVCaptureSession</abstract>
 </codex>
 */

import UIKit
import AVFoundation
import CoreMotion
import Photos

@objc(VideoSnakeSessionManagerDelegate)
protocol VideoSnakeSessionManagerDelegate: NSObjectProtocol {
    
    func sessionManager(_ sessionManager: VideoSnakeSessionManager, didStopRunningWith error: Error)
    
    // Preview
    func sessionManager(_ sessionManager: VideoSnakeSessionManager, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer)
    func sessionManagerDidRunOutOfPreviewBuffers(_ sessionManager: VideoSnakeSessionManager)
    
    // Recording
    func sessionManagerRecordingDidStart(_ manager: VideoSnakeSessionManager)
    func sessionManager(_ manager:VideoSnakeSessionManager, recordingDidFailWith error: Error) // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
    func sessionManagerRecordingWillStop(_ manager: VideoSnakeSessionManager)
    func sessionManagerRecordingDidStop(_ manager: VideoSnakeSessionManager)
    
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
    case idle = 0
    case startingRecording
    case recording
    case stoppingRecording
} // internal state machine
#if LOG_STATUS_TRANSITIONS
    extension VideoSnakeRecordingStatus: CustomStringConvertible {
        var description: String {
            switch self {
            case .idle:
                return "Idle"
            case .startingRecording:
                return "StartingRecording"
            case .recording:
                return "Recording"
            case .stoppingRecording:
                return "StoppingRecording"
            }
        }
    }
#endif // LOG_STATUS_TRANSITIONS

private func angleOffsetFromPortraitOrientationToOrientation(_ orientation: AVCaptureVideoOrientation) -> CGFloat {
    var angle: CGFloat = 0.0
    
    switch orientation {
    case .portrait:
        angle = 0.0
    case .portraitUpsideDown:
        angle = .pi
    case .landscapeRight:
        angle = -(CGFloat.pi/2)
    case .landscapeLeft:
        angle = .pi/2
    @unknown default:
        break
    }
    
    return angle
}

@objc(VideoSnakeSessionManager)
class VideoSnakeSessionManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate, MotionSynchronizationDelegate {
    var recordingOrientation: AVCaptureVideoOrientation // client can set the orientation for the recorded movie
    private weak var _delegate: VideoSnakeSessionManagerDelegate?
    private var _delegateCallbackQueue: DispatchQueue!
    
    private var _previousSecondTimestamps: [CMTime] = []
    
    private var _captureSession: AVCaptureSession?
    private var _videoDevice: AVCaptureDevice!
    private var _audioConnection: AVCaptureConnection?
    private var _videoConnection: AVCaptureConnection?
    private var _running: Bool = false
    private var _startCaptureSessionOnEnteringForeground: Bool = false
    private var _applicationWillEnterForegroundNotificationObserver: AnyObject?
    
    private var _sessionQueue: DispatchQueue
    private var _videoDataOutputQueue: DispatchQueue
    private var _motionSyncedVideoQueue: DispatchQueue
    
    private var _renderer: VideoSnakeOpenGLRenderer!
    private var _renderingEnabled: Bool = false
    
    private var _recordingURL: URL
    private var _recordingStatus: VideoSnakeRecordingStatus = .idle
    
    private var _pipelineRunningTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    private var currentPreviewPixelBuffer: CVPixelBuffer?
    
    // Stats
    private(set) var videoFrameRate: Float = 0.0
    private(set) var videoDimensions: CMVideoDimensions = CMVideoDimensions()
    
    private var videoOrientation: AVCaptureVideoOrientation = AVCaptureVideoOrientation.portrait
    private var motionSynchronizer: MotionSynchronizer
    
    private var outputVideoFormatDescription: CMFormatDescription?
    private var outputAudioFormatDescription: CMFormatDescription?
    private var recorder: MovieRecorder?
    
    override init() {
        recordingOrientation = AVCaptureVideoOrientation(rawValue: UIDeviceOrientation.portrait.rawValue)!
        
        if #available(iOS 10.0, *) {
            _recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("Movie.MOV")
        } else {
            _recordingURL = URL(fileURLWithPath: NSString.path(withComponents: [NSTemporaryDirectory(), "Movie.MOV"]) as String)
        }
        
        _sessionQueue = DispatchQueue(label: "com.apple.sample.sessionmanager.capture", attributes: [])
        
        // In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
        // In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
        // Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
        // AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
        //###Causes runtime error on iPhone 7+/iOS 10.3.2
        //_videoDataOutputQueue = DispatchQueue(label: "com.apple.sample.sessionmanager.video")
        //_videoDataOutputQueue.setTarget(queue: DispatchQueue.global(qos: .userInteractive))
        _videoDataOutputQueue = DispatchQueue(label: "com.apple.sample.sessionmanager.video", qos: .userInteractive)
        
        motionSynchronizer = MotionSynchronizer()
        _motionSyncedVideoQueue = DispatchQueue(label: "com.apple.sample.sessionmanager.motion")
        super.init()
        motionSynchronizer.setSynchronizedSampleBufferDelegate(self, queue: _motionSyncedVideoQueue)
        
        _renderer = VideoSnakeOpenGLRenderer()
        
        _pipelineRunningTask = .invalid
    }
    
    deinit {
        _delegate = nil // unregister _delegate as a weak reference
        
        self.teardownCaptureSession()
        
    }
    
    //MARK: Delegate
    
    func setDelegate(_ delegate: VideoSnakeSessionManagerDelegate?, callbackQueue delegateCallbackQueue:DispatchQueue?) {
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
        _sessionQueue.sync {
            
            self.setupCaptureSession()
            
            self._captureSession?.startRunning()
            self._running = true
        }
    }
    
    func stopRunning() {
        _sessionQueue.sync {
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
        
        NotificationCenter.default.addObserver(self, selector: #selector(VideoSnakeSessionManager.captureSessionNotification(_:)), name: nil, object: _captureSession)
        _applicationWillEnterForegroundNotificationObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: UIApplication.shared, queue: nil) {note in
            // Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
            // Client must stop us running before we can be deallocated
            self.applicationWillEnterForeground()
        }
        
        #if RECORD_AUDIO
            /* Audio */
            let audioDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeAudio)
            let audioIn: AVCaptureDeviceInput?
            do {
                audioIn = try AVCaptureDeviceInput(device: audioDevice)
            } catch {
                audioIn = nil
            }
            if _captureSession!.canAddInput(audioIn) {
                _captureSession!.addInput(audioIn)
            }
            
            let audioOut = AVCaptureAudioDataOutput()
            // Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
            let audioCaptureQueue = DispatchQueue(label: "com.apple.sample.sessionmanager.audio")
            audioOut.setSampleBufferDelegate(self, queue: audioCaptureQueue)
            
            if _captureSession!.canAddOutput(audioOut) {
            _captureSession!.addOutput(audioOut)
            }
            _audioConnection = audioOut.connection(withMediaType: AVMediaTypeAudio)
        #endif // RECORD_AUDIO
        
        /* Video */
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            fatalError("Video capturing is not available for this device")
        }
        _videoDevice = videoDevice
        let videoIn: AVCaptureDeviceInput!
        do {
            videoIn = try AVCaptureDeviceInput(device: videoDevice)
        } catch _ {
            videoIn = nil
        }
        if _captureSession!.canAddInput(videoIn) {
            _captureSession!.addInput(videoIn)
        }
        
        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA.l]
        videoOut.setSampleBufferDelegate(self, queue: _videoDataOutputQueue)
        
        // VideoSnake records videos and we prefer not to have any dropped frames in the video recording.
        // By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
        // We do however need to ensure that on average we can process frames in realtime.
        // If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
        videoOut.alwaysDiscardsLateVideoFrames = false
        
        if _captureSession!.canAddOutput(videoOut) {
            _captureSession!.addOutput(videoOut)
        }
        _videoConnection = videoOut.connection(with: .video)
        
        var frameRate: Int
        var frameDuration = CMTime.invalid
        // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
        if ProcessInfo.processInfo.processorCount == 1 {
            if _captureSession!.canSetSessionPreset(.vga640x480) {
                _captureSession!.sessionPreset = .vga640x480
            }
            frameRate = 15
        } else {
            _captureSession!.sessionPreset = .high
            frameRate = 30
        }
        frameDuration = CMTimeMake(value: 1, timescale: frameRate.i)
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.unlockForConfiguration()
        } catch let error {
            NSLog("videoDevice lockForConfiguration returned error \(error)")
        }
        
        self.videoOrientation = _videoConnection!.videoOrientation
        
        /* Motion */
        self.motionSynchronizer.motionRate = Int32(frameRate * 2)
        
    }
    
    private func teardownCaptureSession() {
        if _captureSession != nil {
            NotificationCenter.default.removeObserver(self, name: nil, object: _captureSession)
            
            NotificationCenter.default.removeObserver(_applicationWillEnterForegroundNotificationObserver!)
            _applicationWillEnterForegroundNotificationObserver = nil
            
            _captureSession = nil
        }
    }
    
    @objc func captureSessionNotification(_ notification: Notification) {
        _sessionQueue.async {
            if notification.name == NSNotification.Name.AVCaptureSessionWasInterrupted {
                NSLog("session interrupted")
                
                self.captureSessionDidStopRunning()
            } else if notification.name == NSNotification.Name.AVCaptureSessionInterruptionEnded {
                NSLog("session interruption ended")
            } else if notification.name == NSNotification.Name.AVCaptureSessionRuntimeError {
                self.captureSessionDidStopRunning()
                
                let error = notification.userInfo![AVCaptureSessionErrorKey] as! NSError
                /*if error.code == AVError.Code.deviceIsNotAvailableInBackground.rawValue {
                    NSLog("device not available in background")
                    
                    // Since we can't resume running while in the background we need to remember this for next time we come to the foreground
                    if self._running {
                        self._startCaptureSessionOnEnteringForeground = true
                    }
                } else*/ if error.code == AVError.Code.mediaServicesWereReset.rawValue {
                    NSLog("media services were reset")
                    self.handleRecoverableCaptureSessionRuntimeError(error)
                } else {
                    self.handleNonRecoverableCaptureSessionRuntimeError(error)
                }
            } else if notification.name == NSNotification.Name.AVCaptureSessionDidStartRunning {
                NSLog("session started running")
            } else if notification.name == NSNotification.Name.AVCaptureSessionDidStopRunning {
                NSLog("session stopped running")
            }
        }
    }
    
    private func handleRecoverableCaptureSessionRuntimeError(_ error: Error) {
        if _running {
            _captureSession?.startRunning()
        }
    }
    
    private func handleNonRecoverableCaptureSessionRuntimeError(_ error: Error) {
        let error = error as NSError
        NSLog("fatal runtime error %@, code \(error.code)", error)
        
        _running = false
        self.teardownCaptureSession()
        
        synchronized(self) {
            if self.delegate != nil {
                self._delegateCallbackQueue.async {
                    autoreleasepool {
                        self.delegate!.sessionManager(self, didStopRunningWith: error)
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
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        _sessionQueue.sync {
            if self._startCaptureSessionOnEnteringForeground {
                NSLog("-[%@ %@] manually restarting session", NSStringFromClass(type(of: self)), #function)
                
                self._startCaptureSessionOnEnteringForeground = false
                if self._running {
                    self._captureSession?.startRunning()
                }
            }
        }
    }
    
    //MARK: Capture Pipeline
    
    private func setupVideoPipelineWithInputFormatDescription(_ inputFormatDescription: CMFormatDescription) {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        self.videoPipelineWillStartRunning()
        
        self.motionSynchronizer.sampleBufferClock = _captureSession?.masterClock
        
        self.motionSynchronizer.start()
        
        self.videoDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        _renderer.prepareWithOutputDimensions(self.videoDimensions, retainedBufferCountHint: RETAINED_BUFFER_COUNT)
        _renderer.shouldMirrorMotion = (_videoDevice!.position == .front); // Account for the fact that front camera preview is mirrored
        self.outputVideoFormatDescription = _renderer.outputFormatDescription
    }
    
    // synchronous, blocks until the pipeline is drained, don't call from within the pipeline
    private func teardownVideoPipeline() {
        // The session is stopped so we are guaranteed that no new buffers are coming through the video data output.
        // There may be inflight buffers on _videoDataOutputQueue or _motionSyncedVideoQueue however.
        // Synchronize with those queues to guarantee no more buffers are in flight.
        // Once the pipeline is drained we can tear it down safely.
        
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        _videoDataOutputQueue.sync{
            
            if self.outputVideoFormatDescription == nil {
                return
            }
            
            self.motionSynchronizer.stop() // no new sbufs will be enqueued to _motionSyncedVideoQueue, but some may already be queued
            self._motionSyncedVideoQueue.sync {
                self.outputVideoFormatDescription = nil
                self._renderer.reset()
                self.currentPreviewPixelBuffer = nil
                
                NSLog("-[%@ %@] finished teardown", NSStringFromClass(type(of: self)), #function)
                
                self.videoPipelineDidFinishRunning()
            }
        }
    }
    
    private func videoPipelineWillStartRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        assert(_pipelineRunningTask == .invalid, "should not have a background task active before the video pipeline starts running")
        
        _pipelineRunningTask = UIApplication.shared.beginBackgroundTask (expirationHandler: {
            NSLog("video capture pipeline background task expired")
        })
    }
    
    private func videoPipelineDidFinishRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        assert(_pipelineRunningTask != .invalid, "should have a background task active when the video pipeline finishes running")
        
        UIApplication.shared.endBackgroundTask(_pipelineRunningTask)
        _pipelineRunningTask = .invalid
    }
    
    // call under @synchronized( self )
    private func videoPipelineDidRunOutOfBuffers() {
        // We have run out of buffers.
        // Tell the delegate so that it can flush any cached buffers.
        if self.delegate != nil {
            _delegateCallbackQueue.async {
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
    private func outputPreviewPixelBuffer(_ previewPixelBuffer: CVPixelBuffer) {
        if self.delegate != nil {
            // Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
            self.currentPreviewPixelBuffer = previewPixelBuffer
            
            _delegateCallbackQueue.async {
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
    
    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
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
                self.setupVideoPipelineWithInputFormatDescription(formatDescription!)
            }
            
            self.motionSynchronizer.appendSampleBufferForSynchronization(sampleBuffer)
        } else if connection === _audioConnection {
            self.outputAudioFormatDescription = formatDescription
            
            synchronized(self) {
                if _recordingStatus == .recording {
                    self.recorder?.appendAudioSampleBuffer(sampleBuffer)
                }
            }
        }
    }
    
    func motionSynchronizer(_ synchronizer: MotionSynchronizer, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, withMotion motion: CMDeviceMotion?) {
        var renderedPixelBuffer: CVPixelBuffer? = nil
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        self.calculateFramerateAtTimestamp(timestamp)
        
        // We must not use the GPU while running in the background.
        // setRenderingEnabled: takes the same lock so the caller can guarantee no GPU usage once the setter returns.
        synchronized(_renderer) {
            if _renderingEnabled {
                let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                renderedPixelBuffer = _renderer.copyRenderedPixelBuffer(sourcePixelBuffer!, motion: motion)
            } else {
                return
            }
        }
        
        synchronized(self) {
            if renderedPixelBuffer != nil {
                self.outputPreviewPixelBuffer(renderedPixelBuffer!)
                
                if _recordingStatus == .recording {
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
            if _recordingStatus != .idle {
                fatalError("Already recording")
            }
            
            self.transitionToRecordingStatus(.startingRecording, error: nil)
        }
        
        let recorder = MovieRecorder(URL: _recordingURL)
        
        #if RECORD_AUDIO
            recorder.addAudioTrackWithSourceFormatDescription(self.outputAudioFormatDescription!)
        #endif // RECORD_AUDIO
        
        let videoTransform = self.transformFromVideoBufferOrientationToOrientation(self.recordingOrientation, withAutoMirroring: false) // Front camera recording shouldn't be mirrored
        
        recorder.addVideoTrackWithSourceFormatDescription(self.outputVideoFormatDescription!, transform:videoTransform)
        
        let callbackQueue = DispatchQueue(label: "com.apple.sample.sessionmanager.recordercallback", attributes: []); // guarantee ordering of callbacks with a serial queue
        recorder.setDelegate(self, callbackQueue: callbackQueue)
        self.recorder = recorder
        
        recorder.prepareToRecord() // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
    }
    
    func stopRecording() {
        synchronized(self) {
            if _recordingStatus != .recording {
                return
            }
            
            self.transitionToRecordingStatus(.stoppingRecording, error: nil)
        }
        
        self.recorder?.finishRecording() // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
    }
    
    //MARK: MovieRecorder Delegate
    
    func movieRecorderDidFinishPreparing(_ recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .startingRecording {
                fatalError("Expected to be in StartingRecording state")
            }
            
            self.transitionToRecordingStatus(.recording, error: nil)
        }
    }
    
    func movieRecorder(_ recorder: MovieRecorder, didFailWithError error: Error) {
        synchronized(self) {
            self.recorder = nil
            self.transitionToRecordingStatus(.idle, error: error)
        }
    }
    
    func movieRecorderDidFinishRecording(_ recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .stoppingRecording {
                fatalError("Expected to be in StoppingRecording state")
            }
            
            // No state transition, we are still in the process of stopping.
            // We will be stopped once we save to the assets library.
        }
        
        self.recorder = nil
        
        let phLibrary = PHPhotoLibrary()
        phLibrary.performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: self._recordingURL)
        }) {success, error in
            
            do {
                try FileManager.default.removeItem(at: self._recordingURL)
            } catch _ {
            }
            
            synchronized(self) {
                if self._recordingStatus != .stoppingRecording {
                    fatalError("Expected to be in StoppingRecording state")
                }
                self.transitionToRecordingStatus(.idle, error: error)
            }
        }
    }
    
    //MARK: Recording State Machine
    
    // call under @synchonized( self )
    private func transitionToRecordingStatus(_ newStatus: VideoSnakeRecordingStatus, error: Error?) {
        var delegateClosure: ((VideoSnakeSessionManager) -> Void)? = nil
        let oldStatus = _recordingStatus
        _recordingStatus = newStatus
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("VideoSnakeSessionManager recording state transition: %@->%@", oldStatus.description, newStatus.description)
        #endif
        
        if newStatus != oldStatus && delegate != nil {
            if let error = error, newStatus == .idle {
                delegateClosure = {manager in self.delegate!.sessionManager(manager, recordingDidFailWith: error)}
            } else {
                // only the above delegate method takes an error
                if oldStatus == .startingRecording && newStatus == .recording {
                    delegateClosure = {manager in self.delegate!.sessionManagerRecordingDidStart(manager)}
                } else if oldStatus == .recording && newStatus == .stoppingRecording {
                    delegateClosure = {manager in self.delegate!.sessionManagerRecordingWillStop(manager)}
                } else if oldStatus == .stoppingRecording && newStatus == .idle {
                    delegateClosure = {manager in self.delegate!.sessionManagerRecordingDidStop(manager)}
                }
            }
        }
        
        if delegateClosure != nil {
            _delegateCallbackQueue.async {
                autoreleasepool {
                    delegateClosure!(self)
                }
            }
        }
    }
    
    
    // Auto mirroring: Front camera is mirrored; back camera isn't
    // only valid after startRunning has been called
    func transformFromVideoBufferOrientationToOrientation(_ orientation: AVCaptureVideoOrientation, withAutoMirroring mirror: Bool) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        
        // Calculate offsets from an arbitrary reference orientation (portrait)
        let orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(orientation)
        let videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(self.videoOrientation)
        
        // Find the difference in angle between the desired orientation and the video orientation
        let angleOffset = orientationAngleOffset - videoOrientationAngleOffset
        transform = CGAffineTransform(rotationAngle: angleOffset)
        
        if _videoDevice!.position == .front {
            if mirror {
                transform = transform.scaledBy(x: -1, y: 1)
            } else {
                let uiOrientation = UIInterfaceOrientation(rawValue: Int(orientation.rawValue))!
                if uiOrientation.isPortrait {
                    transform = transform.rotated(by: .pi)
                }
            }
        }
        
        return transform
    }
    
    private func calculateFramerateAtTimestamp(_ timestamp: CMTime) {
        _previousSecondTimestamps.append(timestamp)
        
        let oneSecond = CMTimeMake(value: 1, timescale: 1)
        let oneSecondAgo = CMTimeSubtract(timestamp, oneSecond)
        
        while _previousSecondTimestamps[0] < oneSecondAgo {
            _previousSecondTimestamps.remove(at: 0)
        }
        
        if _previousSecondTimestamps.count > 1 {
            let duration = CMTimeGetSeconds(CMTimeSubtract(_previousSecondTimestamps.last!, _previousSecondTimestamps[0]))
            let newRate = Float(_previousSecondTimestamps.count - 1) / duration.f
            self.videoFrameRate = newRate
        }
    }
    
}
