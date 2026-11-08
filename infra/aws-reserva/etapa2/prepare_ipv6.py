"""Saída IPv6 da ponte para PostgreSQL direto; não abre entrada do banco."""
import sys,json,ipaddress,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from criar_ponte import aws,state,save
from exportar_origem import send,result
VPC='vpc-02971768e93bd5b58';SUBNET='subnet-081f484b4978958f0'
v=aws('ec2','describe-vpcs','--vpc-ids',VPC)['Vpcs'][0]
blocks=[x for x in v.get('Ipv6CidrBlockAssociationSet',[])if x['Ipv6CidrBlockState']['State'] in ['associated','associating']]
if not blocks:
 r=aws('ec2','associate-vpc-cidr-block','--vpc-id',VPC,'--amazon-provided-ipv6-cidr-block')
 blocks=[r['Ipv6CidrBlockAssociation']];state['ipv6_association']=blocks[0]['AssociationId'];save()
cidr=blocks[0]['Ipv6CidrBlock']
s=aws('ec2','describe-subnets','--subnet-ids',SUBNET)['Subnets'][0]
if not any(x['Ipv6CidrBlockState']['State']in['associated','associating']for x in s.get('Ipv6CidrBlockAssociationSet',[])):
 network=str(next(ipaddress.ip_network(cidr).subnets(new_prefix=64)))
 r=aws('ec2','associate-subnet-cidr-block','--subnet-id',SUBNET,'--ipv6-cidr-block',network)
 state['subnet_ipv6_association']=r['Ipv6CidrBlockAssociation']['AssociationId'];save()
interfaces=aws('ec2','describe-instances','--instance-ids',state['instance_id'])['Reservations'][0]['Instances'][0]['NetworkInterfaces']
interface=interfaces[0]
if not interface.get('Ipv6Addresses'):
 r=aws('ec2','assign-ipv6-addresses','--network-interface-id',interface['NetworkInterfaceId'],'--ipv6-address-count','1')
 state['bridge_ipv6']=r['AssignedIpv6Addresses'][0];save()
routes=aws('ec2','describe-route-tables','--filters','Name=association.subnet-id,Values='+SUBNET)['RouteTables']
if not routes:routes=aws('ec2','describe-route-tables','--filters','Name=vpc-id,Values='+VPC,'Name=association.main,Values=true')['RouteTables']
route=routes[0]
if not any(x.get('DestinationIpv6CidrBlock')=='::/0'for x in route['Routes']):
 igw=aws('ec2','describe-internet-gateways','--filters','Name=attachment.vpc-id,Values='+VPC)['InternetGateways'][0]['InternetGatewayId']
 aws('ec2','create-route','--route-table-id',route['RouteTableId'],'--destination-ipv6-cidr-block','::/0','--gateway-id',igw)
 state['ipv6_route_table']=route['RouteTableId'];save()
# HTTPS IPv6 também é necessário quando os endpoints AWS resolvem em IPv6.
sg=aws('ec2','describe-security-groups','--group-ids',state['security_group'])['SecurityGroups'][0]
if not any(x.get('CidrIpv6')=='::/0'for rule in sg['IpPermissionsEgress']if rule.get('FromPort')==443 for x in rule.get('Ipv6Ranges',[])):
 aws('ec2','authorize-security-group-egress','--group-id',state['security_group'],'--ip-permissions',json.dumps([{'IpProtocol':'tcp','FromPort':443,'ToPort':443,'Ipv6Ranges':[{'CidrIpv6':'::/0','Description':'AWS APIs and certificate renewal HTTPS'}]}]))
command="python3 -c \"import socket,json; print(json.dumps(sorted(set(x[4][0]for x in socket.getaddrinfo('db.etulhyboogqhyyevpnlo.supabase.co',5432,socket.AF_INET6)))))\""
send([command],'replication_source_ipv6_resolve',60)
for _ in range(15):
 resolved=result('replication_source_ipv6_resolve')
 if resolved['Status']not in ['Pending','InProgress','Delayed']:break
 time.sleep(2)
if resolved['Status']!='Success':raise RuntimeError('Resolução IPv6 da origem ainda não concluída; não abrir regra ampla para PostgreSQL')
addresses=json.loads(resolved['StandardOutputContent'])
if not addresses:raise RuntimeError('Origem sem endereço IPv6')
for address in addresses:
 cidr=str(ipaddress.IPv6Address(address))+'/128'
 if not any(x.get('CidrIpv6')==cidr for rule in sg['IpPermissionsEgress']if rule.get('FromPort')==5432 for x in rule.get('Ipv6Ranges',[])):
  aws('ec2','authorize-security-group-egress','--group-id',state['security_group'],'--ip-permissions',json.dumps([{'IpProtocol':'tcp','FromPort':5432,'ToPort':5432,'Ipv6Ranges':[{'CidrIpv6':cidr,'Description':'Only Supabase source PostgreSQL'}]}]))
print('IPv6 de saída preparado; nenhuma entrada IPv6 ou porta PostgreSQL pública aberta.')
