#!/bin/bash
echo "CYCLECLOUD: CyelceCloud postinstall settings..."

CYCLECLOUDNAME=cyclecloud01

MyResourceGroup=tmcbmt01-hpccicd01
VMPREFIX=hpccicd01
# ユーザ名: デフォルト azureuser
USERNAME=azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
#SSHKEYFILE="./${VMPREFIX}.pub"

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
az login --service-principal --username "${azure_name}" --password "${azure_password}" --tenant "${azure_tenant}" --output none

# コマンド名取得
CMDNAME=$(basename "$0")
# SSH鍵チェック
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
curl -s https://ipinfo.io/ip >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(head -n 1 tmpip)/32"
rm ./tmpip
echo "current your client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
#LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
#echo "addtional accessible CIDR: $LIMITEDIP2"

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
sudo apt-get install -qq -y parallel jq curl

# VM1 IPアドレス取得
unset cycleip
cycleip=$(az vm show -d -g $MyResourceGroup --name ${CYCLECLOUDNAME} --query publicIps -o tsv)
echo "accessing vm1: $cycleip"
if [ -z "$cycleip" ]; then 
	echo "can not get ${CYCLECLOUDNAME} ip address"
	exit 1
fi

# SSHアクセスチェック
unset checkssh
checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@"${cycleip}" "uname")
if [ -z "$checkssh" ]; then
	echo "can not access by ssh"
	exit 1
fi

# CyeleCloud 設定バックアップ
echo "configpuring CyeleCloud settings"
rm ./cycle_server.properties
SSHCMD="ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${cycleip} -t -t "
${SSHCMD} "sudo cp /opt/cycle_server/cycle_server.properties /opt/cycle_server/cycle_server.properties.old"
${SSHCMD} "sudo cp /opt/cycle_server/cycle_server.properties /home/$USERNAME"
${SSHCMD} "sudo chown $USERNAME:$USERNAME /home/$USERNAME/"
scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@"${cycleip}":/home/"$USERNAME"/cycle_server.properties ./

# CycleCloud 設定作成
sed -i -e "s/webServerPort=8080/webServerPort=443/" ./cycle_server.properties
sed -i -e "s/webServerEnableHttp=true/webServerEnableHttp=false/" ./cycle_server.properties
sed -i -e "s/webServerEnableHttps=false/webServerEnableHttps=true/" ./cycle_server.properties
echo "CyelceCloud: cycle_server.properties setting..."
cat ./cycle_server.properties

# CyeleCloud 設定
scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./cycle_server.properties $USERNAME@"${cycleip}":/home/"$USERNAME"/
${SSHCMD} "sudo cp /home/$USERNAME/cycle_server.properties /opt/cycle_server/cycle_server.properties"

# CyelceCloud プロセス再起動
echo "CyecleCloud listening port..."
${SSHCMD} "netstat -ntlp"


echo "$CMDNAME: CYCLECLOUD -  end of CyelcCloud postinstall settings."