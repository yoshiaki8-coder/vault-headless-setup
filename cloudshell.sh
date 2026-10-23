#!/bin/bash
# Google Cloud Shell で1回流す: 常時機（e2-micro・無料枠）を作り、SSH で setup.sh を段階ごとに流す。
# 人の手が要るのは2か所だけ: GitHub の承認（画面に出る8文字を github.com/login/device に入れる）と、
# Obsidian のログイン（機械の画面に直接打つ）。初めの写しは機械が裏で取るので、終わったら閉じてよい。
#
# 公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル
# （my-obsidian-vault の 90_Automation（自動化スクリプト）/cloud/headless/cloudshell.sh）。
# 流し方（Cloud Shell に1行貼る。<コミット> は公開リポの40桁）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット>
#
# 無料枠に収めるための形: e2-micro 1台・us-west1・標準の永続ディスク 30GB・Spot にしない。
# 外部 IPv4 は Obsidian Sync と GitHub へ出るのに要る（エフェメラル）。料金が出ないかは
# 請求の画面で確かめる。見張りとして、使えれば少額の予算アラートも作る。
#
# GitHub の deploy key は、機械の上で作った公開鍵を、このスクリプトが GitHub CLI（版と sha256 を固定）で
# リポに登録する。GitHub CLI のログインは使い捨ての設定フォルダに置き、登録が済んだら消す。

set -euo pipefail

REF="${1:?公開リポのコミット（40桁）を渡してください}"
# コミットは40桁の16進だけ受け付ける（下で機械の上のコマンドと URL に埋め込むため）
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "コミットは40桁の16進で渡してください: $REF" >&2; exit 1; }
RAW="https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/$REF"
NAME="${NAME:-vault-headless}"
ZONE="${ZONE:-us-west1-b}"
VAULT_REPO="yoshiaki8-coder/my-obsidian-vault"
GH_VERSION=2.89.0
GH_SHA256=d0422caade520530e76c1c558da47daebaa8e1203d6b7ff10ad7d6faba3490d8

project="$(gcloud config get-value project 2>/dev/null || true)"
if [ -z "$project" ] || [ "$project" = "(unset)" ]; then
  project="$(gcloud projects list --format='value(projectId)' --limit=1)"
  if [ -z "$project" ]; then
    project="vault-headless-$(date +%y%m%d%H%M)"
    gcloud projects create "$project" --name="vault-headless"
  fi
  gcloud config set project "$project"
fi
echo "プロジェクト: $project"

billing="$(gcloud billing accounts list --filter=open=true --format='value(name)' --limit=1)"
if [ -z "$billing" ]; then
  echo "請求先アカウントがまだありません。https://console.cloud.google.com/billing で作ってから流し直してください。"
  exit 1
fi
if [ "$(gcloud billing projects describe "$project" --format='value(billingEnabled)')" != "True" ]; then
  gcloud billing projects link "$project" --billing-account="$billing"
fi

echo "Compute Engine を使えるようにしています（初回は1〜2分）。"
gcloud services enable compute.googleapis.com

if gcloud services enable billingbudgets.googleapis.com >/dev/null 2>&1 \
   && ! gcloud billing budgets list --billing-account="$billing" --format='value(displayName)' 2>/dev/null \
        | grep -qxF "vault-headless の見張り"; then
  gcloud billing budgets create --billing-account="$billing" --display-name="vault-headless の見張り" \
    --budget-amount=100JPY --threshold-rule=percent=0.5 --threshold-rule=percent=1.0 >/dev/null 2>&1 \
    && echo "予算アラート（100円）を作りました。超えそうになるとメールが来ます。" \
    || echo "予算アラートは作れませんでした（請求の画面から作れます）。先へ進みます。"
fi

if ! gcloud compute instances describe "$NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$NAME" --zone "$ZONE" \
    --machine-type e2-micro --provisioning-model=STANDARD \
    --image-family debian-12 --image-project debian-cloud \
    --boot-disk-size 30GB --boot-disk-type pd-standard
fi

echo "機械が SSH を受け付けるまで待っています。"
for _ in $(seq 1 30); do
  if gcloud compute ssh "$NAME" --zone "$ZONE" --quiet --command true >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

remote() { gcloud compute ssh "$NAME" --zone "$ZONE" --quiet -- "$@"; }

echo "機械に部品を入れています（5分ほど・人の手は要りません）。"
remote "curl -fsSLo ~/vault-headless-setup.sh $RAW/setup.sh && bash ~/vault-headless-setup.sh $REF prepare"

if ! remote "bash ~/vault-headless-setup.sh $REF keyok" >/dev/null 2>&1; then
  pub="$(remote "bash ~/vault-headless-setup.sh $REF pubkey" | tr -d '\r')"
  [[ "$pub" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || { echo "機械の公開鍵が読めませんでした: $pub" >&2; exit 1; }

  gh_bin="$(command -v gh || true)"
  if [ -z "$gh_bin" ]; then
    curl -fsSLo /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v$GH_VERSION/gh_${GH_VERSION}_linux_amd64.tar.gz"
    echo "$GH_SHA256  /tmp/gh.tgz" | sha256sum -c --quiet
    mkdir -p "$HOME/.local/share" && tar -xzf /tmp/gh.tgz -C "$HOME/.local/share"
    gh_bin="$HOME/.local/share/gh_${GH_VERSION}_linux_amd64/bin/gh"
  fi
  # ふだんの gh のログインに触らないよう、使い捨ての設定フォルダで1回だけログインする
  export GH_CONFIG_DIR="$(mktemp -d)"
  trap 'rm -rf "$GH_CONFIG_DIR"' EXIT
  unset GH_TOKEN GITHUB_TOKEN
  echo
  echo "========================================"
  echo "GitHub の承認をお願いします。"
  echo "  1. https://github.com/login/device を開く"
  echo "  2. すぐ下に出る8文字（XXXX-XXXX）を入れて Continue → Authorize"
  echo "========================================"
  BROWSER=echo "$gh_bin" auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web --scopes repo </dev/null
  out="$("$gh_bin" api -X POST "repos/$VAULT_REPO/keys" -f title="headless-gcp（常時機）" -f key="$pub" -F read_only=false 2>&1)" \
    || grep -q "key is already in use" <<<"$out" \
    || { echo "deploy key を登録できませんでした: $out" >&2; exit 1; }
  "$gh_bin" auth logout --hostname github.com </dev/null >/dev/null 2>&1 || true
  rm -rf "$GH_CONFIG_DIR"
  echo "deploy key を GitHub に登録しました（GitHub CLI のログインは消しました）。"
fi

echo
echo "最後に Obsidian にログインします。"
remote -t "bash ~/vault-headless-setup.sh $REF finish"
