#!/usr/bin/env bash
# PhotoMCP 配布用ビルド: ビルド → .app組み立て → 署名 → 公証 → ステープル → 配布用zip
#
# 使い方:
#   scripts/release.sh <version> <build> [--no-notarize] [--force]
#     version : CFBundleShortVersionString（例: 0.2.0）
#     build   : CFBundleVersion（整数。配布のたびに+1。READMEの「バージョニング方針」参照）
#     --no-notarize : 署名・検証までで止める（公証=Appleへの提出を行わない。動作確認用）
#     --force       : 未コミットの変更があっても続行する
#
# 出力: dist/release-<version>-<build>/
#   PhotoMCPApp.app                        署名済み（公証時はステープル済み）
#   PhotoMCPApp-<version>-<build>.zip      配布用（公証時のみ。ステープル後に作り直したもの）
#
# 前提:
#   - Developer ID Application 証明書がキーチェーンにある（IDENTITYで上書き可）
#   - notarytool の認証情報がキーチェーンプロファイル "AC_PASSWORD" で登録済み（NOTARY_PROFILEで上書き可）
#   - 公証は数分かかる。Claudeのシェルツールから実行する場合はタイムアウトするので nohup で回すこと
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

VERSION="${1:-}"; BUILD="${2:-}"
[[ -n "$VERSION" && -n "$BUILD" ]] || usage
shift 2
NOTARIZE=1; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --force) FORCE=1 ;;
    *) echo "不明なオプション: $arg" >&2; usage ;;
  esac
done
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "build は整数で指定してください: $BUILD" >&2; exit 1; }

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${IDENTITY:-Developer ID Application: Makoto Otsuka (J62DX722EL)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
BUNDLE_ID="com.makoto.PhotoMCP.app"
ENT="$PROJ/PhotoMCPApp/PhotoMCPApp.entitlements"
PLIST_TEMPLATE="$PROJ/PhotoMCPApp/Info.plist"
PRODUCTS="$PROJ/.build/out/Products/Release"
OUT="$PROJ/dist/release-$VERSION-$BUILD"
APP="$OUT/PhotoMCPApp.app"
ZIP_NAME="PhotoMCPApp-$VERSION-$BUILD.zip"

step() { printf '\n==> %s\n' "$*"; }
die()  { echo "エラー: $*" >&2; exit 1; }

# --- 0. 事前チェック ---------------------------------------------------------
step "事前チェック"
cd "$PROJ"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
COMMIT="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  if [[ $FORCE -eq 1 ]]; then
    echo "警告: 未コミットの変更があります（--force で続行）"
  else
    die "未コミットの変更があります。コミットするか --force を付けてください"
  fi
fi
[[ "$BRANCH" == "master" ]] || echo "警告: master 以外のブランチです（${BRANCH}）"
[[ -e "$OUT" ]] && die "出力先が既にあります: ${OUT}（build番号を上げるか、中身を確認して手で退避してください）"
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || die "署名証明書が見つかりません: $IDENTITY"
echo "version=$VERSION build=$BUILD branch=$BRANCH commit=$COMMIT notarize=$NOTARIZE"

# --- 1. ビルド ---------------------------------------------------------------
step "ビルド（release）"
swift build -c release --product PhotoMCPApp
swift build -c release --product MCPServer

# --- 2. .app 組み立て ---------------------------------------------------------
step ".app 組み立て: $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/PhotoMCPApp" "$APP/Contents/MacOS/PhotoMCPApp"
cp "$PRODUCTS/MCPServer" "$APP/Contents/Resources/MCPServer"
ditto "$PRODUCTS/PhotoMCP_PhotoMCPApp.bundle" "$APP/Contents/Resources/PhotoMCP_PhotoMCPApp.bundle"
cp "$PROJ/PhotoMCPApp/Resources/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# ライセンス表記（2026-09-29追加）: 本体のLICENSEと、同梱依存パッケージのライセンス文・NOTICE。
# 配布zipは.appを固めたものなので、.app内に入れればzipにも含まれる。
# THIRD_PARTY_LICENSES.txt が依存の現状とずれていたら止める（依存更新時の再生成漏れ防止）
LIC_CHECK="$(mktemp)"
"$PROJ/scripts/gen-third-party-licenses.sh" "$LIC_CHECK" >/dev/null
cmp -s "$LIC_CHECK" "$PROJ/THIRD_PARTY_LICENSES.txt" \
  || { rm -f "$LIC_CHECK"; die "THIRD_PARTY_LICENSES.txt が古いです。scripts/gen-third-party-licenses.sh を実行してコミットしてください"; }
rm -f "$LIC_CHECK"
cp "$PROJ/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$PROJ/THIRD_PARTY_LICENSES.txt" "$APP/Contents/Resources/THIRD_PARTY_LICENSES.txt"
# SMAppService で登録する LaunchAgent の plist（2026-09-28追加。AgentRegistration.swift 参照）
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$PROJ/Resources/LaunchAgents/com.makoto.photomcp.agent.plist" "$APP/Contents/Library/LaunchAgents/"
plutil -lint "$APP/Contents/Library/LaunchAgents/com.makoto.photomcp.agent.plist"

# Info.plist: リポジトリのテンプレート（コメント付き・部分的）を元に、バンドル必須キーを補完する
PLIST="$APP/Contents/Info.plist"
cp "$PLIST_TEMPLATE" "$PLIST"
plutil -convert xml1 "$PLIST"   # コメントを除去して正規化
pb_set() { # key type value
  /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}
pb_set CFBundleExecutable string PhotoMCPApp
pb_set CFBundleIdentifier string "$BUNDLE_ID"
pb_set CFBundleName string PhotoMCPApp
pb_set CFBundlePackageType string APPL
pb_set CFBundleShortVersionString string "$VERSION"
pb_set CFBundleVersion string "$BUILD"
plutil -lint "$PLIST"
for key in NSPhotoLibraryUsageDescription NSAppleEventsUsageDescription LSUIElement CFBundleIconFile; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 || die "Info.plist に $key がありません"
done

# --- 3. 署名 -----------------------------------------------------------------
step "署名（同梱MCPServer → .app の順）"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/MCPServer"
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY" "$APP"

step "署名の検証"
codesign --verify --deep --strict -vv "$APP"
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
for key in com.apple.security.personal-information.photos-library com.apple.security.automation.apple-events; do
  grep -q "$key" <<<"$ENTS" || die "entitlement が付いていません: $key"
done
echo "entitlements OK"

if [[ $NOTARIZE -eq 0 ]]; then
  step "--no-notarize のため、ここで終了します（公証・ステープルなし。配布には使わないこと）"
  echo "出力: $APP"
  exit 0
fi

# --- 4. 公証 -----------------------------------------------------------------
step "公証に提出（数分かかります）"
SUBMIT_ZIP="$OUT/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
SUBMIT_LOG="$OUT/notarize-submit.json"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$SUBMIT_LOG"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMIT_LOG" 2>/dev/null || true)"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$SUBMIT_LOG" 2>/dev/null || true)"
echo "status=$STATUS id=$SUBMISSION_ID"
if [[ "$STATUS" != "Accepted" ]]; then
  [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" "$OUT/notarize-log.json" || true
  die "公証が通りませんでした（status=${STATUS}）。詳細: $OUT/notarize-log.json"
fi
rm -f "$SUBMIT_ZIP"

# --- 5. ステープル・最終確認 ---------------------------------------------------
step "ステープル"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

# --- 6. 配布用zip ------------------------------------------------------------
step "配布用zip（ステープル済みの.appを固め直す）"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP_NAME"
shasum -a 256 "$OUT/$ZIP_NAME" | tee "$OUT/$ZIP_NAME.sha256"

step "完了"
echo "出力: $OUT"
echo "  $APP"
echo "  $OUT/$ZIP_NAME"
echo "commit=$COMMIT"
