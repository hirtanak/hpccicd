#!/bin/bash
echo "CYCLECLOUD: creating CycleCloud..."

VMPREFIX=tmcbmt01
CYCLECLOUDNAME=${VMPREFIX}-cyclecloud01
CCVMSIZE=Standard_D4as_v4
IMAGE="OpenLogic:CentOS:8_2:latest"

MyResourceGroup=tmcbmt01
Location=japaneast #southcentralus
# ネットワーク設定
MyAvailabilitySet=${VMPREFIX}avset01
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
ACCELERATEDNETWORKING="--accelerated-networking true" # もし問題がある場合にはNOで利用可能。コンピュートノードのみ対象 true/false
MyNetworkSecurityGroup=${VMPREFIX}-nsg
#IMAGE="OpenLogic:CentOS-HPC:7_8:latest" #Azure URNフォーマット。OpenLogic:CentOS-HPC:8_1:latest
USERNAME=azureuser # ユーザ名: デフォルト azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
SSHKEYFILE="./${VMPREFIX}.pub"
TAG=${VMPREFIX}=$(date "+%Y%m%d")

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
#az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
curl -s https://ipinfo.io/ip >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(head -n 1 tmpip)/32"
rm ./tmpip
echo "current your client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"

# コマンド名取得
CMDNAME=$(basename "$0")

# github actions向けダイレクト指定
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
apt-get install -qq -y parallel jq curl

# ネットワークチェック
tmpnetwork=$(az network vnet show -g $MyResourceGroup --name $MyNetwork --query id)
echo "current netowrk id: $tmpnetwork"
checknsg=$(az network nsg show --name $MyNetworkSecurityGroup -g $MyResourceGroup --query name -o tsv)

# NSGがあるかどうかチェック
checknsg=$(az network nsg show --name $MyNetworkSecurityGroup -g $MyResourceGroup --query name -o tsv)
if [ -z "$checknsg" ]; then
	# NSGがあれば、アップデート
	az network nsg rule create --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
		--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
	az network nsg rule create --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
		--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
fi

# Azure CyleCloud VM作成
az vm availability-set create --name $MyAvailabilitySet -g $MyResourceGroup -l $Location --tags "$TAG" --output none
echo "================= creating CyeleCloud =================="
az vm create --resource-group $MyResourceGroup --location $Location \
	--name ${CYCLECLOUDNAME} --size $CCVMSIZE \
	--vnet-name $MyNetwork --subnet $MySubNetwork \
	--nsg $MyNetworkSecurityGroup --nsg-rule SSH $ACCELERATEDNETWORKING \
	--public-ip-address-allocation static \
	--image $IMAGE \
	--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
	--tags "$TAG" -o table

# SSHアクセスチェック：CycleCloud
cycleip=$(az vm show -d -g $MyResourceGroup --name ${CYCLECLOUDNAME} --query publicIps -o tsv)
unset checkssh
for count in 1 8; do
	checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i "${SSHKEYDIR}" -t $USERNAME@"${cycleip}" "uname")
	if [ -n "$checkssh" ]; then
		break
	fi
	echo "${count}: sleep 15" && sleep 15
done
if [ -z "$checkssh" ]; then
	echo "can not access Azure CycleCloud by ssh"
	exit 1
fi
echo "checkssh: $checkssh"

# アクセス先設定
echo "cycleip: $cycleip"
SSHCMD="ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${cycleip} -t -t"

# Azure Cylecloud インストール
echo "accessing to azure cyclecloud vm..."
${SSHCMD} "cat /etc/redhat-release"
#${SSHCMD} "sudo su"
echo "cyclecloud: sudo 設定"
${SSHCMD} "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
# Javaインストール
${SSHCMD} "sudo yum install --quiet -y java-1.8.0-openjdk.x86_64 python3"
${SSHCMD} "java -version"

cat <<'EOL' >> cyclecloud.repo
[cyclecloud]
name=cyclecloud
baseurl=https://packages.microsoft.com/yumrepos/cyclecloud
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOL
echo "cyclecloud.repo..."
cat cyclecloud.repo
scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./cyclecloud.repo $USERNAME@"${cycleip}":/home/$USERNAME/
${SSHCMD} "sudo cp /home/$USERNAME/cyclecloud.repo /etc/yum.repos.d/"

${SSHCMD} "sudo yum -y install cyclecloud8"
echo "CyecleCloud listening port..."
${SSHCMD} "netstat -ntlp"


echo "$CMDNAME: CYCLECLOUD - end of cyclecloud creation script"