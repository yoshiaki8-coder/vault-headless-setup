#!/bin/bash
# 常時機（Google Cloud の e2-micro・Debian 12）に Obsidian Headless の影運転を入れる。1回だけ流す。
#
# 公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル
# （my-obsidian-vault の 90_Automation（自動化スクリプト）/cloud/headless/setup.sh）。
# 設計は docs/Obsidian_Headless_git橋_設計_2026-10-19.md。cloudshell.sh が VM を作ってから、SSH で
# 段階ごとに流す:
#   bash setup.sh <コミット> prepare … 部品を入れ、deploy key を機械の上で作る（人の手は要らない）
#   bash setup.sh <コミット> pubkey  … deploy key の公開鍵を出す（cloudshell.sh が GitHub に登録する）
#   bash setup.sh <コミット> keyok   … deploy key で読み書きできるかだけ見る（できれば 0）
#   bash setup.sh <コミット> finish  … Obsidian にログインし、常駐を入れる。初めの写しは裏で取る
#   bash setup.sh <コミット> doctor  … 様子を GitHub の headless-status ブランチへ上げる仕組みを入れ、
#                                      止まった初めの写しを動かし直す（ログインは要らない）
#   bash setup.sh <コミット> minutes … 議事録の周回（PLAUD の取り込みと議事録づくり・10分おき）を入れる。
#                                      書くのは旗 minutes が cloud のときだけ（ログインは要らない）
#   bash setup.sh <コミット> bridge  … 一方通行の橋（GitHub で変わった Markdown を Sync へ流す）のために、
#                                      Sync の写しを「読むだけ」から「書ける」に替える（ログインは要らない）
#
# このスクリプトに鍵は入っていない。鍵とパスワードは本人がこの画面に打つか、機械の上で作る:
#   - Obsidian のログイン（メール・パスワード・2段階）と暗号化のパスワード → ob が機械の上に保存
#   - GitHub への deploy key → 機械の上で作る。秘密鍵は機械から出ない
#
# 入れるもの: git・Node.js 22（版と sha256 を固定）・obsidian-headless（版を固定）・2GB のスワップ・
# OS の自動更新・専用ユーザー vaultsync・systemd の常駐（ob sync --continuous・pull-only）と
# 15分おきの突き合わせ（run_shadow.sh）と、30分おきに様子を上げる仕組み（status_report.sh）。
# 影運転のあいだは main にも Sync にも書かない。

set -euo pipefail

REF="${1:?公開リポのコミット（40桁）を渡してください}"
# コミットは40桁の16進だけ受け付ける（下で機械の上のコマンドと URL に埋め込むため）
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "コミットは40桁の16進で渡してください: $REF" >&2; exit 1; }
PHASE="${2:?段階（prepare・pubkey・keyok・finish・doctor）を渡してください}"
RAW="https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/$REF"
NODE_VERSION=22.23.3
NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
OB_VERSION=0.0.14
SVC_USER=vaultsync
SVC_HOME="/home/$SVC_USER"
REPO_SSH="git@github.com:yoshiaki8-coder/my-obsidian-vault.git"
SYNC_VAULT="${SYNC_VAULT:-yoshi88_main}"
DEVICE_NAME="${DEVICE_NAME:-headless-gcp}"
FILE_TYPES="image,audio,video,pdf,unsupported"
PLAUD_VERSION=0.3.15
# 議事録づくりの Python の部品（Debian 12 の Python 3.11 で、この版のテストが通るのを確かめた・2026-10-27）
MINUTES_PIP="google-genai==2.33.0 python-docx==1.2.0 pdfplumber==0.11.10 requests==2.34.2
  google-api-python-client==2.201.0 google-auth==2.62.0 google-auth-oauthlib==1.5.0 google-auth-httplib2==0.4.4"

step() { printf '\n【%s】%s\n' "$1" "$2"; }
as_svc() { sudo -u "$SVC_USER" -H "$@"; }

# 読めるか（ls-remote）と、書けるか（--dry-run の push。読むだけの鍵ならここで断られる）を見る
key_ok() {
  as_svc bash -c '
    set -e
    git ls-remote "$1" HEAD >/dev/null
    d=$(mktemp -d); cd "$d"; git init -q
    git -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe
    git push -q --dry-run "$1" HEAD:refs/heads/headless-shadow-probe
    cd /; rm -rf "$d"' _ "$REPO_SSH" >/dev/null 2>&1
}

# 様子を GitHub に上げる仕組み（root で30分おき）。初めの写しが終わる前から動かす。
# 上げ先は headless-status ブランチ（status.md 1枚）。入れるだけで、動かし始めるのは呼ぶ側
install_status() {
  curl -fsSL "$RAW/status_report.sh" | sudo tee /usr/local/sbin/vault-headless-status >/dev/null
  sudo chmod 755 /usr/local/sbin/vault-headless-status
  sudo tee /etc/systemd/system/vault-headless-status.service >/dev/null <<EOF
[Unit]
Description=常時機の様子を GitHub に上げる
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
TimeoutStartSec=5min
ExecStart=/bin/bash /usr/local/sbin/vault-headless-status
EOF
  sudo tee /etc/systemd/system/vault-headless-status.timer >/dev/null <<EOF
[Unit]
Description=30分おきに常時機の様子を上げる

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
}

# 議事録の周回（2026-10-27）。常時機で PLAUD の取り込みと議事録づくりを回し、結果を main へ上げる。
# 入れるだけで、書くのは旗 minutes が cloud のときだけ。鍵は Mac の「常時機へ議事録の鍵を送る.command」が
# この機械の age の公開鍵で包んで送り、周回が受け取る（鍵をこの画面に打ったり貼ったりはしない）
install_minutes() {
  step 1/4 "部品（Python の venv・age・PLAUD の CLI $PLAUD_VERSION）"
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-venv age
  sudo /opt/node/bin/npm install -g --no-fund --no-audit "@plaud-ai/cli@$PLAUD_VERSION"
  test -x /opt/node/bin/plaud

  step 2/4 "議事録づくりの Python（版を固定）"
  sudo test -x "$SVC_HOME/minutes-venv/bin/python" || as_svc python3 -m venv "$SVC_HOME/minutes-venv"
  # shellcheck disable=SC2086 # 版の並びをそのまま pip に渡す
  as_svc "$SVC_HOME/minutes-venv/bin/pip" install -q --disable-pip-version-check $MINUTES_PIP

  step 3/4 "鍵の受け取り口（age の鍵をこの機械の上で作る・秘密の鍵は機械から出ない）"
  as_svc install -d -m 700 "$SVC_HOME/.config/headless"
  # 有無は sudo で見る（vaultsync の家は流している人の権限では覗けない）
  if ! sudo test -f "$SVC_HOME/.config/headless/age.key"; then
    as_svc age-keygen -o "$SVC_HOME/.config/headless/age.key" 2>/dev/null
  fi
  as_svc chmod 600 "$SVC_HOME/.config/headless/age.key"
  echo "受け取り口: $(sudo age-keygen -y "$SVC_HOME/.config/headless/age.key")"

  step 4/4 "10分おきの周回（初めの写しは周回が裏で取る）"
  sudo tee /usr/local/sbin/vault-minutes-cycle >/dev/null <<EOF
#!/bin/bash
# 議事録の周回の入口（vault-minutes.timer が $SVC_USER で10分おきに呼ぶ）。正本は setup.sh の minutes の段。
# 作業用の写しを main に合わせてから、写しの中の minutes_cycle.sh を流す（周回の中身は main が正本）。
set -uo pipefail
CO="\$HOME/minutes-git"
if [ ! -d "\$CO/.git" ]; then
  # 初めの写し（2GB ほど）。取り切ってから置き換えるので、途中で止まっても半端な写しは残らない
  rm -rf "\$CO.tmp"
  git clone -q --filter=blob:none --single-branch --branch main $REPO_SSH "\$CO.tmp" \\
    || { echo "写しを取れませんでした。次の周回でもう一度"; rm -rf "\$CO.tmp"; exit 75; }
  git -C "\$CO.tmp" config core.hooksPath .githooks
  mv "\$CO.tmp" "\$CO"
fi
git -C "\$CO" pull -q --rebase --autostash origin main \\
  || { git -C "\$CO" rebase --abort 2>/dev/null; echo "main に合わせられませんでした。次の周回でもう一度"; exit 75; }
cycle="\$CO/90_Automation（自動化スクリプト）/cloud/headless/minutes_cycle.sh"
[ -f "\$cycle" ] || { echo "main にまだ周回の中身（minutes_cycle.sh）がありません"; exit 0; }
exec /bin/bash "\$cycle"
EOF
  sudo chmod 755 /usr/local/sbin/vault-minutes-cycle
  sudo tee /etc/systemd/system/vault-minutes.service >/dev/null <<EOF
[Unit]
Description=常時機の議事録の周回（PLAUD の取り込みと議事録づくり）
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SVC_USER
Environment=HOME=$SVC_HOME
Environment=PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash /usr/local/sbin/vault-minutes-cycle
# 75 は「今は無理・次の周回でよい」。初めの写しと長い録音の議事録づくりに時間がかかる
SuccessExitStatus=75
TimeoutStartSec=90min
Nice=10
EOF
  sudo tee /etc/systemd/system/vault-minutes.timer >/dev/null <<EOF
[Unit]
Description=10分おきに議事録の周回を回す

[Timer]
OnBootSec=4min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now vault-minutes.timer
}

case "$PHASE" in
  pubkey) sudo cat "$SVC_HOME/.ssh/vault_deploy.pub"; exit 0 ;;
  keyok) key_ok; exit $? ;;
  prepare|finish|doctor|minutes|bridge) ;;
  *) echo "段階は prepare・pubkey・keyok・finish・doctor・minutes・bridge のどれか: $PHASE" >&2; exit 1 ;;
esac

# 一方通行の橋（2026-10-27）。本人は iPhone の Obsidian で読むだけなので、橋は GitHub → Sync の向きだけ。
# Sync に書くのは議事録の周回の終わりに回る git_to_sync.py だけで、運ぶのは main で変わった Markdown だけ
# （Sync で直されたものは触らない）。ここでは Sync の写しを「書ける」に替えて、常駐を入れ直すだけ。
# 運ぶ種類の設定（file-types）は替えない。常時機は Markdown 以外を自分で書き換えないので、上がることはない
if [ "$PHASE" = "bridge" ]; then
step 1/2 "Sync の写しを「書ける」に替える（GitHub で変わった Markdown だけを流す）"
sudo test -f "$SVC_HOME/.local/state/headless/linked" || { echo "Sync への結び付けがまだです。設定の1行を先に流してください。" >&2; exit 1; }
systemctl is-enabled --quiet vault-minutes.timer 2>/dev/null || { echo "議事録の周回がまだ入っていません。minutes の1行を先に流してください。" >&2; exit 1; }
as_svc ob sync-config --path "$SVC_HOME/vault-sync" --mode bidirectional
sudo systemctl restart vault-headless-sync.service
as_svc ob sync-status --path "$SVC_HOME/vault-sync" | grep -i "mode" || true

step 2/2 "様子を GitHub に上げる"
install_status
sudo env FORCE_PUSH=1 bash /usr/local/sbin/vault-headless-status \
  && echo "様子を my-obsidian-vault の headless-status ブランチへ上げました。" \
  || echo "様子を GitHub に上げられませんでした。下の画面をそのまま送ってください。"
echo
echo "終わりました。この画面は閉じてかまいません。"
echo "次の議事録の周回（10分以内）から、GitHub で変わった Markdown が Sync へ流れます。"
echo "止めるとき: 旗 git_to_sync を mac にする PR をマージする（流すのが止まる。Sync の写しは「書ける」のままでも、常時機は何も書き換えない）。"
exit 0
fi

if [ "$PHASE" = "minutes" ]; then
install_minutes
echo
install_status
sudo env FORCE_PUSH=1 bash /usr/local/sbin/vault-headless-status \
  && echo "様子（受け取り口の公開鍵を含む）を my-obsidian-vault の headless-status ブランチへ上げました。" \
  || echo "様子を GitHub に上げられませんでした。下の画面をそのまま送ってください。"
sudo systemctl enable --now vault-headless-status.timer
echo
echo "終わりました。この画面は閉じてかまいません。"
echo "初めの写し（2GB ほど）は周回が裏で取ります。旗 minutes が mac のあいだは、鍵の有無を見て休みます。"
exit 0
fi

if [ "$PHASE" = "doctor" ]; then

step 1/2 "様子を GitHub に上げる仕組み（30分おき）"
install_status
sudo env FORCE_PUSH=1 bash /usr/local/sbin/vault-headless-status \
  && echo "様子を my-obsidian-vault の headless-status ブランチへ上げました。" \
  || echo "様子を GitHub に上げられませんでした。下の画面をそのまま送ってください。"
sudo systemctl enable --now vault-headless-status.timer
echo
sudo cat "$SVC_HOME/status-report/status.md"

step 2/2 "止まっている初めの写しを動かし直す"
if systemctl is-enabled --quiet vault-headless-sync.service 2>/dev/null; then
  echo "初めの写しは済んでいます（常駐が入っています）。"
  systemctl is-active --quiet vault-headless-sync.service || sudo systemctl restart vault-headless-sync.service
elif [ -f /etc/systemd/system/vault-headless-first-sync.service ]; then
  state="$(systemctl show -p ActiveState --value vault-headless-first-sync.service)"
  if [ "$state" = "activating" ] || [ "$state" = "active" ]; then
    echo "初めの写しはまだ取っている途中です。そのまま待ちます。"
  else
    echo "初めの写しが止まっていた（$state）ので、動かし直します。"
    sudo systemctl enable vault-headless-first-sync.service
    sudo systemctl restart --no-block vault-headless-first-sync.service
  fi
else
  echo "初めの写しの仕組みがまだ入っていません。README の設定の1行を流してください。"
fi
echo
echo "終わりました。この画面は閉じてかまいません。様子はこれから30分おきに GitHub へ上がります。"
exit 0
fi

if [ "$PHASE" = "prepare" ]; then

step 1/9 "OS の部品と自動更新"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q git curl xz-utils python3 build-essential unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null

step 2/9 "スワップ 2GB（メモリが1GBしかないため）"
# 使っているかは /proc/swaps で見る（swapon は /usr/sbin にあり、普通のユーザーの PATH では見つからない。
# 見つからないまま「無い」と読むと、使用中の /swapfile を作り直そうとして止まる・2026-10-23 の2回目で実際に起きた）
if ! grep -q '^/swapfile ' /proc/swaps; then
  if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
  fi
  sudo swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null

step 3/9 "Node.js $NODE_VERSION"
if [ "$(/opt/node/bin/node --version 2>/dev/null)" != "v$NODE_VERSION" ]; then
  tarball="node-v$NODE_VERSION-linux-x64.tar.xz"
  curl -fsSLo "/tmp/$tarball" "https://nodejs.org/dist/v$NODE_VERSION/$tarball"
  echo "$NODE_SHA256  /tmp/$tarball" | sha256sum -c --quiet
  sudo tar -xJf "/tmp/$tarball" -C /opt
  sudo ln -sfn "/opt/node-v$NODE_VERSION-linux-x64" /opt/node
  rm -f "/tmp/$tarball"
fi
for bin in node npm npx; do sudo ln -sf "/opt/node/bin/$bin" "/usr/local/bin/$bin"; done

step 4/9 "obsidian-headless $OB_VERSION"
sudo /opt/node/bin/npm install -g --no-fund --no-audit "obsidian-headless@$OB_VERSION"
sudo ln -sf /opt/node/bin/ob /usr/local/bin/ob
ob --version >/dev/null

step 5/9 "専用ユーザー $SVC_USER と、突き合わせのスクリプト"
id "$SVC_USER" >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash "$SVC_USER"
as_svc mkdir -p "$SVC_HOME/headless" "$SVC_HOME/vault-sync" "$SVC_HOME/.ssh"
for f in shadow_compare.py run_shadow.sh; do
  curl -fsSL "$RAW/$f" | as_svc tee "$SVC_HOME/headless/$f" >/dev/null
done
as_svc chmod 700 "$SVC_HOME/.ssh"

step 6/9 "GitHub への deploy key（この機械の上で作る・秘密鍵は機械から出ない）"
# 有無は sudo で見る（~/.ssh は 700 で、流している人の権限では覗けない。覗けないまま「無い」と読むと
# 鍵を作り直そうとして上書きを聞かれ、GitHub への登録がやり直しになる・2026-10-23 と 10-24 に実際に起きた）
if ! sudo test -f "$SVC_HOME/.ssh/vault_deploy"; then
  as_svc ssh-keygen -q -t ed25519 -N "" -C "$DEVICE_NAME vault deploy key" -f "$SVC_HOME/.ssh/vault_deploy"
fi
# GitHub のホスト鍵は HTTPS の api.github.com/meta から取る（初回接続で知らない鍵を信じない）
curl -fsSL https://api.github.com/meta \
  | python3 -c 'import json,sys; [print("github.com", k) for k in json.load(sys.stdin)["ssh_keys"]]' \
  | as_svc tee "$SVC_HOME/.ssh/known_hosts" >/dev/null
printf 'Host github.com\n  IdentityFile ~/.ssh/vault_deploy\n  IdentitiesOnly yes\n' \
  | as_svc tee "$SVC_HOME/.ssh/config" >/dev/null
echo
echo "部品を入れ終わりました。"
exit 0
fi

# ここから finish
step 7/9 "deploy key で読み書きできるか（GitHub への登録を待つ）"
for _ in $(seq 1 60); do
  key_ok && break
  sleep 10
done
key_ok || { echo "deploy key で読み書きできません。GitHub のリポ設定 → Deploy keys を見てください。" >&2; exit 1; }
echo "読み書きできました。"

echo "Vault の目録だけを取ります（中身は落とさない clone）。"
if [ ! -d "$SVC_HOME/vault-git/.git" ]; then
  as_svc git clone -q --filter=blob:none --no-checkout --single-branch --branch main "$REPO_SSH" "$SVC_HOME/vault-git"
fi

step 8/9 "Obsidian にログインし、Sync の写しに結び付ける（読むだけ・pull-only）"
echo "Obsidian のメール・パスワード・2段階認証のコードを聞かれます。この画面に直接打ってください。"
as_svc ob login
# 結び付ける Sync の Vault を決める: SYNC_VAULT の名前があればそれ、Vault が1つだけならそれ、ほかは聞く
names=$(as_svc ob sync-list-remote --json 2>/dev/null | python3 -c '
import json, sys
def walk(x):
    if isinstance(x, dict):
        if isinstance(x.get("name"), str):
            yield x["name"]
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
try:
    print("\n".join(dict.fromkeys(walk(json.load(sys.stdin)))))
except ValueError:
    pass' || true)
if ! printf '%s\n' "$names" | grep -qxF "$SYNC_VAULT"; then
  if [ -n "$names" ] && [ "$(printf '%s\n' "$names" | wc -l)" -eq 1 ]; then
    SYNC_VAULT="$names"
  else
    listing="$(as_svc ob sync-list-remote 2>/dev/null || true)"
    printf '%s\n' "$listing"
    # 入れた名前は、Sync の一覧にあるものだけ受け付ける
    while :; do
      read -r -p "結び付ける Sync の Vault の名前を入れてください: " SYNC_VAULT
      if [ -n "$SYNC_VAULT" ] && { printf '%s\n' "$names" | grep -qxF -- "$SYNC_VAULT" \
           || { [ -z "$names" ] && grep -qF -- "$SYNC_VAULT" <<<"$listing"; }; }; then
        break
      fi
      echo "一覧にない名前です。上の一覧から、もう一度入れてください。"
    done
  fi
fi
echo "結び付ける Sync の Vault: $SYNC_VAULT"
# 結び付けた印は Sync の写しの外に置く（写しの中に置くと、切り替え後に Sync へ上がってしまう）
LINKED="$SVC_HOME/.local/state/headless/linked"
# 印の有無も sudo で見る（vaultsync の家は流している人の権限では覗けないことがある）
if ! sudo test -f "$LINKED"; then
  echo "エンドツーエンド暗号化の Vault なら、暗号化のパスワードを聞かれます。"
  echo "（Obsidian のアカウントのパスワードとは別。Sync の Vault を作ったときに決めたもの）"
  # 打ち間違えても最初から流し直さずに済むよう、3回まで打ち直せる（2026-10-26 本人が1回目で弾かれた）
  for try in 1 2 3; do
    if as_svc ob sync-setup --vault "$SYNC_VAULT" --path "$SVC_HOME/vault-sync" --device-name "$DEVICE_NAME"; then
      as_svc mkdir -p "$(dirname "$LINKED")"
      as_svc touch "$LINKED"
      break
    fi
    echo "結び付けられませんでした（暗号化のパスワードが違う、など）。もう一度打ってください（$try/3）。"
  done
  sudo test -f "$LINKED" || { echo "3回とも結び付けられませんでした。暗号化のパスワードを確かめてから、同じ1行を流し直してください。" >&2; exit 1; }
fi
as_svc ob sync-config --path "$SVC_HOME/vault-sync" --mode pull-only --configs "" --file-types "$FILE_TYPES"

step 9/9 "常駐と15分おきの突き合わせ（初めの写しは裏で取る）"
sudo tee /usr/local/sbin/vault-headless-first-sync >/dev/null <<EOF
#!/bin/bash
# 初めの写し（2GB ほど）を取り切ってから、常駐と15分おきの突き合わせを入れる。済んだら自分を外す。
set -euo pipefail
sudo -u $SVC_USER -H /usr/local/bin/ob sync --path $SVC_HOME/vault-sync
systemctl enable --now vault-headless-sync.service vault-headless-shadow.timer
systemctl disable vault-headless-first-sync.service
EOF
sudo chmod 755 /usr/local/sbin/vault-headless-first-sync
sudo tee /etc/systemd/system/vault-headless-first-sync.service >/dev/null <<EOF
[Unit]
Description=初めの写しを取り、常駐を入れる（1回だけ）
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vault-headless-first-sync
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/systemd/system/vault-headless-sync.service >/dev/null <<EOF
[Unit]
Description=Obsidian Headless の写し（影運転・pull-only）
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Environment=HOME=$SVC_HOME
ExecStart=/usr/local/bin/ob sync --continuous --path $SVC_HOME/vault-sync
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/systemd/system/vault-headless-shadow.service >/dev/null <<EOF
[Unit]
Description=Sync の写しと main の突き合わせ（影運転）

[Service]
Type=oneshot
User=$SVC_USER
Environment=HOME=$SVC_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash $SVC_HOME/headless/run_shadow.sh
EOF
sudo tee /etc/systemd/system/vault-headless-shadow.timer >/dev/null <<EOF
[Unit]
Description=15分おきに突き合わせる

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
install_status
sudo systemctl enable --now vault-headless-status.timer
if systemctl is-enabled --quiet vault-headless-sync.service 2>/dev/null; then
  sudo systemctl restart vault-headless-sync.service
else
  sudo systemctl enable vault-headless-first-sync.service
  sudo systemctl start --no-block vault-headless-first-sync.service
fi
echo
echo "終わりました。この画面は閉じてかまいません。"
echo "初めの写し（2GB ほど）は機械が裏で取り、済んだら15分おきの突き合わせが始まります。"
echo "結果は my-obsidian-vault の headless-shadow ブランチへ、様子は headless-status ブランチへ上がります。"
