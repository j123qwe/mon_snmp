#!/bin/bash

##Variables
VERSION=21.12.2
SCRIPTDIR=$(pwd)
TMPDIR=${SCRIPTDIR}/tmp

##Functions
prechecks(){
	#Create TMP directory if does not exist
	mkdir -p ${SCRIPTDIR}/tmp
	check_packages
}

check_packages(){
    DISTRO=$(cat /etc/*-release | grep ID_LIKE | cut -d= -f2)
    if [[ ${DISTRO} =~ "debian" ]]; then
        debian_package_install
    elif [[ ${DISTRO} =~ "rhel" ]]; then
        #rhel_package_install
        echo "Not yet implemented. Exiting..."
        exit
    else
        echo "This utility will only work with Debian or RHEL based Linux system. Exiting..."
        exit
    fi
}

debian_package_install(){
    PACKAGES="snmp snmp-mibs-downloader"
    TOINSTALL=()
    for PKG in ${PACKAGES[@]}; do
        dpkg -s ${PKG} &> /dev/null
        if [ $? -eq 1 ]; then
            TOINSTALL+=("${PKG}")
        elif [ $? -gt 1 ]; then
            echo "Potential problem with ${PKG}. Please investigate. Exiting..."
            exit
        fi
    done
    if [[ ! -z ${TOINSTALL[@]} ]]; then
            sudo apt install -y "${TOINSTALL[@]}"
    fi
}

colorize(){
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)
NORMAL=$(tput sgr0)
if [ ${1} == "GREEN" ]; then
	printf "${GREEN}${2}${NORMAL}"
elif [ ${1} == "YELLOW" ]; then
	printf "${YELLOW}${2}${NORMAL}"
elif [ ${1} == "RED" ]; then
	printf "${RED}${2}${NORMAL}"
elif [ ${1} == "NORMAL" ]; then
	printf "${NORMAL}${2}${NORMAL}"
fi
}

get_variables(){
echo ""
if [ -z ${1} ]; then
	read -p "Node IP Address? " NODE
else
	NODE=${1}
fi
if [ -z ${2} ]; then
	read -p "SNMPv2 Community? " COMMUNITY
else
	COMMUNITY=${2}
fi
if [ -z ${3} ]; then
	get_int_id
else
	ID=${3}
fi
if [ -z ${4} ]; then
	read -p "Refresh Rate in Seconds? " REFRESH
else
	REFRESH=${4}
fi
REFRESH=$(expr ${REFRESH} - 1)
}

get_int_list(){
	printf "ID|Interface\n" | column -t -s '|'
	snmpwalk -v 2c -c ${COMMUNITY} -Oq ${NODE} IF-MIB::ifName | cut -d. -f2 | sed 's/ /|/g' | column -t -s '|'
	set_int_id
}

get_int_id(){
	options=("Retrieve Interface List" "Specify Interface ID")
	select opt in "${options[@]}"
		do
	        case $opt in
        	    "Retrieve Interface List")
                	   get_int_list
			   break
	                ;;
        	    "Specify Interface ID")
			  set_int_id
			  break
	                ;;
        	    *) echo invalid option;;
	        esac
	    done
}

set_int_id(){
	read -p "Enter Interface ID: " ID
}

get_thresholds(){
if [ -z ${1} ]; then
	echo "Please enter thresholds (in Mbps):"
        read -p "Input RED >=: " INRED
else
        INRED=${1}
fi
if [ -z ${2} ]; then
        read -p "Input YELLOW >=: " INYELLOW
else
        INYELLOW=${2}
fi
if [ -z ${3} ]; then
        read -p "Output RED >=: " OUTRED
else
        OUTRED=${3}
fi
if [ -z ${4} ]; then
        read -p "Output YELLOW >=: " OUTYELLOW
else
        OUTYELLOW=${4}
fi
INRED=$(echo "${INRED} * 100" | bc)
INYELLOW=$(echo "${INYELLOW} * 100" | bc)
OUTRED=$(echo "${OUTRED} * 100" | bc)
OUTYELLOW=$(echo "${OUTYELLOW} * 100" | bc)
}

monitor_int(){
	SYSNAME=$(snmpget -v2c -c ${COMMUNITY} ${NODE} -Ovq iso.3.6.1.2.1.1.5.0)
	INTNAME=$(snmpget -v2c -c ${COMMUNITY} ${NODE} -Ovq IF-MIB::ifName.${ID})
	printf "Getting counters from ${SYSNAME} (${NODE}), interface ${INTNAME} (${ID}). Please wait...\n\n"
	A_TIME=$(date +%s.%N)
	A_IN=$(snmpget -v2c -c ${COMMUNITY} -Ovq ${NODE} 1.3.6.1.2.1.31.1.1.1.6.${ID})
	A_OUT=$(snmpget -v2c -c ${COMMUNITY} -Ovq ${NODE} 1.3.6.1.2.1.31.1.1.1.10.${ID})
	while sleep ${REFRESH}.$((1999999999 - 1$(date +%N))); do
	# while true; do
		# sleep ${REFRESH}
		TIME=$(date +%H:%M:%S.%N)
		B_TIME=$(date +%s.%N)
		B_IN=$(snmpget -v2c -c ${COMMUNITY} -Ovq ${NODE} 1.3.6.1.2.1.31.1.1.1.6.${ID})
		B_OUT=$(snmpget -v2c -c ${COMMUNITY} -Ovq ${NODE} 1.3.6.1.2.1.31.1.1.1.10.${ID})
		C_IN=$(expr ${B_IN} - ${A_IN})
		C_OUT=$(expr ${B_OUT} - ${A_OUT})
		C_TIME=$(echo "${B_TIME} - ${A_TIME}" | bc)
		A_TIME=${B_TIME}
		A_IN=${B_IN}
		A_OUT=${B_OUT}
		IN=$(echo "scale=2;((${C_IN} * 8) / ${C_TIME}) / 1000 / 1000" | bc | awk ' { printf "%07.2f\n", $1 } ')
		OUT=$(echo "scale=2;((${C_OUT} * 8) / ${C_TIME}) / 1000 / 1000" | bc | awk ' { printf "%07.2f\n", $1 } ') 
                ININT=$(echo "${IN} * 100" | bc | cut -d. -f1)
                OUTINT=$(echo "${OUT} * 100" | bc | cut -d. -f1)
		if [ "${ININT}" -ge "${INRED}" ] || [ "${OUTINT}" -ge "${OUTRED}" ]; then
			colorize RED "${TIME}\t|\tIn: ${IN}Mbps\t|\tOut: ${OUT}Mbps\n"
		elif [ "${ININT}" -ge "${INYELLOW}" ] || [ "${OUTINT}" -ge "${OUTYELLOW}" ]; then
			colorize YELLOW "${TIME}\t|\tIn: ${IN}Mbps\t|\tOut: ${OUT}Mbps\n"
		else
			colorize GREEN "${TIME}\t|\tIn: ${IN}Mbps\t|\tOut: ${OUT}Mbps\n"
		fi
	done

}

begin_monitor(){
#Wait until the 9th second to begin the monitor_sap function
SEC=$(date +%S | cut -c2)
while true; do
if [ ${SEC} -eq 9 ]; then
       monitor_int
fi
SEC=$(date +%S | cut -c2)
echo "Please wait..."
sleep 0.75
done
}

##Execute
echo "SNMP Monitor v${VERSION}"
echo "Usage:  ./monitor.sh <NODEIP> <COMMUNITY> <IF_INDEX> <INTERVAL> <INPUT_RED> <INPUT_YELLOW> <OUTPUT_RED> <OUTPUT_YELLOW>"
prechecks
get_variables ${1} ${2} ${3} ${4}
get_thresholds ${5} ${6} ${7} ${8}
begin_monitor

