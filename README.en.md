# PhotoMCP

English | [日本語](README.md)

A resident MCP server that lets AI agents such as Claude Desktop and Claude Code search, view, and save photos from your macOS photo library.

## What it can do

- List albums
- Search photos by keyword and shooting date (equivalent to Photos.app search)
- View photos (downscaled images) and save them to local files
- Get metadata such as shooting date and GPS coordinates

## Requirements

- macOS 14 or later
- Claude Desktop or Claude Code

## Installation

1. Download the latest `PhotoMCPApp-<version>-<build>.zip` (for example, `PhotoMCPApp-0.1.1-2.zip`) from [Releases](https://github.com/kotowo/PhotoMCP/releases), and place `PhotoMCPApp.app` in `/Applications`.
2. Double-click `PhotoMCPApp.app` to launch it once.
   - On the first launch, it only registers the resident agent and then quits.
   - After that, it starts automatically at login (an icon appears in the menu bar).
3. If you are asked for permission in "System Settings > General > Login Items", turn it on.
4. Dialogs appear asking for access to your photos, and for permission to control the Photos app (Automation), which the search feature uses. Allow both.

From the menu bar icon, you can quit the resident process and unregister it.

## Register with Claude Desktop

Add the following to `~/Library/Application Support/Claude/claude_desktop_config.json`.

```json
{
  "mcpServers": {
    "photomcp": {
      "command": "/Applications/PhotoMCPApp.app/Contents/Resources/MCPServer"
    }
  }
}
```

## Register with Claude Code

```bash
claude mcp add --scope user photomcp -- \
  "/Applications/PhotoMCPApp.app/Contents/Resources/MCPServer"
```

The `photomcp` tools become visible via the `/mcp` command in new sessions opened after registration (sessions that were already open at registration time are not affected).

To unregister:

```bash
claude mcp remove photomcp -s user
```

## Tools

| Tool | Arguments | Description |
|---|---|---|
| `list_albums` | none | List of album names, IDs, and photo counts |
| `search_photos` | `keyword?`, `date_from?`, `date_to?`, `location?` | List of photo IDs, shooting dates, and sizes (up to 200). `keyword` accepts the same conditions as Photos.app search |
| `get_album_photos` | `album_id` | List of photos in an album (up to 500) |
| `get_photo` | `id`, `max_size?` (default 1024px) | Get a photo as a downscaled image |
| `save_photo` | `id`, `path?`, `max_size?` (default 1024px) | Save a photo as a JPEG file (to `~/Downloads` if `path` is omitted) |
| `get_metadata` | `id` | Shooting date, GPS coordinates, camera information, favorite status, etc. |

Use the IDs returned by `search_photos`, `list_albums`, and `get_album_photos` as `id`.

## Building from source

The project does not use an Xcode project; it is built with Swift Package Manager.

```bash
git clone https://github.com/kotowo/PhotoMCP.git
cd PhotoMCP
swift build -c release --product PhotoMCPApp --product MCPServer
```

For assembling, signing, and notarizing the distributable `.app`, see `scripts/release.sh`.

## Versioning policy

Release artifacts have two numbers, and the file name is `PhotoMCPApp-<version>-<build>.zip` (for example, `PhotoMCPApp-0.1.1-2.zip`).

### version (`CFBundleShortVersionString`)

Written as `major.minor.patch`.

- Major: Set to 1 once all the requirements for V1.0.0 are met, and never changed after that.
- Minor: Feature additions. When it exceeds 9, it continues as 10, 11, and so on (no carry-over to the major).
- Patch: Bug fixes.

The 0.x series, up to 1.0.0, is the period before the official release, and is published without a suffix.

### Beta releases

From 1.0.0 onward, when the minor version is raised, a beta release is published first. It goes `1.1.0-beta.1`, `1.1.0-beta.2`, and so on, and `1.1.0` is published after verification.

### build (`CFBundleVersion`)

An integer that is incremented by 1 every time a release artifact is built. It is not reset to 1 when the version is raised, and it increases monotonically regardless of whether the release is a beta or an official one.

### Git tags and GitHub Releases

Tags and Releases are named `v<version>` (for example, `v1.1.0-beta.1`). Beta releases are published as GitHub pre-releases.

Distributable builds are made with `scripts/release.sh <version> <build>`. The version string that `MCPServer` reports about itself (`PhotoMCPHelper/main.swift`) is hard-coded separately from Info.plist, so update it by hand with each release.

## License

Released under the [MIT License](LICENSE).

The licenses of the bundled dependency packages (SwiftNIO, MCP Swift SDK, etc.) are collected in [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt). The same file is also included in `Contents/Resources/` of the distributable `.app`.

---

This project was built with the help of [Claude Code](https://claude.com/claude-code).
