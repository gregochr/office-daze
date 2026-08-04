#if DEBUG
import Foundation

/// A real `.pkpass` and a real model response, built in-process so the capture
/// pipeline can be driven from the command line.
///
/// There is no way to hand the simulator a file through the share sheet from a
/// script, so without this the confirm screen could only ever be checked by
/// hand. Debug builds only — it never ships.
nonisolated enum CaptureSamples {

    static let eurostarPassJSON = """
    {
      "formatVersion": 1,
      "passTypeIdentifier": "pass.com.eurostar.ticket",
      "serialNumber": "XKR48821",
      "organizationName": "Eurostar",
      "description": "Eurostar ticket",
      "relevantDate": "2026-09-07T17:04:00+01:00",
      "expirationDate": "2026-09-07T20:05:00+02:00",
      "boardingPass": {
        "transitType": "PKTransitTypeTrain",
        "primaryFields": [
          {"key": "origin", "label": "London", "value": "St Pancras"},
          {"key": "destination", "label": "Brussels", "value": "Brussels Midi"}
        ],
        "secondaryFields": [
          {"key": "coach", "label": "Coach", "value": "09"},
          {"key": "seat", "label": "Seat", "value": 51}
        ],
        "backFields": [
          {"key": "bookingRef", "label": "Booking reference", "value": "XKR48821"}
        ]
      }
    }
    """

    /// The Ropewalk as a screengrab would come back: two fields the model could
    /// not read, named rather than guessed.
    static let incompleteStay = ParsedBooking(
        detail: .stay(StayDetail(
            hotelName: "The Ropewalk",
            address: "41 Rivington St",
            city: "London",
            checkIn: nil,
            checkOut: Day(2026, 9, 11).at(11, 0, in: TimeDisplay.uk),
            nights: 1,
            bookingRef: nil
        )),
        startsAt: Day(2026, 9, 10).at(19, 30, in: TimeDisplay.uk),
        startZoneID: "Europe/London",
        endsAt: Day(2026, 9, 11).at(11, 0, in: TimeDisplay.uk),
        endZoneID: "Europe/London",
        unsureFields: ["checkIn", "bookingRef"],
        provenance: .screengrab,
        confidence: .low
    )

    /// A stored (uncompressed) zip holding one file.
    static func zip(named name: String, contents: Data) -> Data {
        var data = Data()
        let nameBytes = Data(name.utf8)
        let crc = crc32(contents)

        func u16(_ value: UInt16) -> Data {
            Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
        }
        func u32(_ value: UInt32) -> Data {
            Data([
                UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF),
                UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF),
            ])
        }

        let localOffset = data.count
        data.append(u32(0x0403_4B50))
        data.append(u16(20)); data.append(u16(0)); data.append(u16(0))
        data.append(u16(0)); data.append(u16(0))
        data.append(u32(crc))
        data.append(u32(UInt32(contents.count)))
        data.append(u32(UInt32(contents.count)))
        data.append(u16(UInt16(nameBytes.count))); data.append(u16(0))
        data.append(nameBytes)
        data.append(contents)

        let centralOffset = data.count
        data.append(u32(0x0201_4B50))
        data.append(u16(20)); data.append(u16(20))
        data.append(u16(0)); data.append(u16(0))
        data.append(u16(0)); data.append(u16(0))
        data.append(u32(crc))
        data.append(u32(UInt32(contents.count)))
        data.append(u32(UInt32(contents.count)))
        data.append(u16(UInt16(nameBytes.count)))
        data.append(u16(0)); data.append(u16(0))
        data.append(u16(0)); data.append(u16(0))
        data.append(u32(0))
        data.append(u32(UInt32(localOffset)))
        data.append(nameBytes)
        let centralSize = data.count - centralOffset

        data.append(u32(0x0605_4B50))
        data.append(u16(0)); data.append(u16(0))
        data.append(u16(1)); data.append(u16(1))
        data.append(u32(UInt32(centralSize)))
        data.append(u32(UInt32(centralOffset)))
        data.append(u16(0))
        return data
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
#endif
