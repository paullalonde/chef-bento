#!/usr/bin/env bash

set -euo pipefail

# Getting script directory location
SCRIPT_RELATIVE_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$SCRIPT_RELATIVE_DIR" || exit

usage() {
  echo "usage: amazonlinux-2023-amd64-virtualbox-build.sh [OPTIONS]"
  echo "Options:"
  echo "  --version <version>   Specify the version to download"
  exit 1
}

ARCHITECTURE=amd64
PROVIDER=virtualbox
KERNEL=6.1
VBOX_HOST_PORT=4422
VERSION=''

while [ $# -gt 0 ]
do
  case "$1" in
    --version)
      VERSION="$2"
      shift
      shift
    ;;
    
    *)
      usage
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "The --version argument is required."
  exit 2
fi

# Delete any leftover VM first: "unregistervm --delete" removes its attached disk
# by path, which would otherwise delete the freshly converted vdi below.
VM="AmazonLinuxBento"
echo Powering off and deleting any existing VMs named $VM
set +e
VBoxManage controlvm $VM poweroff --type headless 2> /dev/null
VBoxManage unregistervm $VM --delete 2> /dev/null
set -e
sleep 5

BENTO_OS=amazonlinux-2023
BENTO_BUILDS_DIR="$(pwd)/builds"
BENTO_BUILD_FILES_DIR="$BENTO_BUILDS_DIR/build_files"
BENTO_OUTPUT_DIR="$BENTO_BUILDS_DIR/build_complete"

# set tmp dir for files
AMZDIR="$BENTO_BUILD_FILES_DIR/$BENTO_OS/$VERSION/$ARCHITECTURE/$PROVIDER"
mkdir -p "$AMZDIR"

echo "Cleaning up old files"
rm -rf "$AMZDIR"/*.iso "$AMZDIR"/*.ovf "$AMZDIR"/*.vmdk "$AMZDIR"/*.vdi "$BENTO_OUTPUT_DIR"

case "$ARCHITECTURE" in
  amd64)
    SOURCE_ARCH=x86_64
    KVM_SUBDIR="kvm"
  ;;
  
  arm64)
    SOURCE_ARCH="$ARCHITECTURE"
    KVM_SUBDIR="kvm-$ARCHITECTURE"
  ;;

  *)
    echo "Unsupported architecture: $ARCHITECTURE"
    exit 3
esac

SOURCE_URL="https://cdn.amazonlinux.com/al2023/os-images/$VERSION/$KVM_SUBDIR/"

CHECKSUM_FILE=SHA256SUMS
SIG_FILE=SHA256SUMS.RSASSA_PKCS1_V1_5_SHA_256
IMAGE_FILE="al2023-kvm-$VERSION-kernel-$KERNEL-$SOURCE_ARCH.xfs.gpt.qcow2"

for FILE in "$CHECKSUM_FILE" "$SIG_FILE" "$IMAGE_FILE"
do
  echo "## Downloading $SOURCE_URL/$FILE ..."

  if [[ ! -f "$AMZDIR/$FILE" ]]; then
    curl -fSL -o "$AMZDIR/$FILE" "$SOURCE_URL/$FILE"
  fi
done

pushd "$AMZDIR" >/dev/null
sha256sum --check --ignore-missing "$CHECKSUM_FILE"
popd >/dev/null

IMAGE_PATH="$AMZDIR/$IMAGE_FILE"

echo "Convert qcow2 to vdi"
VDI_NAME="$PROVIDER.vdi"
VDI_PATH="$AMZDIR/$VDI_NAME"
qemu-img convert -f qcow2 "$IMAGE_PATH" -O vdi "$VDI_PATH"

if [ ! -f "$VDI_PATH" ]; then
  echo There must be a file named "$VDI_NAME" in "$AMZDIR"!
  echo You can download the files at  https://cdn.amazonlinux.com/al2023/os-images/latest/
  exit 1
fi

echo "Creating ISO"
SEED_ISO_DIR="$(pwd)/packer_templates/http/amazon"
ISO_PATH="$AMZDIR"/seed.iso
if [ -x "$(command -v genisoimage)" ]; then
  genisoimage -output "$ISO_PATH" -volid cidata -joliet -rock "$SEED_ISO_DIR"/user-data "$SEED_ISO_DIR"/meta-data
elif [ -x "$(command -v hdiutil)" ]; then
  hdiutil makehybrid -o "$ISO_PATH" -hfs -joliet -iso -default-volume-name cidata "$SEED_ISO_DIR"/
elif [ -x "$(command -v mkisofs)" ]; then
  mkfsiso9660 -o "$ISO_PATH" "$SEED_ISO_DIR"/
else
  echo "No tool found to create the seed.iso"
  exit 1
fi

echo "Creating the VM"
# from https://www.perkin.org.uk/posts/create-virtualbox-vm-from-the-command-line.html
VBoxManage createvm --name $VM --ostype "Fedora_64" --register
VBoxManage storagectl $VM --name "SATA Controller" --add sata --controller IntelAHCI
VBoxManage storageattach $VM --storagectl "SATA Controller" --port 0 --type hdd --medium "$VDI_PATH"
VBoxManage storageattach $VM --storagectl "SATA Controller" --port 1 --type dvddrive --medium "$ISO_PATH"
VBoxManage modifyvm $VM --memory 2048
VBoxManage modifyvm $VM --cpus 2
VBoxManage modifyvm $VM --nat-localhostreachable1 on
VBoxManage modifyvm $VM --vram 10
VBoxManage modifyvm $VM --graphicscontroller vmsvga
VBoxManage modifyvm $VM --vrde off
VBoxManage modifyvm $VM --audio-driver none
VBoxManage modifyvm $VM --ioapic on
sleep 5

echo "Sleeping for 120 seconds to let the system boot and cloud-init to run"
VBoxManage startvm $VM --type headless
sleep 120
VBoxManage controlvm $VM poweroff --type headless
VBoxManage storageattach $VM --storagectl "SATA Controller" --port 1 --type dvddrive --medium none
sleep 5

echo "Exporting the VM to an OVF file"
OVF_PATH="$AMZDIR"/$PROVIDER.ovf
VBoxManage export $VM -o "$OVF_PATH"
sleep 5

echo "Deleting the VM"
VBoxManage unregistervm $VM --delete

echo "starting packer build of amazonlinux"
# bento only keeps the last --vars option, so all variables go in a single one
BENTO_VARS="ssh_timeout=60m,vbox_source_path=$OVF_PATH,vbox_checksum=null,vbox_host_port_min=$VBOX_HOST_PORT,vbox_host_port_max=$VBOX_HOST_PORT"
bento build --version "$VERSION" --vars "$BENTO_VARS" "$(pwd)"/os_pkrvars/amazonlinux/$BENTO_OS-$ARCHITECTURE.pkrvars.hcl

echo "Cleaning up files"
rm -f "$AMZDIR"/*.iso "$AMZDIR"/*.ovf "$AMZDIR"/*.vmdk "$AMZDIR"/*.vdi

BENTO_BOX="$BENTO_OUTPUT_DIR/$BENTO_OS-$ARCHITECTURE.$PROVIDER.box"
BENTO_METADATA="$BENTO_OUTPUT_DIR/$BENTO_OS-$ARCHITECTURE._metadata.json"
OUTPUT_DIR="$BENTO_OUTPUT_DIR/$BENTO_OS"
OUTPUT_VERSION_DIR="$OUTPUT_DIR/$VERSION"
OUTPUT_ARCHITECTURE_DIR="$OUTPUT_VERSION_DIR/$ARCHITECTURE"
OUTPUT_BOX="$OUTPUT_ARCHITECTURE_DIR/$PROVIDER.box"
OUTPUT_CATALOG="$OUTPUT_DIR/catalog.json"

mkdir -p "$OUTPUT_ARCHITECTURE_DIR"

mv "$(pwd)/builds/build_complete/$BENTO_OS-$ARCHITECTURE.$PROVIDER.box" "$OUTPUT_BOX"

jq <"$BENTO_METADATA" \
  --arg url "$OUTPUT_BOX" \
  '{ name: "paullalonde/amazon-linux-2023", versions: [{ version: .version, status: "active", providers: [{ architecture: .arch, checksum: .providers[0].checksum, checksum_type: .providers[0].checksum_type, name: .providers[0].name, url: $url }] }] }' \
  >"$OUTPUT_CATALOG"

# rm -f "$BENTO_METADATA"
