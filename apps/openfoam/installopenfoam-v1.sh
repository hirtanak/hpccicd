#!/bin/bash
echo "BUILD: try openfoam build...."
set -x

# 引数1：OpenFOAMのバージョン
OPENFOAM_VERSION=$1

MyResourceGroup=tmcbmt01
VMPREFIX=tmcbmt01
USERNAME=azureuser # ユーザ名: デフォルト azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
#SSHKEYFILE="./${VMPREFIX}.pub"
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
#az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# コマンド名取得
CMDNAME=$(basename "$0")
# コマンドオプションエラー処理
if [ $# -gt 2 ]; then
	echo "実行するには1個の引数が必要です。" 1>&2
	exit 1
fi

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
sudo apt-get install -qq -y parallel jq curl

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

# VM1 IPアドレス取得
unset vm1ip
vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
echo "accessing vm1: $vm1ip"
for count in $(seq 1 10); do
	if [ -z "$vm1ip" ]; then 
		vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
		echo "sleep 2" & sleep 2
	else
		break
	fi
done
if [ -z "$vm1ip" ]; then 
	echo "can not get ${VMPREFIX}-1 ip address"
	exit 1
fi

# SSHアクセスチェック：VM#1
unset checkssh
checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@"${vm1ip}" "uname")
echo "accessing vm1 by ssh...: $checkssh"
for count in $(seq 1 10); do
	if [ -z "$checkssh" ]; then 
		echo "sleep 2" & sleep 2
		checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@"${vm1ip}" "uname")
	else
		break
	fi
done
if [ -z "$checkssh" ]; then
	echo "can not access ${VMPREFIX}-1 by ssh"
	exit 1
fi

# コマンド設定
SSHCMD="ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1ip} -t -t"

# ビルドチェック
${SSHCMD} "ls -la /mnt/share/OpenFOAM/OpenFOAM-${OPENFOAM_VERSION}/bin/foamSystemCheck" > ./buildfiles
buildfiles=$(cat ./buildfiles | grep cannot)
echo "buildfiles: $buildfiles"
if [ -z "$buildfiles" ]; then
	echo "You have already buit for this OoenFOAM version."
else
	# OpenFOAM インストールセットアップ
	${SSHCMD} "wget -q https://gitlab.com/OpenCAE/installOpenFOAM/-/archive/master/installOpenFOAM-master.tar.gz -O /home/$USERNAME/installOpenFOAM-master.tar.gz"
	${SSHCMD} "tar zxf /home/$USERNAME/installOpenFOAM-master.tar.gz"
	${SSHCMD} "rm -rf /home/$USERNAME/installOpenFOAM"
	${SSHCMD} "mv /home/$USERNAME/installOpenFOAM-master /home/$USERNAME/installOpenFOAM"
	${SSHCMD} "rm -rf /mnt/share/OpenFOAM/installOpenFOAM"
	${SSHCMD} "mv /home/$USERNAME/installOpenFOAM /mnt/share/installOpenFOAM"
	${SSHCMD} "sudo mkdir -p /mnt/share/OpenFOAM"
	${SSHCMD} "sudo chown -R $USERNAME:$USERNAME /mnt/share/"
	# OoenFOAMコンパイル設定のダウンロード：githubリポジトリ
	${SSHCMD} "wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/compile.sh -O /home/$USERNAME/compile.sh"
	${SSHCMD} "cp /home/$USERNAME/compile.sh /mnt/share/OpenFOAM/"
	# OpenFOAMダウンロードスクリプトのダウンロード：githubリポジトリ
	${SSHCMD} "wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/download-installOpenFOAM.sh -O /home/$USERNAME/download-installOpenFOAM.sh"
	${SSHCMD} "bash /home/$USERNAME/download-installOpenFOAM.sh"

	# デバック：各ディレクトリの状況
	${SSHCMD} "echo "show: ls -la /home/$USERNAME/""
	${SSHCMD} "ls -la /home/$USERNAME/"
	${SSHCMD} "echo 'show ls -la /mnt/share/OpenFOAM'"
	${SSHCMD} "ls -la /mnt/share/OpenFOAM"
	${SSHCMD} "echo 'show ls -la details'"
	${SSHCMD} "ls -la /mnt/share/OpenFOAM/v1906"
	${SSHCMD} "ls -la /mnt/share/OpenFOAM/v1906/installOpenFOAM"

	# v1906 OpenFOAM install.sh パッチ
	${SSHCMD} "wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/of1906install.patch -O /home/$USERNAME/of1906install.patch"
	${SSHCMD} "cp /home/$USERNAME/of1906install.patch /mnt/share/OpenFOAM/v1906/installOpenFOAM/of1906install.patch"
	${SSHCMD} "patch /mnt/share/OpenFOAM/v1906/installOpenFOAM/install.sh < /mnt/share/OpenFOAM/v1906/installOpenFOAM/of1906install.patch"
	# v1906 OpenFOAM bashrc パッチ
	${SSHCMD} "wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/of1906bashrc.patch -O /home/$USERNAME/of1906bashrc.patch"
	${SSHCMD} "cp /home/$USERNAME/of1906bashrc.patch /mnt/share/OpenFOAM/v1906/installOpenFOAM/of1906bashrc.patch"
	${SSHCMD} "patch /mnt/share/OpenFOAM/v1906/installOpenFOAM/system/default/bashrc < /mnt/share/OpenFOAM/v1906/installOpenFOAM/of1906bashrc.patch"

	# run compile
	${SSHCMD} "bash /mnt/share/OpenFOAM/v1906/installOpenFOAM/install.sh"

	# コンパイルできたかどうか判断
	${SSHCMD} "ls -la /mnt/share/OpenFOAM/OpenFOAM-${OPENFOAM_VERSION}/bin/ | wc -l " > buildfiles2
	buildfiles2=$(cat ./buildfiles2 | wc -l)
 	echo "buildfiles2: $buildfiles2"
 	if [ $((buildfiles2)) -gt 35 ]; then
		echo "error!: you have to rebuild due to some reasons."
		exit 1
	fi
fi

# リンカ設定
checklink=$(${SSHCMD} "file  /mnt/share/OpenFOAM/OpenFOAM-v1906/platforms/linux64GccDPInt320pt")
if [ -z "$checklink" ]; then
	echo "making link"
	${SSHCMD} "ln -s /mnt/share/OpenFOAM/OpenFOAM-v1906/platforms/linux64Gcc4_8_5DPInt32Opt /mnt/share/OpenFOAM/OpenFOAM-v1906/platforms/linux64GccDPInt320pt"
fi

#========================================================================
#インストール後の処理2（以下は v1712 のみで実施すること）
#========================================================================
#$HOME/apps/OpenFOAM配下に以下各コンポーネントをインストールしているがv1712だけ  sphereSurfactantFoam が以下に作成される。
#$HOME/OpenFOAM/azureuser-v1712/platforms/linux64Gcc4_8_5DPInt32Opt/bin/sphereSurfactantFoam
#→ このバイナリファイルだけマニュアルで
#   $HOME/apps/OpenFOAM/OpenFOAM-v1712/platforms/linux64Gcc4_8_5DPInt32Opt/bin へ複製すること。
#   他のVersionでは、上記ディレクトリに正しく生成される。
#以下の処理を追加する。
#> cp $HOME/OpenFOAM/azureuser-v1712/platforms/linux64Gcc4_8_5DPInt32Opt/bin/sphereSurfactantFoam $HOME/apps/OpenFOAM/OpenFOAM-v1712/platforms/linux64Gcc4_8_5DPInt32Opt/bin
#> \rm -rf $HOME/OpenFOAM

# システムチェック実行：あとで調査
${SSHCMD} "/mnt/share/OpenFOAM/OpenFOAM-v1906/bin/foamSystemCheck" > checkfile
checksystem=$(cat checkfile | grep "System check:" | cut -d " " -f 3)
# checksytem 内の下位行削除
checksystem=`echo ${checksystem} | sed -e "s/[\r\n]\+//g"`
echo "checksystem: $checksystem"
if [[ ${checksystem} = PASS ]]; then
	echo "passed the OpenFOAM system check"
else
	echo "failure by some reason"
	exit 1
fi


echo "$CMDNAME: BUILD END: end of application build & install script"