#!/bin/bash
set -euo pipefail

# ====== CONFIG ======
STORAGE_NAME="local-lvm"
DISK_ENTRY="scsi0"
BRIDGE="vmbr0"
TIMEOUT=60
# ====================

print_header() { echo -e "\n\033[1;36m=== $1 ===\033[0m"; }
error_exit()   { echo -e "\n\033[0;31m[ERROR] $1\033[0m"; exit 1; }
success()      { echo -e "\033[0;32m[SUCCESS] $1\033[0m"; }
info()         { echo -e "\033[0;34m[INFO] $1\033[0m"; }

VMID="${1-:-}"

ask_vmid() {
  # ถ้ามีอาร์กิวเมนต์ ให้ใช้เลย
  if [[ -n "$VMID" ]]; then
    echo "🔧 ใช้ VMID จากอาร์กิวเมนต์: $VMID"
    return
  fi

  # แสดงรายการ VM
  echo "🖥️  VM ที่กำลังใช้งานบน Proxmox:"
  qm list

  # อ่านจาก /dev/tty เสมอ (ปลอดภัยกับ piped execution)
  if [[ -r /dev/tty ]]; then
    read -r -p $'\n🔧 ใส่ VMID ที่ต้องการ reset fingerprint: ' VMID </dev/tty
  else
    # fallback: อ่านจาก stdin (ถ้ามี)
    read -r -p $'\n🔧 ใส่ VMID ที่ต้องการ reset fingerprint: ' VMID
  fi

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
    if [[ -r /dev/tty ]]; then
      read -r -p "❓ ต้องการปิด VM นี้ก่อนทำงานต่อหรือไม่? [y/N] " confirm </dev/tty
    else
      read -r -p "❓ ต้องการปิด VM นี้ก่อนทำงานต่อหรือไม่? [y/N] " confirm
    fi
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
  local config="/etc/pve/qemu-server/${VMID}.conf"
  local backup="${config}.bak.$(date +%s)"
  local tmp="/tmp/${VMID}.conf.tmp.$RANDOM"
  local newuuid="$1"

  cp "$config" "$backup"
  info "สำรองไฟล์ config -> $backup"

  # เอา uuid= เดิมออก แล้ววาง uuid ใหม่เป็นบรรทัดแรก
  grep -v '^uuid=' "$config" > "$tmp" || true
  {
    echo "uuid=$newuuid"
    cat "$tmp"
  } > "${config}.new"

  # แทนที่ไฟล์ config แบบ atomic
  mv "${config}.new" "$config"

  # ตรวจสอบ parse
  if qm config "$VMID" > /dev/null 2>&1; then
    success "UUID เขียนเรียบร้อย: $newuuid"
    rm -f "$tmp" || true
  else
    # คืนค่า backup ถ้า parse ไม่ผ่าน
    mv "$backup" "$config"
    rm -f "$tmp" || true
    error_exit "การอัปเดต config ล้มเหลว — คืนค่า config เดิมแล้ว"
  fi
}

reset_fingerprint() {
  print_header "กำลังรีเซ็ต UUID, MAC, และ Disk Serial"

  local NEW_UUID NEW_MAC NEW_DISK_SERIAL
  NEW_UUID=$(uuidgen)
  NEW_MAC=$(hexdump -n3 -e '/1 ":%02X"' /dev/random)
  NEW_MAC="52:54:00${NEW_MAC}"
  NEW_DISK_SERIAL="DISK$(openssl rand -hex 4 | tr 'a-f' 'A-F')"

  safe_write_uuid_into_config "$NEW_UUID"

  qm set "$VMID" --net0 "e1000=${NEW_MAC},bridge=${BRIDGE}"
  success "MAC Address ใหม่: $NEW_MAC"

  qm set "$VMID" --"$DISK_ENTRY" "${STORAGE_NAME}:vm-${VMID}-disk-0,serial=${NEW_DISK_SERIAL}"
  success "Disk Serial ใหม่: $NEW_DISK_SERIAL"
}

final_message() {
  print_header "🎉 เสร็จสมบูรณ์"
  echo "✅ คุณสามารถบูต VM ID: $VMID และติดตั้ง/ทดสอบ PHPMaker ใหม่ได้"
}

# ---- MAIN ----
print_header "⚙️ Proxmox VM Fingerprint Reset Tool (interactive)"
ask_vmid
check_vm_exists
shutdown_vm_if_running
reset_fingerprint
final_message
