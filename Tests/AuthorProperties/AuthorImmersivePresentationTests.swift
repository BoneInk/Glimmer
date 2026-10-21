import Foundation

@main
struct AuthorImmersivePresentationTests {
    static func main() throws {
        let source = Data(#"{"type":"web","general":{"properties":{"speed":{"type":"slider","text":"速度","value":1,"min":0,"max":4},"ui_browse_properties_scheme_color":{"type":"color","value":"1 1 1"},"heading":{"type":"text","text":"作者说明"},"opaque":{"type":"vendor-extension","value":true},"unsafe":{"type":"bool","value":true,"condition":"unknownFunction()"}}}}"#.utf8)
        let project = try AuthorPropertyProject.parse(data: source, projectURL: URL(fileURLWithPath: "/fixture/project.json"))
        func capabilities(_ keys: Set<String>) -> AuthorPropertyEditingCapabilities {
            .init(editableKeys: keys, runtimeLabel: "Fixture", unsupportedReason: "")
        }
        let waiting = capabilities([])
        precondition(!waiting.hasEditableOptions(in: project), "loading/unsupported host must not mount an empty floating card")
        let supported = capabilities(["speed"])
        precondition(supported.hasEditableOptions(in: project), "actual supported host readiness must reveal the settings card")
        let values = project.resolve(overrides: [:]).values
        let immersiveKeys = project.properties.filter { supported.allows($0, project: project, values: values) }.map(\.key)
        precondition(immersiveKeys == ["speed"], "immersive view must omit disabled raw keys, read-only headings and unknown schema")
        precondition(!capabilities(["heading", "opaque"]).hasEditableOptions(in: project), "read-only/unknown keys cannot create a meaningless card")
        precondition(!capabilities(["unsafe"]).hasEditableOptions(in: project), "unsupported visibility conditions cannot create an editable card")
        precondition(!waiting.hasEditableOptions(in: project), "loss of host capability must hide the full card again")
        precondition(project.definition(for: "ui_browse_properties_scheme_color") != nil && project.properties.count == 5,
                     "presentation filtering must preserve original definitions for standard author UI")
        print("PASS: 7 immersive author presentation checks: empty/ready/lost capability, raw-key/schema/condition filtering, standard definitions retained")
    }
}
