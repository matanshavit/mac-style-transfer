import CoreMedia
import CoreMediaIO

enum CMIOProperty {
    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        address(CMIOObjectPropertySelector(selector))
    }

    static func objectIDs(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func string(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var address = address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        string(object, CMIOObjectPropertySelector(selector))
    }

    static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr ? value : nil
    }

    static func formatDescription(_ object: CMIOObjectID) -> CMFormatDescription? {
        var address = address(kCMIOStreamPropertyFormatDescription)
        var value: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size), &used, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue()
    }
}

enum FourCC {
    static func code(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
