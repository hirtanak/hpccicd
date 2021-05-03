#!/bin/bash
echo "pbs configure...."

MyResourceGroup=tmcbmt01-hpccicd01
VMPREFIX=hpccicd01
USERNAME=azureuser # ユーザ名: デフォルト azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
# SSHKEYFILE="./${VMPREFIX}.pub"
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# コマンド名取得
CMDNAME=$(basename "$0")
# コマンドオプションエラー処理
if [ $# -eq 1 ]; then
	echo "実行するには1個の引数が必要です。" 1>&2
	exit 1
fi

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
curl -s https://ipinfo.io/ip >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(head -n 1 ./tmpip)/32"
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
if [ -z "$pbsvmip" ]; then 
	echo "can not get ${VMPREFIX}-1 ip address"
	exit 1
fi

# SSHアクセスチェック
unset checkssh
checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@"${pbsvmip}" "uname")
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
scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./setuppbs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/setuppbs.sh
# SSH鍵登録
ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@"${pbsvmip}" -t -t "sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@"${pbsvmip}" -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
# ジョブスケジューラセッティング
ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} root@"${pbsvmip}" -t -t "bash /home/$USERNAME/setuppbs.sh"


echo "$CMDNAME: end of pbs configure"
