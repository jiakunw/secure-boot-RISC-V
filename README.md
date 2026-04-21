# COMS 6424 Project Proposal — Option 1
## Secure Boot Microcontroller on a 64-bit In-Order RISC-V Pipeline

**Team:** SecureMaxxing: Jiakun Wang (jw4865), Luckie Bah (kno2117)
**Date:** April 20, 2026

---

## 1. Project Summary

We will design and implement a 64-bit RISC-V microcontroller that supports
secure boot. The processor is an in-order scalar pipeline with branch
prediction and Sv39 virtual memory. Our work focuses on establishing a root
of trust in an immutable BootROM, enforcing a chain of trust over subsequent
boot stages via cryptographic signature verification, and hardening the boot
path against microarchitectural side channels.

All modifications — BootROM logic, OTP/fuse model, anti-rollback counter,
PMP configuration, and signature verification code — are authored by the
team.

Chipyard Repo: https://github.com/ucb-bar/chipyard/

usage:

```
git clone --recursive https://github.com/ucb-bar/chipyard.git
```

---

## 2. Threat Model

### 2.1 Assets We Protect
- **A1. Boot image integrity:** the code that runs after BootROM must not
  have been modified from what the developer signed.
- **A2. Boot image authenticity:** only images signed by the authorized
  developer key shall execute.
- **A3. BootROM integrity at runtime:** later-stage software must not be
  able to overwrite or bypass the BootROM.
- **A4. Rollback resistance:** an attacker cannot force the system to
  execute an older, signed-but-vulnerable image.
- **A5. Confidentiality of boot-time secrets:** intermediate verification
  state (hashes, buffers) must not leak to later-stage untrusted software
  via shared microarchitectural state.

### 2.2 Attacker Capabilities (In Scope)
- **C1. Malicious flash contents:** the attacker can arbitrarily modify
  any data in off-chip flash, including boot images, manifests, and
  signatures.
- **C2. Malicious post-boot software:** after boot completes, untrusted
  user-mode or supervisor-mode code may inject malicious code/data.
- **C3. Software-initiated microarchitectural attacks:** the attacker can
  mount Spectre-class, cache, TLB, or branch-predictor side-channel
  attacks from post-boot software.
- **C4. Replay of old signed images:** the attacker may attempt to load
  legitimately signed but outdated (vulnerable) firmware.

### 2.3 Trust Assumptions
- **T1.** The BootROM content and the public-key hash burned into the
  OTP peripheral are correct at manufacture time and immutable thereafter.
- **T2.** The hardware RTL is correctly synthesized and not tampered with
  physically.
- **T3.** The developer's signing private key is stored offline and is
  not compromised.
- **T4.** Cryptographic primitives (SHA-256, Ed25519) are computationally
  secure against realistic adversaries.

### 2.4 Out of Scope
- **O1.** Physical attacks: fault injection, EM analysis, decapping,
  probing, power analysis.
- **O2.** Supply-chain attacks on the RTL or toolchain.
- **O3.** DRAM-level attacks (e.g., Rowhammer) — our simulation
  environment does not model DRAM.
- **O4.** Denial of service: an attacker who controls flash can always
  produce an image that fails verification and bricks the device; our
  design detects this but does not guarantee availability.
- **O5.** Covert channels exploiting shared off-chip resources.

---

## 3. Architecture

### 3.1 Core Pipeline
- 64-bit RV64GC in-order scalar pipeline
- Branch predictor: BHT + BTB + Return Address Stack
- Sv39 virtual memory with TLB
- M / S / U privilege modes
- 16-entry Physical Memory Protection (PMP) unit with Lock bit

### 3.2 Added Security Components
- **BootROM:** read-only, reset vector target; contains verification code,
  hardcoded verification constants, and jump logic.
- **OTP Peripheral:** MMIO read-only device returning a 32-byte public-key
  hash; modeled as a fixed constant in simulation.
- **Rollback Counter Peripheral:** MMIO monotonic counter enforced in
  hardware (writes only allowed to a strictly greater value).
- **PMP Configuration:** locked at end of BootROM to prevent later stages
  from accessing or modifying BootROM, OTP, and counter regions.

### 3.3 Software Stack in BootROM
- Minimal crt0 (set SP, clear BSS)
- SHA-256 reference implementation (RFC 6234 derivative)
- Ed25519 verification from MonoCypher (constant-time)
- Manifest parser and verification orchestrator
- PMP lock-down routine
- Speculation fence + jump to next stage

---

## 4. Boot Flow

1. Reset deasserted → PC = BootROM entry.
2. BootROM initializes stack, clears BSS.
3. BootROM loads the 2nd-stage manifest from flash.
4. BootROM computes SHA-256 over (manifest || payload).
5. BootROM verifies Ed25519 signature using the public key whose hash
   matches the OTP value.
6. BootROM checks manifest.version ≥ rollback_counter.
7. BootROM writes manifest.version back to rollback_counter
   (monotonic update).
8. BootROM configures PMP entries covering BootROM, OTP, and counter
   regions with R=1, W=0, X=0, L=1 (locked).
9. BootROM executes `fence.i` and `fence` to serialize pipeline state.
10. BootROM jumps to the verified entry point of the 2nd stage.
11. For now, the 2nd stage is a simple kernel, which only does one thing: switch from M mode to S mode (user mode), and hangs.

Any failure in steps 4–6 triggers a halt (no fallback in the baseline
design; a recovery partition is listed as future work).

---

## 5. Microarchitectural Security Analysis

### 5.1 Attacks Inherently Prevented by In-Order Scalar Design
- **Meltdown-class:** absent, as permission checks complete before
  value forwarding in an in-order pipeline.
- **Spectre-v4 (Store-to-Load bypass):** absent, as in-order execution
  does not reorder memory operations speculatively.
- **MDS / LVI:** absent, as the relevant fill/line buffers are not
  present in CVA6-class cores.

### 5.2 Residual Risks and Mitigations
| Channel | Applies? | Mitigation |
|---------|----------|------------|
| Spectre-v1 (bounds-check bypass) | Yes (BP present) | Post-boot code is untrusted; BootROM itself has no secret-dependent bounds checks |
| Spectre-v2 (BTB poisoning) | Possible | `fence.i` before jumping out of BootROM; BTB not shared with post-boot secrets |
| Cache side channel | Possible post-boot | Ed25519 and SHA-256 implementations are constant-time; BootROM clears scratch buffers before exit |
| TLB side channel | Not during boot | BootROM runs in M-mode without paging; no TLB state tied to secrets |
| BHT/BranchScope | Possible post-boot | Constant-time crypto; no secret-dependent branches in verification code |

### 5.3 Boot-Exit Hygiene
- All scratch buffers (hash state, signature working set) are zeroed
  before the jump.
- PMP locks prevent post-boot code from reading BootROM contents,
  OTP, or the rollback counter.
- `fence.i` + `fence` serialize the pipeline so that speculative state
  tied to BootROM execution does not persist across the privilege
  boundary.

---

## 6. Verification & Evaluation Plan

### 6.1 Functional Verification
- **Positive tests:** valid signed image boots successfully; rollback
  counter updates; PMP correctly configured.
- **Negative tests:** unsigned image rejected; tampered payload rejected;
  tampered manifest rejected; signature from wrong key rejected;
  version-downgrade rejected.
- **PMP tests:** post-boot code attempting to read/write BootROM, OTP,
  or counter region triggers access fault.

### 6.2 Performance Validation
- Measure boot latency (cycles from reset to jump-to-2nd-stage).
- Decompose latency by phase: SHA-256, Ed25519, PMP config, jump.
- Compare against baseline (non-secure boot) to quantify overhead.
- Confirm zero steady-state overhead (secure boot executes only once).

### 6.3 Security Validation
- Run negative tests listed in 6.1 and confirm expected halt behavior.
- Inspect waveforms to confirm PMP Lock bit is set before jump.
- Demonstrate, via simulation, that post-boot attempts to access
  protected regions trigger access faults.

---

## 7. Milestones

| Date | Milestone |
|------|-----------|
| Apr 20 | Checkpoint 1: threat model, architecture, plan, artifact list |
| Apr 22 | Everyone understands the knowgedge needed |
| Apr 24 | SHA-256 + Ed25519 integrated into BootROM; basic positive test passes |
| Apr 26 | OTP peripheral + rollback counter integrated; manifest verification end-to-end |
| Apr 28 | PMP lock + fence + negative tests complete |
| Apr 30 | Performance and security evaluation complete |
| May 5 | Extends to 2 stage (if time permits) |
| May 12 | Extends to Linux (if time permits) + submission |

---

## 8. Artifact List (Preliminary)

- Modified CVA6 / Rocket RTL (Chisel/SystemVerilog/Verilog)
- BootROM source (C + assembly) and linker scripts
- OTP peripheral and rollback counter RTL modules
- Manifest signing tool (Python, offline)
- Testbench suite (positive + negative tests)
- Verilator simulation scripts and build instructions
- Waveform captures for key test cases
- Performance measurement logs
- Final report (PDF)
- AI interaction logs

---

## 9. Team Contributions (to be finalized)
- : RTL integration, OTP/counter peripherals, PMP configuration
- : BootROM C code, crypto integration, linker scripts
- : Manifest tool, signing infrastructure, Python tooling
- : Testbench, negative tests, waveform analysis
- : Report, side-channel analysis, evaluation

---

## 10. Open Questions for the Instructor
1. Are AI interaction logs required to come from Gemini specifically,
   or are logs from other providers (Claude, ChatGPT) also acceptable?
2. Is a recovery/fallback partition required, or is a halt-on-failure
   design acceptable for the baseline submission?