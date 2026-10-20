#!/usr/bin/env python3
"""Publish a verified, locally signed APK as a versioned GitHub Release.

Uses GITHUB_TOKEN or the existing Git credential helper. Never prints credentials.
Only signed APKs/checksums are uploaded; signing keys stay on the build machine.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'charitha-only/sara-pdf-reader'
PUBLISHER_CERT = '0521eaeb7f03e8a8463166377d68995d507569bd3a93207b9b8a8cf4d6c90f86'


def run(*args):
    command = list(map(str, args))
    if os.name == 'nt' and command[0].lower().endswith('.bat'):
        command = [os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/c', *command]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} failed: {result.stdout}\n{result.stderr}')
    return result.stdout


def build_tools():
    sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    if not sdk:
        local = ROOT / 'android/local.properties'
        if local.exists():
            match = re.search(r'^sdk.dir=(.+)$', local.read_text(), re.M)
            if match:
                sdk = match[1].replace('\\:', ':').replace('\\\\', '\\')
    if not sdk and os.name == 'nt' and os.environ.get('LOCALAPPDATA'):
        sdk = str(Path(os.environ['LOCALAPPDATA']) / 'Android/sdk')
    if not sdk:
        raise RuntimeError('Set ANDROID_SDK_ROOT to the Android SDK directory.')
    versions = [p for p in (Path(sdk) / 'build-tools').iterdir()
                if re.fullmatch(r'\d+(\.\d+)*', p.name)]
    return max(versions, key=lambda p: tuple(map(int, p.name.split('.'))))


def get_token():
    if os.environ.get('GITHUB_TOKEN'):
        return os.environ['GITHUB_TOKEN']
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GCM_INTERACTIVE='never')
    result = subprocess.run(['git', 'credential', 'fill'], cwd=ROOT,
                            input='protocol=https\nhost=github.com\nusername=charitha-only\n\n',
                            capture_output=True, text=True, env=env)
    values = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if result.returncode or not values.get('password'):
        raise RuntimeError('Sign in with Git Credential Manager or set GITHUB_TOKEN locally. Do not commit a token.')
    return values['password']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True, help='Visible version, for example v1.01')
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--notes', required=True, type=Path)
    parser.add_argument('--certificate-sha256', default=PUBLISHER_CERT)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'v\d+\.\d+(?:\.\d+)?', args.tag):
        raise RuntimeError('Tag must be a version such as v1.01.')
    apk = args.apk.resolve()
    notes = args.notes.resolve().read_text(encoding='utf-8')
    asset_name = f'Sara-PDF-Reader-{args.tag}.apk'
    sdk = build_tools()
    badging = run(sdk / ('aapt.exe' if os.name == 'nt' else 'aapt'), 'dump', 'badging', apk)
    if "name='app.pageflow.reader'" not in badging or f"versionName='{args.tag}'" not in badging:
        raise RuntimeError('APK package or version does not match the release.')
    if "application-label:'Sara PDF Reader'" not in badging:
        raise RuntimeError('APK application label does not match Sara PDF Reader.')
    build = re.search(r"versionCode='(\d+)'", badging)
    if not build:
        raise RuntimeError('APK has no Android version code.')
    pubspec = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    if not re.search(r'^version:\s*\d+\.\d+\.\d+\+' + build[1] + r'\s*$', pubspec, re.M):
        raise RuntimeError('APK build code and pubspec.yaml differ.')
    if f'versionName = "{args.tag}"' not in (ROOT / 'android/app/build.gradle.kts').read_text():
        raise RuntimeError('Source Android version differs from the tag.')
    if f"applicationVersion: '{args.tag}'" not in (ROOT / 'lib/main.dart').read_text(encoding='utf-8'):
        raise RuntimeError('Source About version differs from the tag.')
    signature = run(sdk / ('apksigner.bat' if os.name == 'nt' else 'apksigner'),
                    'verify', '--print-certs', apk)
    cert = re.search(r'certificate SHA-256 digest:\s*([a-fA-F0-9]+)', signature)
    if not cert or cert[1].lower() != args.certificate_sha256.lower():
        raise RuntimeError('APK signer does not match the publisher certificate.')
    run(sdk / ('zipalign.exe' if os.name == 'nt' else 'zipalign'), '-c', '-P', '16', '4', apk)
    permissions = run(sdk / ('aapt.exe' if os.name == 'nt' else 'aapt'), 'dump', 'permissions', apk)
    if 'android.permission.INTERNET' in permissions:
        raise RuntimeError('Reader release unexpectedly requests Internet access.')
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    checksum = f'{digest}  {asset_name}\n'.encode()
    apk.with_name('SHA256SUMS.txt').write_bytes(checksum)
    print(f'Verified {args.tag}, build {build[1]}, signed APK, offline permissions and 16 KB ZIP alignment.')
    if args.verify_only:
        return
    if run('git', 'status', '--porcelain').strip():
        raise RuntimeError('Commit source changes before publishing.')
    commit = run('git', 'rev-parse', 'HEAD').strip()
    remote = run('git', 'ls-remote', 'origin', 'refs/heads/main').split()
    if not remote or remote[0] != commit:
        raise RuntimeError('Push the release source commit to origin/main first.')
    token = get_token()

    def request(url, method='GET', data=None, content_type='application/json'):
        payload = json.dumps(data).encode() if isinstance(data, dict) else data
        req = urllib.request.Request(url, data=payload, method=method, headers={
            'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': content_type,
            'User-Agent': 'Sara-PDF-Reader-release'})
        with urllib.request.urlopen(req, timeout=300) as response:
            return json.load(response)

    api = f'https://api.github.com/repos/{REPOSITORY}/releases'
    # Never replace a published version or delete an older download.
    existing = request(api + '?per_page=100')
    if any(item['tag_name'] == args.tag for item in existing):
        raise RuntimeError('This version already has a release. Use a new version; do not overwrite old downloads.')
    previous_builds = [int(match[1]) for item in existing if not item['draft']
                       for match in re.finditer(r'Android build\s+(\d+)', item.get('body') or '', re.I)]
    if previous_builds and int(build[1]) <= max(previous_builds):
        raise RuntimeError('Increase the Android build code so existing installations can update.')
    notes += f'\n\nAndroid build {build[1]}. APK SHA-256: `{digest}`.\n'
    release = request(api, 'POST', {'tag_name': args.tag, 'target_commitish': commit,
        'name': f'Sara PDF Reader {args.tag}', 'body': notes, 'draft': True, 'prerelease': False})
    print('Created draft release; uploading APK and checksum.')
    upload = release['upload_url'].split('{', 1)[0]
    request(upload + '?name=' + urllib.parse.quote(asset_name), 'POST', apk.read_bytes(),
            'application/vnd.android.package-archive')
    request(upload + '?name=SHA256SUMS.txt', 'POST', checksum, 'text/plain')
    published = request(api + '/' + str(release['id']), 'PATCH', {'draft': False, 'make_latest': 'true'})
    print('Published: ' + published['html_url'])
    print('APK: ' + next(item['browser_download_url'] for item in published['assets'] if item['name'] == asset_name))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, urllib.error.HTTPError) as error:
        print(f'Release failed: {error}', file=sys.stderr)
        sys.exit(1)
