//
//  VideoSnakeOpenGLRenderer.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/12.
//
//
/*
 <codex>
 <abstract>The VideoSnake OpenGL effect renderer.</abstract>
 </codex>
 */
import Foundation
import CoreMedia
import CoreVideo
import CoreMotion

private let ATTRIB_VERTEX = 0
private let ATTRIB_TEXTUREPOSITON = 1
private let NUM_ATTRIBUTES = 2

private func CreatePixelBufferPool(_ width: Int32, height: Int32, pixelFormat: OSType, maxBufferCount: Int32) -> CVPixelBufferPool? {
    var outputPool: CVPixelBufferPool? = nil
    
    var sourcePixelBufferOptions: [AnyHashable: Any] = [:]
    sourcePixelBufferOptions[kCVPixelBufferPixelFormatTypeKey as AnyHashable] = Int(pixelFormat)
    
    sourcePixelBufferOptions[kCVPixelBufferWidthKey as AnyHashable] = Int(width)
    
    sourcePixelBufferOptions[kCVPixelBufferHeightKey as AnyHashable] = Int(height)
    
    sourcePixelBufferOptions[kCVPixelFormatOpenGLESCompatibility as AnyHashable] = true
    
    let ioSurfaceProps: [AnyHashable: Any] = [:]
    sourcePixelBufferOptions[kCVPixelBufferIOSurfacePropertiesKey as AnyHashable] = ioSurfaceProps
    
    let pixelBufferPoolOptions: [AnyHashable: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as AnyHashable: Int(maxBufferCount),
    ]
    
    CVPixelBufferPoolCreate(kCFAllocatorDefault, pixelBufferPoolOptions as CFDictionary?, sourcePixelBufferOptions as CFDictionary?, &outputPool)
    
    return outputPool
}

private func CreatePixelBufferPoolAuxAttributes(_ maxBufferCount: Int32) -> CFDictionary {
    // CVPixelBufferPoolCreatePixelBufferWithAuxAttributes() will return kCVReturnWouldExceedAllocationThreshold if we have already vended the max number of buffers
    let auxAttributes: [AnyHashable: Any] = [kCVPixelBufferPoolAllocationThresholdKey as AnyHashable: Int(maxBufferCount)]
    return auxAttributes as CFDictionary
}

private func PreallocatePixelBuffersInPool(_ pool: CVPixelBufferPool, auxAttributes: CFDictionary) {
    // Preallocate buffers in the pool, since this is for real-time display/capture
    var pixelBuffers: [CVPixelBuffer] = []
    while true {
        var pixelBuffer: CVPixelBuffer? = nil
        let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
        
        if err == kCVReturnWouldExceedAllocationThreshold {
            break
        }
        assert(err == noErr)
        
        pixelBuffers.append(pixelBuffer!)
    }
}

@objc(VideoSnakeOpenGLRenderer)
class VideoSnakeOpenGLRenderer: NSObject {
    var shouldMirrorMotion: Bool = false
    private(set) var outputFormatDescription: CMFormatDescription?
    private var _oglContext: EAGLContext!
    private var _textureCache: CVOpenGLESTextureCache?
    private var _renderTextureCache: CVOpenGLESTextureCache?
    private var _backFramePixelBuffer: CVPixelBuffer?
    private var _bufferPool: CVPixelBufferPool?
    private var _bufferPoolAuxAttributes: CFDictionary?
    private var _program: GLuint = 0
    private var _frame: GLint = 0
    private var _backgroundColor: GLint = 0
    private var _modelView: GLint = 0
    private var _projection: GLint = 0
    private var _offscreenBufferHandle: GLuint = 0
    
    // Snake effect
    private var _velocityDeltaX: Double = 0.0
    private var _velocityDeltaY: Double = 0.0
    private var _lastMotionTime: TimeInterval = 0.0
    
    class func readFile(_ name: String) -> String? {
        
        let path = Bundle.main.path(forResource: name, ofType: nil)
        let source: String?
        do {
            source = try String(contentsOfFile: path!, encoding: String.Encoding.utf8)
        } catch _ {
            source = nil
        }
        return source
    }
    
    override init() {
        super.init()
        self._oglContext = EAGLContext(api: .openGLES2)
        if self._oglContext == nil {
            fatalError("Problem with OpenGL context.")
        }
    }
    
    deinit {
        self.deleteBuffers()
    }
    
    func prepareWithOutputDimensions(_ outputDimensions: CMVideoDimensions, retainedBufferCountHint: size_t) {
        self.deleteBuffers()
        if !self.initializeBuffersWithOutputDimensions(outputDimensions, retainedBufferCountHint:retainedBufferCountHint) {
            fatalError("Problem preparing renderer.")
        }
    }
    
    private func initializeBuffersWithOutputDimensions(_ outputDimensions: CMVideoDimensions, retainedBufferCountHint clientRetainedBufferCountHint: size_t) -> Bool {
        var success = true
        
        let oldContext = EAGLContext.current()
        if oldContext !== _oglContext {
            if !EAGLContext.setCurrent(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        
        glDisable(GL_DEPTH_TEST.ui)
        
        glGenFramebuffers(1, &_offscreenBufferHandle)
        glBindFramebuffer(GL_FRAMEBUFFER.ui, _offscreenBufferHandle)
        
        bail: repeat {
            var err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, _oglContext, nil, &_textureCache)
            if err != 0 {
                fatalError("Error at CVOpenGLESTextureCacheCreate \(err)")
            }
            
            err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, _oglContext, nil, &_renderTextureCache)
            if err != 0 {
                fatalError("Error at CVOpenGLESTextureCacheCreate \(err)")
            }
            
            // Load vertex and fragment shaders
            let attribLocation: [GLuint] = [
                ATTRIB_VERTEX.ui, ATTRIB_TEXTUREPOSITON.ui,
            ]
            let attribName: [String] = [
                "position", "texturecoordinate",
            ]
            
            let videoSnakeVertSrc = VideoSnakeOpenGLRenderer.readFile("videoSnake.vsh")!
            let videoSnakeFragSrc = VideoSnakeOpenGLRenderer.readFile("videoSnake.fsh")!
            
            // videoSnake shader program
            glue.createProgram(videoSnakeVertSrc, videoSnakeFragSrc,
                attribName, attribLocation,
                [], nil,
                &_program)
            if _program == 0 {
                NSLog("Problem initializing the program.")
                success = false
                break bail
            }
            _backgroundColor = glue.getUniformLocation(_program, "backgroundcolor")
            _modelView = glue.getUniformLocation(_program, "amodelview")
            _projection = glue.getUniformLocation(_program, "aprojection")
            _frame = glue.getUniformLocation(_program, "videoframe")
            
            // Because we will retain one buffer in _backFramePixelBuffer we increment the client's retained buffer count hint by 1
            let maxRetainedBufferCount = clientRetainedBufferCountHint + 1
            
            _bufferPool = CreatePixelBufferPool(outputDimensions.width, height: outputDimensions.height, pixelFormat: OSType(kCVPixelFormatType_32BGRA), maxBufferCount: Int32(maxRetainedBufferCount))
            if _bufferPool == nil {
                NSLog("Problem initializing a buffer pool.")
                success = false
                break bail
            }
            
            _bufferPoolAuxAttributes = CreatePixelBufferPoolAuxAttributes(Int32(maxRetainedBufferCount))
            PreallocatePixelBuffersInPool(_bufferPool!, auxAttributes: _bufferPoolAuxAttributes!)
            
            var outputFormatDescription: CMFormatDescription? = nil
            var testPixelBuffer: CVPixelBuffer? = nil
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool!, _bufferPoolAuxAttributes, &testPixelBuffer)
            if testPixelBuffer == nil {
                NSLog("Problem creating a pixel buffer.")
                success = false
                break bail
            }
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: testPixelBuffer!, formatDescriptionOut: &outputFormatDescription)
            self.outputFormatDescription = outputFormatDescription
            testPixelBuffer = nil
            
        } while false
        if !success {
            self.deleteBuffers()
        }
        if oldContext !== _oglContext {
            EAGLContext.setCurrent(oldContext)
        }
        return success
    }
    
    func reset() {
        self.deleteBuffers()
    }
    
    private func deleteBuffers() {
        let oldContext = EAGLContext.current()
        if oldContext !== _oglContext {
            if !EAGLContext.setCurrent(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        if _offscreenBufferHandle != 0 {
            glDeleteFramebuffers(1, &_offscreenBufferHandle)
            _offscreenBufferHandle = 0
        }
        if _program != 0 {
            glDeleteProgram(_program)
            _program = 0
        }
        if _backFramePixelBuffer != nil {
            _backFramePixelBuffer = nil
        }
        if _textureCache != nil {
            _textureCache = nil
        }
        if _renderTextureCache != nil {
            _renderTextureCache = nil
        }
        if _bufferPool != nil {
            _bufferPool = nil
        }
        if _bufferPoolAuxAttributes != nil {
            _bufferPoolAuxAttributes = nil
        }
        if outputFormatDescription != nil {
            outputFormatDescription = nil
        }
        if oldContext !== _oglContext {
            EAGLContext.setCurrent(oldContext)
        }
    }
    
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer, motion: CMDeviceMotion?) -> CVPixelBuffer? {
        let kBlackUniform: [Float] = [0.0, 0.0, 0.0, 1.0]
        let squareVertices: [GLfloat] = [
            -1.0, -1.0, // bottom left
            1.0, -1.0, // bottom right
            -1.0,  1.0, // top left
            1.0,  1.0, // top right
        ]
        let textureVertices: [Float] = [
            0.0, 0.0, // bottom left
            1.0, 0.0, // bottom right
            0.0,  1.0, // top left
            1.0,  1.0, // top right
        ]
        
        let kMotionDampingFactor = 0.75
        let kMotionScaleFactor: Float = 0.01
        let kFrontScaleFactor: Float = 0.25
        let kBackScaleFactor: Float = 0.85
        
        if _offscreenBufferHandle == 0 {
            fatalError("Unintialize buffer")
        }
        
        let srcDimensions = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(pixelBuffer)), height: Int32(CVPixelBufferGetHeight(pixelBuffer)))
        let dstDimensions = CMVideoFormatDescriptionGetDimensions(outputFormatDescription!)
        if srcDimensions.width != dstDimensions.width ||
            srcDimensions.height != dstDimensions.height {
                fatalError("Invalid pixel buffer dimensions")
        }
        
        if CVPixelBufferGetPixelFormatType(pixelBuffer) != OSType(kCVPixelFormatType_32BGRA) {
            fatalError("Invalid pixel buffer format")
        }
        
        let oldContext = EAGLContext.current()
        if oldContext != _oglContext {
            if !EAGLContext.setCurrent(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        
        var err = noErr
        var srcTexture: CVOpenGLESTexture? = nil
        var dstTexture: CVOpenGLESTexture? = nil
        var backFrameTexture: CVOpenGLESTexture? = nil
        var dstPixelBuffer: CVPixelBuffer? =  nil
        
        if _lastMotionTime == 0 {
            _lastMotionTime = motion?.timestamp ?? 0
        }
        let timeDelta = (motion?.timestamp ?? 0) - _lastMotionTime
        _lastMotionTime = motion?.timestamp ?? 0
        
        _velocityDeltaX += (motion?.userAcceleration.x ?? 0.0) * timeDelta
        _velocityDeltaX *= kMotionDampingFactor
        _velocityDeltaY += (motion?.userAcceleration.y ?? 0.0) * timeDelta
        _velocityDeltaY *= kMotionDampingFactor
        
        bail: repeat {
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                _textureCache!,
                pixelBuffer,
                nil,
                GL_TEXTURE_2D.ui,
                GL_RGBA,
                srcDimensions.width,
                srcDimensions.height,
                GL_BGRA.ui,
                GL_UNSIGNED_BYTE.ui,
                0,
                &srcTexture)
            if srcTexture == nil || err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err)
                break bail
            }
            
            err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool!, _bufferPoolAuxAttributes, &dstPixelBuffer)
            if err == kCVReturnWouldExceedAllocationThreshold {
                // Flush the texture cache to potentially release the retained buffers and try again to create a pixel buffer
                CVOpenGLESTextureCacheFlush(_renderTextureCache!, 0)
                err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool!, _bufferPoolAuxAttributes, &dstPixelBuffer)
            }
            if err != 0 {
                if err == kCVReturnWouldExceedAllocationThreshold {
                    NSLog("Pool is out of buffers, dropping frame")
                } else {
                    NSLog("Error at CVPixelBufferPoolCreatePixelBuffer %d", err)
                }
                break bail
            }
            
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                _renderTextureCache!,
                dstPixelBuffer!,
                nil,
                GL_TEXTURE_2D.ui,
                GL_RGBA,
                dstDimensions.width,
                dstDimensions.height,
                GL_BGRA.ui,
                GL_UNSIGNED_BYTE.ui,
                0,
                &dstTexture)
            
            if dstTexture == nil || err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err)
                break bail
            }
            
            glBindFramebuffer(GL_FRAMEBUFFER.ui, _offscreenBufferHandle)
            glViewport(0, 0, srcDimensions.width, srcDimensions.height)
            glUseProgram(_program)
            
            glActiveTexture(GL_TEXTURE0.ui)
            glBindTexture(CVOpenGLESTextureGetTarget(dstTexture!), CVOpenGLESTextureGetName(dstTexture!))
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE)
            glFramebufferTexture2D(GL_FRAMEBUFFER.ui, GL_COLOR_ATTACHMENT0.ui, CVOpenGLESTextureGetTarget(dstTexture!), CVOpenGLESTextureGetName(dstTexture!), 0)
            
            var modelview: [Float] = Array(repeating: 0.0, count: 16)
            var projection: [Float] = Array(repeating: 0.0, count: 16)
            
            // setup projection matrix
            mat4f.LoadIdentity(&projection)
            glUniformMatrix4fv(_projection, 1, false, projection)
            
            if _backFramePixelBuffer != nil {
                
                let motionPixels: Float = kMotionScaleFactor * dstDimensions.width.f
                let motionMirroring: Float = self.shouldMirrorMotion ? -1 : 1
                let transBack: [Float] = [-_velocityDeltaY.f * motionPixels, -_velocityDeltaX.f * motionPixels * motionMirroring, 0.0]
                let scaleBack: [Float] = [kBackScaleFactor, kBackScaleFactor, 0.0]
                
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                    _renderTextureCache!,
                    _backFramePixelBuffer!,
                    nil,
                    GL_TEXTURE_2D.ui,
                    GL_RGBA,
                    dstDimensions.width,
                    dstDimensions.height,
                    GL_BGRA.ui,
                    GL_UNSIGNED_BYTE.ui,
                    0,
                    &backFrameTexture)
                
                if backFrameTexture == nil || err != 0 {
                    NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err)
                    break bail
                }
                
                glActiveTexture(GL_TEXTURE1.ui)
                glBindTexture(CVOpenGLESTextureGetTarget(backFrameTexture!), CVOpenGLESTextureGetName(backFrameTexture!))
                glUniform1i(_frame, 1)
                
                glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
                glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
                glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE)
                glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE)
                
                var translation: [Float] = Array(repeating: 0.0, count: 16)
                mat4f.LoadTranslation(transBack, &translation)
                
                var scaling: [Float] = Array(repeating: 0.0, count: 16)
                mat4f.LoadScale(scaleBack, &scaling)
                
                mat4f.MultiplyMat4f(translation, scaling, &modelview)
                
                glUniformMatrix4fv(_modelView, 1, false, modelview)
                
                glClearColor(kBlackUniform[0], kBlackUniform[1], kBlackUniform[2], kBlackUniform[3])
                glUniform4fv(_backgroundColor, 1, kBlackUniform)
                
                glClear(GL_COLOR_BUFFER_BIT.ui)
                
                glVertexAttribPointer(ATTRIB_VERTEX.ui, 2, GL_FLOAT.ui, 0, 0, squareVertices)
                glEnableVertexAttribArray(ATTRIB_VERTEX.ui)
                glVertexAttribPointer(ATTRIB_TEXTUREPOSITON.ui, 2, GL_FLOAT.ui, 0, 0, textureVertices)
                glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITON.ui)
                
                glDrawArrays(GL_TRIANGLE_STRIP.ui, 0, 4)
                
                glBindTexture(CVOpenGLESTextureGetTarget(backFrameTexture!), 0)
            } else {
                glClear(GL_COLOR_BUFFER_BIT.ui)
            }
            
            glActiveTexture(GL_TEXTURE2.ui)
            glBindTexture(CVOpenGLESTextureGetTarget(srcTexture!), CVOpenGLESTextureGetName(srcTexture!))
            glUniform1i(_frame, 2)
            
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE)
            
            let scaleFront: [Float] = [kFrontScaleFactor, kFrontScaleFactor, 0.0]
            mat4f.LoadScale(scaleFront, &modelview)
            
            glUniformMatrix4fv(_modelView, 1, false, modelview)
            
            glVertexAttribPointer(ATTRIB_VERTEX.ui, 2, GL_FLOAT.ui, 0, 0, squareVertices)
            glEnableVertexAttribArray(ATTRIB_VERTEX.ui)
            glVertexAttribPointer(ATTRIB_TEXTUREPOSITON.ui, 2, GL_FLOAT.ui, 0, 0, textureVertices)
            glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITON.ui)
            
            glDrawArrays(GL_TRIANGLE_STRIP.ui, 0, 4)
            
            glBindTexture(CVOpenGLESTextureGetTarget(srcTexture!), 0)
            glBindTexture(CVOpenGLESTextureGetTarget(dstTexture!), 0)
            
            if _backFramePixelBuffer != nil {
                _backFramePixelBuffer = nil
            }
            _backFramePixelBuffer = dstPixelBuffer
            
            glFlush()
            
        } while false
        if oldContext !== _oglContext {
            EAGLContext.setCurrent(oldContext)
        }
        return dstPixelBuffer
    }
    
}
