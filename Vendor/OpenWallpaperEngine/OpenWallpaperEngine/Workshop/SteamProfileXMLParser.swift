import Foundation

/// Reads a player's persona name and avatar from `steamcommunity.com/profiles/<id>?xml=1`,
/// the keyless source for author names when no Steam Web API key is set.
///
/// Private profiles still list the name and avatar. A missing profile answers with
/// `<response><error>…</error></response>`, which parses to `nil`.
final class SteamProfileXMLParser: NSObject, XMLParserDelegate {
    private var fields: [String: String] = [:]
    private var path: [String] = []
    private var text = ""

    static func player(from data: Data, steamId: String) -> SteamPlayer? {
        let delegate = SteamProfileXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            OWELog.error(.workshop, "Can't parse the Steam profile of \(steamId): \(parser.parserError.map { "\($0)" } ?? "unknown error")")
            return nil
        }
        let fields = delegate.fields
        guard let name = fields["steamID"], !name.isEmpty else { return nil }
        if let id = fields["steamID64"], id != steamId { return nil }
        return SteamPlayer(
            steamId: steamId,
            personaName: name,
            avatarURL: fields["avatarFull"].flatMap(URL.init(string:))
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        // Only the profile's own top-level fields; nested groups and games repeat some names.
        if path == ["profile", elementName] {
            fields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        path.removeLast()
        text = ""
    }
}
