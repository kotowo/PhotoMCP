# PhotoMCP

MacOS の写真ライブラリを、Claude DesktopやClaude Code等の AI Agent から検索・閲覧・保存できるようにする常駐型 MCP サーバです。

## できること

- アルバム一覧の取得
- キーワード・撮影日での写真検索（Photos.appの検索と同等）
- 写真の閲覧（縮小画像）・ローカルファイルへの保存
- 撮影日・GPS座標などのメタデータ取得

## 必要環境

- macOS 14以降
- Claude Desktop または Claude Code

## インストール

1. [Releases](https://github.com/kotowo/PhotoMCP/releases) から最新の `PhotoMCPApp-<version>-<build>.zip`（例: `PhotoMCPApp-0.1.1-2.zip`）をダウンロードし、`PhotoMCPApp.app` を `/Applications` または `~/Applications` に置く
2. `PhotoMCPApp.app` をダブルクリックで一度起動する
   - 初回は常駐用の登録だけ行って終了する
   - 以降はログイン時に自動起動する（メニューバーにアイコンが表示される）
3. 「システム設定 > 一般 > ログイン項目」で許可を求められた場合はオンにする
4. 写真へのアクセス許可、および検索機能で使う「写真」アプリの操作許可（オートメーション）のダイアログが表示されるので許可する

メニューバーアイコンから、常駐プロセスの終了・登録解除ができます。

## Claude Desktopに登録する

`~/Library/Application Support/Claude/claude_desktop_config.json` に追加します。

```json
{
  "mcpServers": {
    "photomcp": {
      "command": "/Users/<your-username>/Applications/PhotoMCPApp.app/Contents/Resources/MCPServer"
    }
  }
}
```

## Claude Codeに登録する

```bash
claude mcp add --scope user photomcp -- \
  "$HOME/Applications/PhotoMCPApp.app/Contents/Resources/MCPServer"
```

登録後に開いた新しいセッションから、`/mcp` コマンドで `photomcp` のツールが見えるようになります（登録時に既に開いていたセッションには反映されません）。

登録解除:

```bash
claude mcp remove photomcp -s user
```

## 提供ツール

| ツール名 | 引数 | 説明 |
|---|---|---|
| `list_albums` | なし | アルバム名・ID・枚数の一覧 |
| `search_photos` | `keyword?`, `date_from?`, `date_to?`, `location?` | 写真ID・撮影日・サイズの一覧（最大200件）。`keyword`はPhotos.appの検索と同じ条件が使える |
| `get_album_photos` | `album_id` | アルバム内の写真一覧（最大500件） |
| `get_photo` | `id`, `max_size?`（デフォルト1024px） | 写真を縮小画像として取得 |
| `save_photo` | `id`, `path?`, `max_size?`（デフォルト1024px） | 写真をJPEGとしてローカルファイルに保存（`path`省略時は`~/Downloads`） |
| `get_metadata` | `id` | 撮影日・GPS座標・カメラ情報・お気に入り等 |

`id`は`search_photos` / `list_albums` / `get_album_photos`で取得できるIDを使います。

## ソースからビルドする

Xcodeプロジェクトは使わず、Swift Package Managerでビルドします。

```bash
git clone https://github.com/kotowo/PhotoMCP.git
cd PhotoMCP
swift build -c release --product PhotoMCPApp --product MCPServer
```

配布用`.app`の組み立て・署名・公証は `scripts/release.sh` を参照してください。

## ライセンス

[MIT License](LICENSE) です。

同梱している依存パッケージ（SwiftNIO、MCP Swift SDK など）のライセンスは [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt) にまとめています。配布用の`.app`にも`Contents/Resources/`に同じファイルを入れています。

---

This project was built with the help of [Claude Code](https://claude.com/claude-code).
