# vault-headless-setup

Obsidian Headless（Obsidian 社のコマンド版の Sync）を、Google Cloud の小さな VM（e2-micro）に入れるためのスクリプト。

写し・編集禁止。正本は非公開のリポ（my-obsidian-vault の `90_Automation（自動化スクリプト）/cloud/headless/`）にあり、ここには鍵を含まない5本だけを同じ中身で置いている。

## 流し方

Google Cloud Shell（https://shell.cloud.google.com/?show=terminal ）に1行貼る。`<コミット>` はこのリポの40桁のコミット。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット>
```

様子を見る・止まった初めの写しを動かし直すだけなら、最後に `doctor` を付ける（ログインは要らない）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット> doctor
```

議事録の周回（PLAUD の取り込みと議事録づくり・10分おき）を入れるなら、最後に `minutes` を付ける（ログインは要らない）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット> minutes
```

一方通行の橋（非公開リポの main で変わった Markdown を Obsidian Sync へ流す）を始めるなら、最後に `bridge` を付ける（ログインは要らない）。Sync の写しを「読むだけ」から「書ける」に替える。流すのは議事録の周回の終わりに回る非公開リポ側のスクリプトで、Sync で直されたものには触らない。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yoshiaki8-coder/vault-headless-setup/<コミット>/cloudshell.sh) <コミット> bridge
```

コミットで固定した URL から取るので、あとからこのリポを変えても、流す中身は変わらない。

## 何をするか

| ファイル | どこで | 何を |
|---|---|---|
| `cloudshell.sh` | Cloud Shell | プロジェクトと請求先を整え、予算アラートを作り、VM（e2-micro・us-west1・標準ディスク 30GB）を作って、SSH で `setup.sh` を段階ごとに流す。VM が作った deploy key の公開鍵を、GitHub CLI の使い捨てのログインでリポに登録する |
| `setup.sh` | VM | Node.js と obsidian-headless（版を固定）を入れ、deploy key を機械の上で作り、Obsidian にログインして Sync の写しに読むだけで結び付ける。初めの写しは裏で取り、済んだら systemd に常駐と15分おきの突き合わせを入れる。`minutes` の段は、Python（版を固定）・age・PLAUD の CLI（版を固定）と、鍵の受け取り口（age の鍵を機械の上で作る）と、10分おきの議事録の周回を入れる。周回の中身は非公開リポの main から読む |
| `run_shadow.sh` | VM（15分おき） | 突き合わせの結果を、非公開リポの結果だけの枝へ上げる |
| `shadow_compare.py` | VM（15分おき） | Sync の写しと GitHub の main を、パスと中身の id で突き合わせる |
| `status_report.sh` | VM（30分おき） | 機械の様子（常駐の状態・写しの大きさ・記録の末尾・議事録の周回と、置いてある鍵の名前）を、非公開リポの様子だけの枝へ上げる |

## 鍵について

このリポに鍵・パスワード・トークンは入っていない。Obsidian のログインと暗号化のパスワードは、`setup.sh` の途中で本人が VM の画面に打ち、ob が VM の上に保存する。GitHub への deploy key は VM の上で作り（秘密鍵は VM から出ない）、公開鍵だけを `cloudshell.sh` が登録する。そのときの GitHub CLI のログインは、本人が github.com/login/device に8文字のコードを入れて承認し、使い捨ての設定フォルダに置いて、登録が済んだら消す。

議事録の周回が使う鍵（Gemini・Slack・Google カレンダー・PLAUD）は、本人の Mac が VM の age の公開鍵で包んで送り、VM の秘密の鍵でしか開かない。このリポにも画面にも出ない。
