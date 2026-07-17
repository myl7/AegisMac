import Foundation

/// A named vault group (`VaultGroup.java`). Entries reference groups by UUID.
///
/// JSON: `{ "uuid": "<lowercase uuid>", "name": "<string>" }`. Both fields are
/// required on read (unlike entries, a group with no uuid fails to parse).
/// Group equality is defined by **uuid AND name** (Swift's synthesized
/// `Hashable`/`Equatable` over both stored properties matches this exactly).
struct VaultGroup: Hashable {
    var uuid: UUID
    var name: String

    init(uuid: UUID = UUID(), name: String) {
        self.uuid = uuid
        self.name = name
    }

    func toJson() -> JSONObject {
        return [
            "uuid": uuid.uuidString.lowercased(),
            "name": name
        ]
    }

    static func fromJson(_ obj: JSONObject) throws -> VaultGroup {
        guard let uuidStr = obj["uuid"] as? String else {
            throw AegisError.vault("group missing 'uuid'")
        }
        guard let uuid = UUID(uuidString: uuidStr) else {
            throw AegisError.vault("invalid group uuid: \(uuidStr)")
        }
        guard let name = obj["name"] as? String else {
            throw AegisError.vault("group missing 'name'")
        }
        return VaultGroup(uuid: uuid, name: name)
    }
}
