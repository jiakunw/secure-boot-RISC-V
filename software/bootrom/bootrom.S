#define BOOTADDR_REG 0x1000
#define STACK_TOP 0x88010000

.extern bootrom_main

// boot all cores and enter the bootrom C path
.section .text.start, "ax", @progbits
.globl _start
_start:
  li a1, 0x2000000 // clint base
  csrr a0, mhartid
  bnez a0, boot_core
  addi a2, a1, 4
  li a3, 1

interrupt_loop:
  sw a3, 0(a2)
  addi a2, a2, 4
  lw a3, -4(a2)
  bnez a3, interrupt_loop
  j boot_core_hart0

// wait here until the simulation wakeup path starts boot
.section .text.hang, "ax", @progbits
.globl _hang
_hang:
  la a0, _start
  csrw mtvec, a0
  csrr t0, misa
  srai t0, t0, 'S' - 'A'
  andi t0, t0, 0x1
  beqz t0, 1f
  csrw mideleg, zero
  li a0, 0x222
  csrc mip, a0

1:
  li a0, 8
  csrw mie, a0
  csrs mstatus, a0

wfi_loop:
  wfi
  j wfi_loop

// reset landing slot
.section .text.hang80, "ax", @progbits
.globl _hang80
_hang80:
  j _hang

// nonzero harts wait for hart 0
boot_core:
  lw t0, 0(a1)
  bnez t0, boot_core
  sll a0, a0, 2
  add a1, a0, a1

boot_core_hart0:
  sw zero, 0(a1)      // clear wakeup interrupt

  li sp, STACK_TOP    // set stack before C
  call bootrom_main   // enter bootrom C logic

bootrom_returned:
  wfi                 // bootrom_main should not return
  j bootrom_returned

.align 3
_dtb: