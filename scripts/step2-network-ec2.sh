#!/bin/bash
# 建 VPC／子網路／IGW／路由／安全群組／Elastic IP 與 EC2（mgmt、prod-1，選用 dr-1）。
# 所有資源都加 Project=${LAB_TAG} 標籤；重跑時以 Name 標籤找既有資源，不重複建立。
#
# 用法：bash step2-network-ec2.sh            預設 dry-run，只印出要做的事，不建立任何資源
#       bash step2-network-ec2.sh --apply    真的建立（會產生費用）
#
# 必填環境變數：
#   AMI         SLES 16 的 AMI ID（依區域不同）。查詢範例：
#               aws ec2 describe-images --owners aws-marketplace \
#                 --filters 'Name=name,Values=suse-sles-16-0-byos-*-x86_64' \
#                 --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name]' --output text
#               （BYOS 映像檔需先在 Marketplace 訂閱，開機後再用自己的註冊碼註冊）
#   OPEN_CIDR   允許連 22／443 的來源，例如自己的對外 IP 192.0.2.50/32。
#               設成 0.0.0.0/0 等於對全網開放 SSH 與 HTTPS，請自行評估。
# 選填環境變數：
#   LAB_TAG（預設 hardened-lab）、AWS_PROFILE、AWS_REGION（預設 ap-northeast-1）、AZ（預設 ${AWS_REGION}a）
#   TYPE（預設 m6i.2xlarge）、DR_TYPE（預設 m6i.xlarge）、WITH_DR=1 一併建第三台 dr-1
#   KEY_NAME   既有的 EC2 key pair 名稱（預設 ${LAB_TAG}-key，需事先建立／匯入）
#   VPC_CIDR（預設 10.0.0.0/16）、SUBNET_CIDR（預設 10.0.1.0/24）
#   STATE_DIR  建立的資源 ID 記錄到 ${STATE_DIR}/resources.tsv（預設 ./state；白名單式 .gitignore 不會收進 state/，請勿手動加入）
# 不含任何憑證；AWS 身分取自 AWS CLI 的設定。
set -euo pipefail

LAB_TAG="${LAB_TAG:-hardened-lab}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

: "${AMI:?請設定 AMI（SLES 16 的 AMI ID，見檔頭說明）}"
: "${OPEN_CIDR:?請設定 OPEN_CIDR（允許連 22／443 的來源 CIDR，例如 192.0.2.50/32）}"
AZ="${AZ:-${AWS_REGION}a}"
TYPE="${TYPE:-m6i.2xlarge}"
DR_TYPE="${DR_TYPE:-m6i.xlarge}"
WITH_DR="${WITH_DR:-0}"
KEY="${KEY_NAME:-${LAB_TAG}-key}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.1.0/24}"
STATE_DIR="${STATE_DIR:-./state}"
OUT="$STATE_DIR/resources.tsv"

tags() { echo "ResourceType=$1,Tags=[{Key=Project,Value=${LAB_TAG}},{Key=Name,Value=$2}]"; }
find_id() { # $1=describe 子指令 $2=JMESPath id 欄位 $3=Name
  aws ec2 "$1" --filters "Name=tag:Project,Values=${LAB_TAG}" "Name=tag:Name,Values=$3" --query "$2" --output text | awk '{print $1}' | grep -v '^None$' || true
}
run() { if [ $APPLY = 1 ]; then "$@"; else echo "[dry-run] $*" >&2; echo "dry-run-id"; fi; }
record() { if [ $APPLY = 1 ]; then mkdir -p "$STATE_DIR"; printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; fi; return 0; }

echo "region: ${AWS_REGION}  tag: ${LAB_TAG}  apply=${APPLY}"
aws sts get-caller-identity --query Arn --output text >/dev/null   # 確認憑證可用，不印出帳號
aws ec2 describe-key-pairs --key-names "$KEY" >/dev/null

# VPC
VPC=$(find_id describe-vpcs 'Vpcs[].VpcId' "${LAB_TAG}-vpc")
if [ -z "$VPC" ]; then
  VPC=$(run aws ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(tags vpc "${LAB_TAG}-vpc")" --query Vpc.VpcId --output text)
  [ $APPLY = 1 ] && aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames '{"Value":true}'
  record vpc "$VPC" "${LAB_TAG}-vpc"
fi
echo "vpc: $VPC"

# 子網路（公開）
SUBNET=$(find_id describe-subnets 'Subnets[].SubnetId' "${LAB_TAG}-public")
if [ -z "$SUBNET" ]; then
  SUBNET=$(run aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$SUBNET_CIDR" --availability-zone "$AZ" --tag-specifications "$(tags subnet "${LAB_TAG}-public")" --query Subnet.SubnetId --output text)
  record subnet "$SUBNET" "${LAB_TAG}-public"
fi
echo "subnet: $SUBNET"

# IGW
IGW=$(find_id describe-internet-gateways 'InternetGateways[].InternetGatewayId' "${LAB_TAG}-igw")
if [ -z "$IGW" ]; then
  IGW=$(run aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway "${LAB_TAG}-igw")" --query InternetGateway.InternetGatewayId --output text)
  [ $APPLY = 1 ] && aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
  record internet-gateway "$IGW" "${LAB_TAG}-igw"
fi
echo "igw: $IGW"

# 路由表
RTB=$(find_id describe-route-tables 'RouteTables[].RouteTableId' "${LAB_TAG}-rtb")
if [ -z "$RTB" ]; then
  RTB=$(run aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tags route-table "${LAB_TAG}-rtb")" --query RouteTable.RouteTableId --output text)
  if [ $APPLY = 1 ]; then
    aws ec2 create-route --route-table-id "$RTB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
    aws ec2 associate-route-table --route-table-id "$RTB" --subnet-id "$SUBNET" >/dev/null
  fi
  record route-table "$RTB" "${LAB_TAG}-rtb"
fi
echo "rtb: $RTB"

# 安全群組：22／443 只對 OPEN_CIDR，群組內互通（節點之間 RKE2／Rancher agent 的流量）
SG=$(find_id describe-security-groups 'SecurityGroups[].GroupId' "${LAB_TAG}-sg")
if [ -z "$SG" ]; then
  SG=$(run aws ec2 create-security-group --group-name "${LAB_TAG}-sg" --description "${LAB_TAG} nodes" --vpc-id "$VPC" --tag-specifications "$(tags security-group "${LAB_TAG}-sg")" --query GroupId --output text)
  if [ $APPLY = 1 ]; then
    aws ec2 authorize-security-group-ingress --group-id "$SG" --tag-specifications "$(tags security-group-rule "${LAB_TAG}-sg-rule")" --ip-permissions \
      "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$OPEN_CIDR,Description=ssh}]" \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$OPEN_CIDR,Description=https}]" \
      "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$SG,Description=intra-cluster}]" >/dev/null
  fi
  record security-group "$SG" "${LAB_TAG}-sg"
fi
echo "sg: $SG"

launch() { # $1=Name $2=磁碟 GiB $3=執行個體類型
  local id
  id=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=${LAB_TAG}" "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -z "$id" ]; then
    id=$(run aws ec2 run-instances --image-id "$AMI" --instance-type "$3" --key-name "$KEY" \
      --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET,Groups=$SG,AssociatePublicIpAddress=true" \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$2,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2 \
      --tag-specifications "$(tags instance "$1")" "$(tags volume "$1-root")" "$(tags network-interface "$1-eni")" \
      --query 'Instances[0].InstanceId' --output text)
    record instance "$id" "$1"
  fi
  echo "$id"
}

A=$(launch "${LAB_TAG}-mgmt" 200 "$TYPE");   echo "A ${LAB_TAG}-mgmt: $A"
B=$(launch "${LAB_TAG}-prod-1" 150 "$TYPE"); echo "B ${LAB_TAG}-prod-1: $B"
INSTANCES=("$A" "$B")
if [ "$WITH_DR" = 1 ]; then
  C=$(launch "${LAB_TAG}-dr-1" 100 "$DR_TYPE"); echo "C ${LAB_TAG}-dr-1: $C"
  INSTANCES+=("$C")
fi

# mgmt 的 Elastic IP（Rancher／Registry 的網址要固定，所以只有 mgmt 掛 EIP）
EIP=$(find_id describe-addresses 'Addresses[].AllocationId' "${LAB_TAG}-mgmt-eip")
if [ -z "$EIP" ]; then
  EIP=$(run aws ec2 allocate-address --domain vpc --tag-specifications "$(tags elastic-ip "${LAB_TAG}-mgmt-eip")" --query AllocationId --output text)
  record elastic-ip "$EIP" "${LAB_TAG}-mgmt-eip"
fi
if [ $APPLY = 1 ]; then
  aws ec2 wait instance-running --instance-ids "${INSTANCES[@]}"
  aws ec2 associate-address --allocation-id "$EIP" --instance-id "$A" >/dev/null
  aws ec2 describe-instances --instance-ids "${INSTANCES[@]}" --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,PublicIpAddress,State.Name]' --output table
fi
