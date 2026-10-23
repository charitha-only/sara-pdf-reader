# Security reports

For a non-sensitive bug, open an issue with the affected app version, Android
version and a generated reproducer. Do not attach personal documents or keys.
For a sensitive issue, use GitHub private vulnerability reporting if available
on this repository. Do not post exploit details or credentials in public issues.

Document parsing involves complex third-party code. Keep parser dependencies
and archive validation current; do not remove offline WebView restrictions to
work around a preview error.

## v1.08 checks

v1.08 review, 23 October 2026:

- Release APKs intentionally have no INTERNET permission. Reading/OCR engines remain local.
- Camera and media permissions are requested by Android. Documents and save destinations use user-selected file grants.
- Shared files are copied into an isolated cache; the FileProvider is non-exported and exposes only share/camera cache subdirectories. The broad files-directory mapping was removed.
- Incoming file URIs are restricted to public external storage after canonical-path resolution; private app/system file paths are rejected. Received batches are bounded to 20 files and 256 MB.
- Office WebViews block network loads, remote navigation and popups. Navigation accepts only HTTPS on the private workspace host/path at port 443; user-info and encoded traversal are rejected.
- Archive preflight checks reject traversal, dangerous sizes/ratios and malformed containers. Native word and PDF parsers still process untrusted data, so parser updates remain part of maintenance.
- 117 locked Pub/direct Maven dependency versions were queried against https://api.osv.dev/v1/querybatch. No advisory matches were returned. The scoped report is in docs/security/v1.08-dependencies.json; this is not a guarantee that every bundled native/JavaScript binary or unknown vulnerability is covered.
- Printing uses Android print services selected by the user. Printer/service software controls the destination; the app itself does not gain Internet access.

Never commit signing keys, key.properties, personal verification documents or account tokens. Signing material stays outside this repository.

## v1.09 resource hardening

Spreadsheet rendering now bounds total cells and sheets, clips merged ranges and budgets overlapping merge work. Truncated preview printing requires explicit acknowledgement. Native incoming imports allow at most two pending tasks. These controls reduce resource exhaustion risk; they do not claim that arbitrary untrusted documents are universally safe. Dependency versions are unchanged from the v1.08 OSV report.

Automatic Android backup is explicitly disabled. Android 12+ cloud-backup and device-transfer rules exclude all app-data domains, including device-protected storage; legacy full backup is disabled too. User-initiated app backup/export remains available. Reference: https://developer.android.com/identity/data/autobackup . Cleartext network traffic is explicitly disabled in addition to the existing absence of INTERNET permission.

Reproduce the v1.09 APK checks with `python tool/verify_security.py /path/to/release.apk` using Android SDK build-tools. It inspects the packaged manifest/resources and bundled resource guards rather than relying only on source settings.
