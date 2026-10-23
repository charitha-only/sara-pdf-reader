import 'package:flutter_test/flutter_test.dart';
import 'package:offline_document_viewer/src/bridge/viewer_bridge.dart';
void main(){
 test('Local viewer accepts only its private HTTPS workspace',(){
 expect(ViewerBridge.allowsAndroidUrl(Uri.parse('https://appassets.androidplatform.net/ws/doc.bin')),isTrue);
 for(final value in ['http://appassets.androidplatform.net/ws/doc.bin','https://evil.test/ws/doc.bin','https://appassets.androidplatform.net/elsewhere','https://appassets.androidplatform.net:444/ws/a','https://user@appassets.androidplatform.net/ws/a','https://appassets.androidplatform.net/ws/%2e%2e/private','https://appassets.androidplatform.net/ws/%252e%252e/private','file:///etc/passwd','javascript:alert(1)']){
 expect(ViewerBridge.allowsAndroidUrl(Uri.parse(value)),isFalse,reason:value);
 }
 });
}
