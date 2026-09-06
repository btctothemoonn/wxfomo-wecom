"""Fake transport and temporary credentials only; no production requests."""
import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

from scripts.test_wxfomo_minimax import FakeResponse
from scripts.test_wxfomo_signal_contract import fixture
from scripts.wxfomo_lan.signal_contract import SyncError, encode_payload
from scripts.wxfomo_lan.signal_transport import (
    SyncConfig, load_sync_config, sign_headers, send_payload, classify_response,
)


URL='https://holdrich.online/api/wecom/ingest'
SECRET='fedcba9876543210'*4


class TransportTests(unittest.TestCase):
    def test_old_and_corrected_public_vectors_all_match_exact_bytes(self):
        roots=('signalhub-v2-handoff-8f6df4f','signalhub-sync')
        for root in roots:
            path=pathlib.Path(__file__).parent/'fixtures'/root
            data=json.loads((path/('signature.example.json' if root==roots[0] else 'signature.json')).read_text())
            for vector in data['vectors']:
                body=vector['body'].encode('utf-8')
                self.assertEqual(encode_payload(json.loads((path/vector['fixture']).read_text())),body)
                headers=sign_headers(body,vector['device'],data['secret'],vector['timestamp'],vector['nonce'])
                self.assertEqual(headers['X-Wecom-Signature'],vector['signature'])
                self.assertEqual(hashlib.sha256(body).hexdigest(),vector['bodySha256'])

    def test_config_permissions_links_keys_and_redacted_repr(self):
        with tempfile.TemporaryDirectory() as root:
            os.chmod(root,0o700)
            path=pathlib.Path(root)/'sync.json'
            payload={'url':URL,'deviceId':'test-device','secret':SECRET}
            path.write_text(json.dumps(payload));path.chmod(0o600)
            config=load_sync_config(str(path))
            self.assertEqual((config.url,config.device_id,config.secret),(URL,'test-device',SECRET))
            self.assertNotIn(SECRET,repr(config))
            path.chmod(0o644)
            with self.assertRaises(SyncError): load_sync_config(str(path))
            path.chmod(0o600);os.chmod(root,0o755)
            with self.assertRaises(SyncError): load_sync_config(str(path))
            os.chmod(root,0o700)
            link=pathlib.Path(root)/'link.json';link.symlink_to(path)
            with self.assertRaises(SyncError):load_sync_config(str(link))
            link.unlink();os.link(str(path),str(link))
            with self.assertRaises(SyncError):load_sync_config(str(path))
            link.unlink()
            for changes in ({'url':URL+'?secret='+SECRET},{'url':'https://example.com/api/wecom/ingest'},
                            {'secret':'short'},{'secret':'TEST-ONLY-'+'x'*40},{'deviceId':'x\r\nPRIVATE'},
                            {'content':'PRIVATE'}):
                path.write_text(json.dumps(dict(payload,**changes)))
                with self.assertRaises(SyncError) as caught:load_sync_config(str(path))
                self.assertNotIn(SECRET,str(caught.exception))
                self.assertIsNone(caught.exception.__context__)
            path.write_text('{"url":"PRIVATE","url":"PRIVATE"}')
            with self.assertRaises(SyncError):load_sync_config(str(path))
            path.write_text('x'*65537)
            with self.assertRaises(SyncError):load_sync_config(str(path))

    def test_fixed_body_new_nonce_tls_endpoint_and_timeout(self):
        calls=[]; value=fixture(); body=encode_payload(value)
        config=SyncConfig(URL,'test-device',SECRET)
        def transport(request,timeout):
            calls.append((request,timeout))
            return FakeResponse(200,{'ok':True,'id':value['report']['id'],'revision':1,'disposition':'stored'})
        for _ in range(2):send_payload(config,body,transport=transport)
        self.assertEqual(len(calls),2)
        for request,timeout in calls:
            self.assertEqual((request.full_url,request.method,request.data,timeout),(URL,'POST',body,10.0))
        self.assertNotEqual(calls[0][0].get_header('X-wecom-nonce'),calls[1][0].get_header('X-wecom-nonce'))

    def test_only_exact_committed_ack_counts_as_success(self):
        report=fixture(); item=report['report']
        ack={'ok':True,'id':item['id'],'revision':item['revision'],'disposition':'stored'}
        for disposition in ('stored','duplicate','stale'):
            result=classify_response(report,200,{},json.dumps(dict(ack,disposition=disposition)).encode(),1000)
            self.assertEqual(result['action'],'ack')
        for changes in ({'ok':1},{'id':'wrong'},{'revision':True},{'revision':2},{'disposition':'unknown'},{'content':'PRIVATE'}):
            result=classify_response(report,200,{},json.dumps(dict(ack,**changes)).encode(),1000)
            self.assertNotEqual(result['action'],'ack')
        for raw in (b'<html>login</html>',b'{"ok":true,"ok":true}',b'x'*16385):
            self.assertNotEqual(classify_response(report,200,{},raw,1000)['action'],'ack')
        heartbeat=fixture('heartbeat.example.json')
        self.assertEqual(classify_response(heartbeat,200,{},b'{"ok":true}',1000)['action'],'ack')
        self.assertNotEqual(classify_response(report,200,{},b'{"ok":true}',1000)['action'],'ack')
        alert=fixture('ca-alert.example.json')
        self.assertNotEqual(classify_response(alert,200,{},json.dumps(ack).encode(),1000)['action'],'ack')

    def test_failure_classification_scopes_and_retry_after(self):
        expected=fixture()
        cases=[(401,{},b'PRIVATE','pause','authentication_failed'),
               (400,{},b'{"error":"unsupported_schema"}','pause','unsupported_schema'),
               (404,{},b'','retry','sync_unconfigured'),(405,{},b'','retry','sync_unconfigured'),
               (503,{},b'{"error":"sync_unconfigured"}','retry','sync_unconfigured'),
               (408,{},b'','retry','transport_error'),(500,{},b'','retry','provider_unavailable'),
               (409,{},b'{"error":"replay"}','retry','replay'),
               (409,{},b'{"error":"revision_conflict"}','quarantine','revision_conflict'),
               (400,{},b'PRIVATE','quarantine','request_invalid'),
               (413,{},b'','quarantine','payload_too_large'),(415,{},b'','quarantine','request_invalid')]
        for status,headers,raw,action,code in cases:
            result=classify_response(expected,status,headers,raw,1000)
            self.assertEqual((result['action'],result['code']),(action,code))
            self.assertNotIn('PRIVATE',str(result))
        self.assertEqual(classify_response(expected,400,{},b'{"error":"unsupported_schema"}',1000)['scope'],'schema')
        self.assertEqual(classify_response(expected,401,{},b'',1000)['scope'],'global')
        for header,want in [('120',120),('99999',900),('Thu, 01 Jan 1970 00:20:00 GMT',200),('bad',60),('-1',60)]:
            result=classify_response(expected,429,{'Retry-After':header},b'',1000)
            self.assertEqual((result['action'],result['scope'],result['retry_after']),('retry','global',want))
        for status in (301,302,303,307,308):
            self.assertNotEqual(classify_response(expected,status,{},b'{"ok":true}',1000)['action'],'ack')

    def test_response_cap_transport_errors_and_no_secret_reflection(self):
        config=SyncConfig(URL,'test-device',SECRET);body=encode_payload(fixture())
        def failure(request,timeout):raise OSError('PRIVATE '+SECRET)
        with self.assertRaises(SyncError) as caught:send_payload(config,body,transport=failure)
        self.assertEqual(str(caught.exception),'transport_error')
        self.assertIsNone(caught.exception.__context__)
        with self.assertRaises(SyncError):
            send_payload(config,body,transport=lambda request,timeout:FakeResponse(200,{},raw=b'x'*16385))
        value=fixture();value['report']['summary']=SECRET
        with self.assertRaises(SyncError) as caught:
            send_payload(config,encode_payload(value),transport=failure)
        self.assertEqual(caught.exception.code,'payload_sensitive')
        with self.assertRaises(SyncError):
            send_payload(SyncConfig('http://127.0.0.1/api/wecom/ingest','test-device',SECRET),body,transport=failure)

    def test_auth_and_rate_limit_do_not_depend_on_reading_body(self):
        config=SyncConfig(URL,'test-device',SECRET);value=fixture();body=encode_payload(value)
        for status in (401,429):
            for oversized in (False,True):
                with self.subTest(status=status,oversized=oversized):
                    response=FakeResponse(status,{},headers={'Retry-After':'120'},raw=b'x'*16385)
                    if not oversized:
                        response.read=mock.Mock(side_effect=OSError('PRIVATE body read failure'))
                    received=send_payload(config,body,transport=lambda request,timeout:response)
                    result=classify_response(value,*received,now=1000)
                    self.assertEqual(result['scope'],'global')
                    self.assertEqual(result['action'],'pause' if status==401 else 'retry')
                    if status==429:self.assertEqual(result['retry_after'],120)

    def test_default_request_deadline_stops_and_reaps_slow_network_process(self):
        from scripts.wxfomo_lan import signal_transport
        config=SyncConfig(URL,'test-device',SECRET);value=fixture();body=encode_payload(value)
        ack={'ok':True,'id':value['report']['id'],'revision':1,'disposition':'stored'}
        real_popen=subprocess.Popen
        for trickle in (False,True):
            children=[]
            # Only a local, synthetic process: no DNS, credentials or network endpoint.
            script=('import sys,time; sys.stdin.buffer.read(); '
                    'sys.stdout.buffer.write(b\'{"status":200,"headers":{}}\\n\'); '
                    'sys.stdout.buffer.flush(); ')
            script+=('[(sys.stdout.buffer.write(b" "),sys.stdout.buffer.flush(),time.sleep(.06)) for _ in range(20)]'
                     if trickle else 'time.sleep(.8)')
            def child(unused_command,**kwargs):
                self.assertNotIn(SECRET,repr(unused_command))
                process=real_popen([sys.executable,'-c',script],**kwargs)
                children.append(process)
                return process
            def old_in_process(request,timeout):
                time.sleep(.8)
                return FakeResponse(200,ack)
            with self.subTest(trickle=trickle), mock.patch.object(signal_transport,'REQUEST_TIMEOUT',.15,create=True), \
                    mock.patch('subprocess.Popen',side_effect=child), \
                    mock.patch.object(signal_transport,'_open',side_effect=old_in_process):
                started=time.monotonic()
                with self.assertRaises(SyncError) as caught:send_payload(config,body)
                self.assertEqual(caught.exception.code,'transport_error')
                self.assertLess(time.monotonic()-started,.7)
                self.assertEqual(len(children),1)
                self.assertIsNotNone(children[0].poll())

    def test_real_child_codec_keeps_body_bytes_and_failure_status(self):
        from scripts.wxfomo_lan import signal_transport
        config=SyncConfig(URL,'test-device',SECRET);value=fixture();body=encode_payload(value)
        ack=json.dumps({'ok':True,'id':value['report']['id'],'revision':1,'disposition':'stored'}).encode()
        real_popen=subprocess.Popen
        cases=((200,False,False),(200,True,False),(401,False,True),(429,False,True))
        for status,oversized,stuck_close in cases:
            with self.subTest(status=status,oversized=oversized,stuck_close=stuck_close):
                children=[]
                # Exercise the real child codec/reader, substituting only HTTP I/O.
                script=('import hashlib,io,time\nfrom wxfomo_lan import signal_transport as m\n'
                        'class Response(io.BytesIO):\n'
                        ' status={status}\n headers={{"Retry-After":"120","Set-Cookie":"PRIVATE"}}\n'
                        ' def close(self):\n  {close}\n'
                        'def fake_open(request,timeout):\n'
                        ' assert request.full_url==m.INGEST_URL and request.method=="POST"\n'
                        ' assert hashlib.sha256(request.data).hexdigest()=={digest!r}\n'
                        ' assert request.get_header("X-wecom-device")=="test-device"\n'
                        ' return Response({raw!r})\n'
                        'm._open=fake_open\nm._http_child()\n').format(
                            status=status,close='time.sleep(2)' if stuck_close else 'pass',
                            digest=hashlib.sha256(body).hexdigest(),raw=b'x'*16385 if oversized else ack)
                def child(command,**kwargs):
                    self.assertEqual(command[1:],['-m','wxfomo_lan.signal_transport'])
                    self.assertNotIn(SECRET,repr(command))
                    process=real_popen([sys.executable,'-c',script],**kwargs)
                    children.append(process)
                    return process
                with mock.patch.object(signal_transport,'REQUEST_TIMEOUT',.4), \
                        mock.patch('subprocess.Popen',side_effect=child):
                    if oversized:
                        with self.assertRaises(SyncError) as caught:send_payload(config,body)
                        self.assertEqual(caught.exception.code,'response_too_large')
                    else:
                        received=send_payload(config,body)
                        self.assertNotIn('Set-Cookie',received[1])
                        result=classify_response(value,*received,now=1000)
                        self.assertEqual(result['action'],{200:'ack',401:'pause',429:'retry'}[status])
                        if status==429:self.assertEqual(result['retry_after'],120)
                    self.assertIsNotNone(children[0].poll())

    def test_completed_ack_past_total_deadline_is_rejected(self):
        from scripts.wxfomo_lan import signal_transport
        config=SyncConfig(URL,'test-device',SECRET);value=fixture();body=encode_payload(value)
        child=mock.Mock(returncode=0)
        child.poll.return_value=0
        child.communicate.return_value=(b'{"status":200,"headers":{}}\n{"body":"e30="}\n',None)
        with mock.patch('subprocess.Popen',return_value=child), \
                mock.patch.object(signal_transport.time,'monotonic',side_effect=(0,0,11)):
            with self.assertRaises(SyncError) as caught:send_payload(config,body)
            self.assertEqual(caught.exception.code,'transport_error')

    def test_escaped_secret_is_detected_in_decoded_text(self):
        secret='a"\\b'*12
        config=SyncConfig(URL,'test-device',secret)
        value=fixture();value['report']['summary']='摘要 '+secret
        def transport(request,timeout):self.fail('reflected secret reached transport')
        with self.assertRaises(SyncError) as caught:
            send_payload(config,encode_payload(value),transport=transport)
        self.assertEqual(caught.exception.code,'payload_sensitive')

    def test_default_opener_never_follows_redirect_even_on_loopback(self):
        from scripts.wxfomo_lan.signal_transport import _open
        paths=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                paths.append(self.path)
                self.send_response(302)
                self.send_header('Location','/should-not-be-visited')
                self.send_header('Content-Length','0');self.end_headers()
        server=HTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever);thread.daemon=True;thread.start()
        try:
            request=urllib.request.Request('http://127.0.0.1:{}/start'.format(server.server_port))
            with self.assertRaises(urllib.error.HTTPError) as caught:_open(request,1)
            caught.exception.close()
            self.assertEqual(paths,['/start'])
        finally:
            server.shutdown();server.server_close();thread.join(2)


if __name__ == '__main__':unittest.main()
