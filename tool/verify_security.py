#!/usr/bin/env python3
"""Inspect a v1.09+ release APK's Android privacy settings and bundled guards."""
import os,re,subprocess,sys,zipfile
from pathlib import Path
apk=Path(sys.argv[1]).resolve()
sdk=Path(os.environ.get('ANDROID_SDK_ROOT') or Path(os.environ['LOCALAPPDATA'])/'Android/sdk')
versions=[p for p in (sdk/'build-tools').iterdir() if re.fullmatch(r'\d+(\.\d+)*',p.name)]
tools=max(versions,key=lambda p:tuple(map(int,p.name.split('.'))));aapt=tools/('aapt.exe' if os.name=='nt' else 'aapt')
def dump(*args):return subprocess.check_output([str(aapt),*map(str,args)],text=True)
manifest=dump('dump','xmltree',apk,'AndroidManifest.xml');badging=dump('dump','badging',apk);permissions=dump('dump','permissions',apk)
assert 'application-debuggable' not in badging,'Release must not be debuggable'
assert 'android.permission.INTERNET' not in permissions,'Offline release must not request Internet'
assert 'android.permission.MANAGE_EXTERNAL_STORAGE' not in permissions,'All-files access is not allowed'
for attribute in ['allowBackup','fullBackupContent','usesCleartextTraffic']:
 assert re.search(r'android:'+attribute+r'[^\n]*\(type 0x12\)0x0\b',manifest),attribute+' must be explicitly false'
assert 'android:dataExtractionRules' in manifest
resources=dump('dump','--values','resources',apk)
def xml_path(name):
 match=re.search(r'(?m)^\s*resource[^\n]*:xml/'+re.escape(name)+r':[^\n]*\n\s*\(string8\) "([^"\n]+)"',resources)
 assert match,'Missing XML resource '+name
 return match.group(1)
rules=dump('dump','xmltree',apk,xml_path('data_extraction_rules'))
assert 'E: cloud-backup' in rules and 'E: device-transfer' in rules
assert rules.count('E: exclude')==18,'Both backup modes must exclude all nine data domains'
provider=dump('dump','xmltree',apk,xml_path('provider_paths'))
assert 'E: files-path' not in provider and 'E: root-path' not in provider
assert 'E: cache-path' in provider
with zipfile.ZipFile(apk) as archive:
 asset=next(name for name in archive.namelist() if name.endswith('/engines/xlsx/xlsx-render.js'))
 js=archive.read(asset)
 assert b'maxCells: 60000' in js and b'remainingCells -= print.rows*print.cols' in js
 assert b'mergeBudget' in js and b'wb.SheetNames.slice(0,100)' in js
print('Verified APK security: offline/non-debuggable, backup and cleartext disabled, data-transfer exclusions, restricted file-provider paths and bounded spreadsheet/print previews.')
