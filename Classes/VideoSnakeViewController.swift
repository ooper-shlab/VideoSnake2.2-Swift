//
//  VideoSnakeViewController.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/25.
//
//
/*
     File: VideoSnakeViewController.h
     File: VideoSnakeViewController.m
 Abstract: View controller for camera interface
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
    private var labelTimer: NSTimer?
    private var previewView: OpenGLPixelBufferView?
    private var videoSnakeSessionManager: VideoSnakeSessionManager!
    
    deinit {
        if _addedObservers {
            NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationDidEnterBackgroundNotification, object: UIApplication.sharedApplication())
            NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillEnterForegroundNotification, object: UIApplication.sharedApplication())
            NSNotificationCenter.defaultCenter().removeObserver(self, name: UIDeviceOrientationDidChangeNotification, object: UIApplication.sharedApplication())
            UIDevice.currentDevice().endGeneratingDeviceOrientationNotifications()
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
        self.videoSnakeSessionManager.setDelegate(self, callbackQueue: dispatch_get_main_queue())
        
        NSNotificationCenter.defaultCenter().addObserver(self,
            selector: "applicationDidEnterBackground",
            name: UIApplicationDidEnterBackgroundNotification,
            object: UIApplication.sharedApplication())
        NSNotificationCenter.defaultCenter().addObserver(self,
            selector: "applicationWillEnterForeground",
            name: UIApplicationWillEnterForegroundNotification,
            object: UIApplication.sharedApplication())
        NSNotificationCenter.defaultCenter().addObserver(self,
            selector: "deviceOrientationDidChange",
            name: UIDeviceOrientationDidChangeNotification,
            object: UIDevice.currentDevice())
        
        // Keep track of changes to the device orientation so we can update the session manager
        UIDevice.currentDevice().beginGeneratingDeviceOrientationNotifications()
        
        _addedObservers = true
        
        // the willEnterForeground and didEnterBackground notifications are subesquently used to udpate _allowedToUseGPU
        _allowedToUseGPU = (UIApplication.sharedApplication().applicationState != .Background)
        self.videoSnakeSessionManager.renderingEnabled = _allowedToUseGPU
        
        super.viewDidLoad()
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        self.videoSnakeSessionManager.startRunning()
        
        self.labelTimer = NSTimer.scheduledTimerWithTimeInterval(0.5, target: self, selector: "updateLabels", userInfo: nil, repeats: true)
    }
    
    override func viewDidDisappear(animated: Bool) {
        super.viewDidDisappear(animated)
        
        self.labelTimer?.invalidate()
        self.labelTimer = nil
        
        self.videoSnakeSessionManager.stopRunning()
    }
    
    override func shouldAutorotate() -> Bool {
        return false
    }
    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.Portrait
    }
    
    //MARK: - UI
    
    @IBAction func toggleRecording(_: AnyObject) {
        if _recording {
            self.videoSnakeSessionManager.stopRecording()
        } else {
            // Disable the idle timer while recording
            UIApplication.sharedApplication().idleTimerDisabled = true
            
            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
            if UIDevice.currentDevice().multitaskingSupported {
                _backgroundRecordingID = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler {}
            }
            
            self.recordButton.enabled = false // re-enabled once recording has finished starting
            self.recordButton.title = "Stop"
            
            self.videoSnakeSessionManager.startRecording()
            
            _recording = true
        }
    }
    
    private func recordingStopped() {
        _recording = false
        self.recordButton.enabled = true
        self.recordButton.title = "Record"
        
        UIApplication.sharedApplication().idleTimerDisabled = false
        
        UIApplication.sharedApplication().endBackgroundTask(_backgroundRecordingID)
        _backgroundRecordingID = UIBackgroundTaskInvalid
    }
    
    private func setupPreviewView() {
        // Set up GL view
        self.previewView = OpenGLPixelBufferView(frame: CGRectZero)
        self.previewView!.autoresizingMask = [.FlexibleHeight, .FlexibleWidth]
        
        let currentInterfaceOrientation = UIApplication.sharedApplication().statusBarOrientation
        self.previewView!.transform = self.videoSnakeSessionManager.transformFromVideoBufferOrientationToOrientation(AVCaptureVideoOrientation(rawValue: currentInterfaceOrientation.rawValue)!, withAutoMirroring: true) // Front camera preview should be mirrored
        
        self.view.insertSubview(self.previewView!, atIndex: 0)
        var bounds = CGRectZero
        bounds.size = self.view.convertRect(self.view.bounds, toView: self.previewView).size
        self.previewView!.bounds = bounds
        self.previewView!.center = CGPointMake(self.view.bounds.size.width/2.0, self.view.bounds.size.height/2.0)
    }
    
    func deviceOrientationDidChange() {
        let deviceOrientation = UIDevice.currentDevice().orientation
        
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
    
    func showError(error: NSError) {
        if #available(iOS 8.0, *) {
            let alert = UIAlertController(title: error.localizedDescription, message: error.localizedFailureReason, preferredStyle: .Alert)
            self.presentViewController(alert, animated: true, completion: {})
        } else {
            let alertView = UIAlertView(title: error.localizedDescription,
                message: error.localizedFailureReason,
                delegate: nil,
                cancelButtonTitle: "OK")
            alertView.show()
        }
    }
    
    //MARK: - VideoSnakeSessionManagerDelegate
    
    func sessionManager(sessionManager: VideoSnakeSessionManager, didStopRunningWithError error: NSError) {
        self.showError(error)
        
        self.recordButton.enabled = false
    }
    
    // Preview
    func sessionManager(sessionManager: VideoSnakeSessionManager, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer) {
        if !_allowedToUseGPU {
            return
        }
        
        if self.previewView == nil {
            self.setupPreviewView()
        }
        
        self.previewView!.displayPixelBuffer(previewPixelBuffer)
    }
    
    func sessionManagerDidRunOutOfPreviewBuffers(sessionManager: VideoSnakeSessionManager) {
        if _allowedToUseGPU {
            self.previewView?.flushPixelBufferCache()
        }
    }
    
    // Recording
    func sessionManagerRecordingDidStart(manager: VideoSnakeSessionManager) {
        self.recordButton.enabled = true
    }
    
    func sessionManagerRecordingWillStop(manager: VideoSnakeSessionManager) {
        // Disable record button until we are ready to start another recording
        self.recordButton.enabled = false
        self.recordButton.title = "Record"
    }
    
    func sessionManagerRecordingDidStop(manager: VideoSnakeSessionManager) {
        self.recordingStopped()
    }
    
    func sessionManager(manager: VideoSnakeSessionManager, recordingDidFailWithError error: NSError) {
        self.recordingStopped()
        self.showError(error)
    }
    
}