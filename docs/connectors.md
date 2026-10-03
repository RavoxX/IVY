# Connecting apps to IVY

In App Connectors, find an app in its category and choose Connect. My apps → Manage opens saved accounts. Bundled logos do not contact vendors automatically.

For OAuth dynamic registration, choose Sign in with browser, review consent, and enable specific tools. Other services need registered native OAuth credentials under Advanced authentication or a server-issued bearer token. IVY uses a random loopback callback at http://127.0.0.1:<port>/callback with PKCE S256 and a fresh state.

Do not copy OAuth credentials from ChatGPT or Claude. Providers can restrict approved clients, plans, workspaces and administrators. A listing does not bypass those requirements.

## Google Workspace

The [Gmail setup guide](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) describes its preview requirements: join Workspace Developer Preview, create a Cloud project, enable Gmail API and Gmail MCP API, and configure OAuth branding, audience/test users and scopes. Use a Desktop OAuth client for IVY's [native loopback flow](https://developers.google.com/identity/protocols/oauth2/native-app).

Enter its client ID and any required secret in IVY. Gmail scopes include https://www.googleapis.com/auth/gmail.readonly and, for drafts, https://www.googleapis.com/auth/gmail.compose. Consent and administrator policy still determine access.

| App | Endpoint | Setup |
| --- | --- | --- |
| Gmail | https://gmailmcp.googleapis.com/mcp/v1 | [Gmail](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| Drive | https://drivemcp.googleapis.com/mcp/v1 | [Drive](https://developers.google.com/workspace/drive/api/guides/configure-mcp-server) |
| Calendar | https://calendarmcp.googleapis.com/mcp/v1 | [Calendar](https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server) |

If OAuth discovery or preview access fails, the error remains visible. Alternatively, add a trusted compatible Gmail MCP server with Add custom connector. IVY does not install a server silently.

## Other featured services

- [Notion](https://developers.notion.com/guides/mcp/get-started-with-mcp), [Linear](https://linear.app/docs/mcp), and [Figma](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/) document hosted access and authentication.
- [Slack](https://docs.slack.dev/ai/slack-mcp-server), [Asana](https://developers.asana.com/docs/integrating-with-asanas-mcp-server), [Canva](https://www.canva.dev/docs/apps/mcp/) and [HubSpot](https://developers.hubspot.com/docs/apps/developer-platform/build-apps/integrate-with-the-remote-hubspot-mcp-server) can impose client registration/account restrictions. Follow their setup links in IVY.
- Microsoft 365 opens a registry search. IVY has no verified universal public endpoint equivalent to Anthropic's private connector.

## Tools and access

Connections discover tools; enable only the ones you want. Up to 24 per account keeps model prompts manageable. Every call requires approval with its exact arguments and destination. Read-only server annotations do not bypass confirmation. Results are untrusted data and may be sent to the selected AI provider.

Disconnect closes the session but retains credentials. Revoke asks the service to invalidate its grant and clears local credentials; services without revocation require their authorized-apps page. Remove clears IVY's entry and credentials. Startup stays disconnected.

Supported: remote Streamable HTTP, JSON/SSE, MCP versions 2025-03-26, 2025-06-18 and 2025-11-25. Unsupported: executing registry npm packages, stdio, legacy HTTP+SSE, sampling and elicitation. Check your server's transport, authentication and schemas.
