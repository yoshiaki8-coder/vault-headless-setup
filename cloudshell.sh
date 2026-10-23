#!/bin/bash
# Google Cloud Shell で1回流す: 常時機（e2-micro・無料枠）を作り、SSH で setup.sh を流す。
#
# 公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル
# （my-obsidian-vault の 90_Automation（自動化スクリプト）/cloud/headless/cloudshell.sh）。
# 流し方（Cloud Shell に1行貼る。<コミット> は公開リポの40桁）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット>
#
# 無料枠に収めるための形: e2-micro 1台・us-west1・標準の永続ディスク 30GB・Spot にしない。
# 外部 IPv4 は Obsidian Sync と GitHub へ出るのに要る（エフェメラル）。料金が出ないかは
# 請求の画面で確かめる。見張りとして、使えれば少額の予算アラートも作る。

set -euo pipefail

REF="${1:?公開リポのコミット（40桁）を渡してください}"
RAW="https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/$REF"
NAME="${NAME:-vault-headless}"
ZONE="${ZONE:-us-west1-b}"

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

if gcloud services enable billingbudgets.googleapis.com >/dev/null 2>&1; then
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

gcloud compute ssh "$NAME" --zone "$ZONE" --quiet -- -t \
  "curl -fsSLo /tmp/setup.sh $RAW/setup.sh && bash /tmp/setup.sh $REF"
