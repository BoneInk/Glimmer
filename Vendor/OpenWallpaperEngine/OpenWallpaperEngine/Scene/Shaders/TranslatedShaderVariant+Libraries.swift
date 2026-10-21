import Metal

extension TranslatedShaderVariant {
    /// The vertex and fragment MSL compiled into Metal libraries (timed as the `pipeline` phase).
    func makeLibraries(device: MTLDevice) throws -> (vertex: MTLLibrary, fragment: MTLLibrary) {
        try OWEPhaseTiming.measure(.pipeline) {
            (try device.makeLibrary(source: vertexMSL, options: nil),
             try device.makeLibrary(source: fragmentMSL, options: nil))
        }
    }
}
