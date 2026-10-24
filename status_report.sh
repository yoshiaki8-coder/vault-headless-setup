#!/bin/bash
# 常時機の様子を GitHub に上げる（30分おき・systemd の vault-headless-status.timer・root で動く）。
# 初めの写しが終わる前から動くので、人が Cloud Shell でスクリーンショットを撮らなくても、
# my-obsidian-vault の headless-status ブランチ（status.md 1枚だけの枝）で様子が読める。main には書かない。
#
# 公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル
# （my-obsidian-vault の 90_Automation（自動化スクリプト）/cloud/headless/status_report.sh）。
# 上げるのは常駐の状態が変わったときと、変わらなくても1時間たったとき。枝は毎回1コミットに作り直す
# （履歴を積まない）。headless-status の書き手はこの常時機だけ。

set -uo pipefail

SVC_USER="${SVC_USER:-vaultsync}"
SVC_HOME="/home/$SVC_USER"
REPO="${HEADLESS_REPO:-git@github.com:yoshiaki8-coder/my-obsidian-vault.git}"
WORK="$SVC_HOME/status-report"
STATE="$SVC_HOME/.local/state/headless/status_pushed"
UNITS="vault-headless-first-sync.service vault-headless-sync.service vault-headless-shadow.service vault-headless-shadow.timer vault-headless-status.timer"
HEARTBEAT_SECONDS=3600

as_svc() { sudo -u "$SVC_USER" -H "$@"; }

units() {
  for u in $UNITS; do
    printf '%s enabled=%s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null)" \
      "$(systemctl show -p ActiveState -p SubState -p Result -p NRestarts -p ExecMainStatus "$u" 2>/dev/null | tr '\n' ' ')"
  done
}

body() {
  echo "# 常時機の様子 $(date -u '+%Y-%m-%d %H:%M') UTC"
  echo
  echo "- 起動から: $(uptime -p)"
  echo "- メモリ: $(free -m | awk '/^Mem:/{print $3 "/" $2 " MB"}')・スワップ: $(free -m | awk '/^Swap:/{print $3 "/" $2 " MB"}')"
  echo "- ディスク: $(df -h "$SVC_HOME" | awk 'NR==2{print $3 "/" $2}')"
  echo "- Sync の写し: $(du -sh "$SVC_HOME/vault-sync" 2>/dev/null | cut -f1)・ファイル $(find "$SVC_HOME/vault-sync" -type f 2>/dev/null | wc -l) 個"
  echo "- Sync への結び付け: $([ -f "$SVC_HOME/.local/state/headless/linked" ] && echo 済み || echo まだ)"
  echo "- ob $(ob --version 2>/dev/null || echo 不明)・node $(node --version 2>/dev/null || echo 不明)"
  echo
  echo "## 常駐"
  echo
  echo '```'
  units
  echo '```'
  echo
  echo "## Sync の状態（ob sync-status）"
  echo
  echo '```'
  as_svc timeout 60 ob sync-status --path "$SVC_HOME/vault-sync" 2>&1 | tail -n 20
  echo '```'
  for u in vault-headless-first-sync vault-headless-sync vault-headless-shadow; do
    echo
    echo "## 記録の末尾: $u"
    echo
    echo '```'
    journalctl -u "$u" -n 25 --no-pager -o short-iso 2>&1 | cut -c1-300
    echo '```'
  done
  echo
  echo "## メモリ不足で落ちた跡（カーネル）"
  echo
  echo '```'
  journalctl -k --no-pager -o short-iso 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -n 10
  echo '```'
}

mkdir -p "$WORK" "$(dirname "$STATE")"
chown "$SVC_USER:$SVC_USER" "$WORK" "$(dirname "$STATE")"
body > "$WORK/status.md"
chown "$SVC_USER:$SVC_USER" "$WORK/status.md"

key="$(units | sha256sum | cut -c1-16)"
last_key=""; last_at=0
[ -f "$STATE" ] && read -r last_key last_at < "$STATE"
now=$(date +%s)
if [ "${FORCE_PUSH:-}" != 1 ] && [ "$key" = "$last_key" ] && [ $((now - last_at)) -lt "$HEARTBEAT_SECONDS" ]; then
  exit 0
fi

if as_svc bash -c '
  set -e
  cd "$1"
  rm -rf .git
  git init -q -b headless-status
  git add status.md
  git -c user.name=yoshi88-headless -c user.email=yoshi88-headless@users.noreply.github.com \
    commit -q -m "headless: 常時機の様子 $(date -u "+%Y-%m-%d %H:%M") UTC [skip ci]"
  git push -q -f "$2" HEAD:headless-status' _ "$WORK" "$REPO"; then
  echo "$key $now" > "$STATE"
  chown "$SVC_USER:$SVC_USER" "$STATE"
else
  echo "様子を GitHub に上げられませんでした（deploy key か回線）。" >&2
  exit 1
fi
