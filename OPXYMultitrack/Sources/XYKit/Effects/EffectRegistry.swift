// EffectRegistry.swift — the one list of every effect the app can use.
// Built-ins register in code. Add-ons are .bundle files dropped into the plugin folder and loaded at launch.

import AVFoundation
import Foundation

public final class EffectRegistry {
    public static let shared = EffectRegistry()

    public private(set) var descriptors: [EffectDescriptor] = []
    private var byID: [String: EffectDescriptor] = [:]

    /// ~/Library/Application Support/OPXYMultitrack/Effects
    public static var pluginDirectory: URL {
        ProjectPackage.supportDirectory.appendingPathComponent("Effects", isDirectory: true)
    }

    private init() {
        AppleEffects.descriptors.forEach(register)
        register(EffectDescriptor(module: TapeSaturation.self, category: "Character"))
        register(EffectDescriptor(module: Bitcrusher.self, category: "Character"))
        register(EffectDescriptor(module: WowFlutter.self, category: "Character"))
        register(EffectDescriptor(module: Noise.self, category: "Character"))
        scanPlugins()
    }

    public func descriptor(_ id: String) -> EffectDescriptor? { byID[id] }

    public var categories: [String] {
        var seen: [String] = []
        for d in descriptors where !seen.contains(d.category) { seen.append(d.category) }
        return seen
    }

    public func register(_ descriptor: EffectDescriptor) {
        guard byID[descriptor.id] == nil else {
            print("[Effects] Skipped duplicate module \(descriptor.id)")
            return
        }
        byID[descriptor.id] = descriptor
        descriptors.append(descriptor)
    }

    // MARK: Downloaded add-ons

    /// Load every .bundle in the plugin folder. A bundle that fails to load is skipped; it can't stop the app.
    public func scanPlugins() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginDirectory, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: Self.pluginDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "bundle" {
            guard let bundle = Bundle(url: url), bundle.load(),
                  let type = bundle.principalClass as? NSObject.Type,
                  let plugin = type.init() as? XYEffectPlugin else {
                print("[Effects] Could not load \(url.lastPathComponent)")
                continue
            }
            register(Self.descriptor(for: plugin))
            print("[Effects] Loaded add-on \(plugin.identifier) \(plugin.version)")
        }
    }

    private static func descriptor(for plugin: XYEffectPlugin) -> EffectDescriptor {
        let parameters: [EffectParameter] = plugin.parameterSpecs.compactMap { spec in
            guard let id = spec["id"] as? String, let name = spec["name"] as? String else { return nil }
            let number = { (key: String, fallback: Float) -> Float in
                (spec[key] as? NSNumber)?.floatValue ?? fallback
            }
            return EffectParameter(id: id, name: name, min: number("min", 0), max: number("max", 1),
                                   defaultValue: number("default", 0), unit: spec["unit"] as? String ?? "")
        }
        return EffectDescriptor(id: plugin.identifier, name: plugin.displayName, version: plugin.version,
                                category: "Add-ons", parameters: parameters) { format in
            let kernel = PluginKernelAdapter(plugin.makeKernel(sampleRate: format.sampleRate,
                                                               channelCount: Int(format.channelCount)))
            for p in parameters { kernel.setParameter(p.id, value: p.defaultValue) }
            return KernelEffectInstance(kernel: kernel)
        }
    }
}

// MARK: Add-on contract
//
// A downloaded bundle can't link against this app's Swift types, so add-ons speak two small
// Objective-C protocols instead. The runtime matches protocols by name, which lets a bundle
// declare the same protocols in its own source (see PluginExample/ExampleEffect.swift).

@objc(XYEffectPlugin) public protocol XYEffectPlugin: NSObjectProtocol {
    var identifier: String { get }
    var displayName: String { get }
    var version: String { get }
    /// One dictionary per parameter with keys: id, name, min, max, default, unit.
    var parameterSpecs: [[String: Any]] { get }
    func makeKernel(sampleRate: Double, channelCount: Int) -> XYEffectPluginKernel
}

@objc(XYEffectPluginKernel) public protocol XYEffectPluginKernel: NSObjectProtocol {
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int)
    func setParameter(_ id: String, value: Float)
    func reset()
}

private final class PluginKernelAdapter: AudioEffectKernel {
    private let kernel: XYEffectPluginKernel
    init(_ kernel: XYEffectPluginKernel) { self.kernel = kernel }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        kernel.process(buffers.unsafeMutablePointer, frameCount: frameCount)
    }
    func setParameter(_ id: String, value: Float) { kernel.setParameter(id, value: value) }
    func reset() { kernel.reset() }
}
