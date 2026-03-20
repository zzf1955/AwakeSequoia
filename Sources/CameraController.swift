import Foundation
import simd

/// Camera state: position + orientation + matrices
struct CameraState {
    let position: SIMD3<Float>
    let forward: SIMD3<Float>
    let up: SIMD3<Float>

    var viewMatrix: float4x4 {
        let target = position + forward
        return CameraState.lookAt(eye: position, target: target, up: up)
    }

    static func orthographicMatrix(left: Float, right: Float, bottom: Float, top: Float,
                                      near: Float, far: Float) -> float4x4 {
        let sx = 2.0 / (right - left)
        let sy = 2.0 / (top - bottom)
        let sz = 1.0 / (near - far)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        let tz = near / (near - far)
        return float4x4(columns: (
            SIMD4(sx, 0, 0, 0),
            SIMD4(0, sy, 0, 0),
            SIMD4(0, 0, sz, 0),
            SIMD4(tx, ty, tz, 1)
        ))
    }

    static func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1.0 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}

/// Camera controller: walks along a path, outputs CameraState
struct CameraController {
    var height: Float = 0.01
    var pitchDegrees: Float = 60.0
    var fovDegrees: Float = 45.0
    var nearPlane: Float = 0.001
    var farPlane: Float = 200.0
    var speed: Float = 0.5
    var swayAmplitude: Float = 0.0   // max yaw offset in degrees (0 = disabled)
    var swaySpeed: Float = 1.0       // base frequency multiplier

    /// Evaluate camera state at a given time (converts to distance via speed)
    func evaluate(planner: PathPlanner, time: Float, aspect: Float) -> CameraState {
        return evaluate(planner: planner, distance: time * speed, aspect: aspect)
    }

    /// Evaluate camera state at a given arc-length distance along the path
    func evaluate(planner: PathPlanner, distance: Float, aspect: Float) -> CameraState {
        let (x, z, _) = planner.evaluate(distance: distance)

        // Camera always faces forward (+Z), with smooth random sway
        var totalYaw: Float = 0
        if swayAmplitude > 0 {
            let t = distance * swaySpeed
            let phi: Float = 1.6180339887
            let sway = sin(t * 1.0) * 0.4
                      + sin(t * phi) * 0.3
                      + sin(t * phi * phi) * 0.2
                      + sin(t / phi) * 0.1
            totalYaw = swayAmplitude * (.pi / 180.0) * sway
        }

        // Mirror X to compensate for Apple shader's X negation in model transform
        let pitchRad = pitchDegrees * .pi / 180.0
        let flatForward = SIMD3<Float>(-sin(totalYaw), 0, cos(totalYaw))

        let camPos = SIMD3<Float>(-x, height, z)

        let cp = cos(pitchRad)
        let sp = sin(pitchRad)
        let forward = cp * flatForward + sp * SIMD3(0, 1, 0)
        let up = -sp * flatForward + cp * SIMD3(0, 1, 0)

        return CameraState(position: camPos, forward: normalize(forward), up: normalize(up))
    }

    /// Projection matrix for current settings
    func projectionMatrix(aspect: Float) -> float4x4 {
        let fovRad = fovDegrees * .pi / 180.0
        return CameraState.perspectiveMatrix(fovY: fovRad, aspect: aspect, near: nearPlane, far: farPlane)
    }
}
