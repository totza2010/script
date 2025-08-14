#!/bin/bash
set -euo pipefail

VMID=""
STORAGE_NAME="local-lvm"
DISK_ENTRY="scsi0"
BRIDGE="vmbr0"
TIMEOUT=60

print_header() { echo -e "\n\033[1;36m=== $1 ===\033[0m"; }
error_exit() { echo -e "\n\033[0;31m[ERROR] $1\033[0m"; exit 1; }
success() { echo -e "\033[0;32m[SUCCESS] $1\033[0m"; }
info() { echo -e "\033[0;34m[INFO] $1\033[0m"; }

ask_vmid() {
  echo "🖥️  VM ที่กำลังใช้งานบน Proxmox:"
  qm list
  echo
  read -p "🔧 ใส่ VMID ที่ต้องการ reset fingerprint: " VMID
  [[ -z "$VMID" ]] && error_exit "VMID ว่างเปล่า"
}

check_vm_exists() {
  qm config "$VMID" > /dev/null 2>&1 || error_exit "ไม่พบ VMID: $VMID"
}

shutdown_vm_if_running() {
  local status
  status=$(qm status "$VMID" | awk '{print $2}')
  if [[ "$status" == "running" ]]; then
    print_header "VM กำลังเปิดอยู่"
    read -p "❓ ต้องการปิด VM นี้ก่อนทำงานต่อหรือไม่? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      error_exit "คุณเลือกไม่ปิด VM — ยกเลิกการทำงาน"
    fi
    info "สั่งปิด VM..."
    qm shutdown "$VMID"
    echo -n "⏳ รอ VM ปิด"
    for ((i = 0; i < TIMEOUT; i++)); do
      sleep 1
      echo -n "."
      status=$(qm status "$VMID" | awk '{print $2}')
      if [[ "$status" == "stopped" ]]; then
        echo
        success "VM ปิดเรียบร้อยแล้ว"
        return
      fi
    done
    echo
    error_exit "VM ยังไม่ปิดภายใน $TIMEOUT วินาที"
  else
    success "VM ปิดอยู่แล้ว"
  fi
}

safe_write_uuid_into_config() {
  local config="/etc/pve/qemu-server/$VMID.conf"
  local backup="${config}.bak.$(date +%s)"
  local tmp="/tmp/${VMID}.conf.tmp.$RANDOM"

  cp "$config" "$backup"
  info "สำรองไฟล์ config -> $backup"

  # เอา uuid= ออกก่อน แล้วเขียนไฟล์ใหม่โดยวาง uuid เป็นบรรทัดแรก
  grep -v '^uuid=' "$config" > "$tmp"
  {
    echo "uuid=$1"
    cat "$tmp"
  } > "${config}.new"

  # ตรวจสอบ parse ก่อน (qm config อ่านไฟล์จริงที่ /etc/pve/qemu-server/VMID.conf)
  # ดังนั้นทดสอบด้วยการชั่วคราวเขียนไปยังไฟล์จริงก่อนตรวจสอบ — แต่เราทำแบบ atomic: ย้ายเข้าไปแทนที่ไฟล์จริงหลังตรวจสอบเสร็จ
  mv "${config}.new" "$config"
  if qm config "$VMID" > /dev/null 2>&1; then
    success "UUID เขียนเรียบร้อย: $1"
  else
    # restore backup ถ้า parse ไม่ผ่าน
    mv "$backup" "$config"
    rm -f "$tmp" || true
    error_exit "การอัปเดต config ล้มเหลว — คืนค่า config เดิมแล้ว"
  fi

  rm -f "$tmp" || true
}

reset_fingerprint() {
  print_header "กำลังรีเซ็ต UUID, MAC, และ Disk Serial"

  NEW_UUID=$(uuidgen)
  NEW_MAC=$(hexdump -n3 -e '/1 ":%02X"' /dev/random)
  NEW_MAC="52:54:00${NEW_MAC}"
  NEW_DISK_SERIAL="DISK$(openssl rand -hex 4 | tr 'a-f' 'A-F')"

  safe_write_uuid_into_config "$NEW_UUID"

  qm set "$VMID" --net0 e1000="$NEW_MAC",bridge="$BRIDGE"
  success "MAC Address ใหม่: $NEW_MAC"

  qm set "$VMID" --$DISK_ENTRY ${STORAGE_NAME}:vm-$VMID-disk-0,serial=$NEW_DISK_SERIAL
  success "Disk Serial ใหม่: $NEW_DISK_SERIAL"
}

final_message() {
  print_header "🎉 เสร็จสมบูรณ์"
  echo "✅ คุณสามารถบูต VM ID: $VMID และติดตั้ง PHPMaker ใหม่ได้"
}

# === MAIN ===
print_header "⚙️ Proxmox VM Fingerprint Reset Tool (fixed uuid write)"
ask_vmid
check_vm_exists
shutdown_vm_if_running
reset_fingerprint
final_message
