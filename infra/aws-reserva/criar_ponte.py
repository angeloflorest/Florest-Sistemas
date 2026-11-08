"""Provisiona somente a ponte temporária autorizada, sem senhas em disco."""
import base64
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent
STATE = ROOT / 'ponte-state.json'
ENV = dict(os.environ, AWS_CONFIG_FILE='/home/agent/.aws/config-florest-reserva')
CLI = '/home/agent/.local/bin/aws'
NAME = 'florest-reserva-ponte-20261107'
state = json.loads(STATE.read_text()) if STATE.exists() else {}

def save():
    STATE.write_text(json.dumps(state, indent=2))

def aws(*args):
    p = subprocess.run([CLI, *args, '--profile', 'florest-reserva', '--region', 'us-east-2', '--output', 'json'], env=ENV, capture_output=True, text=True, timeout=45)
    if p.returncode:
        raise RuntimeError(p.stderr[:1500])
    return json.loads(p.stdout or '{}')

def j(value):
    return json.dumps(value)

def main():
    config = json.loads((ROOT / 'preflight.json').read_text())
    db = config['db']
    vpc = db['DBSubnetGroup']['VpcId']
    dbsg = db['VpcSecurityGroups'][0]['VpcSecurityGroupId']
    subnet = next(s for s in config['subnets'] if s['AvailabilityZone'] == db['AvailabilityZone'])
    tags = [{'Key':'Name','Value':NAME}, {'Key':'Purpose','Value':'temporary-private-rds-access'}, {'Key':'ManagedBy','Value':'Codex-user-authorized'}]
    if 'role' not in state:
        trust = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'ec2.amazonaws.com'},'Action':'sts:AssumeRole'}]}
        result = aws('iam','create-role','--role-name',NAME,'--assume-role-policy-document',j(trust),'--tags',j(tags))
        state['role'] = result['Role']['RoleName']; save(); print('Papel exclusivo criado.', flush=True)
    aws('iam','attach-role-policy','--role-name',NAME,'--policy-arn','arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore')
    policy = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':['secretsmanager:GetSecretValue'],'Resource':config['secret_arn']}]}
    aws('iam','put-role-policy','--role-name',NAME,'--policy-name','LerSomenteCredencialReserva','--policy-document',j(policy))
    if 'profile' not in state:
        aws('iam','create-instance-profile','--instance-profile-name',NAME,'--tags',j(tags))
        state['profile'] = NAME; save()
    profile = aws('iam','get-instance-profile','--instance-profile-name',NAME)['InstanceProfile']
    if not profile['Roles']:
        aws('iam','add-role-to-instance-profile','--instance-profile-name',NAME,'--role-name',NAME)
    if 'security_group' not in state:
        result = aws('ec2','create-security-group','--group-name',NAME,'--description','Temporary SSM access to Florest reserve RDS; no ingress','--vpc-id',vpc,'--tag-specifications',j([{'ResourceType':'security-group','Tags':tags}]))
        state['security_group'] = result['GroupId']; save()
    sg = state['security_group']
    existing = aws('ec2','describe-security-groups','--group-ids',sg)['SecurityGroups'][0]
    if existing['IpPermissionsEgress']:
        aws('ec2','revoke-security-group-egress','--group-id',sg,'--ip-permissions',j(existing['IpPermissionsEgress']))
    aws('ec2','authorize-security-group-egress','--group-id',sg,'--ip-permissions',j([
        {'IpProtocol':'tcp','FromPort':443,'ToPort':443,'IpRanges':[{'CidrIp':'0.0.0.0/0','Description':'AWS SSM, Secrets Manager and HTTPS packages'}]},
        {'IpProtocol':'tcp','FromPort':5432,'ToPort':5432,'UserIdGroupPairs':[{'GroupId':dbsg,'Description':'Only reserve RDS'}]}
    ]))
    if 'db_rule' not in state:
        result = aws('ec2','authorize-security-group-ingress','--group-id',dbsg,'--ip-permissions',j([{'IpProtocol':'tcp','FromPort':5432,'ToPort':5432,'UserIdGroupPairs':[{'GroupId':sg,'Description':'Authorized temporary Florest bridge'}]}]))
        state['db_rule'] = result.get('SecurityGroupRules',[]); state['db_security_group']=dbsg; save()
    image = aws('ec2','describe-images','--image-ids',config['ami'])['Images'][0]
    # Sem credenciais no user data; acesso administrativo exclusivamente por SSM.
    userdata = '#!/bin/bash\nset -eu\nsystemctl enable --now amazon-ssm-agent\n'
    if 'launch_template' not in state:
        template = {
            'ImageId':config['ami'],'InstanceType':'t3.micro',
            'IamInstanceProfile':{'Name':NAME},
            'NetworkInterfaces':[{'DeviceIndex':0,'SubnetId':subnet['SubnetId'],'AssociatePublicIpAddress':True,'Groups':[sg],'DeleteOnTermination':True}],
            'BlockDeviceMappings':[{'DeviceName':image['RootDeviceName'],'Ebs':{'VolumeSize':8,'VolumeType':'gp3','Encrypted':True,'DeleteOnTermination':True}}],
            'MetadataOptions':{'HttpTokens':'required','HttpEndpoint':'enabled','HttpPutResponseHopLimit':1},
            'CreditSpecification':{'CpuCredits':'standard'},'Monitoring':{'Enabled':False},
            'InstanceInitiatedShutdownBehavior':'stop',
            'UserData':base64.b64encode(userdata.encode()).decode(),
            'TagSpecifications':[{'ResourceType':'instance','Tags':tags},{'ResourceType':'volume','Tags':tags}]
        }
        result=aws('ec2','create-launch-template','--launch-template-name',NAME,'--launch-template-data',j(template),'--tag-specifications',j([{'ResourceType':'launch-template','Tags':tags}]))
        state['launch_template']=result['LaunchTemplate']['LaunchTemplateId']; save()
    if 'instance_id' not in state:
        # Propagação IAM é eventual. Repetir somente a falha específica, com token idempotente.
        for attempt in range(5):
            try:
                result=aws('ec2','run-instances','--launch-template',j({'LaunchTemplateId':state['launch_template'],'Version':'1'}),'--count','1','--client-token',NAME)
                break
            except RuntimeError as e:
                if ('Invalid IAM Instance Profile' not in str(e) and 'InvalidParameterValue' not in str(e)) or attempt==4:
                    raise
                time.sleep(5)
        state['instance_id']=result['Instances'][0]['InstanceId']; save()
    print('Ponte criada:',state['instance_id'],flush=True)

if __name__ == '__main__':
    main()
