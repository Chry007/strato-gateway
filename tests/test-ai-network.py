"""Exercise the actual embedded Compose validator with allowed and rejected models."""
import copy,json,pathlib,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
source=(root/'codex-skill/deploy-strato-app/scripts/remote-app.sh').read_text()
validator=source.split("<<'PY'\nimport json, sys\nfrom pathlib import Path\n",1)[1].split('\nPY\n',1)[0]
validator='import json, sys\nfrom pathlib import Path\n'+validator
model={'services':{'web':{'image':'strato-storysound-web:20261102T000000Z','expose':['8787'],
  'labels':{'com.strato.ai.client':'storysound'},'networks':{'strato-app-edge':{'aliases':['strato-storysound-web']},'strato-ai-internal':{}}}},
  'networks':{'strato-app-edge':{'external':True,'name':'strato-app-edge'},'strato-ai-internal':{'external':True,'name':'strato-ai-internal'}}}
def check(value,accepted):
    with tempfile.TemporaryDirectory(prefix='strato-compose-test-') as directory:
        file=pathlib.Path(directory)/'model.json';file.write_text(json.dumps(value))
        result=subprocess.run([sys.executable,'-c',validator,str(file),'storysound','20261102T000000Z','8787','/var/snap/docker/common/strato-apps/apps/storysound'],capture_output=True,text=True)
        assert (result.returncode==0)==accepted,result.stderr
check(model,True)
for mutation in ['label','alias','ingress','private','worker','rename']:
    value=copy.deepcopy(model);web=value['services']['web']
    if mutation=='label':web['labels']={}
    elif mutation=='alias':web['networks']['strato-ai-internal']={'aliases':['strato-ai']}
    elif mutation=='ingress':web['networks']['strato-ingress']={}
    elif mutation=='private':value['networks']['other']={'external':True,'name':'mobikitcrm_database'}
    elif mutation=='worker':value['services']['worker']={'labels':{'com.strato.ai.client':'storysound'},'networks':{'strato-ai-internal':{}}}
    elif mutation=='rename':value['networks']['strato-ai-internal']['name']='mobikitcrm_database'
    check(value,False)
print('Central AI Compose boundaries: 7 cases passed.')
