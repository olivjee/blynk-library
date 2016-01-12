#!/bin/bash
# Detect script path
pushd `dirname $0` > /dev/null
SCRIPTPATH=`pwd`
popd > /dev/null

# === Edit default options to match your need ===

FROM_TYPE="SER" # SER, TCP
TO_TYPE="SSL"   # TCP, SSL

COMM_PORT_LINUX=/dev/ttyUSB0
COMM_PORT_OSX=/dev/tty.usbmodem
COMM_BAUD=9600
SERV_ADDR=cloud.blynk.cc
SERV_PORT_SSL=8441
SERV_PORT_TCP=8442
SERV_PORT_2WAY=8443
LSTN_PORT=8442

SRVR_CERT="$SCRIPTPATH/certs/server.crt"
CLNT_CERT="$SCRIPTPATH/certs/client.pem"

# === Edit the lines below only if absolutely sure what you're doing ===

# Setup exit handler
trap "echo Exited!; exit;" SIGINT SIGTERM
echo [ Press Ctrl+C to exit ]

usage="
    This script redirects serial communication to the server.

    You can specify port, baud rate, and server endpoint like this:
      blynk-ser.sh -c <serial port> -b <baud rate> -s <server address> -p <server port>

    The defaults are:
      -c,--comm      /dev/ttyUSB0       (on Linux)
                     COM1               (on Windows)
                     /dev/tty.usbserial (on OSX)
      -b,--baud      9600
      -s,--server    cloud.blynk.cc
      -p,--port      8442

    If the specified serial port is not found, it will ask to enter another one.
    The script also tries to reestablish connection if it was lost.
"

avrdude_warn="Warning: avrdude is running
 Avoid uploading sketches and running this script at the same time.
 If you didn't run avrdude, maybe it just stuck. You can kill it using:
   killall avrdude
"

function detect_conflicts {
    # Detect if avrdude is running
    if pgrep avrdude; then echo -n "$avrdude_warn"; fi
}

detect_conflicts

# Detect socat
if ! hash socat 2>/dev/null; then
    echo "This script uses socat utility, but could not find it."
    echo
    if [[ "$OSTYPE" == "linux-gnu" ]]; then
        echo "  Try installing it using: sudo apt-get install socat"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Try installing it using: brew install socat"
    fi
    exit 1
fi

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    GETOPT=getopt -o
elif [[ "$OSTYPE" == "darwin"* ]]; then
    GETOPT=getopt
fi

# Execute getopt
ARGS=$($GETOPT hf:c:b:l:t:s:p: -l "help,from:,comm:,baud:,listen:,to:,server:,port:,cert:" -n "blynk-gateway.sh" -- "$@");

# Bad arguments
if [ $? -ne 0 ];
then
  echo -n "$usage"
  exit 1
fi

eval set -- "$ARGS";

while true; do
  case "$1" in
    -h|--help)
      shift
      echo -n "$usage"
      exit 0
      ;;
    ####
    -f|--from)
      shift
      if [ -n "$1" ]; then
        FROM_TYPE=$1
        shift
      fi
      ;;
    -c|--comm)
      shift
      if [ -n "$1" ]; then
        COMM_PORT_LINUX=$1
        COMM_PORT_OSX=$1
        shift
      fi
      ;;
    -b|--baud)
      shift
      if [ -n "$1" ]; then
        COMM_BAUD=$1
        shift
      fi
      ;;
    -l|--listen)
      shift
      if [ -n "$1" ]; then
        LSTN_PORT=$1
        shift
      fi
      ;;
    ####
    -t|--to)
      shift
      if [ -n "$1" ]; then
        TO_TYPE=$1
        shift
      fi
      ;;
    -s|--server)
      shift
      if [ -n "$1" ]; then
        SERV_ADDR=$1
        shift
      fi
      ;;
    -p|--port)
      shift
      if [ -n "$1" ]; then
        SERV_PORT_SSL=$1
        SERV_PORT_TCP=$1
        SERV_PORT_2WAY=$1
        shift
      fi
      ;;
    --cert)
      shift
      if [ -n "$1" ]; then
        SRVR_CERT=$1
        shift
      fi
      ;;
    ####
    --)
      shift;
      break;
      ;;
  esac
done

# Construct command
GEN_ATTR="-d -d"

TCP_ATTR="nodelay" #,nonblock=1,rcvtimeo=1,sndtimeo=1
SER_ATTR="raw,echo=0,clocal=1,cs8,nonblock=1"

if [[ "$FROM_TYPE" == "SER" ]]; then
    if [[ "$OSTYPE" == "linux-gnu" ]]; then
        COMM_PORT=$COMM_PORT_LINUX
        COMM_WCARD="/dev/ttyUSB* /dev/ttyACM*"
        COMM_STTY="-F"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        COMM_PORT=$COMM_PORT_OSX
        COMM_WCARD="/dev/tty.usbserial* /dev/tty.usbmodem*"
        COMM_STTY="-f"
    else
        echo "Can't detect OS type!"
        exit 1
    fi

    # Ask for serial port interactively if not found
    if [ ! -e "$COMM_PORT" ]; then
        echo $COMM_PORT not found.
        echo -n "Select serial port [" `ls $COMM_WCARD 2> /dev/null` "]: "
        read COMM_PORT
    fi
    echo Resetting device $COMM_PORT...
    stty $COMM_STTY $COMM_PORT hupcl
    # Disable restarting
    #stty $COMM_STTY $COMM_PORT -hupcl

    if [[ "$OSTYPE" == "linux-gnu" ]]; then
        FROM_ATTR="FILE:$COMM_PORT,$SER_ATTR,b$COMM_BAUD"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        FROM_ATTR="GOPEN:$COMM_PORT,$SER_ATTR,ixoff=0,ixon=0,ispeed=$COMM_BAUD,ospeed=$COMM_BAUD,crtscts=0"
    fi
elif [[ "$FROM_TYPE" == "TCP" ]]; then
    FROM_ATTR="TCP-LISTEN:$LSTN_PORT,reuseaddr,fork,$TCP_ATTR"
else
    echo "$FROM_TYPE is not supported."
    exit 1
fi

if [[ "$TO_TYPE" == "TCP" ]]; then
    echo "Warning: Server connection may be insecure!"
    TO_ATTR="TCP:$SERV_ADDR:$SERV_PORT_TCP,$TCP_ATTR"
elif [[ "$TO_TYPE" == "SSL" ]]; then
    if [ -e $SRVR_CERT ]; then
        TCP_ATTR="cafile=$SRVR_CERT,$TCP_ATTR"
    else
        echo "Warning: $SRVR_CERT not found. Skipping server verification (connection may be insecure)!"
        TCP_ATTR="verify=0,$TCP_ATTR"
    fi

    if [ -e $CLNT_CERT ]; then
        TCP_ATTR="cert=$CLNT_CERT,$TCP_ATTR"
    fi

    TO_ATTR="openssl-connect:$SERV_ADDR:$SERV_PORT_SSL,$TCP_ATTR"
elif [[ "$TO_TYPE" == "2WAY" ]]; then
    echo "2WAY is not supported yet."
    exit 1
else
    echo "$TO_TYPE is not supported."
    exit 1
fi

while [ 1 ]; do
    echo Connecting: "$FROM_ATTR <-> $TO_ATTR"

    socat $GEN_ATTR $FROM_ATTR $TO_ATTR

    detect_conflicts

    echo Reconnecting in 3s...
    sleep 3
done

