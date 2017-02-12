//
//  matrix.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/4.
//
//
//
/*
 <codex>
 <abstract>Simple 4x4 matrix computations</abstract>
 </codex>
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
