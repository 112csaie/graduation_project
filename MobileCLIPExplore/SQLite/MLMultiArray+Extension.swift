import Foundation
import CoreML
import Accelerate

extension MLMultiArray {
    func toFloatArray() -> [Float] {
        let count = self.count
        let pointer = self.dataPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

extension Array where Element == Float {
    func normalized() -> [Float] {
        var sumOfSquares: Float = 0
        // 極速計算平方和
        vDSP_svesq(self, 1, &sumOfSquares, vDSP_Length(self.count))
        let length = sqrt(sumOfSquares)
        
        guard length > 0 else { return self }
        
        // 極速除以長度
        var result = [Float](repeating: 0, count: self.count)
        vDSP_vsdiv(self, 1, [length], &result, 1, vDSP_Length(self.count))
        return result
    }
}
