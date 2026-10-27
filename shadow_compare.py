"""常時機（Obsidian Headless）の影運転: Sync の写しと GitHub の main を突き合わせる。

公開の写しあり（yoshiaki8-coder/vault-headless-setup）。写しは編集禁止・正本はこのファイル。
設計は docs/Obsidian_Headless_git橋_設計_2026-10-19.md。

読むだけ。Sync の写しにも main にも書かない（Sync の写しへ書くのは一方通行の橋 git_to_sync.py だけ）。
突き合わせの結果は --out に report.json と report.md を書くだけで、上げるのは run_shadow.sh。

比べ方:
- main は blob を落とさない clone（--filter=blob:none）の ls-tree で、パスごとの blob id を読む
- Sync の写しは、ファイルの中身から git と同じ blob id を計算する（大きさと更新時刻が前回と同じなら計算し直さない）
- パスは NFC にそろえる（Mac の git と Linux のファイル名で濁点の表し方が違うことがある）
- Sync の設定フォルダ（既定 .obsidian）は比べない。常時機は設定を同期しない設計

出すもの:
- 一致・中身の差・main にだけある・Sync にだけある、の数
- 差が続いている時間。24時間を超えた差は「いつもある差」（Sync に乗らない種類など）として
  フォルダと拡張子ごとにまとめ、それ未満は「遅れの差」として並べる
- 消えた差がどれだけ続いていたか（遅れの目安）。見回りは15分おきなので15分刻みの上限
- 中身の差は、どちらが新しいかの見立て（Sync のファイルの更新時刻と、main でそのパスを最後に変えたコミットの時刻）
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import statistics
import subprocess
import sys
import unicodedata
from collections import Counter
from pathlib import Path

STEADY_SECONDS = 24 * 3600
LIST_LIMIT = 50
RESOLVED_KEEP = 300
KINDS = ("differ", "only_git", "only_sync")
KIND_JA = {"differ": "中身の差", "only_git": "main にだけある", "only_sync": "Sync にだけある"}


def nfc(path: str) -> str:
    return unicodedata.normalize("NFC", path)


def blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def blob_id_of_file(path: str, size: int) -> str:
    """大きな動画でもメモリに載せきらないよう、少しずつ読む（常時機はメモリ1GB）。"""
    h = hashlib.sha1(b"blob %d\0" % size)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout


def read_git_tree(repo: Path, ref: str) -> tuple[dict[str, str], int]:
    """main のファイル（通常と実行可能）のパス→blob id。シンボリックリンクとサブモジュールは数だけ返す。"""
    out = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", "-z", "--full-tree", ref],
                         check=True, capture_output=True).stdout
    files: dict[str, str] = {}
    skipped = 0
    for entry in out.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, _type, sha = meta.decode().split(" ")
        if mode in ("100644", "100755"):
            files[nfc(path.decode("utf-8", "surrogateescape"))] = sha
        else:
            skipped += 1
    return files, skipped


def read_sync_copy(root: Path, config_dir: str, cache: dict) -> tuple[dict[str, str], dict[str, float]]:
    """Sync の写しのパス→blob id と、パス→更新時刻（秒）。cache は {パス: [大きさ, 更新時刻ns, blob id]}。"""
    files: dict[str, str] = {}
    mtimes: dict[str, float] = {}
    seen = set()
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            dirnames[:] = [d for d in dirnames if d != config_dir]
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            rel = nfc(os.path.relpath(full, root).replace(os.sep, "/"))
            st = os.stat(full)
            hit = cache.get(rel)
            if hit and hit[0] == st.st_size and hit[1] == st.st_mtime_ns:
                sha = hit[2]
            else:
                sha = blob_id_of_file(full, st.st_size)
                cache[rel] = [st.st_size, st.st_mtime_ns, sha]
            files[rel] = sha
            mtimes[rel] = st.st_mtime
            seen.add(rel)
    for gone in set(cache) - seen:
        del cache[gone]
    return files, mtimes


def compare(git_files: dict[str, str], sync_files: dict[str, str]) -> dict[str, list[str]]:
    both = git_files.keys() & sync_files.keys()
    return {
        "same": sorted(p for p in both if git_files[p] == sync_files[p]),
        "differ": sorted(p for p in both if git_files[p] != sync_files[p]),
        "only_git": sorted(git_files.keys() - sync_files.keys()),
        "only_sync": sorted(sync_files.keys() - git_files.keys()),
    }


def track(state: dict, result: dict[str, list[str]], now: float) -> list[dict]:
    """差ごとに見えはじめた時刻を覚え、消えた差はどれだけ続いたかを resolved に残す。今回消えた分を返す。"""
    opened = state.setdefault("open", {})
    current = {f"{k}:{p}" for k in KINDS for p in result[k]}
    resolved_now = []
    for key in sorted(set(opened) - current):
        kind, path = key.split(":", 1)
        resolved_now.append({"kind": kind, "path": path, "seconds": round(now - opened.pop(key))})
    for key in current:
        opened.setdefault(key, now)
    resolved = state.setdefault("resolved", [])
    resolved.extend(resolved_now)
    del resolved[:-RESOLVED_KEEP]
    return resolved_now


def group_key(path: str) -> str:
    top = path.split("/", 1)[0] if "/" in path else "（直下）"
    ext = os.path.splitext(path)[1].lower() or "（拡張子なし）"
    return f"{top} {ext}"


def newer_side(path: str, sync_mtime: float | None, last_commit: dict[str, int]) -> str:
    commit = last_commit.get(path)
    if sync_mtime is None or commit is None:
        return "不明"
    return "Sync が新しい" if sync_mtime > commit else "main が新しい"


def last_commit_times(repo: Path, ref: str, paths: list[str]) -> dict[str, int]:
    times = {}
    for path in paths:
        out = git(repo, "log", "-1", "--format=%ct", ref, "--", path).strip()
        if out:
            times[path] = int(out)
    return times


def build_report(result, state, now, git_head, skipped, sync_mtimes, last_commit, sync_status) -> dict:
    opened = state.get("open", {})
    steady: dict[str, Counter] = {k: Counter() for k in KINDS}
    transient: dict[str, list[dict]] = {k: [] for k in KINDS}
    for kind in KINDS:
        for path in result[kind]:
            age = now - opened.get(f"{kind}:{path}", now)
            if age >= STEADY_SECONDS:
                steady[kind][group_key(path)] += 1
            else:
                item = {"path": path, "minutes": round(age / 60)}
                if kind == "differ":
                    item["newer"] = newer_side(path, sync_mtimes.get(path), last_commit)
                transient[kind].append(item)
    lags = [r["seconds"] for r in state.get("resolved", [])]
    lag = {}
    if lags:
        ordered = sorted(lags)
        lag = {"count": len(ordered), "median_minutes": round(statistics.median(ordered) / 60),
               "p90_minutes": round(ordered[int(0.9 * (len(ordered) - 1))] / 60),
               "max_minutes": round(ordered[-1] / 60)}
    return {
        "checked_at": dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(timespec="seconds"),
        "git_head": git_head,
        "counts": {k: len(v) for k, v in result.items()},
        "git_skipped_links_or_submodules": skipped,
        "steady": {k: dict(steady[k].most_common()) for k in KINDS},
        "transient": {k: transient[k][:LIST_LIMIT] for k in KINDS},
        "transient_total": {k: len(transient[k]) for k in KINDS},
        "lag": lag,
        "sync_status": sync_status,
    }


def render_markdown(report: dict) -> str:
    c = report["counts"]
    lines = [
        "# 常時機の影運転（Sync の写しと main の突き合わせ）",
        "",
        f"見た時刻（UTC）: {report['checked_at']}　main: {report['git_head'][:7]}",
        "",
        f"一致 {c['same']}・中身の差 {c['differ']}・main にだけある {c['only_git']}・Sync にだけある {c['only_sync']}",
        "",
    ]
    lag = report["lag"]
    if lag:
        lines += [f"消えた差 {lag['count']}件の続いた時間: 中央 {lag['median_minutes']}分・"
                  f"9割 {lag['p90_minutes']}分以内・最長 {lag['max_minutes']}分（15分刻みの上限）", ""]
    for kind in KINDS:
        steady = report["steady"][kind]
        if steady:
            lines.append(f"## いつもある差（24時間以上）: {KIND_JA[kind]}")
            lines += [f"- {k}: {n}" for k, n in steady.items()]
            lines.append("")
    for kind in KINDS:
        items = report["transient"][kind]
        if items:
            lines.append(f"## 遅れの差（24時間未満）: {KIND_JA[kind]} {report['transient_total'][kind]}件")
            for item in items:
                extra = f"・{item['newer']}" if "newer" in item else ""
                lines.append(f"- {item['path']}（{item['minutes']}分{extra}）")
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def sync_status_of(sync_root: Path) -> dict:
    try:
        out = subprocess.run(["ob", "sync-status", "--path", str(sync_root), "--json"],
                             capture_output=True, text=True, timeout=60)
        return json.loads(out.stdout) if out.returncode == 0 else {"error": out.stderr.strip()[:300]}
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        return {"error": str(exc)[:300]}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sync", required=True, type=Path)
    ap.add_argument("--git", required=True, type=Path)
    ap.add_argument("--state", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--config-dir", default=".obsidian")
    ap.add_argument("--no-fetch", action="store_true")
    ap.add_argument("--no-sync-status", action="store_true")
    args = ap.parse_args(argv)

    if not args.no_fetch:
        git(args.git, "fetch", "--quiet", "--filter=blob:none", "origin", "main")
    state = json.loads(args.state.read_text(encoding="utf-8")) if args.state.exists() else {}
    git_head = git(args.git, "rev-parse", args.ref).strip()
    git_files, skipped = read_git_tree(args.git, args.ref)
    sync_files, sync_mtimes = read_sync_copy(args.sync, args.config_dir, state.setdefault("hash_cache", {}))
    result = compare(git_files, sync_files)
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    track(state, result, now)
    last_commit = last_commit_times(args.git, args.ref, result["differ"][:LIST_LIMIT])
    status = {} if args.no_sync_status else sync_status_of(args.sync)
    report = build_report(result, state, now, git_head, skipped, sync_mtimes, last_commit, status)

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    (args.out / "report.md").write_text(render_markdown(report), encoding="utf-8")
    tmp = args.state.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    tmp.replace(args.state)
    c = report["counts"]
    print(f"一致 {c['same']}・中身の差 {c['differ']}・main にだけ {c['only_git']}・Sync にだけ {c['only_sync']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
