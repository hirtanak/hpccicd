#!/bin/bash
# Repositry: https://github.com/hirtanak/hpcbmtenv
# Last update: 2021/5/7
SCRIPTVERSION=0.3.1

echo "SCRIPTVERSION: $SCRIPTVERSION - startup azure hpc delopment create script..."

### 基本設定
MyResourceGroup=tmcbmt01
Location=japaneast #southcentralus
VMPREFIX=tmcbmt01
VMSIZE=Standard_HB120rs_v2 #Standard_HC44rs, Standard_HB120rs_v3
PBSVMSIZE=Standard_D8as_v4
MAXVM=2 # 作成するコンピュートノード数

### ネットワーク設定
MyAvailabilitySet=${VMPREFIX}avset01 #HPCクラスターのVMサイズ別に異なる可用性セットが必要。自動生成するように変更したため、基本変更しない
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
MySubNetwork2=management # ログインノード用サブネット
ACCELERATEDNETWORKING="--accelerated-networking true" # もし問題がある場合にはflaseで利用可能。コンピュートノードのみ対象 true/false
MyNetworkSecurityGroup=${VMPREFIX}-nsg
# MACアドレスを維持するためにNICを保存するかどうかの設定
STATICMAC=false #true or false

### ユーザ設定
IMAGE="OpenLogic:CentOS-HPC:7_8:latest" #Azure URNフォーマット。OpenLogic:CentOS-HPC:8_1:latest
USERNAME=azureuser # ユーザ名: デフォルト azureuser
SSHKEYFILE="./${VMPREFIX}.pub" # SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
TAG=${VMPREFIX}=$(date "+%Y%m%d")

# 追加の永続ディスクが必要な場合、ディスクサイズ(GB)を記入する https://azure.microsoft.com/en-us/pricing/details/managed-disks/
PERMANENTDISK=0
PBSPERMANENTDISK=2048

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理(az login)を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
#az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# デバックオプション: DEBUG="parallel -v"
# コマンド名取得
CMDNAME=$(basename "$0")
# コマンドオプションエラー処理
if [ $# -eq 0 ]; then
	echo "実行するには1,2,3個の引数が必要です。" 1>&2
	echo "create,delete,start,stop,stop-all,stopvm #,stopvm #1 #2,startvm #1,list,remount,pingpong,addlogin,updatensg,privatenw,publicnw の引数を一つ指定する必要があります。" 1>&2
	echo "0. updatensg コマンド: スクリプト実行ノードのグローバルIPを利用してセキュリティグループを設定します。" 1>&2
	echo "1. create コマンド: コンピュートノードを作成します。" 1>&2
	echo "2. addlogin コマンド: login, PBSノードを作成します。" 1>&2
	echo "3. privatenw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを除きます" 1>&2
	echo "その他のコマンド"  1>&2
	echo " - stop: すべてのコンピュートノードを停止します。" 1>&2
	echo " - stop-all: すべてのコンピュートノード＋PBSノード・ログインノードもすべて停止します。" 1>&2
	echo " - stopvm <vm#>: コンピュートノードVM#のみを停止します。" 1>&2
	echo " - stopvms <start vm#> <end vm#>: コンピュートノードVM# xからVM# yまで停止します。" 1>&2
	echo " - startvm <vm#>: コンピュートノードVM#を起動します。" 1>&2
	echo " - list: VMの状況・およびマウンド状態を表示します。"  1>&2
	echo " - listip: IPアドレスアサインの状態を表示します。"  1>&2
	echo " - pingpong: すべてのノード間でpingpongを取得します。ローカルファイル result に保存します。" 1>&2
	echo " - remount: デフォルトで設定されているディレクトリの再マウントを実施します。" 1>&2
	echo " - publicnw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを再度追加します。" 1>&2
	echo " - delete: すべてのコンピュートノードを削除します。" 1>&2
	echo " - delete-all: すべてのコンピュートノード、PBSノード、ログインノードを削除します。" 1>&2
	echo " - deletevm <vm#>: 特定のコンピュートノード#のみを削除します。(PBSの設定削除などは未実装)" 1>&2
	echo " - checkfiles: ローカルで利用するスクリプトを生成します。" 1>&2
	echo " - ssh: 各VMにアクセスできます。 例：$CMDNAME ssh 1: コンピュートノード#1にSSHアクセスします。" 1>&2
	exit 1
fi
# SSH鍵チェック。なければ作成
if [ ! -f "./${VMPREFIX}" ] || [ ! -f "./${VMPREFIX}.pub" ] ; then
	ssh-keygen -f ./${VMPREFIX} -m pem -t rsa -N "" -b 4096
else
	chmod 600 ./${VMPREFIX}
fi
# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	* )
		cp ./${VMPREFIX} "$HOME"/.ssh/
		chmod 600 "$HOME"/.ssh/${VMPREFIX}
		SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
	;;
esac
# github actions向けスペース
echo "SSHKEYDIR: $SSHKEYDIR"

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
curl -s https://ipinfo.io/ip >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
# 空行削除
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(head -n 1 ./tmpip)/32"
rm ./tmpip
echo "current your client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"

# 必要なパッケージ： GNU parallel, jq, curlのインストール。別途、azコマンドも必須
if   [ -e /etc/debian_version ] || [ -e /etc/debian_release ]; then
    # Check Ubuntu or Debian
    if [ -e /etc/lsb-release ]; then echo "your linux distribution is: ubuntu";
		sudo apt-get install -qq -y parallel jq curl || apt-get install -qq -y parallel jq curl
    else echo "your linux distribution is: debian";
		if [[ $(hostname) =~ [a-z]*-*-*-* ]]; then echo "skipping...due to azure cloud shell";
		else sudo apt-get install -qq -y parallel jq curl || apt-get install -qq -y parallel jq curl; fi
	fi
elif [ -e /etc/fedora-release ]; then echo "your linux distribution is: fedora";
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
elif [ -e /etc/redhat-release ]; then echo "your linux distribution is: Redhat or CentOS"; 
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
fi

function getipaddresslist () {
	# $1: vmlist
	# $2: ipaddresslist
	# $3: nodelist
	# list-ip-addresses 作成
	if [ -f ./vmlist ]; then rm ./vmlist; fi
	if [ -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
	if [ -f ./nodelist ]; then rm ./nodelist; fi
	echo "creating vmlist and ipaddresslist"
	az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name, PublicIp:network.publicIpAddresses[0].ipAddress, PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmpfile
	for count in $(seq 1 10); do
		if [ -s tmpfile ]; then
			break
		else
			az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name, PublicIp:network.publicIpAddresses[0].ipAddress, PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmpfile
			echo "getting list-ip-addresse... sleep 4" && sleep 4
		fi
	done
	# pbs, loging, cyclecloud など削除
	grep "${VMPREFIX}-[1-99]" ./tmpfile > ./tmpfile2
	# 自然番号順にソート
	sort -V ./tmpfile2 > tmpfile3
	echo "az vm list-ip-addresses..."
	cat ./tmpfile3

	# Check num of parameters.
    if [ $# -gt 4 ]; then echo "error!. you can use 3 parameters."; exit 1; fi

	if [ "$1" = "vmlist" ]; then
		# vmlist 作成: $1
		echo "creating vmlist"
		cut -f 1 ./tmpfile3 > vmlist
		# vmlist チェック
		numvm=$(cat ./vmlist | wc -l)
		if [ $((numvm)) -eq $((MAXVM)) ]; then
			echo "number of vmlist and maxvm are matched."
		else
			echo "number of vmlist and maxvm are unmatched!"
		fi
	fi

	if [ "$2" = "ipaddresslist" ]; then
		# ipaddresslist 作成: $2
		echo "careating IP Address list"
		cut -f 2 ./tmpfile3 > ipaddresslist
		echo "ipaddresslist file contents"
		cat ./ipaddresslist
		numip=$(cat ./ipaddresslist | wc -l)
		# ipaddresslist チェック
		if [ $((numip)) -eq $((MAXVM)) ]; then
			echo "number of ipaddresslist and maxvm are matched."
		else
			echo "number of ipaddresslist and maxvm are unmatched!"
		fi
	fi

	if [ $# -eq 3 ] && [ "$3" = "nodelist" ]; then
		# nodelist 作成: $3
		echo "careating nodelist"
		cut -f 3 ./tmpfile3 > nodelist
		echo "nodelist file contents"
		cat ./nodelist
		numnd=$(cat ./nodelist | wc -l)
		# nodelist チェック
		if [ $((numnd)) -eq $((MAXVM)) ]; then
			echo "number of nodelist and maxvm are matched."
		else
			echo "number of nodelist and maxvm are unmatched!"
		fi
	fi

	# テンポラリファイル削除
	rm ./tmpfile
	rm ./tmpfile2
	rm ./tmpfile3
}

function mountdirectory () {
	# $1: vm: vm1 or pbs
	# $2: directory: /mnt/resource/scrach or /mnt/share
	# requirement, ipaddresslist
	# case1: vm1, /mnt/resource/scratch, case2: pbs /mnt/share
	directory="$2"
	if [ "$1" = vm1 ] && [ -z "$2" ]; then
		directory="/mnt/resource/scratch"
	fi
	if [ "$1" = pbs ] && [ -z "$2" ]; then
		directory="/mnt/share"
	fi
	echo "directory: $directory"
	if [ ! -f ./ipaddresslist ]; then 
		echo "error!. ./ipaddresslist is not found!"
		getipaddresslist vmlist ipaddresslist nodelist
	fi 
	case $1 in
		vm1 )
			# コマンド実行判断
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
			echo "${VMPREFIX}-1's IP: $vm1ip"
			# コンピュートノードVM#1：マウント用プライベートIP 
			mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
			echo "checking ssh access for vm1..."
			for count in $(seq 1 10); do
				checkssh=(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${vm1ip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				else
					checkssh=(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${vm1ip}" "uname")
					echo "getting ssh connection. sleep 2" && sleep 2
				fi	
			done
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-1: $vm1ip - mount setting by ssh"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" "sudo mkdir -p ${directory}"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" "sudo chown $USERNAME:$USERNAME ${directory}"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" 'sudo showmount -e'
				# 1行目を削除したIPアドレスリストを作成
				sed '1d' ./ipaddresslist > ./ipaddresslist-tmp
				echo "${VMPREFIX}-2 to $MAXVM: mounting"
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mkdir -p ${directory}""
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME ${directory}""
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:${directory} ${directory}""
				echo "current mounting status"
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "df -h | grep ${directory}""
				rm ./ipaddresslist-tmp
			else
				echo "vm1: mount setting by az vm run-command"
				for count in $(seq 2 $MAXVM) ; do
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo mount -t nfs ${mountip}:${directory} ${directory}" 
					echo "sleep 60" && sleep 60
				done
			fi
		;;
		pbs )
			# PBSノード：展開済みかチェック: pbsvmname=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query name -o tsv)
			pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
			# PBSノード：マウントプライベートIP
			pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
			echo "checking ssh access for pbs..."
			for count in $(seq 1 10); do
				checkssh=(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${pbsvmip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				else
					checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${pbsvmip}" "uname")
					echo "getting ssh connection. sleep 2" && sleep 2
				fi
			done
			if [ -n "$checkssh" ]; then
				echo "pbsnode: mount setting by ssh"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mkdir -p ${directory}""
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME ${directory}""
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mount -t nfs ${pbsmountip}:${directory} ${directory}""
				echo "current mounting status"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "df -h | grep ${directory}""
			else
				echo "pbsnode: mount setting by az vm run-command"
				for count in $(seq 1 $MAXVM) ; do
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo mount -t nfs ${pbsmountip}:${directory} ${directory}"
					echo "sleep 60" && sleep 60
				done
			fi
		;;
	esac
}

function checksshconnection () {
	# $1: vm1, pbs, all
	# requirement, ipaddresslist
	# usecase: connected - Linux or, disconnected - nothing
	case $1 in
		vm1 )
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
			for cnt in $(seq 1 10); do
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				fi
				echo "waiting sshd @ ${VMPREFIX}-${vm1ip}: sleep 5" && sleep 5
			done
		;;
		pbs )
			pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
			for cnt in $(seq 1 10); do
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				fi
				echo "waiting sshd @ ${VMPREFIX}-${vm1ip}: sleep 5" && sleep 5
			done
		;;
		all )
			if [ -f ./checksshtmp ]; then rm ./checksshtmp; fi
			for count in $(seq 1 $MAXVM); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				for cnt in $(seq 1 10); do
					checksshtmp=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${line}" "uname")
					if [ -n "${checksshtmp}" ]; then
						echo "${checksshtmp}" >> checksshtmp
						break
					fi
					echo "waiting ssh connection @ ${VMPREFIX}-${count}: sleep 5" && sleep 5
				done
			done
		;;
	esac
}

function basicsettings () {
	# 作成中。。。
	# $1: vm1, pbs, login, all
	# requirement, ipaddresslist
	# locale, sudo, passwordless, ssh config
	case $1 in
		vm1 )
			echo "vm1: all basic settings...."
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
			if [ -z "$locale" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
			else
				echo "LC_ALL=C has arelady setting"
			fi
			# コンピュートノード：パスワードレス設定
			echo "コンピュートノード: confugring passwordless settings"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/${VMPREFIX}
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/id_rsa
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
			# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		;;
		pbs )
			echo "pbs: all basic settings...."
			pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
			if [ -z "$locale" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
			else
				echo "LC_ALL=C has arelady setting"
			fi
			# PBSノード：sudo設定
			echo "PBSノード: sudo 設定"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			sudotmp=$(cat ./sudotmp)
			if [ -z "$sudotmp" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
			fi
			unset sudotmp && rm ./sudotmp
			# PBSノード：パスワードレス設定
			echo "PBSノード: confugring passwordless settings"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/${VMPREFIX}
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/id_rsa
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
			# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		;;
		login )
			echo "login vm: all basic settings...."
			loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
			if [ -z "$locale" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
			else
				echo "LC_ALL=C has arelady setting"
			fi
			# ログインノード：パスワードレス設定
			echo "ログインノード: confugring passwordless settings"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/${VMPREFIX}
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/id_rsa
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
			# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		;;
		all )
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			for count in $(seq 1 $MAXVM); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
				if [ -z "$locale" ]; then
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
				else
					echo "LC_ALL=C has arelady setting"
				fi
			done
			echo "${VMPREFIX}-1 to ${MAXVM}: sudo 設定"
			for count in $(seq 1 $((MAXVM))); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
				if [ -z "$sudotmp" ]; then
					echo "sudo: setting by ssh command"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo grep $USERNAME /etc/sudoers"
					unset sudotmp && rm ./sudotmp
				else
					echo "sudo: setting by run-command"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "echo '$USERNAME ALL=NOPASSWD: ALL' | sudo tee -a /etc/sudoers"
				fi
			done
			for count in $(seq 1 $((MAXVM))); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				# コンピュートノード：パスワードレス設定
				echo "コンピュートノード: confugring passwordless settings"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${line}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${line}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${line}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
				# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${line}":/home/$USERNAME/.ssh/config
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
			done
		;;
	esac
}

case $1 in
	create )
		# 全体環境作成
		az group create --resource-group $MyResourceGroup --location $Location --tags "$TAG" --output none
		# ネットワークチェック
		tmpnetwork=$(az network vnet show -g $MyResourceGroup --name $MyNetwork --query id)
		echo "current netowrk id: $tmpnetwork"
		if [ -z "$tmpnetwork" ] ; then
			az network vnet create -g $MyResourceGroup -n $MyNetwork --address-prefix 10.0.0.0/22 --subnet-name $MySubNetwork --subnet-prefix 10.0.0.0/24 --output none
		fi
		# NSGがあるかどうかチェック
		checknsg=$(az network nsg show --name $MyNetworkSecurityGroup -g $MyResourceGroup --query name -o tsv)
		if [ -z "$checknsg" ]; then
			# 既存NSGがなければ作成
			az network nsg create --name $MyNetworkSecurityGroup -g $MyResourceGroup -l $Location --tags "$TAG" --output none
			az network nsg rule create --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
			az network nsg rule create --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
		else
			# NSGがあれば、アップデート
			az network nsg rule create --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
			az network nsg rule create --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
		fi

		# 可用性セットの処理
		checkavset=$(az vm availability-set list-sizes --name ${VMPREFIX}avset01 -g $MyResourceGroup -o tsv | head -n 1 | cut -f 3)
		if [ -z "$checkavset" ]; then
			az vm availability-set create --name $MyAvailabilitySet -g $MyResourceGroup -l $Location --tags "$TAG" --output none
		else
			echo "checkavset : $checkavset - current cluster vmsize or no assignment or general sku."
			echo "your VMSIZE: $VMSIZE"
			# ${VMPREFIX}avset01: 同じVMサイズの場合、可用性セットを利用する
			if [ ${VMSIZE} = "$checkavset" ]; then
				# 既に avset01 が利用済みの場合で VMSIZE が異なれば、以下実行
				echo "use same avset: ${VMPREFIX}avset01"
				MyAvailabilitySet="${VMPREFIX}avset01"
			else
				# 可用性セット 1+2~10, 10クラスタ想定
				for count in $(seq 2 10); do
					checkavsetnext=$(az vm availability-set list-sizes --name ${VMPREFIX}avset0"${count}" -g $MyResourceGroup -o tsv | wc -l)
					# 0 の場合、この可用性セットは利用されていない
					if [ $((checkavsetnext)) -eq 0 ]; then
						echo "${VMPREFIX}avset0${count} is nothing. assining a new avaiability set: ${VMPREFIX}avset0${count}"
						MyAvailabilitySet="${VMPREFIX}avset0${count}"
						az vm availability-set create --name "$MyAvailabilitySet" -g $MyResourceGroup -l $Location --tags "$TAG" --output none
						break
					# 1 の場合、可用性セットは利用中
					elif [ $((checkavsetnext)) -eq 1 ]; then
						echo "${VMPREFIX}avset0${count} has already used."
					# 多数 の場合、一般SKUを利用。利用中か不明だが、既存可用性セットとして再利用可能
					elif [ $((checkavsetnext)) -gt 5 ]; then
						# check avset: ${VMPREFIX}avset01
						checkavset2=$(az vm availability-set list-sizes --name ${VMPREFIX}avset01 -g $MyResourceGroup -o tsv | cut -f 3 | wc -l)
						if [ $((checkavset2)) -gt 5 ]; then
							echo "use existing availalibty set: ${VMPREFIX}avset01"
							MyAvailabilitySet=${VMPREFIX}avset01
							break
						else
							echo "${VMPREFIX}avset0${count} is belong to general sku."
							MyAvailabilitySet="${VMPREFIX}avset0${count}"
							az vm availability-set create --name "$MyAvailabilitySet" -g $MyResourceGroup -l $Location --tags "$TAG" --output none
							break
						fi
					fi
					# 未使用の場合、すべてのサイズがリストされる. ex. 379　この可用性セットは利用可能
				done
			fi
		fi

		# VM作成
		for count in $(seq 1 $MAXVM); do
			# echo "creating nic # $count"
			if [ ${STATICMAC} = "true" ]; then
				az network nic create --name ${VMPREFIX}-"${count}"VMNic --resource-group $MyResourceGroup --vnet-name $MyNetwork --subnet $MySubNetwork --network-security --accelerated-networking true
				echo "creating VM # ${count} with static nic"
				# $ACCELERATEDNETWORKING: にはダブルクォーテーションはつけない
				az vm create -g $MyResourceGroup -l $Location --name ${VMPREFIX}-"${count}" --size $VMSIZE --availability-set "$MyAvailabilitySet" --nics ${VMPREFIX}-"${count}"VMNic --image $IMAGE --admin-username $USERNAME --ssh-key-values $SSHKEYFILE --no-wait --tags "$TAG" -o none
			fi
			echo "creating VM # $count with availability set: $MyAvailabilitySet"
			# $ACCELERATEDNETWORKING: にはダブルクォーテーションはつけない
			az vm create \
				--resource-group $MyResourceGroup --location $Location \
				--name ${VMPREFIX}-"${count}" \
				--size $VMSIZE --availability-set "$MyAvailabilitySet" \
				--vnet-name $MyNetwork --subnet $MySubNetwork \
				--nsg $MyNetworkSecurityGroup --nsg-rule SSH $ACCELERATEDNETWORKING \
				--image $IMAGE \
				--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
				--no-wait --tags "$TAG" -o table
		done

		# 永続ディスクが必要な場合に設定可能
		if [ $((PERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-1 --name ${VMPREFIX}-1-disk0 -o table
		fi

		# IPアドレスが取得できるまで停止する
		if [ $((MAXVM)) -ge 20 ]; then
			echo "sleep 180" && sleep 180
		else
			echo "sleep 90" && sleep 90
		fi

		# vmlist and ipaddress 作成
		getipaddresslist vmlist ipaddresslist

		checksshconnection all

		# all computenodes: basicsettings - locale, sudo, passwordless, sshd
		basicsettings all

		# fstab設定
		echo "setting fstab"
		mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -otsv)
		if [ ! -s ./checkfstab ]; then 
			for count in $(seq 1 $MAXVM); do
				checkssh=$(sed -n "${count}"P ./checksshtmp)
				if [ -n "$checkssh" ]; then
					echo "${VMPREFIX}-${count}: configuring fstab by ssh"
					line=$(sed -n "${count}"P ./ipaddresslist)
					#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@${line} -t -t "sudo sed -i -e '/azure_resource-part1/d' /etc/fstab"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t 'sudo umount /dev/disk/cloud/azure_resource-part1'
					# 重複していないかチェック
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo grep ${mountip}:/mnt/resource/scratch /etc/fstab" > checkfstab
					checkfstab=$(cat checkfstab | wc -l)
					if [ $((checkfstab)) -ge 2 ]; then 
						echo "deleting dupulicated settings...."
						#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e '/${mountip}:\/mnt\/resource/d' /etc/fstab"
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab"
					elif [ $((checkfstab)) -eq 1 ]; then
						echo "correct fstab setting"
					elif [ $((checkfstab)) -eq 0 ]; then
						echo "fstab missing: no /mnt/resource/scratch here!"
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab"
					fi
				else
					# fstab 設定: az vm run-command
					echo "${VMPREFIX}-${count}: configuring fstab by az vm run-command"
					#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo sed -i -e '/azure_resource-part1/d' /etc/fstab"
					#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts 'sudo umount /dev/disk/cloud/azure_resource-part1'
					# 重複していないかチェック
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo grep "${mountip}:/mnt/resource/scratch" /etc/fstab" > checkfstab
					checkfstab=$(cat checkfstab | wc -l)
					if [ $((checkfstab)) -ge 2 ]; then
						echo "deleting dupulicated settings...."
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript \
							--scripts "sudo sed -i -e '/${mountip}:\/mnt\/resource/d' /etc/fstab"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript \
							--scripts "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab"
					elif [ $((checkfstab)) -eq 1 ]; then
						echo "correct fstab setting"
					elif [ $((checkfstab)) -eq 0 ]; then
						echo "fstab missing: no /mnt/resource/scratch here!"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript \
							--scripts "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab"
					fi
				fi
			done
		fi

		echo "setting up nfs server"
		vm1ip=$(head -n 1 ./ipaddresslist)
		for count in $(seq 1 15); do
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
			if [ -n "$checkssh" ]; then
				break
			fi
			echo "waiting sshd @ ${VMPREFIX}-1: sleep 10" && sleep 10
		done
		echo "checkssh connectiblity for ${VMPREFIX}-1: $checkssh"
		if [ -z "$checkssh" ]; then
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
				--scripts "sudo yum install --quiet -y nfs-utils epel-release && echo '/mnt/resource/scratch *(rw,no_root_squash,async)' >> /etc/exports"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo yum install --quiet -y htop"
			sleep 5
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource/scratch"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo chown ${USERNAME}:${USERNAME} /mnt/resource/scratch"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
			#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
		else
			# SSH設定が高速なため、checkssh が有効な場合、SSHで実施
			echo "${VMPREFIX}-1: sudo 設定"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			if [ -z "$sudotmp" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
			fi
			unset sudotmp && rm ./sudotmp
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo yum install --quiet -y nfs-utils epel-release"
			# アフターインストール：epel-release
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo yum install --quiet -y htop"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo '/mnt/resource/scratch *(rw,no_root_squash,async)' | sudo tee /etc/exports"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo mkdir -p /mnt/resource/scratch"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo chown ${USERNAME}:${USERNAME} /mnt/resource/scratch"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
			#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo showmount -e"
		fi

		# 高速化のためにSSHで一括設定しておく
		echo "ssh parallel settings: nfs client"
		# 1行目を削除したIPアドレスリストを作成
		sed '1d' ./ipaddresslist > ./ipaddresslist-tmp
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y nfs-utils epel-release""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y htop""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource/scratch""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource/scratch""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount -t nfs ${mountip}:/mnt/resource/scratch /mnt/resource/scratch""
		rm ./ipaddresslist-tmp

		# NFSサーバ・マウント設定
		echo "${VMPREFIX}-2 to ${MAXVM}: mouting VM#1"
		mountdirectory vm1
		echo "${VMPREFIX}-2 to ${MAXVM}: end of mouting ${mountip}:/mnt/resource/scratch"

		# ホストファイル事前バックアップ（PBSノード追加設定向け）
		echo "backup original hosts file"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} "sudo cp /etc/hosts /etc/hosts.original""

		# PBSノードがなければ終了
		if [ -z "$pbsvmname" ]; then
			echo "no PBS node here!"
			exit 0
		fi

### ===========================================================================
		# PBSノード：マウント設定
		echo "pbsnode: nfs server @ ${VMPREFIX}-pbs"
		mountdirectory pbs
		echo "${VMPREFIX}-1 to ${MAXVM}: end of mouting ${pbsmountip}:/mnt/share"

		# PBSノードがある場合にのみ、ホストファイル作成
		# ホストファイル作成準備：既存ファイル削除
		if [ -f ./vmlist ]; then rm ./vmlist; echo "recreating a new vmlist"; fi
		if [ -f ./hostsfile ]; then rm ./hostsfile; echo "recreating a new hostsfile"; fi
		if [ -f ./nodelist ]; then rm ./nodelist; echo "recreating a new nodelist"; fi
		# ホストファイル作成
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmphostsfile
		# 自然な順番でソートする
		sort -V ./tmphostsfile > hostsfile
		# vmlist 取り出し：1列目
		cut -f 1 ./hostsfile > vmlist
		# nodelist 取り出し：2列目
		cut -f 2 ./hostsfile > nodelist
		# ダブルクォーテーション削除: sed -i -e "s/\"//g" ./tmphostsfile
		# ファイルの重複行削除。列は2列まで想定: cat  ./tmphostsfile2 | awk '!colname[$1]++{print $1, "\t", $2}' > ./hostsfile
		echo "show current hostsfile"
		cat ./hostsfile
		# テンポラリファイル削除
		rm ./tmphostsfile

		# PBSノード：ホストファイル転送・更新
		checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
		if [ -n "$checkssh" ]; then
			# ssh成功すれば実施
			echo "${VMPREFIX}-pbs: updating hosts file by ssh"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "rm /home/$USERNAME/hostsfile"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${pbsvmip}":/home/$USERNAME/
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /etc/hosts.original /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
		else
			# SSH失敗した場合、az vm run-commandでのホストファイル転送・更新
			echo "${VMPREFIX}-pbs: updating hosts file by az vm running command"
			# ログインノードIPアドレス取得：空なら再取得
			loginvmip=$(cat ./loginvmip)
			if [ -n "$loginvmip" ]; then
				loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
			fi
			echo "loginvmip: $loginvmip"
			echo "PBSノード: ssh: ホストファイル転送 local to login node"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "rm /home/$USERNAME/hostsfile"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${loginvmip}":/home/$USERNAME/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/${VMPREFIX}
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/${VMPREFIX}"
			echo "PBSノード: ssh: ホストファイル転送 ログインノード to PBSノード"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "scp -o StrictHostKeyChecking=no -i /home/$USERNAME/${VMPREFIX} $USERNAME@${loginprivateip}:/home/$USERNAME/hostsfile /home/$USERNAME/"
			echo "PBSノード: az: ホストファイル更新"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "sudo cp /etc/hosts.original /etc/hosts"
			# az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "cat /etc/hosts"
		fi
		# コンピュートノード：ホストファイル転送・更新
		echo "copy hostsfile to all compute nodes"
		count=0
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			# ログインノードへのSSHアクセスチェック
			loginvmip=$(cat ./loginvmip)
			if [ -n "$loginvmip" ]; then
				loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
			fi
			echo "loginvmip: $loginvmip"
			# コンピュートノードへの直接SSHアクセスチェック
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "uname")
			echo "checkssh: $checkssh"
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-1 to ${MAXVM}: updating hostsfile by ssh(direct)"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/hostsfile"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${line}":/home/$USERNAME/
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /etc/hosts.original /etc/hosts"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /home/$USERNAME/hostsfile /etc/hosts"
				echo "${VMPREFIX}-${count}: show new hosts file"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
			else
				# ログインノード経由で設定
				checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "uname")
				if [ -n "$checkssh2" ]; then
					echo "${VMPREFIX}-1 to ${MAXVM}: updating hostsfile by ssh(via login node)"
					# 多段SSH
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "rm /home/$USERNAME/hostsfile""
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./hostsfile $USERNAME@${line}:/home/$USERNAME/"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cp /etc/hosts.original /etc/hosts""
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cp /home/$USERNAME/hostsfile /etc/hosts""
					echo "${VMPREFIX}-${count}: show new hosts file"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}""
				else
					# SSHできないため、az vm run-commandでのホストファイル転送・更新
					echo "${VMPREFIX}-${count}: updating hosts file by az vm running command"
					# ログインノードIPアドレス取得：取得済み
					echo "loginvmip: $loginvmip"
					echo "ローカル: ssh: ホストファイル転送 transfer login node"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "rm /home/$USERNAME/hostsfile"
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${loginvmip}":/home/$USERNAME/
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/${VMPREFIX}"
					# ログインプライベートIPアドレス取得：すでに取得済み
					#loginprivateip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-login -d --query privateIps -o tsv)
					for count2 in $(seq 1 $MAXVM); do
						# ログインノードへはホストファイル転送済み
						echo "コンピュートノード： az: ホストファイル転送 login to compute node"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "scp -o StrictHostKeyChecking=no -i /home/$USERNAME/${VMPREFIX} $USERNAME@${loginprivateip}:/home/$USERNAME/hostsfile /home/$USERNAME/"
						echo "コンピュートノード： az: ホストファイル更新"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cp /etc/hosts.original /etc/hosts"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cp /home/$USERNAME/hostsfile /etc/hosts"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cat /etc/hosts"
					done
				fi
			fi
		done
		# ホストファイル更新完了
		echo "end of hostsfile update"
		# 追加ノードのPBS設定：実装済み。追加の場合、ダイレクトSSHが必須
### ===========================================================================
		# ローカルにopenPBSファイルがあるのは前提
		# PBSノード：openPBSクライアントコピー
		echo "copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
		parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
		# ダウンロード、およびMD5チェック
		count=0
		if [ -f ./md5executionremote ]; then rm ./md5executionremote; fi
		if [ -f ./md5executionremote2 ]; then rm ./md5executionremote2; fi
		# CentOS バージョンチェック
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /etc/redhat-release" > centosversion
		centosversion=$(cat -d " " -f 4)
		# CentOS 7.x か 8.xか判別する
		case $centosversion in
			7.?.???? )
				# CentOS 7.xの場合
				for count in $(seq 1 $MAXVM); do
					line=$(sed -n "${count}"P ./ipaddresslist)
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
					md5executionremote=$(cat ./md5executionremote)
					echo "md5executionremote: $md5executionremote"
				for cnt in $(seq 1 3); do
					if [ "$md5executionremote" == "$md5execution" ]; then
					# 固定ではうまくいかない
					# if [ "$md5executionremote" != "59f5110564c73e4886afd579364a4110" ]; then
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
						scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@"${line}":/home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
						md5executionremote=$(cat ./md5executionremote)
						echo "md5executionremote: $md5executionremote"
						echo "md5executionremote2: $md5executionremote2"
						for cnt2 in $(seq 1 3); do
							echo "checking md5...: $cnt2"
							if [ "$md5executionremote2" != "$md5execution" ]; then
							# 固定ではうまくいかない
							# if [ "$md5executionremote2" != "59f5110564c73e4886afd579364a4110" ]; then
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /tmp/openpbs-execution-20.0.1-0.x86_64.rpm  | cut -d ' ' -f 1" > md5executionremote2
								md5executionremote2=$(cat ./md5executionremote2)
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "cp /tmp/openpbs-execution-20.0.1-0.x86_64.rpm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
								echo "md5executionremote2: $md5executionremote2"
							else
								echo "match md5 by md5executionremote2"
								md5executionremote2=$(cat ./md5executionremote2)
								break
							fi
						done
				else
					echo "match md5 by md5executionremote"
					md5executionremote=$(cat ./md5executionremote)
					break
				fi
			done
		done
			;;
			8.?.???? )
				echo "skip check md5"
			;;
		esac
		rm ./centosversion
		rm ./md5executionremote
		rm ./md5executionremote2
		# openPBSクライアント：インストール
		echo "confuguring all compute nodes"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo yum install --quiet -y hwloc-libs libICE libSM'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo yum install --quiet -y libnl3'"
		echo "installing libnl3"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo rpm -aq | grep openpbs'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /opt/pbs/libexec/pbs_habitat'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /opt/pbs/libexec/pbs_postinstall'"
		# pbs.confファイル生成
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo cat /etc/pbs.conf""
		# openPBSクライアント：パーミッション設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo chmod 4755 /opt/pbs/sbin/pbs_iff'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo chmod 4755 /opt/pbs/sbin/pbs_rcp'"
		# openPBSクライアント：/var/spool/pbs/mom_priv/config コンフィグ設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config""
		for count in $(seq 1 $MAXVM) ; do
			line=$(sed -n "${count}"P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config"
		done
### ===========================================================================
		# PBSプロセス起動
		# PBSノード起動＆$USERNAME環境変数設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "yes | sudo /etc/init.d/pbs start"
		fi
		# openPBSクライアントノード起動＆$USERNAME環境変数設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /etc/init.d/pbs start'"
		vm1ip=$(head -n 1 ./ipaddresslist)
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'echo 'source /etc/profile.d/pbs.sh' >> $HOME/.bashrc'"
		fi
		rm ./pbssh
		echo "finished to set up additonal login and PBS node"
### ===========================================================================
		# PBSジョブスケジューラセッティング
		echo "configpuring PBS settings"
		rm ./setuppbs.sh
		for count in $(seq 1 $MAXVM); do
			echo "/opt/pbs/bin/qmgr -c "create node ${VMPREFIX}-${count}"" >> setuppbs.sh
		done
		sed -i -e "s/-c /-c '/g" setuppbs.sh
		sed -i -e "s/$/\'/g" setuppbs.sh
		echo "setuppbs.sh: $(cat ./setuppbs.sh)"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./setuppbs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/setuppbs.sh
		# SSH鍵登録
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
		# ジョブスケジューラセッティング
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/setuppbs.sh"
		rm ./setuppbs.sh
	;;
#### ==========================================================================
#### ==========================================================================
	# ログインノード、PBSノードを作成します。
	addlogin )
		# 既存ネットワークチェック
		tmpsubnetwork=$(az network vnet subnet show -g $MyResourceGroup --name $MySubNetwork2 --vnet-name $MyNetwork --query id)
		echo "current subnetowrk id: $tmpsubnetwork"
		if [ -z "$tmpsubnetwork" ]; then
			# mgmtサブネット追加
			az network vnet subnet create -g $MyResourceGroup --vnet-name $MyNetwork -n $MySubNetwork2 --address-prefixes 10.0.1.0/24 --network-security-group $MyNetworkSecurityGroup -o table
		fi
		# ログインノード作成
		echo "========================== creating login node =========================="
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-login \
			--size Standard_D2a_v4 \
			--vnet-name $MyNetwork --subnet $MySubNetwork2 \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
			--public-ip-address-allocation static \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags "$TAG" -o table
		# PBSジョブスケジューラノード作成
		echo "========================== creating PBS node ============================"
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-pbs \
			--size $PBSVMSIZE \
			--vnet-name $MyNetwork --subnet $MySubNetwork \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH $ACCELERATEDNETWORKING \
			--public-ip-address-allocation static \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags "$TAG" -o table

		# LoginノードIPアドレス取得
		loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
		echo "$loginvmip" > ./loginvmip
		# PBSノードIPアドレス取得
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		echo "$pbsvmip" > ./pbsvmip
		# 永続ディスクが必要な場合に設定可能
		if [ $((PBSPERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PBSPERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-pbs --name ${VMPREFIX}-pbs-disk0 -o table || \
				az vm disk attach -g $MyResourceGroup --vm-name ${VMPREFIX}-pbs --name ${VMPREFIX}-pbs-disk0 -o table
		fi

		# all computenodes: basicsettings - locale, sudo, passwordless, sshd
		basicsettings pbs

		# PBSノード：ディスクフォーマット
		echo "pbsnode: /dev/sdc disk formatting"
		diskformat=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdc1")
		echo "diskformat: $diskformat"
		# リモートの /dev/sdc が存在する
		diskformat2=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdc")
		echo "diskformat2: $diskformat2"
		if [ -n "$diskformat2" ]; then
			# かつ、 /dev/sdc1 が存在しない場合のみ実施
			diskformat3=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdc1")
			if [[ $diskformat3 != "/dev/sdc1" ]]; then
				# /dev/sdc1が存在しない (not 0)場合のみ実施
				# リモートの /dev/sdc が未フォーマットであるか
				disktype1=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdc | grep 'Disk label type'")
				disktype2=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdc | grep 'Disk identifier'")
				# どちらも存在しない場合、フォーマット処理
				if [[ -z "$disktype1" ]] || [[ -z "$disktype2" ]] ; then 
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkfs.xfs /dev/sdc1"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo partprobe /dev/sdc1"
					echo "pbsnode: fromatted a new disk."
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdc1"
				fi
			else
				echo "your pbs node has not the device."
			fi
		fi
		unset diskformat && unset diskformat2 && unset diskformat3

		# fstab設定
		echo "pbsnode: setting fstab"
		#pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		for count in $(seq 1 10); do
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
			if [ -n "$checkssh" ]; then
				break
			fi
			echo "waiting sshd @ ${VMPREFIX}-${count}: sleep 10" && sleep 10
		done
		if [ -n "$checkssh" ]; then
			# 重複していないかチェック
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo grep '/dev/sdc1' /etc/fstab" > checkfstabpbs
			checkfstabpbs=$(cat checkfstabpbs | wc -l)
			if [ $((checkfstabpbs)) -ge 2 ]; then 
				echo "pbsnode: deleting dupulicated settings...."
				#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e '/\/dev/sdc1    \/mnt\/share/d' /etc/fstab"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			elif [ $((checkfstabpbs)) -eq 1 ]; then
				echo "pbsnode: correct fstab setting"
			elif [ $((checkfstabpbs)) -eq 0 ]; then
				echo "pbsnode: fstab missing - no /dev/sdc1 here!"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			fi
		else
			# fstab 設定: az vm run-command
			echo "pbsnode: configuring fstab by az vm run-command"
			# 重複していないかチェック
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo grep /dev/sdc1 /etc/fstab" > checkfstabpbs
			checkfstabpbs=$(cat checkfstabpbs | wc -l)
			if [ $((checkfstabpbs)) -ge 2 ]; then 
				echo "pbsnode: deleting dupulicated settings...."
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo sed -i -e '/\/dev/sdc1    \/mnt\/share/d' /etc/fstab"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			elif [ $((checkfstabpbs)) -eq 1 ]; then
				echo "pbsnode: correct fstab setting"
			elif [ $((checkfstabpbs)) -eq 0 ]; then
				echo "pbsnode: fstab missing: no /mnt/share here!"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			fi
		fi
		rm ./checkfstabpbs

		# PBSノード：ディレクトリ設定
		echo "pbsnode: data directory setting"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkdir -p /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mount /dev/sdc1 /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chown $USERNAME:$USERNAME /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ls -la /mnt"
		# NFS設定
		echo "pbsnode: nfs server settings"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y nfs-utils epel-release"
		# アフターインストール：epel-release
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y md5sum htop"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo '/mnt/share *(rw,no_root_squash,async)' | sudo tee /etc/exports"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo showmount -e"

		# コンピュートノード：NFSマウント設定
		pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
		echo "pbsnode: mouting new directry on compute nodes: /mnt/share"
		mountdirectory pbs

		# ローカル：openPBSバイナリダウンロード
		# PBSノード：CentOS バージョンチェック
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /etc/redhat-release" > centosversion
		centosversion=$(cut -d " " -f 4 ./centosversion)
		# CentOS 7.x か 8.xか判別する
		case $centosversion in
			7.?.???? )
				# ローカル：CentOS 7.x openPBSバイナリダウンロード
				baseurl="https://github.com/hirtanak/scripts/releases/download/0.0.1"
				wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
				md5sum ./openpbs-server-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5server
				md5server=$(cat ./md5server)
				while [ ! "$md5server" = "6e7a7683699e735295dba6e87c6b9fd0" ]; do
					rm ./openpbs-server-20.0.1-0.x86_64.rpm
					wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
				done
				wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
				md5sum ./openpbs-client-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5client
				md5client=$(cat ./md5client)
				while [ ! "$md5client" = "7bcaf948e14c9a175da0bd78bdbde9eb" ]; do
					rm ./openpbs-client-20.0.1-0.x86_64.rpm
					wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
				done
				wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O ./openpbs-execution-20.0.1-0.x86_64.rpm
				md5sum ./openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5execution
				md5execution=$(cat ./md5execution)
				while [ ! "$md5execution" = "59f5110564c73e4886afd579364a4110" ]; do
					rm ./openpbs-client-20.0.1-0.x86_64.rpm
					wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
				done
			;;
			8.?.???? )
				# パッケージダウンロード
				wget https://github.com/openpbs/openpbs/releases/download/v20.0.1/openpbs_20.0.1.centos_8.zip -O ./openpbs_20.0.1.centos_8.zip
				unzip ./openpbs_20.0.1.centos_8.zip
				mv ./openpbs_20.0.1.centos_8/*.rpm ./
				rm -rf ./openpbs_20.0.1.centos_8
			;;
		esac
		rm ./centosversion
		if [ ! -f ./openpbs-server-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-client-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-execution-20.0.1-0.x86_64.rpm ]; then
			echo "file download error!. please download manually OpenPBS file in current diretory"
			echo "openPBSバイナリダウンロードエラー。githubにアクセスできないネットワーク環境の場合、カレントディレクトリにファイルをダウンロードする方法でも可能"
			exit 1
		fi

		# ホストファイル作成準備：既存ファイル削除
		if [ -f ./hostsfile ]; then rm ./hostsfile; echo "recreating a new hostfile"; fi
		if [ -f ./vmlist ]; then rm ./vmlist; echo "recreating a new vmlist"; fi
		if [ -f ./nodelist ]; then rm ./nodelist; echo "recreating a new nodelist"; fi
		# ホストファイル作成
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmphostsfile
		#,PublicIp:network.publicIpAddresses[0].ipAddress}
		# 自然な順番でソートする
		sort -V ./tmphostsfile > ./tmphostsfile2
		awk '{print $2, "\t", $1}' ./tmphostsfile2 > ./hostsfile
		# vmlist 取り出し：1列目
		cut -f 1 ./hostsfile > vmlist
		# nodelist 取り出し：2列目
		cut -f 2 ./hostfile > nodelist
		# ダブルクォーテーション削除: sed -i -e "s/\"//g" ./tmphostsfile
		# ファイルの重複行削除。列は2列まで想定: cat  ./tmphostsfile | awk '!colname[$1]++{print $1, "\t" ,$2}' > ./hostsfile
		echo "show current hostsfile"
		cat ./hostsfile
		# テンポラリファイル削除
		rm ./tmphostsfile
		rm ./tmphostsfile2

		# PBSノード：OpenPBSサーババイナリコピー＆インストール
		echo "copy openpbs-server-20.0.1-0.x86_64.rpm"
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# PBSノード：OpenPBSクライアントバイナリコピー＆インストール
		scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/

		# PBSノード：openPBS Requirement設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y expat libedit postgresql-server postgresql-contrib python3 sendmail sudo tcl tk libical"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y hwloc-libs libICE libSM"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ls -la /home/$USERNAME/"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm"

		# openPBSをビルドする場合：現在は利用していない
#		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "wget -q https://github.com/openpbs/openpbs/archive/refs/tags/v20.0.1.tar.gz -O /home/$USERNAME/openpbs-20.0.1.tar.gz"
#		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "tar zxvf /home/$USERNAME/openpbs-20.0.1.tar.gz"
#		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "LANG=C /home/$USERNAME/openpbs-20.0.1/autogen.sh"
#		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "LANG=C /home/$USERNAME/openpbs-20.0.1/configure --prefix=/opt/pbs"
#		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "make"
#		ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo make install"

		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-client-20.0.1-0.x86_64.rpm"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo /opt/pbs/libexec/install_db"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo /opt/pbs/libexec/pbs_habitat"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo /opt/pbs/libexec/pbs_postinstall"
		# PBSノード：configure /etc/pbs.conf file
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e 's/PBS_START_SERVER=0/PBS_START_SERVER=1/g' /etc/pbs.conf"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e 's/PBS_START_SCHED=0/PBS_START_SCHED=1/g' /etc/pbs.conf"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e 's/PBS_START_COMM=0/PBS_START_COMM=1/g' /etc/pbs.conf"
		# PBSノード：openPBSパーミッション設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_iff"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_rcp"
		# PBSノード：ホストファイルコピー
		echo "pbsnodes: copy hostsfile to all compute nodes"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# /etc/hosts.original の確認
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "file /etc/hosts.original" > hostsoriginal
		if [ -z "$hostsoriginal" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /etc/hosts /etc/hosts.original"
		fi
		rm hostsoriginal
		# ホストファイルの追加（重複チェック）
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
		if [ -f ./duplines.sh ]; then rm ./duplines; fi
cat <<'EOL' >> duplines.sh
#!/bin/bash 
lines=$(sudo cat /etc/hosts | wc -l)
MAXVM=
USERNAME=
if [ $((lines)) -ge $((MAXVM+2)) ]; then
    sudo awk '!colname[$2]++{print $1, "\t" ,$2}' /etc/hosts > /home/$USERNAME/hosts2
	if [ -s /home/$USERNAME/hosts2 ]; then
		echo "-s: copy hosts2 to host...."
		sudo cp /home/$USERNAME/hosts2 /etc/hosts
	fi
	if [ ! -f /home/$USERNAME/hosts2 ]; then
		echo "!-f: copy hosts2 to host...."
		sudo sort -V -k 2 /etc/hosts | uniq > /etc/hosts2
		sudo cp /home/$USERNAME/hosts2 /etc/hosts
	fi
else
	echo "skip"
fi
EOL
		sed -i -e "s/MAXVM=/MAXVM=${MAXVM}/" duplines.sh
		sed -i -e "s/USERNAME=/USERNAME=${USERNAME}/" duplines.sh
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./duplines.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo bash /home/$USERNAME/duplines.sh"
		echo "pbsnodes: /etc/hosts"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "rm -rf /home/$USERNAME/hosts2"

		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ln -s /mnt/share/ /home/$USERNAME/"

### ===========================================================================
		# openPBSクライアントコピー
		echo "copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
		parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
		# ダウンロード、およびMD5チェック
		count=0
		if [ -f ./md5executionremote ]; then rm ./md5executionremote; fi
		if [ -f ./md5executionremote2 ]; then rm ./md5executionremote2; fi
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
			md5executionremote=$(cat ./md5executionremote)
			echo "md5executionremote: $md5executionremote"
			for cnt in $(seq 1 3); do
				echo "checking md5...: $cnt"
				if [ "$md5executionremote" == "$md5execution" ]; then
				# 固定ではうまくいかない
				# if [ "$md5executionremote" != "59f5110564c73e4886afd579364a4110" ]; then
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@"${line}":/home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
					md5executionremote=$(cat ./md5executionremote)
					echo "md5executionremote: $md5executionremote"
					echo "md5executionremote2: $md5executionremote2"
					for cnt2 in $(seq 1 3); do
						echo "checking md5...: $cnt2"
						if [ "$md5executionremote2" != "$md5execution" ]; then
						# 固定ではうまくいかない
						# if [ "$md5executionremote2" != "59f5110564c73e4886afd579364a4110" ]; then
							ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
							ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
							ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /tmp/openpbs-execution-20.0.1-0.x86_64.rpm  | cut -d ' ' -f 1" > md5executionremote2
							md5executionremote2=$(cat ./md5executionremote2)
							ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "cp /tmp/openpbs-execution-20.0.1-0.x86_64.rpm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
							echo "md5executionremote2: $md5executionremote2"
						else
							echo "match md5 by md5executionremote2"
							md5executionremote2=$(cat ./md5executionremote2)
							break
						fi
					done
				else
					echo "match md5 by md5executionremote"
					md5executionremote=$(cat ./md5executionremote)
					break
				fi
			done
		done
		rm ./md5executionremote
		rm ./md5executionremote2
		# openPBSクライアント：インストール
		echo "confuguring all compute nodes"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30'-i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y hwloc-libs libICE libSM""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y libnl3""
		echo "installing libnl3"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo rpm -aq | grep openpbs""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_habitat""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_postinstall""
		# pbs.confファイル生成
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo cat /etc/pbs.conf""
		# openPBSクライアント：パーミッション設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_iff""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_rcp""
		# openPBSクライアント：/var/spool/pbs/mom_priv/config コンフィグ設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config""
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config"
		done
		# openPBSクライアント：HOSTSファイルコピー・設定（全体）
		parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} ./hostsfile $USERNAME@{}:/home/$USERNAME/"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts""
		# openPBSクライアント：HOSTSファイルコピー・設定（個別）・重複排除
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			# /etc/hosts.original の確認
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "file /etc/hosts.original" > hostsoriginal
			if [ -z "$hostsoriginal" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /etc/hosts /etc/hosts.original"
			fi
			rm hostsoriginal
			# ホストファイルの重複排除
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			if [ ! -f ./duplines.sh ]; then 
				echo "error!: duplines.sh was deleted. please retry addlogin command."
			fi
				sed -i -e "s/MAXVM=/MAXVM=${MAXVM}/" duplines.sh
				sed -i -e "s/USERNAME=/USERNAME=${USERNAME}/" duplines.sh
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./duplines.sh $USERNAME@"${line}":/home/$USERNAME/
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo bash /home/$USERNAME/duplines.sh"
			echo "${VMPREFIX}-${count}: show /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo rm -rf /home/$USERNAME/hosts2"
		done
### ===========================================================================
		# PBSプロセス起動
		# PBSノード起動＆$USERNAME環境変数設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "yes | sudo /etc/init.d/pbs start"
		fi
		# openPBSクライアントノード起動＆$USERNAME環境変数設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /etc/init.d/pbs start""
		vm1ip=$(head -n 1 ./ipaddresslist)
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'echo 'source /etc/profile.d/pbs.sh' >> $HOME/.bashrc'"
		fi
		rm ./pbssh
		echo "finished to set up additonal login and PBS node"
### ===========================================================================
		# PBSジョブスケジューラセッティング
		echo "configpuring PBS settings"
		if [ -f ./setuppbs.sh ]; then rm ./setuppbs.sh; fi
		for count in $(seq 1 $MAXVM); do
			echo "/opt/pbs/bin/qmgr -c "create node ${VMPREFIX}-${count}"" >> setuppbs.sh
		done
		# ジョブ履歴有効化
		echo "/opt/pbs/bin/qmgr -c s s job_history_enable = 1" >> setuppbs.sh
		# シングルクォーテーション処理
		sed -i -e "s/-c /-c '/g" setuppbs.sh || sudo sed -i -e "s/-c /-c '/g" setuppbs.sh
		sed -i -e "s/$/\'/g" setuppbs.sh || sudo sed -i -e "s/$/\'/g" setuppbs.sh
		echo "setuppbs.sh: $(cat ./setuppbs.sh)"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./setuppbs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/setuppbs.sh
		# SSH鍵登録
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t 'sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old'
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
		# ジョブスケジューラセッティング
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/setuppbs.sh"
		rm ./setuppbs.sh
### ===========================================================================
		# 追加機能：PBSノードにnodelistを転送する
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./nodelist $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# PBSノードからマウンド状態をチェックするスクリプト生成
		if [ -f ./checknfs.sh ]; then rm checknfs.sh; fi
		cat <<'EOL' >> checknfs.sh
#!/bin/bash

#VMPREFIX=sample
#MAXVM=4

USERNAME=$(whoami)
echo $USERNAME
SSHKEY=$(echo ${VMPREFIX})
echo $SSHKEY
# 文字列"-pbs" は削除
SSHKEYDIR="$HOME/.ssh/${SSHKEY%-pbs}"
chmod 600 $SSHKEYDIR
echo $SSHKEYDIR
vm1ip=$(cat /home/$USERNAME/nodelist | head -n 1)
echo $vm1ip

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
if   [ -e /etc/debian_version ] || [ -e /etc/debian_release ]; then
    # Check Ubuntu or Debian
    if [ -e /etc/lsb-release ]; then
        # Ubuntu
        echo "ubuntu"
		sudo apt install -qq -y parallel jq curl || apt install -qq -y parallel jq curl
    else
        # Debian
        echo "debian"
		sudo apt install -qq -y parallel jq curl || apt install -qq -y parallel jq curl
	fi
elif [ -e /etc/fedora-release ]; then
    # Fedra
    echo "fedora"
elif [ -e /etc/redhat-release ]; then
	echo "Redhat or CentOS"
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
fi

ssh -i $SSHKEYDIR $USERNAME@${vm1ip} -t -t 'sudo showmount -e'
parallel -v -a ./ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'df -h | grep 10.0.0.'"
echo "====================================================================================="
parallel -v -a ./ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'sudo cat /etc/fstab'"
EOL
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./checknfs.sh
		MAXVM=$(grep "MAXVM=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#MAXVM=4/MAXVM=$MAXVM/" ./checknfs.sh
		# 最後に転送実施		
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./checknfs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# PBSノードでの実施なので ipaddresslist(外部IP) から nodelist(内部IP) に変更
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sed -i -e "s!./ipaddresslist!./nodelist!" /home/$USERNAME/checknfs.sh"
	;;
#### ==========================================================================
#### ==========================================================================
	start )
		## PBSノード：OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		# PBSノードの存在チェック
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
		if [ -n "$osdiskidpbs" ]; then
			az disk update --sku ${azure_sku2} --ids "${osdiskidpbs}" -o table
			echo "starting PBS VM"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-pbs -o none &
			# PBSノードが存在すればログインノードも存在する
			echo "starting loging VM"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-login -o none &
		else
			# PBSノードのOSディスクが存在しなければPBSノードも存在しない
			echo "no PBS node here!"
		fi

		# VM1-N: OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		if [ ! -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv)
			echo "$disktmp" >> tmposdiskidlist
		done
		echo "converting computing node OS disk"
		parallel -a ./tmposdiskidlist "az disk update --sku ${azure_sku2} --ids {} -o none &"
		sleep 10
		echo "starting VM ${VMPREFIX}-1"
		az vm start -g $MyResourceGroup --name "${VMPREFIX}"-1 -o none &
		echo "starting VM ${VMPREFIX}:2-$MAXVM compute nodes"
		seq 2 "$MAXVM" | parallel "az vm start -g $MyResourceGroup --name ${VMPREFIX}-{} -o none &"
		echo "checking $MAXVM compute VM's status"
		numvm=0
		tmpnumvm="default"
		while [ -n "$tmpnumvm" ]; do
			tmpnumvm=$(az vm list -d -g $MyResourceGroup --query "[?powerState=='VM starting']" -o tsv)
			echo "$tmpnumvm" | tr ' ' '\n' > ./tmpnumvm.txt
			numvm=$(grep -c "starting" ./tmpnumvm.txt)
			echo "current starting VMs: $numvm. All VMs are already running!"
			sleep 5
		done
		rm ./tmpnumvm.txt
		sleep 30

		# ダイナミックの場合（デフォルト）、再度IPアドレスリストを作成しなおす
		if [ ! -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		echo "creating ipaddresslist"
		getipaddresslist vmlist ipaddresslist
		echo "show new ipaddresslist"
		cat ./ipaddresslist

		# check ssh connectivity
		checksshconnection all
		connection=$(cat ./checksshtmp | wc -l)
		if [ $((connection)) -eq $((MAXVM)) ]; then 
			echo "all node ssh avaiable"
		else
			echo "some of nodes are not ssh avaiable"
		fi
		rm ./checksshtmp

		# VM1 $2 マウント
		echo "vm1: nfs server @ ${VMPREFIX}-1"
		mountdirectory vm1

		echo "end of starting up computing nodes"
		# PBSノードがなければ終了
		if [ -z "$osdiskidpbs" ]; then
			echo "no PBS node here!"
			exit 0
		fi
		# PBSノード：マウント設定
		echo "pbsnode: nfs server @ ${VMPREFIX}-pbs"
		mountdirectory pbs
		echo "end of start command"
	;;
	startvm )
		## PBSノード：OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		# PBSノードの存在チェック
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
		if [ -n "$osdiskidpbs" ]; then
			az disk update --sku ${azure_sku2} --ids "${osdiskidpbs}" -o table
			echo "starting PBS VM"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-pbs -o none &
			# PBSノードが存在すればログインノードも存在する
			echo "starting loging VM"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-login -o none &
		else
			# PBSノードのOSディスクが存在しなければPBSノードも存在しない
			echo "no PBS node here!"
		fi

		# VM1-N: OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${2}" --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo "converting computing node OS disk"
		az disk update --sku ${azure_sku2} --ids "${disktmp}" -o none
		echo "starting VM ${VMPREFIX}-1"
		az vm start -g $MyResourceGroup --name "${VMPREFIX}"-1 -o none
		echo "starting VM ${VMPREFIX}:2-$MAXVM compute nodes"
		az vm start -g $MyResourceGroup --name ${VMPREFIX}-"${2}" -o none
		echo "checking $MAXVM compute VM's status"
		sleep 30

		# ダイナミックの場合（デフォルト）、再度IPアドレスリストを作成しなおす
		if [ ! -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		echo "creating ipaddresslist"
		getipaddresslist vmlist ipaddresslist
		echo "show new vm ip"
		sed -n "${2}"P ./ipaddresslist

		# VM1 $2 マウント
		echo "${VMPREFIX}-${2}: mounting vm1 nfs server...."
		mountdirectory vm1

		# PBSノードがなければ終了
		if [ -z "$osdiskidpbs" ]; then
			echo "no PBS node here!"
			exit 0
		fi
		# PBSノード：マウント設定
		echo "${VMPREFIX}-${2}: mounting nfs server...."
		mountdirectory pbs
		echo "end of start command"
	;;
	stop )
		for count in $(seq 1 "$MAXVM") ; do
			echo "stoping VM $count"
			az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" &
		done
	;;
	stop-all )
		if [ -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv)
			echo "$disktmp" >> tmposdiskidlist
		done
		for count in $(seq 1 "$MAXVM") ; do
			echo "stoping VM $count"
			az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" &
		done
		echo "stoping PBS VM"
		az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-pbs &
		echo "stoping login VM"
		az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-login &
		# OSディスクタイプ変更: Standard_LRS
		azure_sku1="Standard_LRS"
		echo "converting computing node OS disk"
		parallel -v -a ./tmposdiskidlist "az disk update --sku ${azure_sku1} --ids {}"
		# Dataディスクタイプ変更: Standard_LRS
		echo "converting PBS node data disk"
		az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {}
		echo "converting compute node #1 data disk"
		az vm show -g $MyResourceGroup --name "${VMPREFIX}"-1 --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {}
	;;
	stopvm )
		echo "コマンドシンタクス:VM#2を停止する場合 ./$CMDNAME stopvm 2"
		echo "stoping VM $2"
		az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"$2" &
	;;
	stopvms )
		echo "コマンドシンタクス:VM#2,3,4を停止する場合 ./$CMDNAME stopvm 2 4"
		echo "stoping VM $2 $3"
		for count in $(seq "$2" "$3") ; do
			echo "stoping VM $count"
			az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" &
		done
	;;
	list )
		echo "listng running/stopped VM"
		az vm list -g $MyResourceGroup -d -o table

		echo "prep..."
		getipaddresslist vmlist ipaddresslist
		echo "nfs server vm status"
		# vm1state=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query powerState)
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv)
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv)
		# PBSノードのパブリックIPアドレスの判定
		if [ -z "$pbsvmip" ]; then
			echo "no PBS node here! checking only compute nodes."
			# コンピュートノードのみのチェック
			count=0
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-1: nfs server status"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" 'sudo showmount -e'
				echo "nfs client mount status"
					for count in $(seq 2 "$MAXVM"); do
						line=$(sed -n "${count}"P ./ipaddresslist)
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "echo '########## host: ${VMPREFIX}-${count} ##########'"
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "df | grep '/mnt/'"
					done
				else
					# SSHできないのでaz vm run-commandでの情報取得
					echo "az vm run-command: nfs server status"
					az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "sudo showmount -e"
					echo "nfs client mount status:=======1-2 others: skiped======="
					az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "df | grep /mnt/"
					az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-2 --command-id RunShellScript --scripts "df | grep /mnt/"
			fi
			# コンピュートノードVM#1のマウントだけ完了し、コマンド完了
			echo "end of list command"
			exit 0
		fi
		# PBSノード、コンピュートノードのNFSマウント確認
		count=0
		checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
		checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
		if [ -n "$checkssh" ] && [ -n "$checkssh2" ]; then
			echo "${VMPREFIX}-pbs: nfs server status"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" 'sudo showmount -e'
			echo "${VMPREFIX}-1: nfs server status"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" 'sudo showmount -e'
			echo "nfs client mount status"
			for count in $(seq 2 "$MAXVM"); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "echo '########## host: ${VMPREFIX}-${count} ##########'"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "df | grep '/mnt/'"
			done
		else
			echo "az vm run-command: nfs server status"
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-pbs --command-id RunShellScript --scripts "sudo showmount -e"
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "sudo showmount -e"
			echo "nfs client mount status:=======VM 1-2'status. other VMs are skiped======="
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "df | grep /mnt/"
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-2 --command-id RunShellScript --scripts "df | grep /mnt/"
		fi
	;;
	delete )
		if [ -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv)
			echo "$disktmp" >> tmposdiskidlist
		done
		echo "deleting compute VMs"
		seq 1 "$MAXVM" | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes &"
		numvm=$(cat ./vmlist | wc -l)
		checkpbs=$(grep pbs ./vmlist)
		if [ -n "$checkpbs" ]; then
			# no pbs
			while [ $((numvm)) -gt 2 ]; do
				echo "sleep 30" && sleep 30
				echo "current running VMs: $numvm"
				az vm list -g $MyResourceGroup | jq '.[] | .name' | grep "${VMPREFIX}" > ./vmlist
				numvm=$(cat ./vmlist | wc -l)
			done
		echo "deleted all compute VMs"
		else
			# pbs node existing
			while [ $((numvm)) -gt 0 ]; do
				echo "sleep 30" && sleep 30
				echo "current running VMs: $numvm"
				az vm list -g $MyResourceGroup | jq '.[] | .name' | grep "${VMPREFIX}" > ./vmlist
				numvm=$(cat ./vmlist | wc -l)
			done
		fi
		echo "deleted all compute VMs. PBS and login node are existing"
		echo "deleting disk"
		parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
		sleep 10
		# STATICMAC が true であればNIC、パブリックIPを再利用する
		if [ "$STATICMAC" == "true" ] || [ "$STATICMAC" == "TRUE" ]; then
			echo "keep existing nic and public ip"
		else
			echo "deleting nic"
			seq 1 "$MAXVM" | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic"
			echo "deleting public ip"
			seq 1 "$MAXVM" | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP"
		fi
		echo "detele data disk"
		az disk delete -g $MyResourceGroup --name "${VMPREFIX}"-1-disk0 --yes
		echo "current running VMs: ${numvm}"
		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
		rm ./nodelist
	;;
	delete-all )
		if [ -f ./tmposdiskidlist ]; then
			rm ./tmposdiskidlist
		fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv)
			echo "$disktmp" >> tmposdiskidlist
		done
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo "$disktmp" >> tmposdiskidlist
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-login --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo "$disktmp" >> tmposdiskidlist
		echo "deleting compute VMs"
		seq 1 "$MAXVM" | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes &"
		echo "deleting pbs node"
		az vm delete -g $MyResourceGroup --name "${VMPREFIX}"-pbs --yes &
		echo "deleting login node"
		az vm delete -g $MyResourceGroup --name "${VMPREFIX}"-login --yes &
		# vmlistがある前提
		if [ ! -f "./vmlist" ]; then
			numvm=$(cat ./vmlist | wc -l)
		else
			numvm=$((MAXVM))
		fi
		# VM削除までの待ち時間
		while [ $((numvm)) -gt 0 ]; do
			echo "sleep 30" && sleep 30
			echo "current running VMs: $numvm"
			az vm list -g $MyResourceGroup | jq '.[] | .name' | grep "${VMPREFIX}" > ./vmlist
			numvm=$(cat ./vmlist | wc -l)
		done
		sleep 10 ##置換##
		echo "deleting disk"
		parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
		sleep 10
		# STATICMAC が true であればNIC、パブリックIPを再利用する
		if [ "$STATICMAC" == "true" ] || [ "$STATICMAC" == "TRUE" ]; then
			echo "keep existing nic and public ip"
		else
			echo "deleting nic"
			seq 1 "$MAXVM" | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic"
			az network nic delete -g $MyResourceGroup --name "${VMPREFIX}"-pbsVMNic
			az network nic delete -g $MyResourceGroup --name "${VMPREFIX}"-loginVMNic
			echo "deleting public ip"
			seq 1 "$MAXVM" | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP"
			az network public-ip delete -g $MyResourceGroup --name "${VMPREFIX}"-pbsPublicIP
			az network public-ip delete -g $MyResourceGroup --name "${VMPREFIX}"-loginPublicIP
		fi
		echo "detelting data disk"
		az disk delete -g $MyResourceGroup --name "${VMPREFIX}"-1-disk0 --yes
		az disk delete -g $MyResourceGroup --name "${VMPREFIX}"-pbs-disk0 --yes
		echo "current running VMs: ${numvm}"
		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
		rm ./config
		rm ./fullpingpong.sh
		rm ./pingponlist
		rm ./nodelist
		rm ./hostsfile
		rm ./tmpcheckhostsfile
		rm ./loginvmip
		rm ./pbsvmip
		rm ./md5*
		rm ./openpbs*
		rm ./pbsprivateip
		rm ./loginpribateip
	;;
	deletevm )
		# $2が必要
		echo "PBSノードとしてのノード削除は行われないので、手動で削除すること"
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${2}" --query storageProfile.osDisk.managedDisk.id -o tsv)
		echo "deleting compute VMs"
		az vm delete -g $MyResourceGroup --name "${VMPREFIX}"-"${2}" --yes
		# 削除すべき行番号を割り出し
		tmpline=$(grep "${VMPREFIX}-${2}" -n ./vmlist | cut -d ":" -f 1)
		echo "$tmpline"
		echo "deliting line: $tmpline"
		# vmlistから特定のVMを削除
		sed -i -e "${tmpline}d" ./vmlist
		echo "show new current vmlist"
		cat ./vmlist
		# nodelistから特定のVMを削除
		sed -i -e "${tmpline}d" ./nodelist
		echo "show new current nodelist"
		cat ./nodelist
		# ディスク削除
		echo "deleting disk"
		az disk delete --ids "${disktmp}" --yes
		# STATICMAC が true であればNIC、パブリックIPを再利用する
		if [ "$STATICMAC" == "true" ] || [ "$STATICMAC" == "TRUE" ]; then
			echo "keep existing nic and public ip"
		else
			echo "deleting nic"
			az network nic delete -g $MyResourceGroup --name "${VMPREFIX}"-"${2}"VMNic
			echo "deleting public ip"
			az network public-ip delete -g $MyResourceGroup --name "${VMPREFIX}"-"${2}"PublicIP
		fi
		# PBSジョブスケジューラから削除する
		echo "deleting PBS node"
		# deletenode.sh
		rm ./deletenode.sh
		echo "/opt/pbs/bin/qmgr -c "create delete "${VMPREFIX}"-${2}"" >> deletenode.sh
		# sed -i -e "s/-c /-c '/g" setuppbs.sh
		# sed -i -e "s/$/\'/g" setuppbs.sh
		echo "deletenode.sh: $(cat ./deletenode.sh)"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./deletenode.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/deletenode.sh
		# SSH鍵登録：未実装
		# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
		# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
		# ジョブスケジューラセッティング
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/deletenode.sh"
		# ホストファイル修正：未実装
	;;
	remount )
		# mounting nfs server from compute node.
		if [ -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		getipaddresslist vmlist ipaddresslist

		echo "vm1 remounting..."
		mountdirectory vm1

		# PBSノード：展開済みかチェック
		echo "pbs...."
		pbsvmname=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query name -o tsv)
		if [ -n "$pbsvmname" ]; then
			echo "pbs remounting...."
			mountdirectory pbs
		fi
	;;
	pingpong )
		# 初期設定：ファイル削除
		if [ -f ./vmlist ]; then rm ./vmlist; fi
		if [ -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		if [ -f ./nodelist ]; then rm ./nodelist; fi
		echo "creating vmlist and ipaddresslist and nodelist"
		getipaddresslist vmlist ipaddresslist nodelist

		# pingponglist ファイルチェック・削除
		if [ -f ./pingponglist ]; then rm ./pingponglist; fi
		# pingponglist 作成：全ノードの組み合わせ作成
		for NODE in $(cat ./nodelist); do
			for NODE2 in $(cat ./nodelist); do
				echo "$NODE,$NODE2" >> pingponglist
			done
		done
		# fullpingpongコマンドスクリプト作成
		if [ -f ./fullpingpong.sh ]; then rm ./fullpingpong.sh; fi
		cat <<'EOL' >> fullpingpong.sh
#!/bin/bash
checkosver=$(cat /etc/redhat-release | cut  -d " " -f 4)
cp /home/$USER/* /mnt/resource/scratch/
cd /mnt/resource/scratch/
max=$(cat ./pingponglist | wc -l)
count=1
## TZ=JST-9 date
echo "========================================================================"
echo -n "$(TZ=JST-9 date '+%Y %b %d %a %H:%M %Z')" && echo " - pingpong #: $max, OS: ${checkosver}"
echo "========================================================================"
# run pingpong
case $checkosver in
	7.?.???? )
		IMPI_VERSION=2018.4.274
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############"; >> result
			/opt/intel/impi/${IMPI_VERSION}/intel64/bin/mpirun -hosts $line -ppn 1 -n 2 -env I_MPI_FABRICS=shm:ofa /opt/intel/impi/${IMPI_VERSION}/bin64/IMB-MPI1 pingpong | grep -e ' 512 ' -e NODES -e usec; >> result
		done
	;;
	8.?.???? )
		IMPI_VERSION=2021.1.1
		 source /opt/intel/oneapi/mpi/2021.1.1/env/vars.sh
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############"; >> result
			/opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/mpiexec -hosts $line -ppn 1 -n 2 /opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/IMB-MPI1 pingpong | grep -e ' 512 ' -e NODES -e usec; >> result
		done
	;;
esac
EOL
# ヒアドキュメントのルール上改行不可
		# SSHコンフィグファイルの再作成は必要ないため、削除
		if [ ! -f  ./config ]; then
			echo "no ssh config file in local directory!"
			cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL

		fi
		# コマンド実行方法判断
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv)
		checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" "uname")
		for count in $(seq 1 10); do
			if [ -z "$checkssh" ]; then
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" "uname")
				echo "accessing VM#1 by ssh...." && sleep 2
			else
				break
			fi
		done
		if [ -n "$checkssh" ]; then
			# SSHアクセス可能：SSHでダイレクトに実施（早い）
			echo "running on direct access to all compute nodes"
			# fullpingpong実行
			echo "pingpong: show pingpong combination between nodes"
			cat ./pingponglist
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${vm1ip}":/home/$USERNAME/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${vm1ip}":/home/$USERNAME/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${vm1ip}":/mnt/resource/scratch/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${vm1ip}":/mnt/resource/scratch/
			# SSH追加設定
			cat ./ipaddresslist
			echo "pingpong: copy passwordless settings"
			seq 1 "$MAXVM" | parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./config $USERNAME@{}:/home/$USERNAME/.ssh/config"
			seq 1 "$MAXVM" | parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/config""
			# コマンド実行
			echo "pingpong: running pingpong for all compute nodes"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "rm /mnt/resource/scratch/result"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "bash /mnt/resource/scratch/fullpingpong.sh > /mnt/resource/scratch/result"
			echo "copying the result from vm1 to local"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}":/mnt/resource/scratch/result ./
			ls -la ./*result*
			cat ./result
			echo "ローカルのresultファイルを確認"
		else
			# SSHアクセス不可能：ログインノード経由で設定
			echo "running via loging node due to limited access to all compute nodes"
			for count in $(seq 1 "${MAXVM}"); do
				loginprivateip=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-login -d --query privateIps -o tsv)
				vm1privateip=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-1 -d --query privateIps -o tsv)
				checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "uname")
				for cnt in $(seq 1 10); do
					if [ -n "$checkssh2" ]; then
						break
					else
						echo "sleep 10" && sleep 1
					fi
				done
				if [ -z "$checkssh2" ]; then
					echo "error!: you can not access by ssh the login node!"
					exit 1
				fi
				# ファイル転送: local to login node
				echo "ローカル: ssh: ホストファイル転送 transfer login node"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${loginvmip}":/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${loginvmip}":/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${loginvmip}":/mnt/resource/scratch/
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${loginvmip}":/mnt/resource/scratch/
				# ファイル転送: login node to VM#1
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./fullpingpong.sh $USERNAME${vm1privateip}:/home/$USERNAME/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./pingponglist $USERNAME@${vm1privateip}:/home/$USERNAME/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./fullpingpong.sh $USERNAME@${vm1privateip}:/mnt/resource/scratch/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./pingponglist $USERNAME@${vm1privateip}:/mnt/resource/scratch/"
				# pingpongコマンド実行
				echo "pingpong: running pingpong for all compute nodes"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1privateip} -t -t 'rm /mnt/resource/scratch/result'"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1privateip} -t -t "bash /mnt/resource/scratch/fullpingpong.sh > /mnt/resource/scratch/result""
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1privateip}:/mnt/resource/scratch/result /home/$USERNAME/"
				# 多段の場合、ローカルにもダウンロードが必要
				echo "copying the result from vm1 to local"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1privateip}":/home/$USERNAME/ ./
				ls -la ./*result*
				cat ./result
				echo "ローカルのresultファイルを確認"
			done
		fi
	;;
	updatensg )
		# NSGアップデート：既存の実行ホストからのアクセスを修正
		echo "current host global ip address: $LIMITEDIP"
		echo "updating NSG for current host global ip address"
		az network nsg rule update --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
			--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 -o table
		az network nsg rule update --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
			--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 -o table
	;;
	privatenw )
		# PBSノード、コンピュートノード：インターネットからの外部接続を削除
		echo "既存のクラスターからインターネットとの外部接続（パブリックIP）を削除"
		count=0
		for count in $(seq 1 "$MAXVM"); do
			tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-"${count}"VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name "$tmpipconfig" -g $MyResourceGroup --nic-name "${VMPREFIX}"-"${count}"VMNic --remove publicIpAddress -o table &
		done
		# PBSノードも同様にインターネットからの外部接続を削除
		tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name "$tmpipconfig" -g $MyResourceGroup --nic-name "${VMPREFIX}"-pbsVMNic --remove publicIpAddress -o table &
	;;
	publicnw )
		# PBSノード、コンピュートノード：インターネットとの外部接続を確立
		echo "既存のクラスターからインターネットとの外部接続を確立（パブリックIP付与）"
		count=0
		for count in $(seq 1 "$MAXVM"); do
			tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-"${count}"VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name ipconfig"${VMPREFIX}"-"${count}" -g $MyResourceGroup --nic-name "${VMPREFIX}"-"${count}"VMNic --public "${VMPREFIX}"-"${count}"PublicIP -o table &
		done
		# PBSノードも同様にインターネットからの外部接続を追加
		tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name ipconfig"${VMPREFIX}"-pbs -g $MyResourceGroup --nic-name "${VMPREFIX}"-pbsVMNic --public "${VMPREFIX}"-pbsPublicIP -o table &
	;;
	listip )
		# IPアドレスを表示
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0],PublicIp:network.publicIpAddresses[0].ipAddress}" -o table
	;;
	ssh )
		# SSHアクセスする
		if [ ! -f ./ipaddresslist ]; then
			getipaddresslist vmlist ipaddresslist
		fi
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv)
		vm1ipexist=$(sed -n 1P ./ipaddresslist)
		if [ "${vm1ip}" != "${vm1ipexist}" ]; then
			rm ./vmlist ./ipaddresslist
			getipaddresslist vmlist ipaddresslist
		fi
		case ${2} in
			login )
				loginvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}"
			;;
			pbs )
				pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}"
			;;
			* )
				line=$(sed -n "${2}"P ./ipaddresslist)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}"
			;;
		esac
	;;
	checkfiles )
		# 利用するローカルスクリプトを作成
		echo "create scripts in local directory"
### ===========================================================================
		rm checkmount.sh
		# VMマウントチェックスクリプト
		cat <<'EOL' >> checkmount.sh
#!/bin/bash
#VMPREFIX=sample
#USERNAME=sample

# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	7** )
		cp ./${VMPREFIX} $HOME/.ssh/
		chmod 600 $HOME/.ssh/${VMPREFIX}
		SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
	;;
esac
echo "SSHKEYDIR: $SSHKEYDIR"
vm1ip=$(sed -n 1P ./ipaddresslist)
ssh -i $SSHKEYDIR $USERNAME@${vm1ip} -t -t 'sudo showmount -e'
parallel -v -a ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'df -h | grep 10.0.0.'"
EOL
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./checkmount.sh
		SSHKEYDIR=$(grep "SSHKEYDIR=" "${CMDNAME}" | sed -n 2p | cut -d "=" -f 2)
		sed -i -e "s:^#SSHKEYDIR=sample:SSHKEYDIR=$SSHKEYDIR:" ./checkmount.sh
		USERNAME=$(grep "USERNAME=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#USERNAME=sample/USERNAME=$USERNAME/" ./checkmount.sh
### ===========================================================================
		rm checktunnel.sh
		# VM LISTENチェックスクリプト
		cat <<'EOL' >> checktunnel.sh
#!/bin/bash
#VMPREFIX=sample
#USERNAME=sample

# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	7** )
		cp ./${VMPREFIX} $HOME/.ssh/
		chmod 600 $HOME/.ssh/${VMPREFIX}
		SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
	;;
esac
echo "SSHKEYDIR: $SSHKEYDIR"
seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -i $SSHKEYDIR azureuser@{} -t -t 'netstat -an | grep -v -e :22 -e 80 -e 443 -e 445'"
EOL
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./checktunnel.sh
		SSHKEYDIR=$(grep "SSHKEYDIR=" "${CMDNAME}" | sed -n 2p | cut -d "=" -f 2)
		sed -i -e "s:^#SSHKEYDIR=sample:SSHKEYDIR=$SSHKEYDIR:" ./checktunnel.sh
		USERNAME=$(grep "USERNAME=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#USERNAME=sample/USERNAME=$USERNAME/" ./checktunnel.sh
### ===========================================================================
		rm createnodelist.sh
		# VMプライベートIPアドレスリスト作成スクリプト
		cat <<'EOL' >> createnodelist.sh
#!/bin/bash
#MAXVM=2
#MyResourceGroup=sample
#VMPREFIX=sample

# ホストファイル作成準備：既存ファイル削除
if [ -f ./nodelist ]; then rm ./nodelist; echo "recreating a new nodelist"; fi
# ホストファイル作成
az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmphostsfile
# 自然な順番でソートする
sort -V ./tmphostsfile > hostsfile
# nodelist 取り出し：2列目
cat hostsfile | cut -f 2 > nodelist
# テンポラリファイル削除
rm ./tmphostsfile
EOL
		MyResourceGroup=$(grep "MyResourceGroup=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#MyResourceGroup=sample/MyResourceGroup=$MyResourceGroup/" ./createnodelist.sh
		MAXVM=$(grep "MAXVM=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#MAXVM=sample/MAXVM=$MAXVM/" ./createnodelist.sh
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./createnodelist.sh
		echo "end of creating script files"
	;;
esac


echo "$CMDNAME: end of vm hpc environment create script"
