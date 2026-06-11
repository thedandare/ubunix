#!/bin/sh

# 1. Set default values
PASSTHROUGH_DEVICE="/dev/sdc"
# PASSTHROUGH_DEVICE="/dev/nvme0n1"
MEMORY=24096M
SPICE_PORT=5900
OVFM_BIOS="/home/leo/emulators/OVMF_CODE_4M.fd"
MY_VARS_FD="/home/leo/emulators/my_vars.fd"
MACHINE="q35"
SMP=24

# 2. Parse named parameters
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device)
      PASSTHROUGH_DEVICE="$2"
      shift 2
      ;;
    -m|--memory)
      MEMORY="$2"
      shift 2
      ;;
    -p|--port)
      SPICE_PORT="$2"
      shift 2
      ;;
    -b|--bios)
      OVFM_BIOS="$2"
      shift 2
      ;;
    -v|--vars)
      MY_VARS_FD="$2"
      shift 2
      ;;
    --machine)
      MACHINE="$2"
      shift 2
      ;;
    -s|--smp)
      SMP="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  -d, --device    Passthrough device (Default: $PASSTHROUGH_DEVICE)"
      echo "  -m, --memory    Memory in MB (Default: $MEMORY)"
      echo "  -p, --port      Spice port (Default: $SPICE_PORT)"
      echo "  -b, --bios      OVMF BIOS file path"
      echo "  -v, --vars      My vars FD file path"
      echo "  --machine       Machine type (Default: $MACHINE)"
      echo "  -s, --smp       SMP cores (Default: $SMP)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage information."
      exit 1
      ;;
  esac
done

# 3. Construct QEMU parameters (Double quotes allow variable expansion)
PARAM_VM="-enable-kvm -m $MEMORY -cpu host -machine $MACHINE -smp $SMP"
# CDROM="-cdrom /win/Windows_InsiderPreview_Server_vNext_en-us_29595.iso"
PARAM_BIOS="-boot menu=on -drive if=pflash,format=raw,readonly=on,file=$OVFM_BIOS -drive if=pflash,format=raw,file=$MY_VARS_FD -device ahci,id=ahci0 "
# USE_AUDIO="-audio driver=pipewire,model=hda "
# User mode networking allows the guest to connect back to the outside world through TCP, UDP etc. ICMP Ping is not allowed. Also connections from host to guest are not allowed unless using port forwarding. ➕ Create a NIC (model e1000) and connect to mynet0 backend created by the previous parameter
USER_MODE_NETWOKRING="-netdev user,id=mynet0,hostfwd=tcp::8080-:80 -device e1000,netdev=mynet0"
# TAP network overcomes all of the limitations of user mode networking, but requires a tap to be setup before running qemu. Also qemu must be root. ➕ Create a tap network backend with id mynet0. This will connect to a tap interface tap0 which must be already setup. Do not use any network configuration scripts. ➕ Create a NIC (model e1000) and connect to mynet0 backend created by the previous parameter.
# TAP_NETWORKING="-netdev tap,id=mynet0,ifname=tap1,script=no,downscript=no -device e1000,netdev=mynet0,mac=52:55:00:d1:55:01"
# BRIDGE_NETWORKING="-netdev bridge,id=mynet0,br=br0 -device virtio-net,netdev=mynet0 "
# USE_GTK_VGA="-vga std -display gtk,show-tabs=on,gl=on -device virtio-vga-gl,max_outputs=1 "
USE_SPICE="-vga qxl -spice port=$SPICE_PORT,addr=127.0.0.1,disable-ticketing=on -chardev spicevmc,id=spicechannel1,name=vdagent"
NVME_PASSTHROUGH="-drive file=$PASSTHROUGH_DEVICE,format=raw,if=none,id=physical_sata,cache=none -device ide-hd,drive=physical_sata,bus=ahci0.0 "
# 4. Menu para escolher qual combinação de comando executar
echo "==========================================="
echo " Selecione o modo de execução da VM:"
echo "==========================================="

options=(
  "Rodar com SPICE (Acesso Remoto)"
  "Rodar com GTK VGA (Interface Local)"
  "Rodar Completo (SPICE + GTK)"
  "Sair"
)

PS3="Digite o número da sua opção: "
        # $USE_TAP \
        # $USE_AUDIO \

select opt in "${options[@]}"
do
  case $opt in
    "Rodar com SPICE (Acesso Remoto)")
      echo "Iniciando VM no modo SPICE..."
      sudo qemu-system-x86_64 \
        $PARAM_VM \
        $PARAM_BIOS \
        $NVME_PASSTHROUGH \
        $BRIDGE_NETWORKING \
        $CDROM \
        # $USE_AUDIO \
        $USE_SPICE
      break
      ;;

    "Rodar com GTK VGA (Interface Local)")
      echo "Iniciando VM no modo GTK VGA..."
      sudo qemu-system-x86_64 \
        $PARAM_VM \
        $PARAM_BIOS \
        $NVME_PASSTHROUGH \
        $BRIDGE_NETWORKING \
        $USE_GTK_VGA
      break
      ;;

    "Rodar Completo (SPICE + GTK)")
      echo "Iniciando VM com SPICE e GTK ativados..."
      sudo qemu-system-x86_64 \
        $PARAM_VM \
        $PARAM_BIOS \
        $NVME_PASSTHROUGH \
        $USE_SPICE \
        $USE_GTK_VGA
      break
      ;;

    "Sair")
      echo "Execução cancelada."
      exit 0
      ;;

    *)
      echo "Opção inválida. Escolha um número válido."
      ;;
  esac
done


# Valid audio device model names:
# ac97        Intel 82801AA AC97 Audio
# adlib       Yamaha YM3812 (OPL2)
# cs4231a     CS4231A
# es1370      ENSONIQ AudioPCI ES1370
# gus         Gravis Ultrasound GF1
# hda         Intel HD Audio
# sb16        Creative Sound Blaster 16
# virtio      Virtio Sound
