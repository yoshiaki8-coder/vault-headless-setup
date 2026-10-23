#!/bin/bash
# 常時機（Google Cloud の e2-micro・Debian 12）に Obsidian Headless の影運転を入れる。1回だけ流す。
#
# 公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル
# （my-obsidian-vault の 90_Automation（自動化スクリプト）/cloud/headless/setup.sh）。
# 設計は docs/Obsidian_Headless_git橋_設計_2026-10-19.md。ふつうは cloudshell.sh が VM を作ってから、
# SSH でこれを流す。手で流すときは  bash setup.sh <公開リポのコミット40桁>
#
# このスクリプトに鍵は入っていない。鍵とパスワードは途中で本人がこの画面に打つか、機械の上で作る:
#   - Obsidian のログイン（メール・パスワード・2段階）と暗号化のパスワード → ob が機械の上に保存
#   - GitHub への deploy key → 機械の上で作る。公開鍵だけを GitHub のリポ設定に登録してもらう
#
# 入れるもの: git・Node.js 22（版と sha256 を固定）・obsidian-headless（版を固定）・2GB のスワップ・
# OS の自動更新・専用ユーザー vaultsync・systemd の常駐（ob sync --continuous・pull-only）と
# 15分おきの突き合わせ（run_shadow.sh）。影運転のあいだは main にも Sync にも書かない。

set -euo pipefail

REF="${1:?公開リポのコミット（40桁）を渡してください}"
RAW="https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/$REF"
NODE_VERSION=22.23.3
NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
OB_VERSION=0.0.14
SVC_USER=vaultsync
SVC_HOME="/home/$SVC_USER"
REPO_SSH="git@github.com:yoshiaki8-coder/my-obsidian-vault.git"
DEPLOY_KEY_PAGE="https://github.com/yoshiaki8-coder/my-obsidian-vault/settings/keys/new"
SYNC_VAULT="${SYNC_VAULT:-yoshi88_main}"
DEVICE_NAME="${DEVICE_NAME:-headless-gcp}"
FILE_TYPES="image,audio,video,pdf,unsupported"

step() { printf '\n【%s】%s\n' "$1" "$2"; }
as_svc() { sudo -u "$SVC_USER" -H "$@"; }

step 1/9 "OS の部品と自動更新"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q git curl xz-utils python3 build-essential unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null

step 2/9 "スワップ 2GB（メモリが1GBしかないため）"
if ! swapon --show | grep -q /swapfile; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

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

step 6/9 "GitHub への deploy key（この機械の上で作る）"
if [ ! -f "$SVC_HOME/.ssh/vault_deploy" ]; then
  as_svc ssh-keygen -q -t ed25519 -N "" -C "$DEVICE_NAME vault deploy key" -f "$SVC_HOME/.ssh/vault_deploy"
fi
# GitHub のホスト鍵は HTTPS の api.github.com/meta から取る（初回接続で知らない鍵を信じない）
curl -fsSL https://api.github.com/meta \
  | python3 -c 'import json,sys; [print("github.com", k) for k in json.load(sys.stdin)["ssh_keys"]]' \
  | as_svc tee "$SVC_HOME/.ssh/known_hosts" >/dev/null
printf 'Host github.com\n  IdentityFile ~/.ssh/vault_deploy\n  IdentitiesOnly yes\n' \
  | as_svc tee "$SVC_HOME/.ssh/config" >/dev/null
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
until key_ok; do
  echo
  echo "次の公開鍵を GitHub に登録してください（鍵の中身は公開してよいものです）:"
  echo
  cat "$SVC_HOME/.ssh/vault_deploy.pub"
  echo
  echo "  1. このページを開く: $DEPLOY_KEY_PAGE"
  echo "  2. Title は何でもよい。Key に上の1行を貼り、「Allow write access」にチェックを入れて Add key"
  echo "  3. 登録したら、ここで Enter"
  read -r _
done
echo "deploy key で読み書きできました。"

step 7/9 "Vault の目録だけを取る（中身は落とさない clone）"
if [ ! -d "$SVC_HOME/vault-git/.git" ]; then
  as_svc git clone -q --filter=blob:none --no-checkout --single-branch --branch main "$REPO_SSH" "$SVC_HOME/vault-git"
fi

step 8/9 "Obsidian にログインし、Sync の写しを取る（読むだけ・pull-only）"
echo "Obsidian のメール・パスワード・2段階認証のコードを聞かれます。この画面に直接打ってください。"
as_svc ob login
as_svc ob sync-list-remote
echo "結び付ける Sync の Vault: $SYNC_VAULT（違うときは Ctrl+C で止めて SYNC_VAULT=名前 を付けて流し直す）"
# 結び付けた印は Sync の写しの外に置く（写しの中に置くと、切り替え後に Sync へ上がってしまう）
LINKED="$SVC_HOME/.local/state/headless/linked"
if [ ! -f "$LINKED" ]; then
  echo "エンドツーエンド暗号化の Vault なら、暗号化のパスワードを聞かれます。"
  as_svc ob sync-setup --vault "$SYNC_VAULT" --path "$SVC_HOME/vault-sync" --device-name "$DEVICE_NAME"
  as_svc mkdir -p "$(dirname "$LINKED")"
  as_svc touch "$LINKED"
fi
as_svc ob sync-config --path "$SVC_HOME/vault-sync" --mode pull-only --configs "" --file-types "$FILE_TYPES"
echo "初めの写しを取っています（2GB ほど・数分〜数十分）。"
as_svc ob sync --path "$SVC_HOME/vault-sync"

step 9/9 "常駐と15分おきの突き合わせ"
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
sudo systemctl enable --now vault-headless-sync.service vault-headless-shadow.timer
sudo systemctl start vault-headless-shadow.service
cat "$SVC_HOME/shadow-report/report.md"
echo
echo "終わりました。突き合わせの結果は15分おきに my-obsidian-vault の headless-shadow ブランチへ上がります。"
