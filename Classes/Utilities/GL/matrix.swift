//
//  matrix.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/4.
//
//
//
/*
     File: matrix.h
     File: matrix.c
 Abstract: Simple 4x4 matrix computations
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

/*
 NOTE: These functions are created for your convenience but the matrix algorithms
 are not optimized. You are encouraged to do additional research on your own to
 implement a more robust numerical algorithm.
*/

struct mat4f {
    static func LoadIdentity(_ m: UnsafeMutablePointer<Float>) {
        m[0] = 1.0
        m[1] = 0.0
        m[2] = 0.0
        m[3] = 0.0
        
        m[4] = 0.0
        m[5] = 1.0
        m[6] = 0.0
        m[7] = 0.0
        
        m[8] = 0.0
        m[9] = 0.0
        m[10] = 1.0
        m[11] = 0.0
        
        m[12] = 0.0
        m[13] = 0.0
        m[14] = 0.0
        m[15] = 1.0
    }
    
    // s is a 3D vector
    static func LoadScale(_ s: UnsafePointer<Float>, _ m: UnsafeMutablePointer<Float>) {
        m[0] = s[0]
        m[1] = 0.0
        m[2] = 0.0
        m[3] = 0.0
        
        m[4] = 0.0
        m[5] = s[1]
        m[6] = 0.0
        m[7] = 0.0
        
        m[8] = 0.0
        m[9] = 0.0
        m[10] = s[2]
        m[11] = 0.0
        
        m[12] = 0.0
        m[13] = 0.0
        m[14] = 0.0
        m[15] = 1.0
    }
    
    // v is a 3D vector
    static func LoadTranslation(_ v: UnsafePointer<Float>, _ mout: UnsafeMutablePointer<Float>) {
        mout[0] = 1.0
        mout[1] = 0.0
        mout[2] = 0.0
        mout[3] = 0.0
        
        mout[4] = 0.0
        mout[5] = 1.0
        mout[6] = 0.0
        mout[7] = 0.0
        
        mout[8] = 0.0
        mout[9] = 0.0
        mout[10] = 1.0
        mout[11] = 0.0
        
        mout[12] = v[0]
        mout[13] = v[1]
        mout[14] = v[2]
        mout[15] = 1.0
    }
    
    static func MultiplyMat4f(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ mout: UnsafeMutablePointer<Float>) {
        mout[0]  = a[0] * b[0]  + a[4] * b[1]  + a[8] * b[2]   + a[12] * b[3]
        mout[1]  = a[1] * b[0]  + a[5] * b[1]  + a[9] * b[2]   + a[13] * b[3]
        mout[2]  = a[2] * b[0]  + a[6] * b[1]  + a[10] * b[2]  + a[14] * b[3]
        mout[3]  = a[3] * b[0]  + a[7] * b[1]  + a[11] * b[2]  + a[15] * b[3]
        
        mout[4]  = a[0] * b[4]  + a[4] * b[5]  + a[8] * b[6]   + a[12] * b[7]
        mout[5]  = a[1] * b[4]  + a[5] * b[5]  + a[9] * b[6]   + a[13] * b[7]
        mout[6]  = a[2] * b[4]  + a[6] * b[5]  + a[10] * b[6]  + a[14] * b[7]
        mout[7]  = a[3] * b[4]  + a[7] * b[5]  + a[11] * b[6]  + a[15] * b[7]
        
        mout[8]  = a[0] * b[8]  + a[4] * b[9]  + a[8] * b[10]  + a[12] * b[11]
        mout[9]  = a[1] * b[8]  + a[5] * b[9]  + a[9] * b[10]  + a[13] * b[11]
        mout[10] = a[2] * b[8]  + a[6] * b[9]  + a[10] * b[10] + a[14] * b[11]
        mout[11] = a[3] * b[8]  + a[7] * b[9]  + a[11] * b[10] + a[15] * b[11]
        
        mout[12] = a[0] * b[12] + a[4] * b[13] + a[8] * b[14]  + a[12] * b[15]
        mout[13] = a[1] * b[12] + a[5] * b[13] + a[9] * b[14]  + a[13] * b[15]
        mout[14] = a[2] * b[12] + a[6] * b[13] + a[10] * b[14] + a[14] * b[15]
        mout[15] = a[3] * b[12] + a[7] * b[13] + a[11] * b[14] + a[15] * b[15]
    }
}
