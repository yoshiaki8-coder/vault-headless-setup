# vault-headless-setup

Obsidian Headless（Obsidian 社のコマンド版の Sync）を、Google Cloud の小さな VM（e2-micro）に入れるためのスクリプト。

写し・編集禁止。正本は非公開のリポ（my-obsidian-vault の `90_Automation（自動化スクリプト）/cloud/headless/`）にあり、ここには鍵を含まない4本だけを同じ中身で置いている。

## 流し方

Google Cloud Shell（https://shell.cloud.google.com/?show=terminal ）に1行貼る。`<コミット>` はこのリポの40桁のコミット。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット>
```

コミットで固定した URL から取るので、あとからこのリポを変えても、流す中身は変わらない。

## 何をするか

| ファイル | どこで | 何を |
|---|---|---|
| `cloudshell.sh` | Cloud Shell | プロジェクトと請求先を整え、予算アラートを作り、VM（e2-micro・us-west1・標準ディスク 30GB）を作って、SSH で `setup.sh` を流す |
| `setup.sh` | VM | Node.js と obsidian-headless（版を固定）を入れ、deploy key を機械の上で作り、Obsidian にログインして Sync の写しを読むだけで取り、systemd に常駐と15分おきの突き合わせを入れる |
| `run_shadow.sh` | VM（15分おき） | 突き合わせの結果を、非公開リポの結果だけの枝へ上げる |
| `shadow_compare.py` | VM（15分おき） | Sync の写しと GitHub の main を、パスと中身の id で突き合わせる |

## 鍵について

このリポに鍵・パスワード・トークンは入っていない。Obsidian のログインと暗号化のパスワードは、`setup.sh` の途中で本人が VM の画面に打ち、ob が VM の上に保存する。GitHub への deploy key は VM の上で作り、公開鍵だけを本人がリポの設定に登録する。
