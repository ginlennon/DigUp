import DigUpKit
import Foundation

/// A quick check that the model makes here the vectors it should (`digup doctor`): two texts, with the prompts search
/// and indexing give them, against the first 16 numbers of their vectors. Those were made by this build on the CPU
/// (llama.cpp b11461, 2026-10-14) and agree with the full reference `ReferenceVectorTests` keeps (made on Metal, in
/// Tests/, which an installed DigUp doesn't have) to a cosine of 0.9998 over these numbers, as Vulkan's do with them.
/// Sixteen numbers can't catch all the full test does, but a wrong model file, a broken backend or a changed pipeline
/// moves them far further than `agreement` allows.
public enum SelfTest {
    public struct Sample: Sendable {
        /// Its name in the reference vectors (Tests/LlamaRuntimeTests/Reference/vectors.json).
        public let name: String
        /// What the model gets, prompt and all.
        public let input: String
        /// The first numbers of its vector.
        public let start: [Float]
    }

    public static let samples = [
        Sample(name: "query", input: Prompts.query("payment declined error"), start: [
            0.00868024, 0.00430524, 0.0381687, -0.0399883, -0.0462158, 0.0329228, -0.0704434, 0.02311,
            -0.0111787, -0.149324, -0.0427562, -0.0277617, -0.00129963, -0.0172323, -0.00786141, -0.0444539,
        ]),
        Sample(name: "document", input: Prompts.document(title: "Tokyo itinerary", text: "Flight to Tokyo Haneda on "
                   + "November 3. Then the train to Kamakura to see the Great Buddha, and back for dinner in Shibuya."),
               start: [
            0.00276755, -0.0231341, -0.0269591, -0.0255922, 0.00487195, -0.0310601, -0.0412968, 0.0316199,
            0.015859, -0.135721, -0.0495061, -0.0665011, -0.00763449, 0.0513932, 0.0403511, -0.00249606,
        ]),
    ]

    /// The cosine each sample must reach over its numbers: runtimes that agree measure 0.9998 or more; a vector from
    /// another model or a broken pipeline, far less.
    public static let agreement: Float = 0.995

    /// Each sample's cosine with what it should be, over the numbers kept.
    public static func run(_ embedder: any Embedder) throws -> [(name: String, cosine: Float)] {
        let vectors = try embedder.embedTexts(samples.map(\.input))
        return zip(samples, vectors).map { sample, vector in
            (sample.name, cosine(Array(vector.prefix(sample.start.count)), sample.start))
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let norms = (a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return norms > 0 && a.count == b.count ? dot / norms : 0
    }
}
