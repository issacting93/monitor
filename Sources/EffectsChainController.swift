// EffectsChainController.swift — live effect chain + chain presets
//
// Owns the live chain's node list and every mutation of it (add/remove/reorder,
// bypass, parameter writes), plus the on-disk preset directory. The @Published
// liveChain / presetNames / showPresetSave / presetSaveName stay on AudioManager
// so the chain editor binds unchanged; this controller writes them through its
// `manager` reference.

import Foundation
import SwiftUI
import AVFoundation

final class EffectsChainController {
    private unowned let manager: AudioManager

    // Instantiated chain nodes, in chain order. Apple nodes are appended during
    // startMonitoring; kernel-based nodes are appended asynchronously afterward.
    private var liveChainNodes: [(id: UUID, node: AVAudioNode)] = []

    private static let presetDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tape08/Presets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(manager: AudioManager) {
        self.manager = manager
    }

    // MARK: - Graph handoff

    func setChainNodes(_ nodes: [(id: UUID, node: AVAudioNode)]) {
        liveChainNodes = nodes
    }

    func clearChainNodes() {
        liveChainNodes = []
    }

    var lastChainNode: AVAudioNode? { liveChainNodes.last?.node }

    func appendChainNode(id: UUID, node: AVAudioNode) {
        liveChainNodes.append((id, node))
    }

    // MARK: - Node bypass

    func setNodeBypass(_ node: AVAudioNode, bypass: Bool) {
        if let effect = node as? AVAudioUnitEffect { effect.bypass = bypass }
        else if let au = node as? AVAudioUnit { au.auAudioUnit.shouldBypassEffect = bypass }
    }

    // MARK: - Chain edits

    func applySlotParam(_ slotIndex: Int, _ paramID: String, _ value: Float) {
        guard slotIndex < manager.liveChain.count else { return }
        let slot = manager.liveChain[slotIndex]
        guard let mod = EffectRegistry.shared.module(for: slot.moduleID),
              let entry = liveChainNodes.first(where: { $0.id == slot.id }) else { return }
        mod.applyParameter?(entry.node, paramID, value)
    }

    func toggleSlotBypass(_ slotIndex: Int) {
        guard slotIndex < manager.liveChain.count else { return }
        manager.liveChain[slotIndex].enabled.toggle()
        let slot = manager.liveChain[slotIndex]
        if let entry = liveChainNodes.first(where: { $0.id == slot.id }) {
            setNodeBypass(entry.node, bypass: !slot.enabled)
        }
    }

    func paramBinding(slot index: Int, param id: String) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                guard let self, index < self.manager.liveChain.count else { return 0 }
                return Double(self.manager.liveChain[index].parameters[id] ?? 0)
            },
            set: { [weak self] newVal in
                guard let self, index < self.manager.liveChain.count else { return }
                self.manager.liveChain[index].parameters[id] = Float(newVal)
                self.applySlotParam(index, id, Float(newVal))
            }
        )
    }

    func addSlot(moduleID: String) {
        manager.liveChain.append(ChainSlot(moduleID: moduleID))
        rebuildChain()
    }

    func removeSlot(at index: Int) {
        guard index < manager.liveChain.count else { return }
        manager.liveChain.remove(at: index)
        rebuildChain()
    }

    func moveSlot(from: Int, to: Int) {
        guard from < manager.liveChain.count, to < manager.liveChain.count, from != to else { return }
        let slot = manager.liveChain.remove(at: from)
        manager.liveChain.insert(slot, at: to)
        rebuildChain()
    }

    private func rebuildChain() {
        guard manager.isMonitoring else { return }
        manager.stopMonitoring()
        manager.startMonitoring()
    }

    // MARK: - Chain presets

    private func presetURL(name: String) -> URL {
        EffectsChainController.presetDir.appendingPathComponent(name + ".json")
    }

    func refreshPresetList() {
        let fm = FileManager.default
        let dir = EffectsChainController.presetDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            manager.presetNames = []
            return
        }
        manager.presetNames = files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func saveChainPreset(name: String) {
        let data = manager.liveChain.map { slot in
            ProjectChainSlotData(moduleID: slot.moduleID, enabled: slot.enabled, parameters: slot.parameters)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(data) else { return }
        try? json.write(to: presetURL(name: name))
        refreshPresetList()
        manager.status = "Preset saved: \(name)"
    }

    func loadChainPreset(name: String) {
        let url = presetURL(name: name)
        guard let json = try? Data(contentsOf: url),
              let slots = try? JSONDecoder().decode([ProjectChainSlotData].self, from: json) else {
            manager.status = "Failed to load preset"
            return
        }
        var newChain: [ChainSlot] = []
        for slotData in slots {
            var slot = ChainSlot(moduleID: slotData.moduleID, enabled: slotData.enabled)
            // Merge saved values over the module defaults so partial presets don't
            // drop unspecified parameters to zero (which desyncs the UI from the DSP).
            for (key, value) in slotData.parameters { slot.parameters[key] = value }
            newChain.append(slot)
        }
        manager.liveChain = newChain
        rebuildChain()
        manager.status = "Loaded preset: \(name)"
    }

    func deleteChainPreset(name: String) {
        try? FileManager.default.removeItem(at: presetURL(name: name))
        refreshPresetList()
        manager.status = "Deleted preset: \(name)"
    }

    func installBuiltInPresets() {
        let builtIns: [(String, [ProjectChainSlotData])] = [
            ("Clean", []),
            ("Warm", [
                ProjectChainSlotData(moduleID: "com.apple.eq", enabled: true, parameters: ["lowGain": 3, "midGain": -1, "highGain": -2]),
                ProjectChainSlotData(moduleID: "com.opxy.tape-saturation", enabled: true, parameters: ["drive": 0.4, "bump": 0.6, "mix": 0.5]),
            ]),
            ("Ambient", [
                ProjectChainSlotData(moduleID: "com.apple.reverb", enabled: true, parameters: ["wetDryMix": 55, "preset": 4]),
                ProjectChainSlotData(moduleID: "com.apple.delay", enabled: true, parameters: ["time": 0.35, "feedback": 40, "wetDryMix": 30, "cutoff": 8000]),
            ]),
            ("Lo-Fi", [
                ProjectChainSlotData(moduleID: "com.opxy.bitcrusher", enabled: true, parameters: ["bits": 10, "downsample": 8, "mix": 0.6]),
                ProjectChainSlotData(moduleID: "com.opxy.tape-saturation", enabled: true, parameters: ["drive": 0.5, "bump": 0.7, "mix": 0.4]),
                ProjectChainSlotData(moduleID: "com.opxy.chorus", enabled: true, parameters: ["rate": 0.8, "depth": 0.5, "mix": 0.4]),
            ]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Built-ins are code-defined defaults, so (re)write them on launch. This
        // keeps them current when their definitions change between builds.
        for (name, chain) in builtIns {
            if let json = try? encoder.encode(chain) {
                try? json.write(to: presetURL(name: name))
            }
        }
    }
}
