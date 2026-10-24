import Metal
import MetalSprocketsPBR
import Testing

@Test
func bindingKeepsSamplerDescriptor() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let placeholder = try PBRMaterial.placeholderBinding(device: device)
    let descriptor = MTLSamplerDescriptor()
    descriptor.minFilter = .nearest
    descriptor.sAddressMode = .mirrorRepeat
    let binding = try PBRMaterial.Binding(texture: placeholder.texture, samplerDescriptor: descriptor, device: device)
    descriptor.minFilter = .linear
    #expect(binding.samplerDescriptor.minFilter == .nearest)
    #expect(binding.samplerDescriptor.sAddressMode == .mirrorRepeat)
    #expect(binding.samplerDescriptor.supportArgumentBuffers)
    #expect(placeholder.samplerDescriptor.sAddressMode == .repeat)
}
