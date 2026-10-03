#!/usr/bin/env python3
"""Loopback-only Responses fixture. Never contacts vendor APIs."""
import http.server, json, sys, time
log, expected_auth = sys.argv[1:]

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(log, 'a') as output:
            output.write(json.dumps({'model': payload.get('model'), 'effort': payload.get('reasoning', {}).get('effort'),
                                     'authorized': self.headers.get('Authorization') == 'Bearer ' + expected_auth}) + '\n')
        response = {'id': 'fixture-response', 'object': 'response', 'created_at': int(time.time()),
                    'status': 'completed', 'model': payload['model'],
                    'output': [{'id': 'fixture-message', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                                'content': [{'type': 'output_text', 'text': 'fixture complete', 'annotations': []}]}],
                    'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        self.wfile.write(('event: response.completed\ndata: ' + json.dumps({'type': 'response.completed', 'response': response}) + '\n\n').encode())
    def log_message(self, *args): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
print(server.server_port, flush=True)
server.serve_forever()
