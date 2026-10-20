Source: pub.dev flutter_inappwebview_android 1.1.3, Apache-2.0.
Original archive SHA256: 62557c15a5c2db5d195cb3892aab74fcaec266d7b86d59a6f0027abd672cddba

Backport the upstream fix for recursive AndroidInternalStoragePathHandler.toMap:
https://github.com/pichillilorenzo/flutter_inappwebview/pull/2452
Call super.toMap() before adding the directory, rather than recursively calling
the current method. This fixes a StackOverflowError in offline Office viewing.
The package's original LICENSE is retained.
