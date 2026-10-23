#!/usr/bin/env python3
"""当 git 传输通道不可用时，用 GitHub Git Data API 推送当前 HEAD。

适用场景：本机代理到 github.com 的 HTTPS/CONNECT 偶发 502 或 HTTP2 framing 错误，
但 api.github.com 仍可访问（`gh api rate_limit` 能返回即说明可用）。

做法：把 `git ls-files` 列出的全部文件上传为 blob，以远端 main 的 tree 为基准
拼出一棵新树，再创建 commit 并移动 ref。幂等——内容与远端一致时不会产生空提交。

用法：
    python tools/push_via_api.py                       # 用最近一次提交的信息
    python tools/push_via_api.py "提交说明"
    python tools/push_via_api.py --repo owner/repo "说明"
"""
import argparse
import base64
import json
import subprocess
import sys


def sh(args):
    p = subprocess.run(args, capture_output=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr.decode('utf-8', 'replace'))
        raise SystemExit('命令失败：%s' % ' '.join(args))
    return p.stdout


def gh(path, body=None, method=None):
    args = ['gh', 'api', path]
    if method:
        args += ['--method', method]
    data = None
    if body is not None:
        args += ['--input', '-']
        data = json.dumps(body).encode('utf-8')
    p = subprocess.run(args, input=data, capture_output=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr.decode('utf-8', 'replace'))
        raise SystemExit('API 调用失败：%s' % path)
    txt = p.stdout.decode('utf-8', 'replace').strip()
    return json.loads(txt) if txt else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('message', nargs='?', help='提交说明，缺省用 HEAD 的提交信息')
    ap.add_argument('--repo', default='david88558855/Nimbo', help='owner/repo')
    ap.add_argument('--branch', default='main')
    args = ap.parse_args()

    repo = 'repos/%s' % args.repo

    dirty = sh(['git', 'status', '--porcelain']).decode('utf-8').strip()
    if dirty:
        raise SystemExit('工作区不干净，先 commit 再推送：\n' + dirty)

    message = args.message or sh(['git', 'log', '-1', '--pretty=%B']).decode('utf-8')

    remote = gh('%s/git/ref/heads/%s' % (repo, args.branch))['object']['sha']
    remote_tree_sha = gh('%s/git/commits/%s' % (repo, remote))['tree']['sha']
    remote_tree = gh('%s/git/trees/%s?recursive=1' % (repo, remote_tree_sha))
    remote_blobs = {e['path']: e['sha'] for e in remote_tree.get('tree', []) if e['type'] == 'blob'}

    files = sh(['git', 'ls-files']).decode('utf-8').split()
    print('远端 %s = %s' % (args.branch, remote[:10]))
    print('受控文件 %d 个' % len(files))

    entries = []
    same = 0
    for path in files:
        content = sh(['git', 'cat-file', 'blob', 'HEAD:%s' % path])
        blob = gh(
            '%s/git/blobs' % repo,
            {'content': base64.b64encode(content).decode('ascii'), 'encoding': 'base64'},
        )
        entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
        if remote_blobs.get(path) == blob['sha']:
            same += 1
        else:
            print('  *  %s' % path)

    if same == len(entries) and len(remote_blobs) == len(entries):
        print('内容与远端完全一致，无需提交')
        return

    tree = gh('%s/git/trees' % repo, {'tree': entries})
    commit = gh(
        '%s/git/commits' % repo,
        {'message': message, 'tree': tree['sha'], 'parents': [remote]},
    )
    gh('%s/git/refs/heads/%s' % (repo, args.branch), {'sha': commit['sha'], 'force': False}, 'PATCH')
    print('已推送 %s -> %s' % (args.branch, commit['sha']))
    print('注意：本地 HEAD 与远端不是同一个 SHA（内容一致），'
          'git 通道恢复后如需对齐请先 fetch 再 rebase/merge。')


if __name__ == '__main__':
    main()
