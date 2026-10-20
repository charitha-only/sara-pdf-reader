XML DOM compatibility subset for Xerces/POI on Android.

Input: xml-apis:xml-apis:1.4.01 from Maven Central.
Input SHA256: a840968176645684bb01aed376e067ab39614885f9eee44abe35a5f20ebe7fad

The jar retains org/w3c/dom class files missing from the Android 36 SDK's
android.jar, plus all upstream license notices. Existing Android DOM classes
and javax/SAX API classes are deliberately excluded to avoid replacing the
platform's XML APIs. No class bytecode is modified.

The subset supplies DOM events, ElementTraversal and other interfaces needed
by Xerces. Apache POI requires W3C live NodeLists; Android's default DOM provides
snapshots and fails when Word span compaction removes a previously detached node.

Licenses/notices are included in the jar and app's third-party disclosures.
