// owe-mcp, the MCP Server plugin's executable (target OWEMCPServer, shipped in
// `Contents/Helpers` and copied into place when the plugin is installed): the Model Context
// Protocol over stdio, each tool call a request to the running app (Packages/OWEControl,
// docs/mcp.md). It links only that package and the system's libraries.
import Foundation
import OWEMCP

exit(await OWEMCPCommand.run())
