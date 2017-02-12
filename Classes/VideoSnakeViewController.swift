//
//  VideoSnakeViewController.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/25.
//
//
/*
 <codex>
 <abstract>View controller for camera interface</abstract>
 </codex>
 */

import UIKit


import QuartzCore
import AVFoundation

@objc(VideoSnakeViewController)
class VideoSnakeViewController: UIViewController, VideoSnakeSessionManagerDelegate {
    private var _addedObservers: Bool = false
    private var _recording: Bool = false
    private var _backgroundRecordingID: UIBackgroundTaskIdentifier = 0
    private var _allowedToUseGPU: Bool = false
    
    @IBOutlet private var recordButton: UIBarButtonItem!
    @IBOutlet private var framerateLabel: UILabel!
    @IBOutlet private var dimensionsLabel: UILabel!
    private var labelTimer: Timer?
    private var previewView: OpenGLPixelBufferView?
    private var videoSnakeSessionManager: VideoSnakeSessionManager!
    
    deinit {
        if _addedObservers {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidEnterBackground, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationWillEnterForeground, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIDeviceOrientationDidChange, object: UIApplication.shared)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        
    }
    
    //MARK: - View lifecycle
    
    func applicationDidEnterBackground() {
        // Avoid using the GPU in the background
        _allowedToUseGPU = false
        self.videoSnakeSessionManager.renderingEnabled = false
        
        self.videoSnakeSessionManager.stopRecording() // no-op if we aren't recording
        
        // We reset the OpenGLPixelBufferView to ensure all resources have been clear when going to the background.
        self.previewView?.reset()
    }
    
    func applicationWillEnterForeground() {
        _allowedToUseGPU = true
        self.videoSnakeSessionManager.renderingEnabled = true
    }
    
    override func viewDidLoad() {
        self.videoSnakeSessionManager = VideoSnakeSessionManager()
        self.videoSnakeSessionManager.setDelegate(self, callbackQueue: DispatchQueue.main)
        
        NotificationCenter.default.addObserver(self,
            selector: #selector(VideoSnakeViewController.applicationDidEnterBackground),
            name: NSNotification.Name.UIApplicationDidEnterBackground,
            object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(VideoSnakeViewController.applicationWillEnterForeground),
            name: NSNotification.Name.UIApplicationWillEnterForeground,
            object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(VideoSnakeViewController.deviceOrientationDidChange),
            name: NSNotification.Name.UIDeviceOrientationDidChange,
            object: UIDevice.current)
        
        // Keep track of changes to the device orientation so we can update the session manager
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        _addedObservers = true
        
        // the willEnterForeground and didEnterBackground notifications are subesquently used to udpate _allowedToUseGPU
        _allowedToUseGPU = (UIApplication.shared.applicationState != .background)
        self.videoSnakeSessionManager.renderingEnabled = _allowedToUseGPU
        
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.videoSnakeSessionManager.startRunning()
        
        self.labelTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(VideoSnakeViewController.updateLabels), userInfo: nil, repeats: true)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        self.labelTimer?.invalidate()
        self.labelTimer = nil
        
        self.videoSnakeSessionManager.stopRunning()
    }
    
    override var shouldAutorotate : Bool {
        return false
    }
    override var supportedInterfaceOrientations : UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.portrait
    }
    
    //MARK: - UI
    
    @IBAction func toggleRecording(_: AnyObject) {
        if _recording {
            self.videoSnakeSessionManager.stopRecording()
        } else {
            // Disable the idle timer while recording
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
            if UIDevice.current.isMultitaskingSupported {
                _backgroundRecordingID = UIApplication.shared.beginBackgroundTask (expirationHandler: {})
            }
            
            self.recordButton.isEnabled = false // re-enabled once recording has finished starting
            self.recordButton.title = "Stop"
            
            self.videoSnakeSessionManager.startRecording()
            
            _recording = true
        }
    }
    
    private func recordingStopped() {
        _recording = false
        self.recordButton.isEnabled = true
        self.recordButton.title = "Record"
        
        UIApplication.shared.isIdleTimerDisabled = false
        
        UIApplication.shared.endBackgroundTask(_backgroundRecordingID)
        _backgroundRecordingID = UIBackgroundTaskInvalid
    }
    
    private func setupPreviewView() {
        // Set up GL view
        self.previewView = OpenGLPixelBufferView(frame: CGRect.zero)
        self.previewView!.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        
        let currentInterfaceOrientation = UIApplication.shared.statusBarOrientation
        self.previewView!.transform = self.videoSnakeSessionManager.transformFromVideoBufferOrientationToOrientation(AVCaptureVideoOrientation(rawValue: currentInterfaceOrientation.rawValue)!, withAutoMirroring: true) // Front camera preview should be mirrored
        
        self.view.insertSubview(self.previewView!, at: 0)
        var bounds = CGRect.zero
        bounds.size = self.view.convert(self.view.bounds, to: self.previewView).size
        self.previewView!.bounds = bounds
        self.previewView!.center = CGPoint(x: self.view.bounds.size.width/2.0, y: self.view.bounds.size.height/2.0)
    }
    
    func deviceOrientationDidChange() {
        let deviceOrientation = UIDevice.current.orientation
        
        // Update recording orientation if device changes to portrait or landscape orientation (but not face up/down)
        if UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation) {
            self.videoSnakeSessionManager.recordingOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        }
    }
    
    func updateLabels() {
        let frameRateString = String(format: "%d FPS", Int(round(self.videoSnakeSessionManager.videoFrameRate)))
        self.framerateLabel.text = frameRateString
        
        let dimensionsString = String(format: "%d x %d", self.videoSnakeSessionManager.videoDimensions.width, self.videoSnakeSessionManager.videoDimensions.height)
        self.dimensionsLabel.text = dimensionsString
    }
    
    func showError(_ error: Error) {
        let error = error as NSError
        if #available(iOS 8.0, *) {
            let alert = UIAlertController(title: error.localizedDescription, message: error.localizedFailureReason, preferredStyle: .alert)
            self.present(alert, animated: true, completion: {})
        } else {
            let alertView = UIAlertView(title: error.localizedDescription,
                message: error.localizedFailureReason,
                delegate: nil,
                cancelButtonTitle: "OK")
            alertView.show()
        }
    }
    
    //MARK: - VideoSnakeSessionManagerDelegate
    
    func sessionManager(_ sessionManager: VideoSnakeSessionManager, didStopRunningWith error: Error) {
        self.showError(error)
        
        self.recordButton.isEnabled = false
    }
    
    // Preview
    func sessionManager(_ sessionManager: VideoSnakeSessionManager, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer) {
        if !_allowedToUseGPU {
            return
        }
        
        if self.previewView == nil {
            self.setupPreviewView()
        }
        
        self.previewView!.displayPixelBuffer(previewPixelBuffer)
    }
    
    func sessionManagerDidRunOutOfPreviewBuffers(_ sessionManager: VideoSnakeSessionManager) {
        if _allowedToUseGPU {
            self.previewView?.flushPixelBufferCache()
        }
    }
    
    // Recording
    func sessionManagerRecordingDidStart(_ manager: VideoSnakeSessionManager) {
        self.recordButton.isEnabled = true
    }
    
    func sessionManagerRecordingWillStop(_ manager: VideoSnakeSessionManager) {
        // Disable record button until we are ready to start another recording
        self.recordButton.isEnabled = false
        self.recordButton.title = "Record"
    }
    
    func sessionManagerRecordingDidStop(_ manager: VideoSnakeSessionManager) {
        self.recordingStopped()
    }
    
    func sessionManager(_ manager: VideoSnakeSessionManager, recordingDidFailWith error: Error) {
        self.recordingStopped()
        self.showError(error)
    }
    
}
