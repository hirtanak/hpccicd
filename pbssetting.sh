#!/bin/bash
echo "pbs configure...."

MyResourceGroup=tmcbmt01-hpccicd01
Location=japaneast #southcentralus
VMPREFIX=hpccicd01
VMSIZE=Standard_HB120rs_v2 #Standard_D2as_v4 #Standard_HC44rs, Standard_HB120rs_v3
PBSVMSIZE=Standard_D8as_v4
# ネットワーク設定
MyAvailabilitySet=${VMPREFIX}avset01
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
MySubNetwork2=management # ログインノード用
ACCELERATEDNETWORKING="--accelerated-networking true" # もし問題がある場合にはNOで利用可能。コンピュートノードのみ対象 true/false
MyNetworkSecurityGroup=${VMPREFIX}-nsg
# MyNic="cfdbmt-nic"
# MACアドレスを維持するためにNICを保存するかどうかの設定
STATICMAC=false
IMAGE="OpenLogic:CentOS-HPC:7_8:latest" #Azure URNフォーマット。OpenLogic:CentOS-HPC:8_1:latest
# ユーザ名: デフォルト azureuser
USERNAME=azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
SSHKEYFILE="./${VMPREFIX}.pub"
TAG=${VMPREFIX}=$(date "+%Y%m%d")
# 作成するコンピュートノード数
MAXVM=2
# 追加の永続ディスクが必要な場合、ディスクサイズ(GB)を記入する https://azure.microsoft.com/en-us/pricing/details/managed-disks/
PERMANENTDISK=0
PBSPERMANENTDISK=2048

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"

az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# コマンド名取得
CMDNAME=$(basename $0)
# コマンドオプションエラー処理
if [ $# -eq 1 ]; then
	echo "実行するには2個の引数が必要です。" 1>&2
	exit 1
fi
# SSH鍵チェック
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
echo $(curl -s https://ipinfo.io/ip) >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(cat tmpip | head -n 1)/32"
rm ./tmpip
echo "current your client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
sudo apt-get install -qq -y parallel jq curl

# VM1 IPアドレス取得
unset pbsvmip
pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
echo "accessing vm1: $pbsvmip"
if [ -z "pbsvmip" ]; then 
	echo "can not get ${VMPREFIX}-1 ip address"
	exit 1
fi

# SSHアクセスチェック
unset checkssh
checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@${pbsvmip} "uname")
if [ -z "$checkssh" ]; then
	echo "can not access ${VMPREFIX}-pbs by ssh"
	exit 1
fi

# PBS configuration
echo "configpuring PBS settings"
if [ -f ./setuppbs.sh ]; then rm ./setuppbs.sh; fi
# PBSキュー作成
echo '/opt/pbs/bin/qmgr -c 'create queue workq queue_type=execution'' >> setuppbs.sh
echo '/opt/pbs/bin/qmgr -c 'set queue workq started=true'' >> setuppbs.sh
echo '/opt/pbs/bin/qmgr -c 'set queue workq enabled=true'' >> setuppbs.sh
echo '/opt/pbs/bin/qmgr -c 'set queue workq resources_default.nodes=1'' >> setuppbs.sh
echo '/opt/pbs/bin/qmgr -c 'set server default_queue=workq'' >> setuppbs.sh
# PBSジョブ履歴有効化
echo '/opt/pbs/bin/qmgr -c 'qmgr -c 's s job_history_enable = 1''' >> setuppbs.sh
# setuppbs.sh 処理
echo "setuppbs.sh: $(cat ./setuppbs.sh)"
scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./setuppbs.sh $USERNAME@${pbsvmip}:/home/$USERNAME/setuppbs.sh
# SSH鍵登録
ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
# ジョブスケジューラセッティング
ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} root@${pbsvmip} -t -t "bash /home/$USERNAME/setuppbs.sh"


echo "$CMDNAME: end of pbs configure"
