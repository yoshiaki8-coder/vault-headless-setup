#!/bin/bash
# 常時機の影運転: 15分おき（systemd の vault-headless-shadow.timer）に Sync の写しと main を突き合わせ、
# 結果を my-obsidian-vault の headless-shadow ブランチ（結果のファイルだけの枝）へ上げる。main には書かない。
#
# 公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル。
# 上げるのは結果が変わったときと、変わらなくても6時間たったとき（止まっていないことの印）。
# headless-shadow の書き手はこの常時機だけ。

set -euo pipefail

H="${HEADLESS_HOME:-$HOME}"
REPO="${HEADLESS_REPO:-git@github.com:yoshiaki8-coder/my-obsidian-vault.git}"
OUT="$H/shadow-report"
STATE_DIR="$H/.local/state/headless"
HEARTBEAT_SECONDS=$((6 * 3600))
mkdir -p "$STATE_DIR" "$OUT"

python3 "$H/headless/shadow_compare.py" \
  --sync "$H/vault-sync" --git "$H/vault-git" \
  --state "$STATE_DIR/state.json" --out "$OUT"

cd "$OUT"
if [ ! -d .git ]; then
  git init -q -b headless-shadow
  git remote add origin "$REPO"
  if git fetch -q origin headless-shadow 2>/dev/null; then
    git reset -q --soft FETCH_HEAD
  fi
fi

# checked_at だけが変わった回は「変わっていない」と数える
changed=$(python3 - <<'EOF'
import json, subprocess
try:
    old = json.loads(subprocess.run(["git", "show", "HEAD:report.json"], capture_output=True, text=True, check=True).stdout)
except Exception:
    print("yes"); raise SystemExit
new = json.load(open("report.json", encoding="utf-8"))
for d in (old, new):
    d.pop("checked_at", None)
print("yes" if old != new else "no")
EOF
)
last=$(git log -1 --format=%ct 2>/dev/null || echo 0)
now=$(date +%s)
if [ "$changed" = "no" ] && [ $((now - last)) -lt "$HEARTBEAT_SECONDS" ]; then
  exit 0
fi

git add report.json report.md
git -c user.name="yoshi88-headless" -c user.email="yoshi88-headless@users.noreply.github.com" \
  commit -q --allow-empty -m "headless: 影運転の結果 $(date -u '+%Y-%m-%d %H:%M') UTC [skip ci]"
git push -q origin HEAD:headless-shadow
