#!/usr/bin/env python3
"""Exercise a supplied Codex binary against a loopback Responses fixture.

Usage: python3 scripts/verify-model-provider.py /absolute/path/to/codex [model-catalog.json]
No real credentials, providers, or billable inference are used.
"""
import json, tempfile, subprocess, os, queue, threading, http.server, time, sys
if len(sys.argv) not in (2, 3):
    raise SystemExit("Supply the absolute Codex executable path")
binary = sys.argv[1]
catalog = json.load(open(sys.argv[2]))['models'][0] if len(sys.argv) == 3 else None
model = catalog['slug'] if catalog else 'custom-model'
effort = catalog['default_reasoning_level'] if catalog else 'none'
class Server(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        tools = [{'name':t.get('name'), 'type':t.get('type')} for t in payload.get('tools',[])]
        seen.append({'path':self.path,'model':payload.get('model'),'reasoning':payload.get('reasoning'),'service_tier':payload.get('service_tier'),'tools':tools})
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        response={'id':'resp_mock','object':'response','created_at':int(time.time()),'status':'completed','model':model,'output':[{'id':'msg_mock','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Mock response verified','annotations':[]}]}],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
        if len(seen) == 1:
            name = next(t['name'] for t in tools if t['name'] in ('exec_command','shell_command'))
            arguments = {'cmd':'printf cloudcodex_fixture_tool'} if name == 'exec_command' else {'command':'printf cloudcodex_fixture_tool'}
            item = {'id':'fc_fixture','type':'function_call','call_id':'call_fixture','name':name,'arguments':json.dumps(arguments),'status':'completed'}
            response['output'] = [item]
            for event in [{'type':'response.output_item.added','output_index':0,'item':item},
                          {'type':'response.output_item.done','output_index':0,'item':item}]:
                self.wfile.write(('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n').encode())
        else:
            outputs = [item.get('output','') for item in payload.get('input',[]) if item.get('type') == 'function_call_output']
            assert any('cloudcodex_fixture_tool' in str(output) for output in outputs), 'No command output round trip'
        event={'type':'response.completed','response':response}
        self.wfile.write(('event: response.completed\ndata: '+json.dumps(event)+'\n\n').encode())
    def log_message(self,*args):pass
seen=[]
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='cloudcodex-provider-smoke-') as root:
    env=os.environ.copy();env['CODEX_HOME']=root;env['CLOUDCODEX_MODEL_API_KEY']='local-fixture-only'
    overrides={'model_provider':'cloudcodex_custom','model':'custom-model','model_providers.cloudcodex_custom.name':'Local fixture','model_providers.cloudcodex_custom.base_url':f'http://127.0.0.1:{server.server_port}/v1','model_providers.cloudcodex_custom.env_key':'CLOUDCODEX_MODEL_API_KEY','model_providers.cloudcodex_custom.wire_api':'responses','model_providers.cloudcodex_custom.requires_openai_auth':False,'model_reasoning_effort':'none','model_reasoning_summary':'none','service_tier':'default','shell_environment_policy.filters.CLOUDCODEX_MODEL_API_KEY':'exclude'}
    overrides['model'] = model
    overrides['model_reasoning_effort'] = effort
    overrides.update({'web_search':'disabled','features.multi_agent':False,'features.goals':False})
    if catalog: overrides['model_catalog_json'] = os.path.abspath(sys.argv[2])
    args=[binary,'app-server','--stdio']
    for key,value in overrides.items():args+=['-c',key+'='+json.dumps(value)]
    process=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    output=queue.Queue()
    usage_events=[]
    def reader():
        for line in process.stdout:
            try:
                row=json.loads(line)
                if row.get('method') == 'thread/tokenUsage/updated': usage_events.append(row['params'])
                output.put(row)
            except:pass
    threading.Thread(target=reader,daemon=True).start()
    n=0
    def request(method,params):
        global n
        n+=1;process.stdin.write(json.dumps({'id':n,'method':method,'params':params})+'\n');process.stdin.flush()
        deadline=time.time()+20
        while time.time()<deadline:
            row=output.get(timeout=20)
            if row.get('id')==n:
                if 'error' in row:raise RuntimeError(method+': '+str(row['error']))
                return row['result']
        raise RuntimeError('timeout')
    try:
        request('initialize',{'clientInfo':{'name':'cloudcodex_provider_fixture','version':'1'},'capabilities':{'experimentalApi':True}})
        params={'cwd':root,'model':model,'modelProvider':'cloudcodex_custom','config':{'model_reasoning_effort':effort,'model_reasoning_summary':'none','service_tier':'default'},'approvalPolicy':'never','ephemeral':False}
        thread=request('thread/start',params)['thread']['id']
        request('turn/start',{'threadId':thread,'model':model,'input':[{'type':'text','text':'Reply with fixture confirmation.'}]})
        deadline=time.time()+25;completed=False
        while time.time()<deadline:
            row=output.get(timeout=25)
            if row.get('method')=='turn/completed':
                completed=row.get('params',{}).get('turn',{}).get('status')=='completed';break
        request('thread/unsubscribe',{'threadId':thread})
        request('thread/resume',dict(params,threadId=thread))
        config=request('config/read',{'includeLayers':False})['config']
        assert config['model_provider']=='cloudcodex_custom'
        request('thread/unsubscribe',{'threadId':thread})
        models=request('model/list',{'limit':100})['data']
        default=next((model for model in models if model.get('isDefault')),models[0])
        request('thread/resume',{'threadId':thread,'modelProvider':'openai','model':default['model']})
        assert len(seen) >= 2 and all(row['model'] == model and row['reasoning']['effort'] == effort for row in seen)
        usage_totals = {event['tokenUsage']['total']['totalTokens'] for event in usage_events if event['tokenUsage']['last']['totalTokens'] > 0}
        assert len(usage_totals) == len(seen), 'Usage events must identify both model responses'
        assert all(event.get('threadId') == thread and event.get('turnId') for event in usage_events)
        if catalog:
            patch = next((tool for tool in seen[0]['tools'] if tool['name'] == 'apply_patch'), None)
            if catalog.get('apply_patch_tool_type') == 'freeform': assert patch and patch['type'] == 'custom'
            else: assert patch is None
            assert not any(tool['type'] in ('namespace','web_search') for tool in seen[0]['tools'])
        print(json.dumps({'switch_back_resume':'passed','thread_start_and_resume':'passed','command_tool_round_trip':'passed','usage_reported_calls':len(usage_totals),'turn_completed':completed,'routed_requests':seen}))
        if not completed:raise RuntimeError('turn did not complete')
    finally:process.terminate();process.wait(timeout=5)
server.shutdown()
